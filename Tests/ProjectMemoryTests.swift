import Foundation

@main struct ProjectMemoryTests {
    @MainActor static func main() throws {
        func check(_ value: Bool, _ label: String) { guard value else { fatalError("FAIL: " + label) }; print("PASS: " + label) }
        let now = Date(timeIntervalSince1970: 1_793_275_200)
        let room = UUID()
        let recent = MemoryNote(kind: "unfinished", text: "Parallel rooms await synthetic transport checks.", author: "Eve", createdAt: now.addingTimeInterval(-2 * ProjectMemory.day))
        let month = MemoryNote(kind: "build", text: "Alexandria accordion passed nine suites; not installed.", author: "Codex", createdAt: now.addingTimeInterval(-20 * ProjectMemory.day))
        let old = MemoryNote(kind: "done", text: "Earlier prototype archived.", author: "Claude", createdAt: now.addingTimeInterval(-60 * ProjectMemory.day))
        let permanent = MemoryNote(kind: "preference", text: "Use plain English and preserve project boundaries.", author: "Jason", createdAt: now.addingTimeInterval(-90 * ProjectMemory.day))
        let pages = try ProjectMemory.updatedPages([], notes: [recent, month, old, permanent], roomID: room, requestID: "source-request", now: now)
        let briefing = pages.first { $0.title == ProjectMemory.recentTitle }!.body
        check(briefing.contains(recent.text) && !briefing.contains(month.text), "Recent selects roughly one week, not the entire archive")
        check(briefing.contains(room.uuidString) && briefing.contains("source-request"), "recent notes retain room and request provenance")
        let index = pages.first { $0.title == ProjectMemory.indexTitle }!.body
        check(index.contains("Last month") && index.contains("Permanent knowledge") && index.contains("Older work archive"), "one searchable index explains all three memory layers")
        check(pages.contains { $0.id == permanent.id && $0.title.hasPrefix(ProjectMemory.knowledgePrefix) }, "durable preferences have a permanent knowledge home")
        let later = try ProjectMemory.updatedPages(pages, notes: [], roomID: nil, requestID: nil, now: now.addingTimeInterval(100 * ProjectMemory.day))
        check([recent, month, old, permanent].allSatisfy { note in later.contains { $0.id == note.id } }, "aging out of the week or month never deletes source notes")
        check(later.first { $0.title == ProjectMemory.recentTitle }!.body.contains(recent.text), "unresolved commitments remain in Recent even after one hundred days")
        var resolved = later
        let openIndex = resolved.firstIndex { $0.id == recent.id }!
        resolved[openIndex].body += "\nResolution: resolved\n"
        let closed = try ProjectMemory.updatedPages(resolved, notes: [], roomID: nil, requestID: nil, now: now.addingTimeInterval(100 * ProjectMemory.day))
        check(!closed.first { $0.title == ProjectMemory.recentTitle }!.body.contains(recent.text), "explicit resolution releases an old commitment from Recent")
        check(closed.contains { $0.id == recent.id }, "resolved commitments remain in the searchable archive")
        resolved[openIndex].body = resolved[openIndex].body.replacingOccurrences(of: "Resolution: resolved", with: "Resolution: superseded")
        check(!ProjectMemory.isUnresolved(resolved[openIndex]), "explicit supersession also releases a commitment without deleting history")
        check(ProjectMemory.recall(later, query: "What happened with the accordion?").contains("not installed"), "lexical recall can recover older work without turning a plan into installation")
        check(ProjectMemory.recall(later, query: "please remember this memory").isEmpty, "generic queries do not invent recalled facts")
        let repeated = try ProjectMemory.updatedPages(pages, notes: [recent, month], roomID: room, requestID: "source-request", now: now)
        check(repeated == pages, "repeated dispatches do not duplicate notes or revisions")
        var many: [MemoryNote] = []
        for i in 0..<40 { many.append(MemoryNote(kind: "build", text: "Work \(i): " + String(repeating: "detail ", count: 60), author: "Eve", createdAt: now.addingTimeInterval(-Double(i)))) }
        let crowded = try ProjectMemory.updatedPages([], notes: many, roomID: room, requestID: "batch", now: now)
        let bounded = crowded.first { $0.title == ProjectMemory.recentTitle }!.body
        check(bounded.count <= 10_000 && bounded.contains("omitted"), "Recent stays bounded and explicitly reports omitted notes")
        check(crowded.filter(ProjectMemory.isRecord).count == many.count, "briefing limits never trim stored knowledge")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectMemoryTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(directory: root)
        check(store.refreshProjectMemory(), "an empty project receives a saved Recent briefing")
        check(store.alexandriaContinuityContext.contains("No curated notes"), "a newly joined teammate receives an honest empty-memory briefing")
        let request = UUID().uuidString
        store.conversation.messages.append(Message(author: "Eve", text: "<<REMEMBER {\"kind\":\"decision\",\"text\":\"Recent accompanies every prompt.\"}>>", state: "completed", requestId: request))
        store.captureMemory(request: request, agent: "eve")
        check(store.alexandriaContinuityContext.contains("Recent accompanies every prompt."), "saved memory enters the shared briefing immediately")
        check(store.libraryPages.contains { $0.body.contains(request) && ProjectMemory.isRecord($0) }, "captured notes have source-linked archival pages")
        let snapshot = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
        check(snapshot.projects.first { $0.id == store.activeProject!.id }?.library == store.libraryPages, "briefing, source notes and index reach durable storage together")
        let source = try String(contentsOfFile: "Sources/Silkwire/ConversationStore.swift", encoding: .utf8)
        check(source.contains("guard refreshProjectMemory(persist: false) else { return }") && source.contains("ProjectMemory.recall(libraryPages, query: text)"), "normal dispatch includes automatic refresh and relevant archive recall")
        print("PASS: three-layer memory checks; no live agents or cloud services used")
    }
}
