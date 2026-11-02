import Foundation

// Alexandria: the team's shared library. Pages are Markdown, saved inside the
// Project with a full revision history. Sections are organizational homes,
// never private: everyone on the team can read and edit every page.

enum LibrarySection: String, CaseIterable, Codable, Identifiable {
    case home, shared, jason, eve, claude, codex, reviewDesign, reviewSecurity, reviewCode, vaults
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .shared: return "Shared"
        case .jason: return "Jason"
        case .eve: return "Eve"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .reviewDesign: return "Design"
        case .reviewSecurity: return "Security"
        case .reviewCode: return "Code"
        case .vaults: return "Vaults"
        }
    }
    /// Section name with its group, for result lists and breadcrumbs.
    var fullTitle: String { isOutsideReview ? "Outside Reviews › " + title : title }
    var isPersonHome: Bool { [.jason, .eve, .claude, .codex].contains(self) }
    var isOutsideReview: Bool { [.reviewDesign, .reviewSecurity, .reviewCode].contains(self) }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .shared: return "square.stack"
        case .jason, .eve, .claude, .codex: return "person"
        case .reviewDesign: return "paintbrush"
        case .reviewSecurity: return "lock.shield"
        case .reviewCode: return "chevron.left.forwardslash.chevron.right"
        case .vaults: return "archivebox"
        }
    }
    var blurb: String {
        switch self {
        case .home: return "Start here."
        case .shared: return "Pages the whole team owns together: plans, decisions, how-tos."
        case .jason, .eve, .claude, .codex: return "\(title)'s home shelf: where \(title) keeps their notes and drafts. It is an organizational home, not a private one. Everyone can read and edit it."
        case .reviewDesign: return "Design reports from outside reviewers (other agents and models), kept as they were received."
        case .reviewSecurity: return "Security reports from outside reviewers (other agents and models), kept as they were received."
        case .reviewCode: return "Code reports from outside reviewers (other agents and models), kept as they were received."
        case .vaults: return "Notes imported from Obsidian vaults. The originals are only read, never changed; importing again brings in newer versions without overwriting edits made here."
        }
    }
}

struct LibraryRevision: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var section: String
    var author: String
    var savedAt: Date
    var revision: Int
}

struct LibraryPage: Codable, Identifiable, Equatable {
    var id = UUID()
    var section: String
    var title: String
    var body: String
    var createdBy: String
    var createdAt: Date
    var updatedBy: String
    var updatedAt: Date
    /// Increments on every save; used to refuse silent overwrites.
    var revision: Int
    /// Earlier versions, oldest first. The current text is not repeated here.
    var history: [LibraryRevision]
    /// Imported pages: where the note came from (vault name/relative path), the
    /// revision the import wrote, and the source file's modification date.
    var sourcePath: String? = nil
    var sourceVault: String? = nil
    var importedRevision: Int? = nil
    var sourceModified: Date? = nil
    var librarySection: LibrarySection { LibrarySection(rawValue: section) ?? .shared }
}

enum LibrarySaveResult: Equatable {
    case saved(LibraryPage)
    case unchanged
    /// Someone else saved first. Nothing was written; the editor's text is kept.
    case conflict(LibraryPage)
    case invalid(String)
}

struct LibraryHit: Identifiable, Equatable {
    var pageID: UUID
    var title: String
    var section: LibrarySection
    var excerpt: String
    var titleMatch: Bool
    var id: UUID { pageID }
}

struct ConversationSearchHit: Identifiable, Equatable {
    var conversationID: UUID
    var title: String
    var archived: Bool
    var matches: Int
    var excerpt: String
    var id: UUID { conversationID }
}

enum Alexandria {
    static let name = "Alexandria"
    static let linkScheme = "alexandria"
    /// A link to another Alexandria page by title, e.g. from an Obsidian [[wiki link]].
    static func pageLink(_ title: String) -> String {
        var parts = URLComponents(); parts.scheme = linkScheme; parts.host = "page"; parts.queryItems = [URLQueryItem(name: "title", value: title)]
        return parts.url?.absoluteString ?? ""
    }
    static func linkedTitle(_ url: URL) -> String? {
        guard url.scheme == linkScheme, url.host == "page" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "title" }?.value
    }
    /// Finds the page a link names: exact title first, then an imported note's file name.
    static func page(titled target: String, in pages: [LibraryPage]) -> LibraryPage? {
        let name = (target as NSString).lastPathComponent
        return pages.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            ?? pages.first { ($0.sourcePath as NSString?)?.lastPathComponent.caseInsensitiveCompare(name + ".md") == .orderedSame }
    }
    static let historyLimit = 50
    static let titleLimit = 120
    static let bodyLimit = 200_000
    static let notPrivate = "Sections are organizational homes, not private spaces. Jason, Eve, Claude and Codex can all read and edit every page, and earlier versions (the latest 50) are kept in History."
    static let notMemory = "Saving a page keeps it in the library. It does not add it to team memory."

    static func save(_ pages: inout [LibraryPage], id: UUID, section: String, title: String, body: String, author: String, baseRevision: Int?, now: Date = Date()) -> LibrarySaveResult {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return .invalid("Give the page a title first.") }
        guard cleanTitle.utf16.count <= titleLimit else { return .invalid("That title is too long (\(titleLimit) characters at most).") }
        guard body.utf16.count <= bodyLimit else { return .invalid("That page is too long to save (\(bodyLimit / 1000)k characters at most).") }
        guard let target = LibrarySection(rawValue: section), target != .home else { return .invalid("Choose a section for this page.") }
        if let i = pages.firstIndex(where: { $0.id == id }) {
            var page = pages[i]
            guard baseRevision == page.revision else { return .conflict(page) }
            if page.title == cleanTitle && page.body == body && page.section == target.rawValue { return .unchanged }
            page.history.append(LibraryRevision(title: page.title, body: page.body, section: page.section, author: page.updatedBy, savedAt: page.updatedAt, revision: page.revision))
            if page.history.count > historyLimit { page.history.removeFirst(page.history.count - historyLimit) }
            page.title = cleanTitle; page.body = body; page.section = target.rawValue
            page.updatedBy = author; page.updatedAt = now; page.revision += 1
            pages[i] = page
            return .saved(page)
        }
        guard baseRevision == nil else { return .invalid("This page is no longer in the library. Copy your text before closing.") }
        let page = LibraryPage(id: id, section: target.rawValue, title: cleanTitle, body: body, createdBy: author, createdAt: now, updatedBy: author, updatedAt: now, revision: 1, history: [])
        pages.append(page)
        return .saved(page)
    }

    static func pages(_ pages: [LibraryPage], in section: LibrarySection) -> [LibraryPage] {
        section == .vaults ? pages.filter { $0.librarySection == section }.sorted { ($0.sourcePath ?? $0.title).localizedStandardCompare($1.sourcePath ?? $1.title) == .orderedAscending } : pages.filter { $0.librarySection == section }.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func search(_ pages: [LibraryPage], query: String, limit: Int = 20) -> [LibraryHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let hits: [LibraryHit] = pages.compactMap { page in
            let inTitle = contains(page.title, q), inBody = contains(page.body, q)
            guard inTitle || inBody else { return nil }
            return LibraryHit(pageID: page.id, title: page.title, section: page.librarySection, excerpt: inBody ? excerpt(page.body, query: q) : firstLine(page.body), titleMatch: inTitle)
        }
        let order = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.updatedAt) })
        return Array(hits.sorted { a, b in a.titleMatch != b.titleMatch ? a.titleMatch : (order[a.pageID] ?? .distantPast) > (order[b.pageID] ?? .distantPast) }.prefix(limit))
    }

    static func conversations(_ rooms: [Conversation], query: String, excluding: UUID? = nil, limit: Int = 25) -> [ConversationSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return Array(rooms.filter { $0.id != excluding }.sorted { $0.updatedAt > $1.updatedAt }.compactMap { room in
            let matching = room.messages.filter { contains($0.text, q) }
            let inTitle = contains(room.title, q)
            guard inTitle || !matching.isEmpty else { return nil }
            return ConversationSearchHit(conversationID: room.id, title: room.title, archived: room.archived, matches: matching.count, excerpt: matching.first.map { "\($0.author): " + excerpt($0.text, query: q) } ?? "Title match")
        }.prefix(limit))
    }

    static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// A one-line window of text around the first match, with ellipses where clipped.
    static func excerpt(_ text: String, query: String, radius: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        guard let match = flat.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return firstLine(text) }
        let start = flat.index(match.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(match.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        let core = flat[start..<end].trimmingCharacters(in: .whitespaces)
        return (start > flat.startIndex ? "…" : "") + core + (end < flat.endIndex ? "…" : "")
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}
