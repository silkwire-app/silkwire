import Foundation
import AppKit
import SwiftUI

// Synthetic accordion transitions and offscreen rows. These checks do not click
// a mounted reader, connect providers, or read Jason's library.
@main struct AlexandriaFolderDisclosureTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS: " + label) }
            else { failures += 1; print("FAIL: " + label) }
        }
        var pages: [LibraryPage] = []
        for path in ["V/AGENTS.md", "V/Projects/Work/AGENTS.md", "V/Projects/Work/Brief.md", "V/Projects/Design/AGENTS.md", "V/Projects/Work/Notes/AGENTS.md", "V/Projects/Design/Notes/AGENTS.md"] {
            let id = UUID(), title = String(path.split(separator: "/").last!.dropLast(3))
            guard case .saved = Alexandria.save(&pages, id: id, section: "vaults", title: title, body: "Synthetic fixture", author: "Obsidian import", baseRevision: nil), let index = pages.firstIndex(where: { $0.id == id }) else { fatalError("Fixture save failed") }
            pages[index].sourcePath = path
            pages[index].sourceVault = "synthetic-vault"
        }
        let original = pages
        func page(_ path: String) -> LibraryPage { pages.first { $0.sourcePath == path }! }
        let work = "Projects › Work", design = "Projects › Design"
        let workNotes = "Projects › Work › Notes", designNotes = "Projects › Design › Notes"
        let root = page("V/AGENTS.md"), workPage = page("V/Projects/Work/AGENTS.md"), designPage = page("V/Projects/Design/AGENTS.md")
        let folders = Alexandria.contentsGroups(pages).map(\.folder).filter { !$0.isEmpty }
        var disclosure = AlexandriaFolderDisclosure()
        check(disclosure.expandedFolder == nil && folders.allSatisfy { !disclosure.isExpanded($0) }, "a fresh contents list starts with every folder closed")
        check(disclosure.isExpanded(""), "root-level documents are always visible")
        disclosure.toggle(work)
        check(disclosure.expandedFolder == work && disclosure.isExpanded(work), "opening the first folder reveals its rows")
        check(!disclosure.isExpanded(design), "opening one folder does not open a sibling")
        disclosure.toggle(design)
        check(disclosure.expandedFolder == design && !disclosure.isExpanded(work), "opening another folder closes the previous one")
        disclosure.toggle(design)
        check(disclosure.expandedFolder == nil, "clicking the open folder closes it, allowing all folders to be closed")
        disclosure.toggle(work)
        disclosure.toggle("")
        check(disclosure.expandedFolder == work && disclosure.isExpanded(""), "root documents do not compete for the single folder choice")
        disclosure.toggle(workNotes)
        check(disclosure.expandedFolder == workNotes && !disclosure.isExpanded(work), "nested full-path groups also replace the previous open group")
        disclosure.toggle(designNotes)
        check(disclosure.expandedFolder == designNotes && !disclosure.isExpanded(workNotes), "identical leaf folder names are distinguished by their full paths")
        disclosure.reveal(pageID: workPage.id, in: pages)
        check(disclosure.expandedFolder == work && !disclosure.isExpanded(designNotes), "following a page by UUID reveals only its destination folder")
        disclosure.reveal(pageID: page("V/Projects/Work/Brief.md").id, in: pages)
        check(disclosure.expandedFolder == work, "moving between pages in one folder keeps that folder open")
        disclosure.reveal(pageID: designPage.id, in: pages)
        check(disclosure.expandedFolder == design && !disclosure.isExpanded(work), "same-named documents in different folders reveal the correct UUID destination")
        disclosure.reveal(pageID: root.id, in: pages)
        check(disclosure.expandedFolder == nil && disclosure.isExpanded(""), "navigating to a root document leaves no artificial folder open")
        disclosure.toggle(work)
        disclosure.reveal(pageID: UUID(), in: pages)
        check(disclosure.expandedFolder == nil, "an unresolved page cannot open the wrong folder")
        disclosure.toggle(work)
        disclosure.reconcile(in: pages)
        check(disclosure.expandedFolder == work, "ordinary page refreshes retain a still-existing folder choice")
        let withoutWork = pages.filter { $0.sourcePath?.hasPrefix("V/Projects/Work/") != true }
        disclosure.reconcile(in: withoutWork)
        check(disclosure.expandedFolder == nil, "removing an open folder clears its stale disclosure choice")
        var otherContents = AlexandriaFolderDisclosure()
        disclosure.toggle(work)
        otherContents.toggle(design)
        check(disclosure.expandedFolder == work && otherContents.expandedFolder == design, "separate contents owners do not share disclosure state")
        check(AlexandriaFolderDisclosure().expandedFolder == nil, "a newly scoped Project or vault starts closed again")

        var invariant = true
        for index in 0..<200 {
            if index % 5 == 0 { disclosure.reveal(pageID: root.id, in: pages) }
            else if index % 5 == 1 { disclosure.reveal(pageID: designPage.id, in: pages) }
            else { disclosure.toggle(folders[index % folders.count]) }
            invariant = invariant && folders.filter { disclosure.isExpanded($0) }.count <= 1 && disclosure.isExpanded("")
        }
        check(invariant, "mixed disclosure and navigation sequences never expose two folders or hide root documents")
        check(pages == original, "all disclosure and navigation transitions leave page bodies, IDs and import metadata unchanged")

        let groups = Alexandria.contentsGroups(pages)
        func size(_ folder: String, expanded: Bool, scheme: ColorScheme) throws -> CGSize {
            let group = groups.first { $0.folder == folder }!
            let view = AlexandriaContentsGroup(folder: folder, pages: group.pages, currentID: workPage.id, expanded: expanded, open: { _ in })
                .frame(width: 220).environment(\.colorScheme, scheme)
            guard let image = ImageRenderer(content: view).nsImage else { throw NSError(domain: "FolderDisclosureTests", code: 1) }
            return image.size
        }
        for scheme in [ColorScheme.light, .dark] {
            let closedWork = try size(work, expanded: false, scheme: scheme)
            let closedDesign = try size(design, expanded: false, scheme: scheme)
            let rootSize = try size("", expanded: true, scheme: scheme)
            var state = AlexandriaFolderDisclosure()
            state.toggle(work)
            let firstWork = try size(work, expanded: state.isExpanded(work), scheme: scheme)
            let firstDesign = try size(design, expanded: state.isExpanded(design), scheme: scheme)
            check(firstWork.width == 220 && firstWork.height > closedWork.height && firstDesign == closedDesign, "only the first chosen folder draws its page rows in \(scheme)")
            state.toggle(design)
            let nextWork = try size(work, expanded: state.isExpanded(work), scheme: scheme)
            let nextDesign = try size(design, expanded: state.isExpanded(design), scheme: scheme)
            check(nextWork == closedWork && nextDesign.width == 220 && nextDesign.height > closedDesign.height, "switching folders removes old rows and draws the new ones in \(scheme)")
            let stillRoot = try size("", expanded: state.isExpanded(""), scheme: scheme)
            check(stillRoot == rootSize && stillRoot.height > 0, "root documents remain rendered when the open folder changes in \(scheme)")
        }
        let source = try String(contentsOfFile: "Sources/Silkwire/AlexandriaView.swift", encoding: .utf8)
        check(source.contains("@State private var disclosure = AlexandriaFolderDisclosure()") && !source.contains("@State private var expanded: Bool"), "source contract: one list owns disclosure instead of separate row states")
        check(source.contains(".onChange(of: pages) { _, updated in disclosure.reconcile(in: updated) }"), "source contract: imported-page refreshes reconcile the open folder")
        print("AlexandriaFolderDisclosureTests: \(checks) checks, \(failures) failures; synthetic state and offscreen rows only, not mounted interaction")
        if failures > 0 { exit(1) }
    }
}
