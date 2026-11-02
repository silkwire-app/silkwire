import Foundation

@main struct FutureTests {
    @MainActor static func main() throws {
        func check(_ value: Bool, _ label: String) { guard value else { fatalError("FAIL: " + label) }; print("PASS: " + label) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FutureTests-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(directory: root)
        let project = store.activeProject!.id
        let future = FutureStore(); future.attach(store)
        let first = FutureItem(title: "Parallel rooms", details: "Late replies stay in their original room.\n\nKeep context separate.\n")
        let second = FutureItem(title: "Mini sidebar")
        let encoded = try FutureMarkdown.encode([first, second])
        let decoded = try FutureMarkdown.decode(encoded)
        for delimiters in [("<!— future-id:", " -->"), ("<!-- future-id:", " —>"), ("<!— future-id:", " —>")] {
            let smart = encoded.replacingOccurrences(of: "<!-- future-id:", with: delimiters.0).replacingOccurrences(of: " -->", with: delimiters.1)
            check(try FutureMarkdown.decode(smart) == [first, second], "smart-dash metadata preserves IDs, order, details and completion")
        }
        let prose = FutureItem(title: "North Star — public beta", details: "Keep prose — and it’s punctuation unchanged.")
        let smartProse = try FutureMarkdown.encode([prose]).replacingOccurrences(of: "<!-- future-id:", with: "<!— future-id:")
        check(try FutureMarkdown.decode(smartProse) == [prose], "metadata recovery leaves prose unchanged")
        let malformed = encoded.replacingOccurrences(of: first.id.uuidString, with: "not-a-uuid")
        do { _ = try FutureMarkdown.decode(malformed); check(false, "invalid IDs remain rejected") } catch { check(true, "invalid IDs remain rejected") }
        check(decoded == [first, second], "readable Markdown round-trips IDs, details and completion without loss")
        future.update(project) { $0 = [first, second] }
        check(future.error == nil && store.libraryPages.count == 1, "Future is one real Alexandria page")
        future.move(second.id, project: project, by: -1)

        check(future.items.map(\.id) == [second.id, first.id], "arrows persist priority order into the page")
        let page = store.libraryPages.first!
        check(page.history.count == 1, "previous page text remains in Alexandria revision history")
        let recovery = root.appendingPathComponent("Alexandria Recovery/\(project.uuidString)/\(page.id.uuidString)/revision-1.json")
        let archived = try JSONDecoder().decode(LibraryPage.self, from: Data(contentsOf: recovery))
        check(archived.body == encoded, "an independent recovery copy preserves the prior page")
        let stale = FutureStore(); stale.attach(store)
        let changed = try FutureMarkdown.encode([first])
        _ = store.saveLibraryPage(id: page.id, section: page.section, title: page.title, body: changed, baseRevision: page.revision, author: "Claude")
        stale.move(second.id, project: project, by: -1)
        check(stale.error != nil && store.libraryPages.first!.body == changed, "stale cards cannot overwrite another editor's work")
        future.refresh()
        check(future.items == [first], "cards reload edits made in Alexandria")
        let beforeSmart = store.libraryPages.first { $0.id == page.id }!
        let smartSaved = changed.replacingOccurrences(of: "<!-- future-id:", with: "<!— future-id:").replacingOccurrences(of: " -->", with: " —>")
        _ = store.saveLibraryPage(id: page.id, section: page.section, title: page.title, body: smartSaved, baseRevision: beforeSmart.revision)
        future.refresh()
        check(future.error == nil && future.items == [first], "Reload saved page recovers smart-dash metadata")
        check(store.libraryPages.first { $0.id == page.id }!.body == smartSaved, "reload never rewrites the saved North Stars")
        check(store.alexandriaContinuityContext.contains("Parallel rooms"), "the shared plan is available in outgoing quoted continuity context")
        let request = UUID().uuidString
        store.conversation.messages.append(Message(author: "Eve", text: "A concise handoff.\n<<REMEMBER {\"kind\":\"decision\",\"text\":\"Keep project contexts separate.\"}>>", state: "completed", requestId: request))
        store.captureMemory(request: request, agent: "eve")
        check(store.libraryPages.contains { $0.title.hasPrefix("Memory / ") && $0.body.contains("Keep project contexts separate.") }, "curated memory notes become searchable Alexandria handoffs")
        check(store.alexandriaContinuityContext.contains("Keep project contexts separate."), "saved handoff accompanies the next conversation context")
        check(store.save(), "all changes reach a durable workspace boundary")
        let workspace = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
        check(workspace.projects.first { $0.id == project }?.library == store.libraryPages, "workspace snapshot retains both Future and handoff pages")
        let original = store.libraryPages.first { $0.id == page.id }!
        _ = store.restoreLibraryRevision(pageID: page.id, revisionID: original.history.first!.id)
        check(store.libraryPages.first { $0.id == page.id }!.body == encoded, "older content restores as a new revision")
        struct Proposal: Encodable { var pageID: UUID; var baseRevision: Int; var items: [FutureItem] }
        let current = store.libraryPages.first { $0.id == page.id }!
        let proposal = Proposal(pageID: page.id, baseRevision: current.revision, items: [second, first])
        let command = "<<UPDATE_FUTURE " + String(data: try JSONEncoder().encode(proposal), encoding: .utf8)! + ">>"
        let editRequest = UUID().uuidString
        store.conversation.messages.append(Message(author: "Eve", text: "Updated the plan.\n" + command, state: "completed", requestId: editRequest))
        store.captureMemory(request: editRequest, agent: "eve")
        let agentEdited = store.libraryPages.first { $0.id == page.id }!
        check(try FutureMarkdown.decode(agentEdited.body).map(\.id) == [second.id, first.id], "a teammate saves the same shared plan with exact-revision checks")
        let staleRequest = UUID().uuidString
        store.conversation.messages.append(Message(author: "Eve", text: command, state: "completed", requestId: staleRequest))
        store.captureMemory(request: staleRequest, agent: "eve")
        check(store.libraryPages.first { $0.id == page.id }!.revision == agentEdited.revision, "stale teammate proposals cannot erase newer work")
        // A failed independent recovery copy must stop the edit before it replaces any page.
        let blockedTarget = root.appendingPathComponent("Alexandria Recovery/\(project.uuidString)/\(page.id.uuidString)/revision-\(agentEdited.revision).json")
        try FileManager.default.createSymbolicLink(at: blockedTarget, withDestinationURL: recovery)
        let blocked = store.saveLibraryPage(id: page.id, section: page.section, title: page.title, body: "replacement", baseRevision: agentEdited.revision)
        if case .invalid = blocked { check(true, "linked recovery storage refuses edits safely") } else { check(false, "linked recovery storage refuses edits safely") }
        check(store.libraryPages.first { $0.id == page.id }!.body == agentEdited.body, "recovery failure leaves the current page untouched")
        // Drawer: free text above the cards is preserved; North Stars edit only their section.
        let notes = "# Future\n\nPriority is not permission to begin work.\n\nSome unfamiliar note — keep me.\n\n## North Stars\n\n- Open source\n\n## Parking lot\nfree text\n"
        let withCards = notes + String(encoded.dropFirst(FutureMarkdown.heading.count))
        let parsed = try FutureMarkdown.decodePage(withCards)
        let reencoded = try FutureMarkdown.encode(parsed)
        check(parsed.items == [first, second] && reencoded == withCards, "text above the cards round-trips byte for byte")
        check(FutureMarkdown.northStars(in: parsed.preamble) == "- Open source", "North Stars are read from their section")
        let starred = try FutureMarkdown.replacingNorthStars(in: parsed.preamble, with: "- Open source\n- Mac is Home")
        check(starred.contains("Some unfamiliar note — keep me.") && starred.contains("## Parking lot\nfree text") && FutureMarkdown.northStars(in: starred) == "- Open source\n- Mac is Home", "editing North Stars leaves every other line untouched")
        let added = try FutureMarkdown.replacingNorthStars(in: FutureMarkdown.heading, with: "- Voice")
        check(added.hasPrefix("# Future\n\nPriority is not permission to begin work.") && FutureMarkdown.northStars(in: added) == "- Voice", "North Stars can be added to a page without them")
        do { _ = try FutureMarkdown.replacingNorthStars(in: notes, with: "## 1. [ ] sneaky"); check(false, "North Stars cannot inject cards") } catch { check(true, "North Stars cannot inject cards") }
        let unknown = "Totally different notes\n- [ ] not our format\n"
        let unknownPage = try FutureMarkdown.decodePage(unknown)
        check(unknownPage.preamble == unknown && unknownPage.items.isEmpty, "unfamiliar pages are preserved as text, never emptied")
        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("FutureDrawer-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root2) }
        let store2 = ConversationStore(directory: root2)
        let p2 = store2.activeProject!.id
        let drawer = FutureStore(); drawer.attach(store2)
        check(drawer.add(title: "  Ship beta  ", details: "notes at creation", project: p2) && drawer.items.first?.details == "notes at creation" && drawer.items.first?.title == "Ship beta", "title and notes are saved at creation")
        drawer.add(title: "Voice", project: p2); drawer.add(title: "iOS lobby", project: p2)
        check(drawer.saveNorthStars("- Public open-source beta", project: p2) && drawer.northStars == "- Public open-source beta", "North Stars save to the Future page")
        let ship = drawer.items[0].id
        drawer.setCompleted(ship, true, project: p2)
        check(drawer.open.map(\.title) == ["Voice", "iOS lobby"] && drawer.done.map(\.title) == ["Ship beta"], "done items move to Completed")
        drawer.add(title: "Signing identity", project: p2)
        check(drawer.open.last?.title == "Signing identity" && drawer.items.last?.title == "Ship beta", "new items join Future above Completed")
        drawer.move(drawer.open.last!.id, project: p2, by: 1)
        check(drawer.open.last?.title == "Signing identity" && drawer.items.last?.title == "Ship beta", "moving down never crosses into Completed")
        let voice = drawer.open[0]
        drawer.delete(voice.id, project: p2)
        check(!drawer.items.contains(voice) && drawer.lastDeleted?.item == voice, "delete removes the item and offers undo")
        drawer.undoDelete(project: p2)
        check(drawer.open.first == voice && drawer.lastDeleted == nil, "undo restores the item in place")
        drawer.setCompleted(ship, false, project: p2)
        check(drawer.open.last?.title == "Ship beta" && drawer.done.isEmpty, "restore returns an item to Future")
        let saved = store2.libraryPages.first { $0.title == FutureStore.pageTitle }!
        check(saved.body.contains("## North Stars") && drawer.lastChange?.by == saved.updatedBy, "drawer shows who changed the page last")
        struct StarProposal: Encodable { var pageID: UUID; var baseRevision: Int; var items: [FutureItem]; var northStars: String? }
        let reorder = StarProposal(pageID: saved.id, baseRevision: saved.revision, items: drawer.items.reversed(), northStars: nil)
        let req = UUID().uuidString
        store2.conversation.messages.append(Message(author: "Eve", text: "Reordered.\n<<UPDATE_FUTURE " + String(data: try JSONEncoder().encode(reorder), encoding: .utf8)! + ">>", state: "completed", requestId: req))
        store2.captureMemory(request: req, agent: "eve")
        drawer.refresh()
        check(drawer.items.map(\.id) == reorder.items.map(\.id) && drawer.northStars == "- Public open-source beta", "agent card updates never drop North Stars")
        let afterReorder = store2.libraryPages.first { $0.id == saved.id }!
        let starEdit = StarProposal(pageID: saved.id, baseRevision: afterReorder.revision, items: drawer.items, northStars: "- Every model, every agent, every provider")
        let req2 = UUID().uuidString
        store2.conversation.messages.append(Message(author: "Eve", text: "<<UPDATE_FUTURE " + String(data: try JSONEncoder().encode(starEdit), encoding: .utf8)! + ">>", state: "completed", requestId: req2))
        store2.captureMemory(request: req2, agent: "eve")
        drawer.refresh()
        check(drawer.northStars == "- Every model, every agent, every provider" && drawer.lastChange?.by == "Eve", "teammates can edit North Stars, and the drawer says who")
        print("PASS: Alexandria Future, conflict, recovery and curated memory checks")
    }
}
