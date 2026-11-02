import Foundation

// Independent re-review of Future editor conflict protection in 70c5128.
// Synthetic stores only; no providers, real library, or mounted UI interaction.
@main struct FutureEditorReReviewTests {
    @MainActor static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS: " + label) }
            else { failures += 1; print("FAIL: " + label) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FutureEditorReReview-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(directory: root)
        let projectA = store.activeProject!.id
        let conversationA = store.conversation.id
        let future = FutureStore(); future.attach(store)
        let first = FutureItem(title: "First task", details: "Original details")
        let other = FutureItem(title: "Unrelated task", details: "Do not replace me")
        future.update(projectA) { $0 = [first, other] }
        func page() -> LibraryPage {
            store.libraryPages.first { $0.title == FutureStore.pageTitle && $0.section == LibrarySection.shared.rawValue }!
        }
        func replaceFixtureLibrary(_ pages: [LibraryPage]) {
            let index = store.projects.firstIndex { $0.id == store.activeProject!.id }!
            guard store.commitLibrary(pages, at: index) else { fatalError("Fixture library could not be saved") }
        }
        check(future.error == nil && future.items == [first, other], "review starts from a durable synthetic Future page")

        // Two genuinely opened editors: observing the first save must not advance
        // the second editor's immutable opening baseline.
        let secondView = FutureStore(); secondView.attach(store)
        let openingA = future.beginEdit(first)!
        let openingB = secondView.beginEdit(first)!
        var draftA = first; draftA.details = "Saved by the first editor"
        var draftB = first; draftB.title = "Unsaved second editor title"
        check(future.saveEdit(draftA, basedOn: openingA), "the first of two editors saves successfully")
        secondView.refresh()
        let afterFirst = page()
        check(!secondView.saveEdit(draftB, basedOn: openingB), "a refreshed second editor still rejects its stale opening revision")
        check(page() == afterFirst, "the rejected second editor changes neither current text nor history")
        check(draftB.title == "Unsaved second editor title" && secondView.error != nil, "a rejected save returns explicit failure without consuming its supplied draft")
        check(try FutureMarkdown.decode(page().body).last == other, "conflicting editor saves preserve unrelated tasks")

        // Unchanged saves are genuine success, not an accidental revision bump.
        future.refresh()
        let unchanged = future.beginEdit(future.items[0])!
        let beforeUnchanged = page()
        check(future.saveEdit(unchanged.item, basedOn: unchanged), "an unchanged editor can explicitly save successfully")
        check(page() == beforeUnchanged, "an unchanged successful save does not manufacture history")

        // Validation failure must keep the exact opening revision usable for a
        // corrected retry, since no content was saved by the failed attempt.
        var invalidDraft = unchanged.item; invalidDraft.title = "Invalid\nTitle"
        check(!future.saveEdit(invalidDraft, basedOn: unchanged), "invalid editor text returns failure")
        check(page() == beforeUnchanged, "validation failure leaves saved text and history untouched")
        var correctedDraft = unchanged.item; correctedDraft.title = "Corrected title"
        check(future.saveEdit(correctedDraft, basedOn: unchanged), "a corrected retry can use the still-current opening revision")
        check(try FutureMarkdown.decode(page().body).first == correctedDraft, "the corrected retry actually persists its complete draft")
        let afterCorrection = page()
        var replayDraft = correctedDraft; replayDraft.details = "Must not replay a consumed revision"
        check(!future.saveEdit(replayDraft, basedOn: unchanged) && page() == afterCorrection, "an earlier successful editor token cannot overwrite its subsequent revision")

        // A replacement page with identical item IDs and text is still a different
        // document. This fixture deliberately gives it the same revision number.
        future.refresh()
        let replacedOpening = future.beginEdit(future.items[0])!
        var replacement = page(); replacement.id = UUID(); replacement.history = []
        let replacedID = replacedOpening.pageID
        replaceFixtureLibrary(store.libraryPages.map { $0.id == replacedID ? replacement : $0 })
        future.refresh()
        var replacementDraft = replacedOpening.item; replacementDraft.details = "Old page's unsaved draft"
        check(!future.saveEdit(replacementDraft, basedOn: replacedOpening), "an editor cannot save into a replacement page with matching item IDs and revision")
        check(page() == replacement, "rejecting a replaced document preserves the replacement exactly")

        // Removing the whole page differs from removing one item from a page.
        future.refresh()
        let deletedPageOpening = future.beginEdit(future.items[0])!
        replaceFixtureLibrary(store.libraryPages.filter { $0.id != deletedPageOpening.pageID })
        future.refresh()
        check(!future.saveEdit(deletedPageOpening.item, basedOn: deletedPageOpening), "deleting the whole page makes the open editor fail explicitly")
        check(!store.libraryPages.contains { $0.id == deletedPageOpening.pageID }, "an old editor never resurrects a removed Future page")

        // Imported or otherwise inconsistent data might retain a revision while
        // changing an item. The value comparison must still refuse a blind save.
        future.refresh(); future.update(projectA) { $0 = [first, other] }
        let inconsistentOpening = future.beginEdit(first)!
        var inconsistentPage = page()
        var importedItem = first; importedItem.details = "Different imported content at the same revision"
        inconsistentPage.body = try FutureMarkdown.encode([importedItem, other])
        replaceFixtureLibrary(store.libraryPages.map { $0.id == inconsistentPage.id ? inconsistentPage : $0 })
        future.refresh()
        check(!future.saveEdit(first, basedOn: inconsistentOpening), "a matching revision cannot bypass the opening item-value comparison")
        check(page() == inconsistentPage, "inconsistent-revision rejection preserves imported content")

        // Actual project switching, not merely a fabricated foreign token. Copy
        // page and item IDs into the other synthetic project to exercise identity
        // guards independently of UUID differences. Never reconnect providers.
        future.refresh()
        let projectOpening = future.beginEdit(future.items[0])!
        let beforeProjectA = store.activeProject!.library
        var copiedProject = store.activeProject!
        copiedProject.id = UUID(); copiedProject.name = "Other synthetic project"
        let projectB = copiedProject.id
        guard store.createProject(copiedProject, reconnect: false) else { fatalError("Could not create the second synthetic project") }
        future.attach(store)
        let beforeProjectB = store.activeProject!.library
        var projectDraft = projectOpening.item; projectDraft.title = "Only for the original project"
        check(!future.saveEdit(projectDraft, basedOn: projectOpening), "a real project switch rejects an old editor despite colliding page and item IDs")
        check(store.activeProject!.library == beforeProjectB, "a foreign editor cannot change the currently open project's plan")
        check(store.projects.first { $0.id == projectA }!.library == beforeProjectA, "rejecting a foreign editor also preserves its original project's plan")
        guard store.selectConversation(conversationA, reconnect: false) else { fatalError("Could not return to the original synthetic conversation") }
        future.attach(store)
        check(future.saveEdit(projectDraft, basedOn: projectOpening), "returning to the original unchanged project permits the valid draft to save")
        check(store.projects.first { $0.id == projectB }!.library == beforeProjectB, "saving after returning does not leak changes into the other project")

        future.refresh()
        let identityOpening = future.beginEdit(future.items[0])!
        var wrongIdentity = identityOpening.item; wrongIdentity.id = UUID()
        let beforeIdentity = page()
        check(!future.saveEdit(wrongIdentity, basedOn: identityOpening), "a submitted item cannot substitute a different task identity")
        check(page() == beforeIdentity, "task identity rejection leaves the original plan unchanged")

        check(store.save(), "both synthetic projects reach a durable save boundary")
        let durable = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
        check(durable.projects.first { $0.id == projectA }?.library == store.projects.first { $0.id == projectA }?.library && durable.projects.first { $0.id == projectB }?.library == beforeProjectB, "durable snapshots retain the separate surviving plans")
        print("FutureEditorReReviewTests: \(checks) checks, \(failures) failures; synthetic production save APIs, not mounted UI")
        if failures > 0 { exit(1) }
    }
}
