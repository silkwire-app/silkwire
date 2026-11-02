import Foundation
import Darwin

/// Independent model-level reproduction of the drawer's North Stars save callback.
/// No live app, provider sessions, credentials or owner library are opened.
/// Expected safety assertions stay red until the editor captures its opening identity/revision.
@main struct FutureDrawerSaveReviewTests {
    @MainActor static func main() throws {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "FutureDrawerSaveReviewTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture setup failed: " + label]) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FutureDrawerSaveReview-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func prepared(_ name: String) throws -> (ConversationStore, FutureStore, UUID) {
            let store = ConversationStore(directory: root.appendingPathComponent(name))
            let future = FutureStore()
            future.attach(store)
            guard let project = store.activeProject?.id else { throw CocoaError(.fileReadCorruptFile) }
            try require(store.storageError == nil, name + " has isolated storage")
            try require(future.add(title: "Preserve this card", details: "Synthetic review fixture", project: project), name + " card")
            try require(future.saveNorthStars("- Original North Star", project: project), name + " initial stars")
            return (store, future, project)
        }
        func page(_ store: ConversationStore) throws -> LibraryPage {
            guard let value = store.libraryPages.first(where: { $0.title == FutureStore.pageTitle && $0.section == LibrarySection.shared.rawValue }) else { throw CocoaError(.fileNoSuchFile) }
            return value
        }
        func externalStars(_ text: String, store: ConversationStore) throws -> LibraryPage {
            let old = try page(store)
            var parsed = try FutureMarkdown.decodePage(old.body)
            parsed.preamble = try FutureMarkdown.replacingNorthStars(in: parsed.preamble, with: text)
            let body = try FutureMarkdown.encode(parsed)
            _ = store.saveLibraryPage(id: old.id, section: old.section, title: old.title, body: body, baseRevision: old.revision, author: "Eve")
            let updated = try page(store)
            try require(updated.body == body && updated.revision > old.revision, "external save reached the synthetic page")
            return updated
        }

        // Control: an intentional, current save still works and preserves the cards.
        do {
            let (store, future, project) = try prepared("fresh")
            let cards = future.items
            let saved = future.saveNorthStars("- Deliberate current edit", project: project)
            check(saved && future.northStars == "- Deliberate current edit", "fresh North Stars save succeeds")
            check(try FutureMarkdown.decodePage(page(store).body).items == cards, "fresh North Stars save preserves card IDs, order and notes")
        }

        // Control: without the view's onChange refresh, the existing revision guard works.
        do {
            let (store, future, project) = try prepared("unobserved-change")
            let draft = "- Original North Star\n- Unsaved human draft"
            let latest = try externalStars("- New agent decision", store: store)
            let saved = future.saveNorthStars(draft, project: project)
            check(!saved, "unrefreshed stale North Stars save is rejected")
            check(try page(store).body == latest.body, "unrefreshed rejection retains the agent's saved text")
        }

        // Regression: FutureDrawer refreshes on libraryPages changes while its text editor
        // retains an older @State draft. Save uses the now-current store revision instead
        // of an immutable editor-opening revision, so it can overwrite an agent's edit.
        do {
            let (store, future, project) = try prepared("observed-change")
            let opening = try page(store)
            guard let edit = future.beginNorthStarsEdit() else { throw CocoaError(.fileReadCorruptFile) } // Captured when the sheet opens.
            check(edit.projectID == project && edit.revision == opening.revision, "North Stars editor captures its opening project and revision")
            let draft = "- Original North Star\n- Unsaved human draft"
            let latest = try externalStars("- New agent decision", store: store)
            future.refresh() // Same model operation as FutureDrawer.onChange(libraryPages).
            check(future.northStars == "- New agent decision" && latest.revision > opening.revision, "drawer model observes the newer agent revision")
            let saved = future.saveNorthStars(draft, basedOn: edit)
            check(!saved, "open North Stars draft must reject a concurrently changed opening revision")
            check(try page(store).body == latest.body, "saving an old open draft must not overwrite the agent's newer North Stars")
            check(draft == "- Original North Star\n- Unsaved human draft", "the human draft remains available for conflict resolution")
        }

        // Control: an editor opened on the current page saves; after a refused save, reopening on the newer text saves.
        do {
            let (store, future, _) = try prepared("snapshot-retry")
            guard let first = future.beginNorthStarsEdit() else { throw CocoaError(.fileReadCorruptFile) }
            check(first.original == "- Original North Star", "editor opens with the saved North Stars")
            _ = try externalStars("- Agent edit", store: store)
            future.refresh()
            check(!future.saveNorthStars("- Stale", basedOn: first), "stale snapshot is refused")
            future.refresh()
            guard let second = future.beginNorthStarsEdit() else { throw CocoaError(.fileReadCorruptFile) }
            check(second.original == "- Agent edit", "reopened editor shows the newer text")
            check(future.saveNorthStars("- Agent edit\n- Human addition", basedOn: second), "current snapshot saves")
            check(future.northStars == "- Agent edit\n- Human addition" && future.items.count == 1, "save keeps cards and applies the new stars")
        }

        // Control: ordinary item editors already carry FutureEdit's immutable snapshot.
        do {
            let (store, future, _) = try prepared("item-snapshot")
            guard let original = future.items.first, let edit = future.beginEdit(original) else { throw CocoaError(.fileReadCorruptFile) }
            let latest = try externalStars("- Agent changed the page during item editing", store: store)
            future.refresh()
            var edited = original
            edited.title = "Unsaved item draft"
            check(!future.saveEdit(edited, basedOn: edit), "item editor retains its opening revision after a drawer refresh")
            check(try page(store).body == latest.body, "item editor conflict preserves the newer saved page")
        }

        // Regression: model the actual drawer closure, which resolves activeProject on
        // Save rather than capturing project/page identity when the sheet opens.
        // This is a callback/model test, not a claim that live sheet navigation was exercised.
        do {
            let (store, future, originalProject) = try prepared("project-change")
            let originalRoom = store.conversation.id
            let originalPage = try page(store)
            let draft = "- Draft belonging only to Project A"
            guard let opened = future.beginNorthStarsEdit() else { throw CocoaError(.fileReadCorruptFile) }
            let saveLikeDrawer: (String) -> Bool = { text in future.saveNorthStars(text, basedOn: opened) }
            var next = Project()
            next.name = "Synthetic Project B"
            next.participants = ["codex"]
            try require(store.createProject(next, reconnect: false), "switch to synthetic Project B without connecting a provider")
            future.attach(store) // Same reattachment performed by the drawer on project change.
            try require(future.add(title: "Project B card", project: next.id), "Project B card")
            try require(future.saveNorthStars("- Project B original", project: next.id), "Project B stars")
            let before = try page(store)
            check(!future.saveNorthStars(draft, project: originalProject), "explicit original-project guard rejects a stale Project A save")
            check(try page(store).body == before.body, "explicit project guard leaves Project B unchanged")
            let saved = saveLikeDrawer(draft)
            check(!saved, "open North Stars callback must reject a project change since the sheet opened")
            check(try page(store).body == before.body, "Project A draft must not replace Project B's North Stars")
            try require(store.selectConversation(originalRoom, reconnect: false), "return to the original synthetic room")
            future.attach(store)
            check(try page(store).body == originalPage.body, "Project A's original saved page remains intact")
        }

        print("Future drawer save review: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
