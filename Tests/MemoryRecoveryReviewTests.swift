import Foundation

// Independent review of candidate 73e83a7. Synthetic library only: the edit helper
// mirrors FuturePanel's sheet Save closure, and refresh() mirrors SilkwireApp's
// onChange(of: store.libraryPages). This is not mounted mouse/keyboard acceptance.
@main struct MemoryRecoveryReviewTests {
    @MainActor static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS: " + label) }
            else { failures += 1; print("FAIL: " + label) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryRecoveryReview-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(directory: root)
        let project = store.activeProject!.id
        let future = FutureStore(); future.attach(store)
        let original = FutureItem(title: "Original title", details: "Original details")
        let other = FutureItem(title: "Other task", details: "Preserve this task too")
        future.update(project) { $0 = [original, other] }
        check(future.error == nil && future.items == [original, other], "fixture starts with a real saved Future page")
        func currentPage() -> LibraryPage { store.libraryPages.first { $0.title == FutureStore.pageTitle }! }
        func saveElsewhere(_ items: [FutureItem]) throws {
            let before = currentPage()
            let result = store.saveLibraryPage(id: before.id, section: before.section, title: before.title, body: try FutureMarkdown.encode(items), baseRevision: before.revision, author: "Eve")
            guard case .saved = result else { fatalError("Fixture remote edit was not saved") }
        }
        // Use the production sheet's immutable opening snapshot and actual Save API.
        // The observer may refresh the list, but must not advance this editor's revision.
        func saveFromOpenEditor(_ updated: FutureItem, basedOn edit: FutureEdit) -> Bool {
            future.saveEdit(updated, basedOn: edit)
        }

        let editorToken = future.beginEdit(future.items[0])!
        let editorSnapshot = editorToken.item
        var newer = original; newer.details = "Newer teammate details that must not be silently lost"
        try saveElsewhere([newer, other])
        future.refresh()
        check(future.items[0] == newer, "library observer refreshes the shared model while an old editor snapshot remains open")
        var localEdit = editorSnapshot; localEdit.title = "Jason's edited title"
        let editReportedSaved = saveFromOpenEditor(localEdit, basedOn: editorToken)
        let afterEdit = try FutureMarkdown.decode(currentPage().body)
        check(!editReportedSaved, "an editor opened before a conflicting update must not report a successful blind replacement")
        check(afterEdit.first { $0.id == original.id }?.details == newer.details, "saving an old editor snapshot must preserve the newer teammate details")
        check(afterEdit.first { $0.id == other.id } == other, "the unrelated task is not changed by the editor test")

        // Deletion is another concurrent edit: a no-op replacement must not make
        // the sheet say Save succeeded and dismiss the user's unsaved text.
        try saveElsewhere([original, other]); future.refresh()
        let deletedEditorToken = future.beginEdit(future.items[0])!
        var deletedEditorSnapshot = deletedEditorToken.item
        deletedEditorSnapshot.details = "Unsaved local text after the item was deleted elsewhere"
        try saveElsewhere([other]); future.refresh()
        let deletionReportedSaved = saveFromOpenEditor(deletedEditorSnapshot, basedOn: deletedEditorToken)
        check(!deletionReportedSaved, "saving an editor for a remotely deleted item must report a conflict instead of success")
        check(try FutureMarkdown.decode(currentPage().body) == [other], "the deleted item is not silently resurrected")

        // Control: an entirely stale store, with no observer refresh, is already
        // protected by the candidate's page-revision check.
        try saveElsewhere([original, other])
        future.refresh()
        let freshEditor = future.beginEdit(future.items[0])!
        var freshEdit = freshEditor.item; freshEdit.title = "A valid editor save"
        check(future.saveEdit(freshEdit, basedOn: freshEditor), "an unchanged opening revision accepts the editor draft")
        check(try FutureMarkdown.decode(currentPage().body).first?.title == freshEdit.title, "successful editor Save actually persists its text")
        let foreignEditor = FutureEdit(item: freshEdit, projectID: UUID(), pageID: currentPage().id, revision: currentPage().revision)
        let beforeForeign = currentPage()
        check(!future.saveEdit(freshEdit, basedOn: foreignEditor) && currentPage() == beforeForeign, "a different project's editor cannot claim success or change this plan")
        let viewSource = try String(contentsOfFile: "Sources/Silkwire/FutureView.swift", encoding: .utf8)
        check(viewSource.contains("future.beginEdit(item)") && viewSource.contains("future.saveEdit(updated, basedOn: edit)"), "the mounted sheet wiring uses the tested opening-snapshot API")
        let stale = FutureStore(); stale.attach(store)
        var newest = original; newest.details = "Latest saved details for the stale-store control"
        try saveElsewhere([newest, other])
        let beforeStale = currentPage()
        stale.update(project) { $0.append(FutureItem(title: "Stale append")) }
        check(stale.error != nil, "control: a stale unrefreshed store is rejected")
        check(currentPage() == beforeStale, "control: a rejected stale store leaves the whole page unchanged")

        // Recovery corruption must fail closed, just as a linked recovery target
        // does in FutureTests. All files below belong to this synthetic fixture.
        let beforeRecovery = currentPage()
        let folder = root.appendingPathComponent("Alexandria Recovery/\(project.uuidString)/\(beforeRecovery.id.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("revision-\(beforeRecovery.revision).json")
        let sentinel = Data("synthetic invalid recovery JSON".utf8)
        try sentinel.write(to: target, options: .withoutOverwriting)
        let recoveryResult = store.saveLibraryPage(id: beforeRecovery.id, section: beforeRecovery.section, title: beforeRecovery.title, body: try FutureMarkdown.encode([other]), baseRevision: beforeRecovery.revision)
        if case .invalid = recoveryResult { check(true, "a corrupt existing recovery copy rejects the new edit") }
        else { check(false, "a corrupt existing recovery copy rejects the new edit") }
        check(currentPage() == beforeRecovery, "recovery failure preserves the current page and its history")
        check(try Data(contentsOf: target) == sentinel, "recovery failure does not overwrite the existing evidence")

        for details in ["", "Paragraph one\n\nParagraph two\n\n", "# Ordinary heading\n```swift\nlet example = 1\n```\nUnicode: 🧵"] {
            let item = FutureItem(title: "Round trip", details: details)
            check(try FutureMarkdown.decode(FutureMarkdown.encode([item])) == [item], "ordinary multiline details round-trip without loss")
        }
        do {
            _ = try FutureMarkdown.encode([original, original])
            check(false, "duplicate task IDs are refused")
        } catch { check(true, "duplicate task IDs are refused") }
        check(store.save(), "the surviving synthetic library reaches a durable boundary")
        let reopened = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
        check(reopened.projects.first { $0.id == project }?.library == store.libraryPages, "the durable snapshot matches the surviving in-memory library")
        print("MemoryRecoveryReviewTests: \(checks) checks, \(failures) failures; synthetic save paths, not mounted UI")
        if failures > 0 { exit(1) }
    }
}
