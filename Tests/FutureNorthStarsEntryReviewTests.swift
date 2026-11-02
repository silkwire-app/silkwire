import Foundation
import Darwin

// Independent review of receipt 57951715 at 165a21b.
// Runtime checks use only isolated synthetic ConversationStore data. The final
// checks inspect the actual view source wiring; they do NOT click or render a UI.
@main struct FutureNorthStarsEntryReviewTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "FutureNorthStarsEntryReviewTests", code: 2, userInfo: [NSLocalizedDescriptionKey: label]) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FutureNorthStarsEntry-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The store can capture and save a first-ever North Stars edit correctly.
        do {
            let store = ConversationStore(directory: root.appendingPathComponent("new-page"))
            let future = FutureStore(); future.attach(store)
            try require(store.storageError == nil, "Synthetic store must be writable")
            guard let project = store.activeProject?.id, let edit = future.beginNorthStarsEdit() else { throw CocoaError(.fileReadCorruptFile) }
            check(edit.projectID == project && edit.pageID == nil && edit.revision == nil && edit.original.isEmpty, "first-use model snapshot identifies the project and absence of a saved page")
            check(future.saveNorthStars("- First synthetic North Star", basedOn: edit), "a captured first-use snapshot can save North Stars")
            guard let saved = store.libraryPages.first(where: { $0.title == FutureStore.pageTitle && $0.section == LibrarySection.shared.rawValue }) else { throw CocoaError(.fileNoSuchFile) }
            let decoded = try FutureMarkdown.decodePage(saved.body)
            check(decoded.items.isEmpty && FutureMarkdown.northStars(in: decoded.preamble) == "- First synthetic North Star", "first-use save creates the intended page without phantom cards")
            let rejected = !future.saveNorthStars("- Stale first-use draft", basedOn: edit)
            check(rejected && store.libraryPages.first(where: { $0.id == saved.id })?.body == saved.body, "the now-stale no-page snapshot cannot overwrite the newly created page")
        }
        // The Add entry is also shown when cards exist but North Stars do not.
        do {
            let store = ConversationStore(directory: root.appendingPathComponent("cards-without-stars"))
            let future = FutureStore(); future.attach(store)
            guard let project = store.activeProject?.id else { throw CocoaError(.fileReadCorruptFile) }
            try require(future.add(title: "Keep this card", details: "Synthetic notes", project: project), "Synthetic card must save")
            let cards = future.items
            guard let edit = future.beginNorthStarsEdit() else { throw CocoaError(.fileReadCorruptFile) }
            check(edit.pageID == future.currentPageID && edit.pageID != nil && edit.revision != nil && edit.original.isEmpty, "cards without stars also provide a valid opening snapshot")
            let saved = future.saveNorthStars("- New stars above existing cards", basedOn: edit)
            check(saved && future.items == cards && future.northStars == "- New stars above existing cards", "first North Stars save preserves existing card identities and notes")
        }

        // This is a deliberately narrow source-level integration regression, not
        // a model imitation presented as a successful GUI reproduction.
        // Scripts/test.swift copies suites under output/tests, but deliberately
        // launches each executable with its currentDirectoryURL set to the repo.
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let view = try String(contentsOf: repository.appendingPathComponent("Sources/Silkwire/FutureView.swift"), encoding: .utf8)
        check(view.contains(".sheet(isPresented: $editingStars") && view.contains("if let edit = starsEdit"), "source control: North Stars sheet requires a captured starsEdit")
        let label = "Add our North Stars"
        check(view.contains(label), "source control: the first-use North Stars entry is present")
        let barePresentation = try NSRegularExpression(pattern: #"Button\("Add our North Stars"\)\s*\{\s*editingStars\s*=\s*true\s*\}"#)
        let matches = barePresentation.matches(in: view, range: NSRange(view.startIndex..., in: view))
        for match in matches {
            if let range = Range(match.range, in: view) {
                let line = view[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                print("Observed source wiring at FutureView.swift:\(line): \(view[range])")
            }
        }
        check(matches.isEmpty, "first-use entry must not present the snapshot-dependent sheet without capturing its opening snapshot")
        print("Future North Stars entry review: \(passed) passed, \(failed) failed; synthetic model data and source-level wiring only, no live UI")
        if failed > 0 { exit(1) }
    }
}
