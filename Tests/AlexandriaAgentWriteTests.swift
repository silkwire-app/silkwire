import Foundation

@main struct AlexandriaAgentWriteTests {
    @MainActor static func main() throws {
        var failures = 0
        func check(_ value: Bool, _ label: String) { if value { print("PASS: " + label) } else { failures += 1; print("FAIL: " + label) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlexandriaAgentWriteTests-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(directory: root)
        func json(_ object: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }
        @discardableResult func reply(_ author: String, _ agent: String, _ text: String) -> Message {
            let request = UUID().uuidString
            store.conversation.messages.append(Message(author: author, text: text, state: "completed", requestId: request))
            store.captureMemory(request: request, agent: agent)
            return store.conversation.messages.last { $0.requestId == request }!
        }

        // Capability is offered even before any page exists.
        check(store.alexandriaWriteContext.contains("UPDATE_ALEXANDRIA") && store.alexandriaWriteContext.contains("none yet"), "teammates are told how to write before the library has pages")

        // 1. Create a page.
        let northBody = "# Silkwire North Star\n\nA harness with a heart."
        let created = reply("Claude", "claude", "Saved our North Star.\n<<UPDATE_ALEXANDRIA " + json(["section": "shared", "title": "North Star", "body": northBody]) + ">>")
        let north = store.libraryPages.first { $0.title == "North Star" }
        check(north?.body == northBody && north?.section == "shared", "a teammate creates a shared page from a finished reply")
        check(north?.createdBy == "Claude" && north?.updatedBy == "Claude" && north?.revision == 1, "authorship and first revision are recorded")
        check(!created.text.contains("UPDATE_ALEXANDRIA") && created.text == "Saved our North Star.", "a saved marker is removed from the transcript")
        check(created.detail?.contains("Saved Alexandria · North Star (Shared) · revision 1") == true, "Jason sees a plain save notice")

        // 2. Another teammate receives it: index plus pinned full text.
        let context = store.alexandriaWriteContext
        check(context.contains("- North Star · Shared · ID \(north!.id.uuidString) · revision 1 · last edited by Claude"), "the page index lists title, section, ID, revision and editor")
        check(context.contains("PINNED PAGE") && context.contains("A harness with a heart."), "the North Star travels in full to the next teammate")

        // 3. Replace with the exact revision.
        let v2 = northBody + "\n\nAssemble your team."
        reply("Eve", "eve", "<<UPDATE_ALEXANDRIA " + json(["pageID": north!.id.uuidString, "baseRevision": 1, "body": v2]) + ">>")
        let afterEve = store.libraryPages.first { $0.id == north!.id }!
        check(afterEve.body == v2 && afterEve.revision == 2 && afterEve.updatedBy == "Eve" && afterEve.createdBy == "Claude", "a second teammate replaces it with the exact revision")
        check(afterEve.history.count == 1 && afterEve.history.first?.body == northBody, "the earlier version stays in history")

        // 4. Stale replace is refused and nothing is lost.
        let stale = reply("Codex", "codex", "<<UPDATE_ALEXANDRIA " + json(["pageID": north!.id.uuidString, "baseRevision": 1, "body": "overwrite"]) + ">>")
        let afterStale = store.libraryPages.first { $0.id == north!.id }!
        check(afterStale.body == v2 && afterStale.revision == 2, "a stale replace cannot erase newer work")
        check(stale.text.contains("UPDATE_ALEXANDRIA") && stale.detail?.contains("edited since the revision you read") == true, "a refused marker stays visible with a plain reason")

        // 5. Replace without a revision is refused.
        reply("Codex", "codex", "<<UPDATE_ALEXANDRIA " + json(["pageID": north!.id.uuidString, "body": "no revision"]) + ">>")
        check(store.libraryPages.first { $0.id == north!.id }!.revision == 2, "replacing requires a baseRevision")

        // 6. Append adds without a revision and never replaces.
        reply("Codex", "codex", "<<UPDATE_ALEXANDRIA " + json(["pageID": north!.id.uuidString, "mode": "append", "body": "Codex: test every claim."]) + ">>")
        let appended = store.libraryPages.first { $0.id == north!.id }!
        check(appended.body == v2 + "\n\nCodex: test every claim." && appended.revision == 3 && appended.updatedBy == "Codex", "append adds to the end of the current page")

        // 7. Duplicate titles are refused.
        reply("Eve", "eve", "<<UPDATE_ALEXANDRIA " + json(["section": "shared", "title": "north star", "body": "duplicate"]) + ">>")
        check(store.libraryPages.filter { $0.title.lowercased() == "north star" }.count == 1, "a second page with the same title is refused")

        // 8. Sections: home shelves allowed; home and vaults refused.
        reply("Eve", "eve", "<<UPDATE_ALEXANDRIA " + json(["section": "eve", "title": "Eve · Daily · Oct 31", "body": "We built a lot."]) + ">>")
        check(store.libraryPages.contains { $0.title == "Eve · Daily · Oct 31" && $0.section == "eve" }, "a teammate writes a daily memory on their own shelf")
        reply("Eve", "eve", "<<UPDATE_ALEXANDRIA " + json(["section": "vaults", "title": "Sneaky", "body": "x"]) + ">>")
        reply("Eve", "eve", "<<UPDATE_ALEXANDRIA " + json(["section": "home", "title": "Sneaky home", "body": "x"]) + ">>")
        check(!store.libraryPages.contains { $0.title.hasPrefix("Sneaky") }, "vaults and home cannot receive teammate pages")

        // 9. Pages kept by their own tools are protected.
        let future = FutureStore(); future.attach(store)
        future.update(store.activeProject!.id) { $0 = [FutureItem(title: "Ship it")] }
        let futurePage = store.libraryPages.first { $0.title == FutureStore.pageTitle }!
        reply("Claude", "claude", "<<UPDATE_ALEXANDRIA " + json(["pageID": futurePage.id.uuidString, "baseRevision": futurePage.revision, "body": "replaced"]) + ">>")
        check(store.libraryPages.first { $0.id == futurePage.id }!.body == futurePage.body, "the Future page is only edited through its own protocol")

        // 10. Per-reply limit.
        let many = (1...4).map { "<<UPDATE_ALEXANDRIA " + json(["section": "claude", "title": "Note \($0)", "body": "n"]) + ">>" }.joined(separator: "\n")
        let limited = reply("Claude", "claude", many)
        check(store.libraryPages.filter { $0.title.hasPrefix("Note ") }.count == 3, "at most three writes apply per reply")
        check(limited.detail?.contains("extra update(s) ignored") == true, "ignored extras are reported")

        // 11. Non-participants and unreadable JSON change nothing.
        let countBefore = store.libraryPages.count
        reply("Stranger", "stranger", "<<UPDATE_ALEXANDRIA " + json(["section": "shared", "title": "Intruder", "body": "x"]) + ">>")
        reply("Claude", "claude", "<<UPDATE_ALEXANDRIA {not json}>>")
        check(store.libraryPages.count == countBefore, "non-participants and unreadable updates change nothing")

        // 12. REMEMBER and UPDATE_ALEXANDRIA in one reply keep both notices.
        let both = reply("Codex", "codex", "Done.\n<<UPDATE_ALEXANDRIA " + json(["section": "shared", "title": "Decisions", "body": "- Alexandria is our memory."]) + ">>\n<<REMEMBER {\"kind\":\"decision\",\"text\":\"Alexandria is writable by teammates.\"}>>")
        print("detail: " + (both.detail ?? "nil"))
        check(store.libraryPages.contains { $0.title == "Decisions" } && both.detail?.contains("Saved Alexandria · Decisions") == true && (store.activeProject?.memory ?? []).contains { $0.text == "Alexandria is writable by teammates." } && !both.text.contains("REMEMBER"), "a reply can save a page and a team note together")
        check(store.alexandriaWriteContext.contains("Alexandria is our memory."), "the Decisions page is pinned in full for every teammate")

        // 12b. Daily memories: the newest daily page on each shelf travels to everyone.
        check(store.alexandriaWriteContext.contains("Daily · YYYY-MM-DD"), "teammates are told the daily memory convention")
        reply("Claude", "claude", "<<UPDATE_ALEXANDRIA " + json(["section": "claude", "title": "Daily · 2026-10-30", "body": "old-day-marker"]) + ">>")
        reply("Claude", "claude", "<<UPDATE_ALEXANDRIA " + json(["section": "claude", "title": "Daily · 2026-10-31", "body": "Claude built Alexandria writes."]) + ">>")
        reply("Eve", "eve", "<<UPDATE_ALEXANDRIA " + json(["section": "eve", "title": "Daily · 2026-10-31", "body": "Eve reviewed the handoff."]) + ">>")
        reply("Codex", "codex", "<<UPDATE_ALEXANDRIA " + json(["section": "shared", "title": "Daily · 2026-10-31", "body": "shared-daily-marker"]) + ">>")
        let dailyContext = store.alexandriaWriteContext
        check(dailyContext.contains("LATEST DAILY MEMORIES") && dailyContext.contains("Claude built Alexandria writes.") && dailyContext.contains("Eve reviewed the handoff."), "each teammate's latest daily memory is read at the start of every request")
        check(!dailyContext.contains("old-day-marker"), "only the newest day per shelf is sent in full")
        check(!dailyContext.contains("shared-daily-marker"), "daily memories come from teammates' own shelves")
        let claudeToday = store.libraryPages.first { $0.section == "claude" && $0.title == "Daily · 2026-10-31" }!
        reply("Claude", "claude", "<<UPDATE_ALEXANDRIA " + json(["pageID": claudeToday.id.uuidString, "mode": "append", "body": String(repeating: "x", count: AlexandriaAgentWrite.dailyLimit + 10)]) + ">>")
        let clippedContext = store.alexandriaWriteContext
        check(clippedContext.contains("[TRUNCATED: append to this page; do not replace it from this excerpt]") && clippedContext.contains("Claude built Alexandria writes."), "a long daily memory is clipped with a clear marker")

        // 12c. Retrieval in a fresh conversation: any team page is reachable by topic.
        reply("Eve", "eve", "<<UPDATE_ALEXANDRIA " + json(["section": "shared", "title": "Ari design notes", "body": "In Midnight, Ari is chrome with lavender highlights."]) + ">>")
        let ariPage = store.libraryPages.first { $0.title == "Ari design notes" }!
        check(store.newConversation(reconnect: false), "a fresh conversation starts")
        check(store.alexandriaWriteContext.contains("- Ari design notes · Shared · ID \(ariPage.id.uuidString)"), "a fresh conversation still sees every team page in the index")
        let recalled = store.alexandriaRecall(query: "What colour is Ari in Midnight?")
        check(recalled.contains("RECALLED TEAM PAGES") && recalled.contains("lavender highlights") && recalled.contains(ariPage.id.uuidString), "another teammate retrieves Eve's page by topic in a fresh conversation")
        check(!store.alexandriaRecall(query: "harness heart").contains("A harness with a heart"), "pinned pages are not repeated in recall")
        _ = store.saveLibraryPage(id: UUID(), section: "vaults", title: "Private vault", body: "zebrapassphrase", baseRevision: nil, author: "Jason")
        check(store.alexandriaRecall(query: "zebrapassphrase").isEmpty, "vault pages are never recalled to teammates")

        // 13. Durable on disk.
        check(store.save(), "changes reach a durable workspace boundary")
        let workspace = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
        let saved = workspace.projects.first { $0.id == store.activeProject!.id }?.library ?? []
        check(saved.first { $0.title == "North Star" }?.revision == 3 && saved.contains { $0.title == "Eve · Daily · Oct 31" }, "teammate pages are on disk for the next launch")
        check(AlexandriaAgentWrite.futureTitle == FutureStore.pageTitle, "the protected Future title matches the Future page")

        print("AlexandriaAgentWriteTests: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
