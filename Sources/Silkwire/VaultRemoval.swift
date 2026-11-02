import Foundation

// Removing an imported Obsidian vault from a Project's Alexandria.
// Only the imported copies are removed: the vault on disk is never touched,
// pages from other vaults and the team's own pages stay, and a backup of
// everything removed is written first so it can be brought back.

struct ImportedVaultGroup: Identifiable, Equatable {
    /// The vault's identity (its location hash), or its name for older imports.
    let id: String
    let name: String
    let pageIDs: [UUID]
    /// Titles of pages changed in Alexandria since they were imported.
    let editedTitles: [String]
}

extension Alexandria {
    static func vaultName(of page: LibraryPage) -> String {
        guard let path = page.sourcePath, let first = path.split(separator: "/").first else { return "Imported notes" }
        return String(first)
    }
    static func vaultKey(of page: LibraryPage) -> String? {
        guard page.sourcePath != nil else { return nil }
        if let id = page.sourceVault, !id.isEmpty { return id }
        return "name:" + vaultName(of: page)
    }
    /// Imported vaults on this Project's shelf, by name.
    static func importedVaults(_ pages: [LibraryPage]) -> [ImportedVaultGroup] {
        var order: [String] = [], groups: [String: [LibraryPage]] = [:]
        for page in pages { guard let key = vaultKey(of: page) else { continue }; if groups[key] == nil { order.append(key) }; groups[key, default: []].append(page) }
        return order.map { key in
            let list = groups[key] ?? []
            let edited = list.filter { page in page.importedRevision.map { page.revision != $0 } ?? false }.map(\.title).sorted()
            return ImportedVaultGroup(id: key, name: list.first.map(vaultName) ?? "Imported notes", pageIDs: list.map(\.id), editedTitles: edited)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// The folder a vault page came from, without the vault name or file name.
    static func folder(of page: LibraryPage) -> String {
        guard let path = page.sourcePath else { return "" }
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return "" }
        parts.removeFirst(); parts.removeLast()
        return parts.joined(separator: " › ")
    }
    /// Contents for the reader's sidebar: top-level pages first, then each folder, titles in natural order.
    static func contentsGroups(_ pages: [LibraryPage]) -> [(folder: String, pages: [LibraryPage])] {
        let grouped = Dictionary(grouping: pages, by: folder(of:))
        let keys = grouped.keys.sorted { a, b in a.isEmpty != b.isEmpty ? a.isEmpty : a.localizedStandardCompare(b) == .orderedAscending }
        return keys.map { key in (key, (grouped[key] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) }
    }
    /// Splits the library into what stays and the vault's imported pages.
    static func removingVault(_ key: String, from pages: [LibraryPage]) -> (kept: [LibraryPage], removed: [LibraryPage]) {
        var kept: [LibraryPage] = [], removed: [LibraryPage] = []
        for page in pages { if vaultKey(of: page) == key { removed.append(page) } else { kept.append(page) } }
        return (kept, removed)
    }
}

extension ConversationStore {
    /// Removes one imported vault's pages from the open Project's Alexandria.
    /// Writes a backup of the removed pages first; if that fails, nothing changes.
    /// Returns the number removed, or an error message.
    func removeImportedVault(_ key: String) -> Result<Int, VaultRemovalError> {
        guard storageError == nil, let projectID = conversation.projectID, let p = projects.firstIndex(where: { $0.id == projectID }) else { return .failure(.message("Open a Project first.")) }
        let before = projects[p].library ?? []
        let split = Alexandria.removingVault(key, from: before)
        guard !split.removed.isEmpty else { return .success(0) }
        let folder = directory.appendingPathComponent("Removed Pages", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = Alexandria.vaultName(of: split.removed[0]).filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(split.removed).write(to: folder.appendingPathComponent("\(stamp) \(name.isEmpty ? "Vault" : name).json"), options: .atomic)
        } catch { return .failure(.message("Couldn't save a backup first, so nothing was removed.")) }
        guard commitLibrary(split.kept, at: p) else { return .failure(.message("Couldn't save the library, so nothing was removed.")) }
        return .success(split.removed.count)
    }
}

enum VaultRemovalError: Error, Equatable { case message(String) }
