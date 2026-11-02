import Foundation
import CryptoKit

// Obsidian import: reads a synthetic vault, never changes it, converts links,
// skips sensitive files and links, and re-imports without overwriting edits.
@main struct VaultImportTests {
    static func main() throws {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ label: String) { checks += 1; if ok { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) } }
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("output/vault-fixture-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("Silkwire Vault")
        defer { try? files.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = vault.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("Projects/Plan.md", "---\ntags: [silkwire, plan]\nstatus: draft\n---\n# The plan\nSee [[Ideas|my ideas]] and [[Projects/Roadmap#Q4]].\n![[sketch.png]]\n")
        try write("Projects/Roadmap.md", "Q4: Alexandria.")
        try write("Ideas.md", "A spider who reads.")
        try write(".obsidian/app.json", "{}")
        try write("Secrets/bank.md", "nope")
        try write("api-token.md", "nope")
        try write("sketch.png", "not really a png")
        try write("Huge.md", String(repeating: "x", count: VaultImport.maxNoteBytes + 10))
        try "outside".write(to: root.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        try files.createSymbolicLink(at: vault.appendingPathComponent("Escape.md"), withDestinationURL: root.appendingPathComponent("outside.md"))

        func fingerprint() throws -> String {
            let items = (files.enumerator(atPath: vault.path)?.allObjects as? [String] ?? []).sorted()
            var hasher = SHA256()
            for item in items {
                hasher.update(data: Data(item.utf8))
                let url = vault.appendingPathComponent(item)
                if (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))?.isSymbolicLink != true, let data = files.contents(atPath: url.path) { hasher.update(data: data) }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let before = try fingerprint()

        let scan = try VaultImport.scan(vault)
        check(scan.vaultName == "Silkwire Vault", "the vault is named after its folder")
        check(scan.notes.map(\.relativePath) == ["Ideas.md", "Projects/Plan.md", "Projects/Roadmap.md"], "only real notes are found, in path order")
        check(scan.skippedSensitive.contains("api-token.md") && !scan.notes.contains { $0.relativePath.hasPrefix("Secrets") } && scan.skippedSensitive.contains("Secrets/"), "files and folders named like secrets or tokens are left out and listed")
        check(!scan.notes.contains { $0.relativePath.hasPrefix(".obsidian") }, "Obsidian's hidden settings folder is ignored")
        check(scan.skippedLinks == 1 && !scan.notes.contains { $0.relativePath == "Escape.md" }, "links pointing outside the vault are never followed")
        check(scan.tooLarge == ["Huge.md"] && scan.otherFiles == 1, "oversized notes and attachments are counted, not imported")
        check(scan.folders.map(\.name) == ["Projects", VaultImport.topLevel] || scan.folders.map(\.name) == [VaultImport.topLevel, "Projects"], "notes are grouped by top folder for choosing")
        check(VaultImport.selection(scan, folders: ["Projects"], limit: 1).map(\.relativePath) == ["Projects/Plan.md"], "a small batch takes only the chosen folders, up to the limit")

        let converted = VaultImport.convert("---\ntags: [a]\n---\nSee [[Ideas|my ideas]], [[Projects/Roadmap#Q4]] and [[]].\n![[sketch.png|200]]")
        check(converted.hasPrefix("> tags: [a]\n\n"), "note properties become a small quoted block")
        check(converted.contains("[my ideas](alexandria://page?title=Ideas)") && converted.contains("[Projects/Roadmap#Q4](alexandria://page?title=Projects/Roadmap)"), "wiki links become Alexandria page links, keeping their labels")
        check(converted.contains("*(Attachment not imported: sketch.png)*"), "embedded attachments are named, not silently dropped")
        check(Alexandria.linkedTitle(URL(string: Alexandria.pageLink("My Note & More"))!) == "My Note & More", "page links round-trip titles with spaces and symbols")

        var pages: [LibraryPage] = []
        let first = VaultImport.apply(scan.notes, vaultName: scan.vaultName, into: &pages)
        check(first.added == 3 && pages.allSatisfy { $0.librarySection == .vaults && $0.sourcePath?.hasPrefix("Silkwire Vault/") == true && $0.updatedBy == VaultImport.author }, "notes arrive on the Vaults shelf with their source path")
        check(Alexandria.page(titled: "Projects/Roadmap", in: pages)?.title == "Roadmap", "a link to a note in a folder finds the imported page")
        check(VaultImport.apply(scan.notes, vaultName: scan.vaultName, into: &pages) == VaultImportReport(unchanged: 3), "importing again changes nothing when nothing changed")

        var newer = scan.notes; newer[0].body = "A spider who reads, and writes."
        let refreshed = VaultImport.apply(newer, vaultName: scan.vaultName, into: &pages)
        let ideas = pages.first { $0.title == "Ideas" }!
        check(refreshed.updated == 1 && ideas.body == "A spider who reads, and writes." && ideas.history.count == 1, "a note changed in Obsidian refreshes its untouched page, keeping the old version in History")

        _ = Alexandria.save(&pages, id: ideas.id, section: ideas.section, title: ideas.title, body: "Edited in Alexandria", author: "Jason", baseRevision: ideas.revision)
        newer[0].body = "Changed again in Obsidian"
        let guarded = VaultImport.apply(newer, vaultName: scan.vaultName, into: &pages)
        check(guarded.keptLocalEdits == ["Ideas.md"] && pages.first { $0.id == ideas.id }?.body == "Edited in Alexandria", "edits made in Alexandria are never overwritten by a re-import")

        // Codex's review: malformed links never crash, and same-named vaults stay apart.
        let odd = VaultImport.convert("a [[|]] b [[#]] c [[ | x]] d [[Note|]]")
        check(odd.contains("[[|]]") && odd.contains("[[#]]") && odd.contains("[[ | x]]") && odd.contains("[Note](alexandria://page?title=Note)"), "malformed links stay as written instead of crashing")
        var twins: [LibraryPage] = []
        _ = VaultImport.apply([VaultNote(relativePath: "Plan.md", title: "Plan", body: "Home vault", modified: nil)], vaultName: "Notes", vaultID: "aaa", into: &twins)
        let other = VaultImport.apply([VaultNote(relativePath: "Plan.md", title: "Plan", body: "Work vault", modified: nil)], vaultName: "Notes", vaultID: "bbb", into: &twins)
        check(other.added == 1 && twins.count == 2 && Set(twins.map { $0.body }) == ["Home vault", "Work vault"], "two vaults with the same name never overwrite each other")
        check(VaultImport.vaultID(vault) != VaultImport.vaultID(root) && scan.vaultID == VaultImport.vaultID(vault), "each vault is identified by its location")

        check(try fingerprint() == before, "the vault on disk is byte-for-byte unchanged")
        // Continuing an import skips notes already in Alexandria.
        var resumeScan = VaultScan(vaultName: "Resume", vaultID: "rv")
        resumeScan.notes = (1...5).map { VaultNote(relativePath: "Folder/n\($0).md", title: "n\($0)", body: "b", modified: nil) }
        var resumePages: [LibraryPage] = []
        _ = VaultImport.apply(Array(resumeScan.notes.prefix(2)), vaultName: "Resume", vaultID: "rv", into: &resumePages)
        let resumeDone = VaultImport.alreadyImported(resumeScan, in: resumePages)
        let resumeNext = VaultImport.selection(resumeScan, folders: ["Folder"], limit: 2, skipping: resumeDone)
        check(resumeDone == ["Folder/n1.md", "Folder/n2.md"] && resumeNext.map(\.relativePath) == ["Folder/n3.md", "Folder/n4.md"], "the next batch continues after the notes already imported")
        print("VaultImportTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
