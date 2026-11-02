import Foundation
import AppKit
import SwiftUI

// Synthetic grouping + offscreen SwiftUI layout checks, not a live-library or
// mouse/keyboard acceptance test. Source contracts protect the wiring that the
// offscreen renderer cannot activate.
@main struct AlexandriaContentsTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        var pages: [LibraryPage] = []
        for path in ["V/AGENTS.md", "V/Projects/Work/AGENTS.md", "V/Projects/Work/Brief 10.md", "V/Projects/Work/Brief 2.md", "V/Projects/Design/AGENTS.md"] {
            let id = UUID(), title = String(path.split(separator: "/").last!.dropLast(3))
            guard case .saved = Alexandria.save(&pages, id: id, section: "vaults", title: title, body: "Synthetic fixture", author: "Obsidian import", baseRevision: nil), let i = pages.firstIndex(where: { $0.id == id }) else { fatalError("Fixture save failed") }
            pages[i].sourcePath = path; pages[i].sourceVault = "synthetic-vault"
        }
        let before = pages
        let groups = Alexandria.contentsGroups(pages)
        check(groups.map(\.folder) == ["", "Projects › Design", "Projects › Work"], "top-level pages and full folder paths stay distinct")
        check(groups[2].pages.map(\.title) == ["AGENTS", "Brief 2", "Brief 10"], "folder pages retain natural title ordering")
        check(Set(groups.flatMap(\.pages).map(\.id)) == Set(pages.map(\.id)), "grouping preserves every page identity exactly once")
        check(Set(pages.filter { $0.title == "AGENTS" }.map(\.id)).count == 3, "same-named pages in different folders remain separate")

        let current = groups[2].pages[0]
        func size(folder: String, list: [LibraryPage], expanded: Bool? = nil, scheme: ColorScheme) throws -> CGSize {
            let group: AlexandriaContentsGroup
            if let expanded {
                group = AlexandriaContentsGroup(folder: folder, pages: list, currentID: current.id, expanded: expanded, open: { _ in })
            } else {
                // The stateless row defaults closed, matching the list's empty disclosure choice.
                group = AlexandriaContentsGroup(folder: folder, pages: list, currentID: current.id, open: { _ in })
            }
            let view = group.frame(width: 220).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            guard let image = renderer.nsImage else { throw NSError(domain: "ContentsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offscreen rendering returned no image"]) }
            return image.size
        }
        for scheme in [ColorScheme.light, .dark] {
            let expanded = try size(folder: groups[2].folder, list: groups[2].pages, expanded: true, scheme: scheme)
            let collapsed = try size(folder: groups[2].folder, list: groups[2].pages, expanded: false, scheme: scheme)
            check(expanded.width == 220 && collapsed.width == 220, "folder layouts fit the existing sidebar width in \(scheme)")
            check(collapsed.height > 0 && expanded.height > collapsed.height + 40, "collapsed folders retain a header and hide their page rows in \(scheme)")
            let defaultFolder = try size(folder: groups[2].folder, list: groups[2].pages, scheme: scheme)
            check(defaultFolder == collapsed, "folders start closed by default, including the initially selected page's folder in \(scheme)")
            let otherDefault = try size(folder: groups[1].folder, list: groups[1].pages, scheme: scheme)
            let otherCollapsed = try size(folder: groups[1].folder, list: groups[1].pages, expanded: false, scheme: scheme)
            check(otherDefault == otherCollapsed, "other imported folders also start closed in \(scheme)")
            let top = try size(folder: "", list: groups[0].pages, expanded: true, scheme: scheme)
            let topCollapsed = try size(folder: "", list: groups[0].pages, expanded: false, scheme: scheme)
            let topDefault = try size(folder: "", list: groups[0].pages, scheme: scheme)
            check(top.height == topCollapsed.height && top.height > 0, "top-level pages cannot be hidden by folder disclosure in \(scheme)")
            check(topDefault == top, "closed folder defaults leave root-level pages visible in \(scheme)")
            let long = try size(folder: String(repeating: "Long nested folder › ", count: 5), list: [current], expanded: false, scheme: scheme)
            check(long.width == 220 && long.height > collapsed.height, "long folder paths wrap instead of being limited to two lines in \(scheme)")
        }
        check(pages == before, "rendering contents never changes pages or import metadata")

        let source = try String(contentsOfFile: "Sources/Silkwire/AlexandriaView.swift", encoding: .utf8)
        check(source.contains("Button { toggle() }") && source.contains("chevron.down") && source.contains("chevron.right"), "source contract: folder control invokes shared disclosure and shows its state")
        check(source.contains("folder.fill") && source.contains("Image(systemName: \"doc.text\")"), "source contract: folders and pages use distinct icons")
        check(source.contains(".padding(.leading, folder.isEmpty ? 0 : 22)"), "source contract: contained pages indent 22 points; top-level pages do not")
        check(source.contains("Button { open(page.id) }") && source.contains("state.go(.page(id))"), "source contract: page buttons navigate by UUID, never by title")
        check(source.contains(".accessibilityLabel(\"Folder: \" + folder)") && source.contains(".accessibilityLabel(\"Page: \" + page.title)"), "source contract: accessibility distinguishes folders from pages")
        check(source.contains(".onChange(of: currentID)") && source.contains("disclosure.reveal(pageID: id, in: pages)"), "source contract: selecting a page through another route reveals only its folder")
        check(source.contains("Label(page.title, systemImage: page.id == current.id ? \"checkmark\" : \"doc.text\")"), "source contract: narrow-window Contents retains page icons and current-page checkmark")
        check(source.contains("expanded: disclosure.isExpanded(group.folder)") && source.contains("toggle: { disclosure.toggle(group.folder) }"), "source contract: every folder row reads and changes the same disclosure owner")
        check(source.contains("return AlexandriaContentsList(title: title, pages: siblings, currentID: current.id)") && source.contains("// Reset the single open-folder choice when entering another Project or vault/shelf."), "source contract: the reader hosts the shared list with a Project/vault identity")
        print("AlexandriaContentsTests: \(checks) checks, \(failures) failures; synthetic/offscreen only")
        if failures > 0 { exit(1) }
    }
}
