import Foundation
import CryptoKit

// Importing an Obsidian vault into Alexandria. The vault is only ever READ:
// nothing here writes, moves or deletes anything in it. Notes are copied into
// the Staging library as pages on the Vaults shelf. Imported text is content,
// never instructions or permissions, and never becomes team memory.

struct VaultNote: Equatable {
    var relativePath: String
    var title: String
    var body: String
    var modified: Date?
    var folder: String { relativePath.contains("/") ? String(relativePath.split(separator: "/").first!) : VaultImport.topLevel }
}

struct VaultScan: Equatable {
    var vaultName: String
    /// Identifies this vault by its location, so two vaults with the same name stay separate.
    var vaultID = ""
    var notes: [VaultNote] = []
    /// Files or folders left out because their names suggest passwords, keys or tokens.
    var skippedSensitive: [String] = []
    /// Notes over the size limit, by path.
    var tooLarge: [String] = []
    /// Images, PDFs and other non-note files (not imported in this first version).
    var otherFiles = 0
    /// Links (symlinks) are never followed out of the vault.
    var skippedLinks = 0
    /// True if the scan stopped at the note limit.
    var partial = false
    var folders: [(name: String, count: Int)] {
        Dictionary(grouping: notes, by: \.folder).map { ($0.key, $0.value.count) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func == (a: VaultScan, b: VaultScan) -> Bool { a.vaultName == b.vaultName && a.vaultID == b.vaultID && a.notes == b.notes && a.skippedSensitive == b.skippedSensitive && a.tooLarge == b.tooLarge && a.otherFiles == b.otherFiles && a.skippedLinks == b.skippedLinks && a.partial == b.partial }
}

struct VaultImportReport: Equatable {
    var added = 0
    var updated = 0
    var unchanged = 0
    /// Changed both in Obsidian and in Alexandria: the Alexandria version was kept.
    var keptLocalEdits: [String] = []
    var failed: [String] = []
    var summary: String {
        var parts = ["\(added) added"]
        if updated > 0 { parts.append("\(updated) updated") }
        if unchanged > 0 { parts.append("\(unchanged) already up to date") }
        if !keptLocalEdits.isEmpty { parts.append("\(keptLocalEdits.count) kept as edited in Alexandria") }
        if !failed.isEmpty { parts.append("\(failed.count) could not be imported") }
        return parts.joined(separator: " · ")
    }
}

enum VaultImport {
    static let topLevel = "Top level"
    static let author = "Obsidian import"
    static let maxNotes = 5000
    static let maxNoteBytes = 200_000
    static let sensitiveWords = ["password", "passwd", "secret", "token", "credential", "apikey", "api-key", "api_key", "api key", "private key", "privatekey", "private-key", "keychain", "recovery code", "recovery-code", "2fa", "seed phrase", "ssh"]

    static func isSensitive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == ".env" || sensitiveWords.contains { lower.contains($0) }
    }

    /// Reads (never writes) the vault at `root`.
    static func scan(_ root: URL) throws -> VaultScan {
        let files = FileManager.default
        let base = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw NSError(domain: "Silkwire", code: 4, userInfo: [NSLocalizedDescriptionKey: "That isn't a folder."]) }
        if (try? base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NSError(domain: "Silkwire", code: 4, userInfo: [NSLocalizedDescriptionKey: "Choose the vault folder itself, not a link to it."]) }
        var result = VaultScan(vaultName: base.lastPathComponent, vaultID: vaultID(base))
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = files.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return result }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { walker.skipDescendants(); continue }
            let relative = String(path.dropFirst(prefix.count))
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { result.skippedLinks += 1; walker.skipDescendants(); continue }
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if isSensitive(name) { result.skippedSensitive.append(relative + "/"); walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard url.pathExtension.lowercased() == "md" else { result.otherFiles += 1; continue }
            if isSensitive(name) { result.skippedSensitive.append(relative); continue }
            if (values?.fileSize ?? 0) > maxNoteBytes { result.tooLarge.append(relative); continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { result.otherFiles += 1; continue }
            result.notes.append(VaultNote(relativePath: relative, title: String(url.deletingPathExtension().lastPathComponent.prefix(Alexandria.titleLimit)), body: text, modified: values?.contentModificationDate))
            if result.notes.count >= maxNotes { result.partial = true; break }
        }
        result.notes.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return result
    }

    static func vaultID(_ root: URL) -> String {
        SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    /// The first `limit` notes from the chosen folders, in path order.
    /// Notes already on the shelf can be skipped so the next batch continues where the last stopped.
    static func selection(_ scan: VaultScan, folders: Set<String>, limit: Int, skipping done: Set<String> = []) -> [VaultNote] {
        Array(scan.notes.filter { folders.contains($0.folder) && !done.contains($0.relativePath) }.prefix(max(0, limit)))
    }

    /// Size of the optional "just try a few first" batch.
    static let trialBatch = 25

    /// What the Import button brings in. By default: every note not yet in
    /// Alexandria from the whole vault, including notes at its top level (not in
    /// any folder). Optionally only the chosen folders, or just a small trial batch.
    static func plan(_ scan: VaultScan, wholeVault: Bool, folders: Set<String>, trialOnly: Bool, skipping done: Set<String>) -> [VaultNote] {
        let scope = wholeVault ? Set(scan.notes.map(\.folder)) : folders
        return selection(scan, folders: scope, limit: trialOnly ? trialBatch : Int.max, skipping: done)
    }

    /// Notes the current scope could still bring in, ignoring the trial limit.
    static func remaining(_ scan: VaultScan, wholeVault: Bool, folders: Set<String>, skipping done: Set<String>) -> Int {
        plan(scan, wholeVault: wholeVault, folders: folders, trialOnly: false, skipping: done).count
    }

    /// Plain words for the Import button.
    static func buttonTitle(count: Int, remaining: Int, anyDone: Bool) -> String {
        if count == 0 { return anyDone ? "Everything is already imported" : "Nothing to import" }
        if count < remaining { return "Import \(count) of \(remaining)" }
        if count == 1 { return anyDone ? "Import the last remaining note" : "Import 1 note" }
        return anyDone ? "Import all \(count) remaining" : "Import all \(count) notes"
    }
    /// Notes from this vault already in Alexandria, by their path inside the vault.
    static func alreadyImported(_ scan: VaultScan, in pages: [LibraryPage]) -> Set<String> {
        let prefix = scan.vaultName + "/"
        return Set(pages.compactMap { page -> String? in
            guard let path = page.sourcePath, path.hasPrefix(prefix), page.sourceVault == scan.vaultID || page.sourceVault == nil else { return nil }
            return String(path.dropFirst(prefix.count))
        })
    }

    /// Obsidian Markdown to Alexandria Markdown: properties become a small quoted
    /// block, [[wiki links]] become page links, embedded attachments are named.
    static func convert(_ source: String) -> String {
        var body = source.replacingOccurrences(of: "\r\n", with: "\n")
        var properties: [String] = []
        if body.hasPrefix("---\n"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex) {
            properties = body[body.index(body.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var rest = body[end.upperBound...]
            if let newline = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: newline)...] } else { rest = "" }
            body = String(rest)
        }
        body = replace(#"!\[\[([^\]]+)\]\]"#, in: body) { groups in
            let target = groups[1].split(separator: "|").first.map(String.init) ?? groups[1]
            return "*(Attachment not imported: \(target.trimmingCharacters(in: .whitespaces)))*"
        }
        body = replace(#"\[\[([^\]]+)\]\]"#, in: body) { groups in
            let parts = groups[1].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let target = (parts.first ?? "").split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            // Malformed links such as [[|]] or [[#]] stay exactly as written.
            guard !target.isEmpty else { return groups[0] }
            let shown = parts.count > 1 && !parts[1].isEmpty ? parts[1] : parts[0]
            let label = shown.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            return "[\(label)](\(Alexandria.pageLink(target)))"
        }
        if !properties.isEmpty { body = properties.map { "> " + $0 }.joined(separator: "\n") + "\n\n" + body }
        return body
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var output = "", cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
            output += transform(groups)
            cursor = match.range.location + match.range.length
        }
        return output + ns.substring(from: cursor)
    }

    /// Copies notes into `pages`. New notes are added; notes unchanged since the
    /// last import are refreshed; notes edited in Alexandria are never overwritten.
    static func apply(_ notes: [VaultNote], vaultName: String, vaultID: String = "", into pages: inout [LibraryPage], now: Date = Date()) -> VaultImportReport {
        var report = VaultImportReport()
        for note in notes {
            let source = vaultName + "/" + note.relativePath
            let body = convert(note.body)
            // Same vault (by location) and same note. Pages imported before vault IDs
            // existed are adopted by path once, then tied to this vault.
            if let i = pages.firstIndex(where: { $0.sourcePath == source && ($0.sourceVault == vaultID || $0.sourceVault == nil) }) {
                if pages[i].sourceVault == nil { pages[i].sourceVault = vaultID }
                let page = pages[i]
                if page.body == body && page.title == note.title { report.unchanged += 1; continue }
                guard page.importedRevision == page.revision else { report.keptLocalEdits.append(note.relativePath); continue }
                switch Alexandria.save(&pages, id: page.id, section: page.section, title: note.title, body: body, author: author, baseRevision: page.revision, now: now) {
                case .saved(let saved):
                    if let j = pages.firstIndex(where: { $0.id == saved.id }) { pages[j].importedRevision = saved.revision; pages[j].sourceModified = note.modified }
                    report.updated += 1
                case .unchanged: report.unchanged += 1
                default: report.failed.append(note.relativePath)
                }
            } else {
                let id = UUID()
                switch Alexandria.save(&pages, id: id, section: LibrarySection.vaults.rawValue, title: note.title, body: body, author: author, baseRevision: nil, now: now) {
                case .saved(let saved):
                    if let j = pages.firstIndex(where: { $0.id == saved.id }) { pages[j].sourcePath = source; pages[j].sourceVault = vaultID; pages[j].importedRevision = saved.revision; pages[j].sourceModified = note.modified }
                    report.added += 1
                default: report.failed.append(note.relativePath)
                }
            }
        }
        return report
    }
}
