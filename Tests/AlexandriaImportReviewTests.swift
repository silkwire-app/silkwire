import Foundation
import CryptoKit
import Darwin

// Independent continuation review. Every file is synthetic and stays inside
// this private worktree's ignored output; no user vault or library is opened.
@main struct AlexandriaImportReviewTests {
    static func main() {
        do { try run() }
        catch { print("FAIL Alexandria import review: \(error)"); exit(1) }
    }

    static func run() throws {
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath)
            .appendingPathComponent("output/tests/ImportReview-" + UUID().uuidString)
        let vault = root.appendingPathComponent("Synthetic Collaboration")
        try files.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else {
                throw NSError(domain: "AlexandriaImportReview", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: label])
            }
            checks += 1; print("PASS " + label)
        }
        func write(_ path: String, _ text: String) throws {
            let url = vault.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        func fingerprint() throws -> String {
            let paths = (files.enumerator(atPath: vault.path)?.allObjects as? [String] ?? []).sorted()
            var digest = SHA256()
            for path in paths {
                digest.update(data: Data(path.utf8))
                let url = vault.appendingPathComponent(path)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true { digest.update(data: try Data(contentsOf: url)) }
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        for i in 1...150 {
            try write(String(format: "Projects/Notes/Note%03d.md", i), "Synthetic note \(i).")
        }
        for path in ["AGENTS.md", "Projects/AGENTS.md", "Other/AGENTS.md"] {
            try write(path, "Different source identity: " + path)
        }
        let before = try fingerprint()
        var scan = try VaultImport.scan(vault)
        try check(scan.notes.count == 153 && !scan.partial, "153-note synthetic vault is fully scanned")
        let folders = Set(scan.folders.map(\.name))
        var pages: [LibraryPage] = []
        let first = VaultImport.selection(scan, folders: folders, limit: 25)
        let firstReport = VaultImport.apply(first, vaultName: scan.vaultName, vaultID: scan.vaultID, into: &pages)
        try check(first.count == 25 && firstReport.added == 25, "first batch imports exactly 25 notes")
        let initialIDs = Set(pages.map(\.id))
        let ordinaryPages = pages.filter { $0.title != "AGENTS" }
        let local = ordinaryPages[0], untouched = ordinaryPages[1]
        let localSource = local.sourcePath!
        let localTitle = "My renamed page"
        let localBody = "Jason's synthetic edit must survive every later batch."
        guard case .saved = Alexandria.save(&pages, id: local.id, section: local.section,
            title: localTitle, body: localBody, author: "Jason", baseRevision: local.revision) else {
            throw NSError(domain: "AlexandriaImportReview", code: 2)
        }
        let editedSnapshot = pages.first { $0.id == local.id }!
        let prefix = scan.vaultName + "/"
        let changedPaths = [String(localSource.dropFirst(prefix.count)),
                            String(untouched.sourcePath!.dropFirst(prefix.count))]
        for path in changedPaths {
            let i = scan.notes.firstIndex { $0.relativePath == path }!
            scan.notes[i].body = "Changed synthetic source: " + path
        }
        var seen = Set(first.map(\.relativePath))
        var batchSizes = [first.count]
        for _ in 0..<10 {
            // Recreate the persisted model between batches, without retaining a cursor.
            pages = try JSONDecoder().decode([LibraryPage].self, from: JSONEncoder().encode(pages))
            let done = VaultImport.alreadyImported(scan, in: pages)
            let batch = VaultImport.selection(scan, folders: folders, limit: 25, skipping: done)
            if batch.isEmpty { break }
            try check(Set(batch.map(\.relativePath)).isDisjoint(with: seen),
                "continuation batch \(batchSizes.count + 1) never repeats a prior source path")
            let report = VaultImport.apply(batch, vaultName: scan.vaultName, vaultID: scan.vaultID, into: &pages)
            try check(report.added == batch.count && report.failed.isEmpty,
                "continuation batch \(batchSizes.count + 1) imports every selected note")
            seen.formUnion(batch.map(\.relativePath)); batchSizes.append(batch.count)
        }
        try check(batchSizes == [25, 25, 25, 25, 25, 25, 3], "153 notes finish in six batches of 25 and one of three")
        try check(pages.count == 153 && Set(pages.map(\.id)).count == 153 && seen.count == 153,
            "complete import has one distinct page per source note")
        try check(initialIDs.isSubset(of: Set(pages.map(\.id))), "later batches preserve every first-batch page identity")
        try check(pages.first { $0.id == local.id } == editedSnapshot,
            "renamed and edited page remains byte-for-byte identical throughout continuation")
        let done = VaultImport.alreadyImported(scan, in: pages)
        try check(done.count == 153 && done.contains(changedPaths[0]),
            "continuation recognizes edited pages by source path, not display title")
        try check(VaultImport.selection(scan, folders: folders, limit: 500, skipping: done).isEmpty,
            "completed vault has no more notes to continue importing")
        let duplicates = pages.filter { $0.title == "AGENTS" }
        try check(duplicates.count == 3 && Set(duplicates.map(\.id)).count == 3 &&
            Set(duplicates.compactMap(\.sourcePath)).count == 3,
            "identical filenames in three folders remain separate page identities")
        try check(duplicates.allSatisfy { $0.body.contains(String($0.sourcePath!.dropFirst(prefix.count))) },
            "duplicate-title pages retain the body belonging to their own source path")
        // Turning off 'skip already imported' must refresh untouched pages only.
        let refresh = VaultImport.selection(scan, folders: folders, limit: 500)
        let report = VaultImport.apply(refresh, vaultName: scan.vaultName, vaultID: scan.vaultID, into: &pages)
        try check(report.added == 0 && report.updated == 1 && report.unchanged == 151 &&
            report.keptLocalEdits == [changedPaths[0]] && report.failed.isEmpty,
            "explicit refresh updates only untouched changed notes and reports the protected edit")
        try check(pages.first { $0.id == local.id } == editedSnapshot,
            "explicit refresh does not alter the edited page or its history")
        let updated = pages.first { $0.id == untouched.id }!
        try check(updated.revision == untouched.revision + 1 && updated.history.last?.body == untouched.body &&
            updated.importedRevision == updated.revision,
            "source refresh preserves the prior body in History and advances the import revision")
        let identities = Set(pages.map(\.id))
        let again = VaultImport.apply(refresh, vaultName: scan.vaultName, vaultID: scan.vaultID, into: &pages)
        try check(again.added == 0 && again.updated == 0 && again.keptLocalEdits == [changedPaths[0]] &&
            Set(pages.map(\.id)) == identities, "repeated refresh creates neither duplicate pages nor extra versions")
        var otherVault = scan; otherVault.vaultID = "different-vault-location"
        try check(VaultImport.alreadyImported(otherVault, in: pages).isEmpty,
            "another vault with the same display name inherits no continuation progress")
        let otherBatch = VaultImport.selection(otherVault, folders: folders, limit: 25,
            skipping: VaultImport.alreadyImported(otherVault, in: pages))
        let otherReport = VaultImport.apply(otherBatch, vaultName: otherVault.vaultName,
            vaultID: otherVault.vaultID, into: &pages)
        try check(otherReport.added == 25 && pages.count == 178 && identities.isSubset(of: Set(pages.map(\.id))),
            "same-name second vault adds separate pages without replacing first-vault identities")
        try check(VaultImport.alreadyImported(scan, in: pages).count == 153 &&
            VaultImport.alreadyImported(otherVault, in: pages).count == 25,
            "continuation progress stays independent for same-name vaults")
        var changedSelection = Set<String>(); changedSelection.insert("Projects")
        let projectsOnly = VaultImport.selection(otherVault, folders: changedSelection, limit: 500,
            skipping: VaultImport.alreadyImported(otherVault, in: pages))
        try check(projectsOnly.allSatisfy { $0.folder == "Projects" } &&
            Set(projectsOnly.map(\.relativePath)).isDisjoint(with: Set(otherBatch.map(\.relativePath))),
            "changing folder selection still excludes already-imported paths")
        try check(VaultImport.selection(scan, folders: [], limit: 25).isEmpty &&
            VaultImport.selection(scan, folders: folders, limit: 0).isEmpty &&
            VaultImport.selection(scan, folders: folders, limit: -1).isEmpty,
            "empty folder selection and nonpositive batch sizes import nothing")
        try check(try fingerprint() == before, "scanning and every import leave all synthetic vault files unchanged")
        print("PASS \(checks) independent Alexandria import review checks; synthetic data only")
    }
}
