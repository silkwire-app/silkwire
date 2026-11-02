import Foundation

// Alexandria library rules: saving, history, no silent overwrites, search.
@main struct AlexandriaTests {
    @MainActor static func main() throws {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ label: String) { checks += 1; if ok { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) } }
        var pages: [LibraryPage] = []
        let id = UUID(), t0 = Date(timeIntervalSince1970: 1_000_000)

        // First journey: create, read, edit, save, reopen.
        guard case .saved(let first) = Alexandria.save(&pages, id: id, section: "shared", title: "  Chime recipe ", body: "Four notes.", author: "Jason", baseRevision: nil, now: t0) else { check(false, "new page saves"); exit(1) }
        check(first.revision == 1 && first.title == "Chime recipe" && first.history.isEmpty && pages.count == 1, "new page saves at version 1 with a trimmed title")
        guard case .saved(let second) = Alexandria.save(&pages, id: id, section: "shared", title: "Chime recipe", body: "Four happy notes.", author: "Eve", baseRevision: 1, now: t0.addingTimeInterval(60)) else { check(false, "edit saves"); exit(1) }
        check(second.revision == 2 && second.updatedBy == "Eve" && second.history.count == 1 && second.history[0].body == "Four notes." && second.history[0].author == "Jason", "an edit keeps the previous version in History with its author")

        // No silent overwrites.
        let stale = Alexandria.save(&pages, id: id, section: "shared", title: "Chime recipe", body: "Mine", author: "Jason", baseRevision: 1)
        if case .conflict(let theirs) = stale { check(theirs.revision == 2 && pages[0].body == "Four happy notes.", "a stale edit is refused as a conflict and nothing is written") } else { check(false, "a stale edit is refused as a conflict") }
        check(Alexandria.save(&pages, id: id, section: "shared", title: "Chime recipe", body: "Four happy notes.", author: "Jason", baseRevision: 2) == .unchanged && pages[0].revision == 2, "saving identical text adds no version")
        check(Alexandria.save(&pages, id: UUID(), section: "shared", title: "   ", body: "x", author: "Jason", baseRevision: nil) == .invalid("Give the page a title first."), "a page needs a title")
        if case .invalid = Alexandria.save(&pages, id: UUID(), section: "home", title: "x", body: "", author: "Jason", baseRevision: nil) { check(true, "Home is not a place to file pages") } else { check(false, "Home is not a place to file pages") }
        if case .invalid = Alexandria.save(&pages, id: UUID(), section: "shared", title: "Gone", body: "", author: "Jason", baseRevision: 3) { check(true, "an edit to a page that no longer exists is refused") } else { check(false, "an edit to a page that no longer exists is refused") }

        // Removing an imported vault takes only its pages.
        var shelf: [LibraryPage] = []
        _ = Alexandria.save(&shelf, id: UUID(), section: "shared", title: "Team plan", body: "Ours", author: "Jason", baseRevision: nil)
        for (vault, name) in [("v1", "Breakroom"), ("v2", "Agent Collaboration")] {
            let pid = UUID()
            if case .saved = Alexandria.save(&shelf, id: pid, section: "vaults", title: name + " note", body: "x", author: "Obsidian import", baseRevision: nil), let i = shelf.firstIndex(where: { $0.id == pid }) {
                shelf[i].sourcePath = name + "/note.md"; shelf[i].sourceVault = vault; shelf[i].importedRevision = 1
            }
        }
        if let i = shelf.firstIndex(where: { $0.sourceVault == "v1" }) { shelf[i].revision = 2 }
        let vaultGroups = Alexandria.importedVaults(shelf)
        check(vaultGroups.count == 2 && vaultGroups.contains { $0.name == "Breakroom" && $0.editedTitles == ["Breakroom note"] }, "imported vaults are listed by name, with pages edited since import flagged")
        let split = Alexandria.removingVault("v1", from: shelf)
        check(split.removed.count == 1 && split.kept.count == 2 && split.kept.contains { $0.title == "Team plan" } && split.kept.contains { $0.sourceVault == "v2" }, "removing a vault takes only its imported pages; team pages and other vaults stay")

        var tocPages: [LibraryPage] = []
        for path in ["V/Zeta.md", "V/AGENTS.md", "V/Projects/Work/AGENTS.md", "V/Projects/Work/Brief 10.md", "V/Projects/Work/Brief 2.md"] {
            let pid = UUID(), name = String(path.split(separator: "/").last!.dropLast(3))
            if case .saved = Alexandria.save(&tocPages, id: pid, section: "vaults", title: name, body: "x", author: "Obsidian import", baseRevision: nil), let i = tocPages.firstIndex(where: { $0.id == pid }) { tocPages[i].sourcePath = path; tocPages[i].sourceVault = "v" }
        }
        let toc = Alexandria.contentsGroups(tocPages)
        check(toc.map(\.folder) == ["", "Projects › Work"] && toc[0].pages.map(\.title) == ["AGENTS", "Zeta"] && toc[1].pages.map(\.title) == ["AGENTS", "Brief 2", "Brief 10"], "contents group vault pages by folder, top level first, titles in natural order")

        // Moving a page between sections keeps its identity.
        _ = Alexandria.save(&pages, id: id, section: "reviewSecurity", title: "Chime recipe", body: "Four happy notes.", author: "Codex", baseRevision: 2)
        check(pages[0].id == id && pages[0].librarySection == .reviewSecurity && pages[0].librarySection.fullTitle == "Outside Reviews › Security", "moving a page keeps the same page, now under Outside Reviews")

        // History is capped, oldest dropped first.
        var rev = pages[0].revision
        for n in 0..<60 { _ = Alexandria.save(&pages, id: id, section: "shared", title: "Chime recipe", body: "v\(n)", author: "Claude", baseRevision: rev); rev += 1 }
        check(pages[0].history.count == Alexandria.historyLimit && pages[0].history.last?.body == "v58" && pages[0].revision == rev, "history keeps the newest \(Alexandria.historyLimit) earlier versions")

        // Sections are homes, not private.
        check(LibrarySection.allCases.filter(\.isPersonHome).allSatisfy { $0.blurb.contains("not a private one") } && Alexandria.notPrivate.contains("not private"), "every person's section says it is not private")
        check(LibrarySection.allCases.filter(\.isOutsideReview).map(\.title) == ["Design", "Security", "Code"], "Outside Reviews has Design, Security and Code")

        // Search: titles first, excerpts around the match.
        var lib: [LibraryPage] = []
        _ = Alexandria.save(&lib, id: UUID(), section: "shared", title: "Notes", body: String(repeating: "filler ", count: 40) + "the Pass button lives here" + String(repeating: " more", count: 40), author: "Jason", baseRevision: nil)
        _ = Alexandria.save(&lib, id: UUID(), section: "eve", title: "Pass button design", body: "Short.", author: "Eve", baseRevision: nil)
        let hits = Alexandria.search(lib, query: "pass button")
        check(hits.count == 2 && hits[0].title == "Pass button design", "title matches come first, case-insensitive")
        check(hits[1].excerpt.hasPrefix("…") && hits[1].excerpt.hasSuffix("…") && hits[1].excerpt.contains("Pass button"), "body matches show a clipped excerpt around the match")
        check(Alexandria.search(lib, query: "   ").isEmpty, "an empty search finds nothing")

        var a = Conversation(); a.title = "Collab Room"; a.messages = [Message(author: "Eve", text: "The chime is lovely", state: "completed"), Message(author: "Codex", text: "chime again", state: "completed")]
        var b = Conversation(); b.title = "Chime ideas"
        let c = Conversation()
        let rooms = Alexandria.conversations([a, b, c], query: "chime", excluding: c.id)
        check(rooms.count == 2 && rooms.first { $0.conversationID == a.id }?.matches == 2 && rooms.first { $0.conversationID == b.id }?.excerpt == "Title match", "conversation search counts matching messages and finds titles")
        check(Alexandria.conversations([a], query: "chime", excluding: a.id).isEmpty, "the open conversation is left to In this conversation")

        // Saved with the Project; older libraries without Alexandria still open.
        var project = Project(); project.library = pages
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        check(decoded.library == pages, "pages and history survive saving and reopening")
        let old = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(Project()))
        check(old.library == nil, "a Project saved before Alexandria opens with an empty library")

        // Review fixes: "Save mine anyway" overwrites only the version that was shown.
        var race: [LibraryPage] = []; let rid = UUID()
        _ = Alexandria.save(&race, id: rid, section: "shared", title: "Plan", body: "v1", author: "Jason", baseRevision: nil)
        _ = Alexandria.save(&race, id: rid, section: "shared", title: "Plan", body: "Eve's v2", author: "Eve", baseRevision: 1)
        let shownToJason = race[0]
        _ = Alexandria.save(&race, id: rid, section: "shared", title: "Plan", body: "Codex's v3", author: "Codex", baseRevision: 2)
        if case .conflict(let newer) = Alexandria.save(&race, id: rid, section: "shared", title: "Plan", body: "Jason's", author: "Jason", baseRevision: shownToJason.revision) {
            check(newer.revision == 3 && race[0].body == "Codex's v3", "a save that arrives while the conflict warning is open triggers a fresh warning, not a silent overwrite")
        } else { check(false, "a save that arrives while the conflict warning is open triggers a fresh warning") }
        check(!Alexandria.notPrivate.contains("every save") && Alexandria.notPrivate.contains("latest 50"), "History wording states the 50-version limit")

        // Drafts survive quitting.
        let suite = "silkwire.alexandria.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let draftID = UUID()
        do { let state = AlexandriaState(defaults: defaults); state.drafts[draftID] = .init(projectID: nil, title: "Half-written", body: "Keep me", section: "shared", baseRevision: nil) }
        let reopened = AlexandriaState(defaults: defaults)
        check(reopened.drafts[draftID]?.body == "Keep me", "an unsaved draft is still there after a restart")
        reopened.drafts[draftID] = nil
        check(AlexandriaState(defaults: defaults).drafts.isEmpty, "a saved or discarded draft does not come back")
        defaults.removePersistentDomain(forName: suite)

        print("AlexandriaTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
