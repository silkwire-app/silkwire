import Foundation
import Combine

struct FutureItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var details = ""
    var completed = false
}

/// The whole Future page: the free text above the first card (heading, North Stars and any
/// other notes) plus the ordered cards. The free text is kept exactly as saved; only its
/// North Stars section changes, and only when someone edits the North Stars on purpose.
struct FuturePage: Equatable {
    var preamble: String
    var items: [FutureItem]
}

/// Readable Markdown is the source of truth, not a second JSON list.
enum FutureMarkdown {
    static let heading = "# Future\n\nPriority is not permission to begin work.\n"
    static let northStarsHeading = "## North Stars"
    /// Offered as a starting point when the page has no North Stars yet. Never written without Jason saving it.
    static let suggestedNorthStars = """
    - Public, open-source beta: come out of stealth.
    - The Mac is Home; iOS is the remote that opens to a lobby of rooms and agents.
    - Every model, every agent, every provider, stated honestly.
    - Voice is part of the longer-term direction.
    - MoM: Mixture of Models.
    """

    /// A card heading such as `## 3. [ ] Title`.
    static func isItemHeading(_ line: String) -> Bool {
        guard line.hasPrefix("## ") else { return false }
        let rest = line.dropFirst(3)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return false }
        return rest.dropFirst(digits.count).hasPrefix(". [")
    }
    static func isMarker(_ line: String) -> Bool { line.hasPrefix("<!-- future-id:") || line.hasPrefix("<!— future-id:") }

    static func encode(_ items: [FutureItem]) throws -> String { try encode(FuturePage(preamble: heading, items: items)) }
    static func encode(_ page: FuturePage) throws -> String {
        let items = page.items
        guard Set(items.map(\.id)).count == items.count,
              !page.preamble.components(separatedBy: "\n").contains(where: { isItemHeading($0) || isMarker($0) }),
              items.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.title.contains("\n") && !$0.details.components(separatedBy: "\n").contains(where: { $0.hasPrefix("## ") || isMarker($0) }) }) else { throw CocoaError(.fileWriteInvalidFileName) }
        var preamble = page.preamble
        if !preamble.isEmpty && !preamble.hasSuffix("\n") { preamble += "\n" }
        return preamble + items.enumerated().map { index, item in
            "\n## \(index + 1). [\(item.completed ? "x" : " ")] \(item.title)\n<!-- future-id:\(item.id.uuidString) -->\n" + item.details + "\n"
        }.joined()
    }
    static func decode(_ body: String) throws -> [FutureItem] { try decodePage(body).items }
    /// Everything before the first card is kept verbatim, so unfamiliar notes are preserved,
    /// never discarded. Cards themselves must be well formed, or nothing is decoded.
    static func decodePage(_ body: String) throws -> FuturePage {
        let lines = body.components(separatedBy: "\n")
        let start = lines.firstIndex(where: isItemHeading) ?? lines.count
        let preamble = lines[..<start].joined(separator: "\n")
        var items: [FutureItem] = [], index = start
        while index < lines.count {
            if lines[index].isEmpty { index += 1; continue }
            let prefix = "## \(items.count + 1). ["
            guard lines[index].hasPrefix(prefix), index + 1 < lines.count else { throw CocoaError(.fileReadCorruptFile) }
            let tail = String(lines[index].dropFirst(prefix.count))
            guard tail.hasPrefix(" ] ") || tail.hasPrefix("x] ") else { throw CocoaError(.fileReadCorruptFile) }
            let title = String(tail.dropFirst(3))
            // macOS smart dashes can alter comment delimiters in Alexandria's editor.
            // Recover only the metadata line; never normalize the user's prose.
            let marker = lines[index + 1]
                .replacingOccurrences(of: "<!— future-id:", with: "<!-- future-id:")
                .replacingOccurrences(of: " —>", with: " -->")
            guard marker.hasPrefix("<!-- future-id:"), marker.hasSuffix(" -->"),
                  let id = UUID(uuidString: String(marker.dropFirst(15).dropLast(4))) else { throw CocoaError(.fileReadCorruptFile) }
            index += 2
            var details: [String] = []
            while index < lines.count && !lines[index].hasPrefix("## ") { details.append(lines[index]); index += 1 }
            // One separator blank line is not part of the editable details.
            if details.last == "" { details.removeLast() }
            items.append(FutureItem(id: id, title: title, details: details.joined(separator: "\n"), completed: tail.hasPrefix("x")))
        }
        let page = FuturePage(preamble: preamble, items: items)
        _ = try encode(page)
        return page
    }
    private static func northStarsRange(_ lines: [String]) -> Range<Int>? {
        guard let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(northStarsHeading) == .orderedSame }) else { return nil }
        let end = lines[(h + 1)...].firstIndex(where: { $0.hasPrefix("# ") || $0.hasPrefix("## ") }) ?? lines.count
        return h..<end
    }
    /// The North Stars section's text, or nil when the page has none.
    static func northStars(in preamble: String) -> String? {
        let lines = preamble.components(separatedBy: "\n")
        guard let range = northStarsRange(lines) else { return nil }
        return lines[(range.lowerBound + 1)..<range.upperBound].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Replaces only the North Stars section; every other line above the cards stays as it was.
    static func replacingNorthStars(in preamble: String, with text: String) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLines = clean.isEmpty ? [] : clean.components(separatedBy: "\n")
        guard !newLines.contains(where: { $0.hasPrefix("# ") || $0.hasPrefix("## ") || isMarker($0) }) else { throw CocoaError(.fileWriteInvalidFileName) }
        let section = [northStarsHeading, ""] + newLines + [""]
        var lines = preamble.components(separatedBy: "\n")
        if let range = northStarsRange(lines) {
            lines.replaceSubrange(range, with: section)
        } else {
            while lines.last == "" { lines.removeLast() }
            if lines.isEmpty { lines = ["# Future", "", "Priority is not permission to begin work."] }
            lines += [""] + section
        }
        return lines.joined(separator: "\n")
    }
}

/// An editor's immutable opening snapshot. Refreshing the list must never advance this revision.
struct FutureEdit: Identifiable {
    let item: FutureItem
    let projectID: UUID
    let pageID: UUID
    let revision: Int
    var id: UUID { item.id }
}

/// The North Stars editor's opening snapshot. A nil page means no Future page existed yet.
struct NorthStarsEdit: Equatable {
    let projectID: UUID
    let pageID: UUID?
    let revision: Int?
    let original: String
}

// Only used to import the first private candidate's data. Never removes its file.
private struct LegacyFuturePlan: Decodable { var version: Int; var projects: [String: [FutureItem]] }

@MainActor final class FutureStore: ObservableObject {
    struct Change: Equatable { var by: String; var at: Date }
    struct Deleted: Equatable { var item: FutureItem; var index: Int }
    @Published private(set) var items: [FutureItem] = []
    @Published private(set) var preamble = FutureMarkdown.heading
    @Published private(set) var northStars: String?
    @Published private(set) var lastChange: Change?
    @Published private(set) var lastDeleted: Deleted?
    @Published private(set) var error: String?
    private weak var conversation: ConversationStore?
    private var projectID: UUID?
    private var pageID: UUID?
    private var revision: Int?
    static let pageTitle = "Future"
    var currentPageID: UUID? { pageID }
    var open: [FutureItem] { items.filter { !$0.completed } }
    var done: [FutureItem] { items.filter(\.completed) }
    func attach(_ store: ConversationStore) {
        if conversation !== store || projectID != store.activeProject?.id { lastDeleted = nil }
        conversation = store
        refresh()
    }
    func refresh() {
        guard let store = conversation else { return }
        if projectID != store.activeProject?.id { lastDeleted = nil }
        projectID = store.activeProject?.id
        let matches = store.libraryPages.filter { $0.title == Self.pageTitle && $0.section == LibrarySection.shared.rawValue }
        guard matches.count <= 1 else { error = "More than one Shared / Future page exists. Resolve the duplicate before editing."; return }
        pageID = matches.first?.id; revision = matches.first?.revision
        lastChange = matches.first.map { Change(by: $0.updatedBy, at: $0.updatedAt) }
        do {
            if let page = matches.first {
                let decoded = try FutureMarkdown.decodePage(page.body)
                items = decoded.items; preamble = decoded.preamble
            } else { items = []; preamble = FutureMarkdown.heading }
            northStars = FutureMarkdown.northStars(in: preamble)
            error = nil
        } catch { self.error = "Future’s cards could not be read. Your page is untouched; open it in Alexandria to fix the card headings." }
    }
    func migrateLegacyIfNeeded() {
        guard let store = conversation, let projectID, pageID == nil, error == nil else { return }
        let file = store.directory.appendingPathComponent("future.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            guard file.resolvingSymlinksInPath() == file.standardizedFileURL else { throw CocoaError(.fileReadNoPermission) }
            let legacy = try JSONDecoder().decode(LegacyFuturePlan.self, from: Data(contentsOf: file))
            guard legacy.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            if let list = legacy.projects[projectID.uuidString] { update(projectID) { $0 = list } }
        } catch { self.error = "The earlier Future list could not be imported. Its file was kept unchanged." }
    }
    /// Saves a new page body against the revision this store last read. Stale saves are refused.
    private func commit(_ project: UUID, preamble newPreamble: String, items candidate: [FutureItem]) -> Bool {
        guard let store = conversation, project == projectID, store.activeProject?.id == project, error == nil else { return false }
        let current = store.libraryPages.filter { $0.title == Self.pageTitle && $0.section == LibrarySection.shared.rawValue }
        guard current.count <= 1, current.first?.id == pageID else {
            refresh(); error = "Future was added or replaced elsewhere. Reload the page before editing."; return false
        }
        do {
            let body = try FutureMarkdown.encode(FuturePage(preamble: newPreamble, items: candidate))
            let result = store.saveLibraryPage(id: pageID ?? UUID(), section: LibrarySection.shared.rawValue, title: Self.pageTitle, body: body, baseRevision: revision)
            switch result {
            case .saved, .unchanged: refresh(); return error == nil
            case .conflict: refresh(); error = "Future changed elsewhere. Your action was not applied. Review the updated list, then try again."; return false
            case .invalid(let message): error = message; return false
            }
        } catch { self.error = "Could not save this. Use a one-line title; text cannot contain a line beginning with ‘## ’ or ‘<!-- future-id:’."; return false }
    }
    func update(_ project: UUID, change: (inout [FutureItem]) -> Void) {
        var candidate = items; change(&candidate)
        _ = commit(project, preamble: preamble, items: candidate)
    }
    /// New items go to the end of the Future section, above anything already done.
    @discardableResult func add(title: String, details: String = "", project: UUID) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = items
        candidate.insert(FutureItem(title: title, details: details), at: candidate.firstIndex(where: \.completed) ?? candidate.count)
        return commit(project, preamble: preamble, items: candidate)
    }
    /// Done items move to Completed; restored ones return to the bottom of Future.
    func setCompleted(_ id: UUID, _ completed: Bool, project: UUID) {
        update(project) { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            var item = list.remove(at: i); item.completed = completed
            if completed { list.append(item) } else { list.insert(item, at: list.firstIndex(where: \.completed) ?? list.count) }
        }
    }
    func delete(_ id: UUID, project: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[i]
        var candidate = items; candidate.remove(at: i)
        if commit(project, preamble: preamble, items: candidate) { lastDeleted = Deleted(item: item, index: i) }
    }
    func undoDelete(project: UUID) {
        guard let deleted = lastDeleted, !items.contains(where: { $0.id == deleted.item.id }) else { lastDeleted = nil; return }
        var candidate = items; candidate.insert(deleted.item, at: min(deleted.index, candidate.count))
        if commit(project, preamble: preamble, items: candidate) { lastDeleted = nil }
    }
    func dismissUndo() { lastDeleted = nil }
    @discardableResult func saveNorthStars(_ text: String, project: UUID) -> Bool {
        do {
            let updated = try FutureMarkdown.replacingNorthStars(in: preamble, with: text)
            return commit(project, preamble: updated, items: items)
        } catch { self.error = "North Stars cannot contain a line beginning with ‘# ’, ‘## ’ or ‘<!-- future-id:’."; return false }
    }
    /// Captures the project, page and revision the North Stars editor opened on.
    func beginNorthStarsEdit() -> NorthStarsEdit? {
        guard let projectID, error == nil, conversation?.activeProject?.id == projectID else { return nil }
        return NorthStarsEdit(projectID: projectID, pageID: pageID, revision: revision, original: northStars ?? "")
    }
    /// Saves North Stars only if nothing changed since the editor opened: same project, same page, same revision.
    /// A refused save leaves the caller's draft untouched so it can be copied or retried.
    @discardableResult func saveNorthStars(_ text: String, basedOn edit: NorthStarsEdit) -> Bool {
        guard let store = conversation, store.activeProject?.id == edit.projectID, projectID == edit.projectID else {
            error = "These North Stars were opened in a different project. Your draft has not been saved."; return false
        }
        let matches = store.libraryPages.filter { $0.title == Self.pageTitle && $0.section == LibrarySection.shared.rawValue }
        guard matches.count <= 1, matches.first?.id == edit.pageID, matches.first?.revision == edit.revision else {
            error = "Future changed after you opened the North Stars. Your draft is still here; review the newer text before saving again."; return false
        }
        if pageID != edit.pageID || revision != edit.revision { refresh() }
        return saveNorthStars(text, project: edit.projectID)
    }
    func beginEdit(_ item: FutureItem) -> FutureEdit? {
        guard let projectID, let pageID, let revision, error == nil, items.contains(item) else { return nil }
        return FutureEdit(item: item, projectID: projectID, pageID: pageID, revision: revision)
    }
    /// Save against the revision seen when the editor opened, not the observer's latest revision.
    @discardableResult func saveEdit(_ item: FutureItem, basedOn edit: FutureEdit) -> Bool {
        guard let store = conversation, store.activeProject?.id == edit.projectID,
              projectID == edit.projectID, item.id == edit.item.id else {
            error = "The editor belongs to a different project. Your draft has not been saved."; return false
        }
        let matches = store.libraryPages.filter { $0.title == Self.pageTitle && $0.section == LibrarySection.shared.rawValue }
        guard matches.count == 1, let page = matches.first, page.id == edit.pageID, page.revision == edit.revision else {
            error = "Future changed after this editor opened. Your draft is still here; review the saved page before trying again."; return false
        }
        do {
            var current = try FutureMarkdown.decodePage(page.body)
            guard let index = current.items.firstIndex(where: { $0.id == edit.item.id }), current.items[index] == edit.item else {
                error = "This item was changed or removed. Your draft has not been saved."; return false
            }
            current.items[index] = item
            let body = try FutureMarkdown.encode(current)
            switch store.saveLibraryPage(id: edit.pageID, section: page.section, title: page.title, body: body, baseRevision: edit.revision) {
            case .saved, .unchanged: refresh(); return error == nil
            case .conflict: error = "Future changed elsewhere. Your draft has not been saved."; return false
            case .invalid(let message): error = message; return false
            }
        } catch {
            self.error = "This item could not be saved. Check the page format and keep your draft before closing."; return false
        }
    }
    /// Moves within its own section (Future or Completed), skipping over the other.
    func move(_ id: UUID, project: UUID, by offset: Int) {
        update(project) { list in
            guard offset != 0, let i = list.firstIndex(where: { $0.id == id }) else { return }
            var j = i + offset
            while list.indices.contains(j) && list[j].completed != list[i].completed { j += offset > 0 ? 1 : -1 }
            guard list.indices.contains(j) else { return }
            list.swapAt(i, j)
        }
    }
}
