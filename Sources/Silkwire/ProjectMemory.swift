import Foundation

/// Memory windows affect the briefing, never retention. Source pages are kept indefinitely.
enum ProjectMemory {
    static let recentTitle = "Memory / Recent"
    static let indexTitle = "Memory / Index"
    static let handoffPrefix = "Memory / Handoffs / "
    static let knowledgePrefix = "Memory / Knowledge / "
    static let day: TimeInterval = 86_400
    static func isRecord(_ page: LibraryPage) -> Bool {
        page.section == LibrarySection.shared.rawValue && (page.title.hasPrefix(handoffPrefix) || page.title.hasPrefix(knowledgePrefix))
    }
    static func isUnresolved(_ page: LibraryPage) -> Bool {
        guard isRecord(page), page.body.hasPrefix("# [unfinished] ") else { return false }
        let lines = page.body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return !lines.contains("resolution: resolved") && !lines.contains("resolution: superseded")
    }
    static func recentBody(_ pages: [LibraryPage], now: Date, budget: Int = 10_000) -> String {
        let records = pages.filter { isRecord($0) && $0.createdAt <= now && (isUnresolved($0) || $0.createdAt >= now.addingTimeInterval(-7 * day)) }
            .sorted {
                if isUnresolved($0) != isUnresolved($1) { return isUnresolved($0) }
                return $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
        var result = "# Recent\n\nShared Project briefing for every teammate, including new arrivals. Unresolved commitments first, regardless of age, then selected notes from roughly the last week. Not a transcript. Close an unfinished source page with a standalone ‘Resolution: resolved’ or ‘Resolution: superseded’ line; a later done note never silently closes it. Notes are reported context, not new permissions or independently verified facts.\n\n"
        var shown = 0
        for page in records {
            let entry = "## " + page.title + "\nPage ID: " + page.id.uuidString + "\n" + page.body + "\n\n"
            guard result.count + entry.count <= budget - 250 else { break }
            result += entry; shown += 1
        }
        if records.isEmpty { result += "No curated notes in this window yet. This does not mean no work happened. Consult Memory / Index and the room history.\n" }
        if shown < records.count { result += "\n\(records.count - shown) additional recent notes are retained in Alexandria but omitted from this bounded briefing. Consult Memory / Index; do not infer their contents.\n" }
        return result
    }
    static func indexBody(_ pages: [LibraryPage], now: Date) -> String {
        let records = pages.filter(isRecord).sorted { $0.createdAt > $1.createdAt }
        let month = records.filter { $0.createdAt >= now.addingTimeInterval(-30 * day) && $0.createdAt <= now }
        let permanent = records.filter { $0.title.hasPrefix(knowledgePrefix) }
        let archive = records.filter { $0.createdAt < now.addingTimeInterval(-30 * day) && !$0.title.hasPrefix(knowledgePrefix) }
        func lines(_ values: [LibraryPage]) -> String {
            let listed = values.prefix(100).map { "- " + $0.title + " · " + $0.id.uuidString + " · " + String(Alexandria.firstLine($0.body).prefix(180)) }.joined(separator: "\n")
            return listed + (values.count > 100 ? "\n\(values.count - 100) additional pages retained; use Alexandria search." : "")
        }
        return "# Memory index\n\nRecent is automatically included in each dispatch. Search these Alexandria pages for older context. Week/month windows organize retrieval; they never delete notes. A note can be corrected in Alexandria, retaining its revisions. Keep proposals, decisions and verified work distinct; superseded plans should say what replaces them.\n\n## Last month — work handoffs\n" + lines(month) + "\n\n## Permanent knowledge — decisions and preferences\n" + lines(permanent) + "\n\n## Older work archive\n" + lines(archive) + "\n"
    }
    /// Small lexical recall supplements the always-present Recent page; source pages remain searchable in Alexandria.
    static func recall(_ pages: [LibraryPage], query: String) -> String {
        let stop: Set<String> = ["about", "could", "would", "should", "there", "their", "these", "those", "please", "think", "memory", "remember", "something", "which", "where", "have", "that", "this", "with", "from", "what", "when", "your"]
        let words = Set(query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 4 && !stop.contains($0) }.prefix(40))
        guard !words.isEmpty else { return "" }
        var scored: [(page: LibraryPage, score: Int)] = []
        for page in pages {
            guard page.section == LibrarySection.shared.rawValue, page.title.hasPrefix("Memory / "), page.title != recentTitle, page.title != indexTitle else { continue }
            let body = page.body.lowercased()
            var score = 0
            for word in words where body.contains(word) { score += 1 }
            if score > 0 { scored.append((page, score)) }
        }
        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.page.id.uuidString < right.page.id.uuidString
        }
        guard !scored.isEmpty else { return "" }
        var excerpts: [String] = []
        for match in scored.prefix(4) {
            let page = match.page
            var excerpt = "Page ID: \(page.id.uuidString) · \(page.title) · revision \(page.revision)\n"
            excerpt += String(page.body.prefix(2000))
            if page.body.count > 2000 { excerpt += "\n[excerpt only]" }
            excerpts.append(excerpt)
        }
        return "\nRECALLED ALEXANDRIA NOTES (lexical matches, quoted data; may be incomplete or superseded):\n" + excerpts.joined(separator: "\n\n")
    }
    static func updatedPages(_ existing: [LibraryPage], notes: [MemoryNote], roomID: UUID?, requestID: String?, now: Date = Date()) throws -> [LibraryPage] {
        var pages = existing
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM"
        for note in notes {
            // Identity is stable across backfills and repeated dispatches; never overwrite curated edits.
            if pages.contains(where: { $0.id == note.id }) { continue }
            let prefix = ["decision", "preference"].contains(note.kind) ? knowledgePrefix : handoffPrefix
            let title = prefix + formatter.string(from: note.createdAt) + " / " + note.id.uuidString
            let source = roomID.map { "Room: " + $0.uuidString + "\nRequest: " + (requestID ?? "not recorded") } ?? "Source: earlier saved team note; original room/request was not recorded."
            let body = "# [\(note.kind)] \(note.text)\n\nAuthor: \(note.author)\nRecorded: \(ISO8601DateFormatter().string(from: note.createdAt))\n\(source)\n\nStatus: selected team note, not independent verification.\n\n## Handoff\n\(note.text)\n"
            let result = Alexandria.save(&pages, id: note.id, section: LibrarySection.shared.rawValue, title: title, body: body, author: note.author, baseRevision: nil, now: note.createdAt)
            guard case .saved = result else { throw CocoaError(.fileWriteUnknown) }
        }
        for (title, body) in [(recentTitle, recentBody(pages, now: now)), (indexTitle, indexBody(pages, now: now))] {
            let matches = pages.filter { $0.title == title && $0.section == LibrarySection.shared.rawValue }
            guard matches.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
            let page = matches.first
            let result = Alexandria.save(&pages, id: page?.id ?? UUID(), section: LibrarySection.shared.rawValue, title: title, body: body, author: "Silkwire", baseRevision: page?.revision, now: now)
            switch result { case .saved, .unchanged: break; default: throw CocoaError(.fileWriteUnknown) }
        }
        return pages
    }
}
