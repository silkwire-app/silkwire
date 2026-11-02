import Foundation
import SwiftUI

// Synthetic state transitions and source wiring, not live data or a rendered-window acceptance test.
@main struct AlexandriaPresentationTests {
    @MainActor static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        let suite = "Silkwire.AlexandriaPresentationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AlexandriaState(defaults: defaults)
        let a = UUID(), b = UUID(), shot = UUID(), project = UUID()
        check(state.screen(for: .browser) == .home && state.screen(for: .reader) == .home, "initial surfaces show library home")
        state.go(.section(.vaults))
        check(state.screen(for: .browser) == .section(.vaults) && !state.reading, "shelves remain browsable without opening a reader")
        state.show(page: a, highlight: "synthetic match")
        check(state.open && state.reading, "choosing a page opens Alexandria and the main reader")
        check(state.screen(for: .reader) == .page(a), "the main reader owns the selected page")
        check(state.screen(for: .browser) == .home, "the dock returns to Welcome instead of duplicating the page")
        check(state.lastList == .section(.vaults), "the return shelf survives the Welcome projection")
        state.notice = "Synthetic notice"
        let screen = state.screen, highlight = state.highlight, notice = state.notice
        for _ in 0..<100 { _ = state.screen(for: .browser); _ = state.screen(for: .reader) }
        check(state.screen == screen && state.highlight == highlight && state.notice == notice && state.reading, "drawing either surface cannot navigate or clear reader state")
        state.go(.history(a))
        check(state.screen(for: .reader) == .history(a) && state.screen(for: .browser) == .home, "revision history also has only one owner")
        state.closeReader()
        check(!state.reading && state.screen == .section(.vaults), "closing history returns to the original shelf")
        state.go(.screenshots)
        check(state.screen(for: .browser) == .screenshots && !state.reading, "the screenshot gallery remains in the browser")
        state.go(.screenshot(shot))
        check(state.screen(for: .reader) == .screenshot(shot) && state.screen(for: .browser) == .home, "a full image is not repeated in the dock")
        state.closeReader()
        check(state.screen == .screenshots && !state.reading, "closing an image restores the screenshot gallery")
        state.show(page: a); state.go(.page(b))
        check(state.screen(for: .reader) == .page(b) && state.screen(for: .browser) == .home, "contents navigation replaces the sole reader page")
        state.go(.section(.shared))
        check(!state.reading && state.screen(for: .browser) == .section(.shared), "choosing a shelf closes the page reader rather than leaving a stale overlay")
        state.startNew(in: .shared, projectID: project)
        guard let draftID = state.editing else { fatalError("New synthetic draft was not created") }
        state.drafts[draftID]?.body = "Unsaved synthetic body"
        check(state.screen(for: .reader) == .page(draftID) && state.screen(for: .browser) == .home, "a new editor has a single surface too")
        state.closeReader()
        check(state.drafts[draftID]?.body == "Unsaved synthetic body" && state.editing == draftID, "closing presentation never discards an edit")
        check(AlexandriaState(defaults: defaults).drafts[draftID]?.body == "Unsaved synthetic body", "the existing persisted-draft recovery remains intact")
        state.go(.section(.shared)); state.reading = true
        check(state.screen(for: .reader) == .section(.shared) && state.screen(for: .browser) == .home, "manually expanded lists still do not mirror into the dock")
        state.closeReader()
        check(state.screen == .section(.shared), "closing a manually expanded list preserves that list")

        let threshold = AlexandriaReaderLayout.contentsWidth + 1 + AlexandriaReaderLayout.minimumPageWidth
        check(threshold == 681, "contents reserve 220 points plus divider and a readable 460-point page")
        check(AlexandriaReaderLayout.showsContents(availableWidth: threshold), "contents appear at the exact content-width boundary")
        check(!AlexandriaReaderLayout.showsContents(availableWidth: threshold - 0.5), "fractionally narrow readers use the compact contents route")
        check(AlexandriaReaderLayout.showsContents(availableWidth: 780), "the screenshot-sized reading area can show the left contents sidebar")
        check(!AlexandriaReaderLayout.showsContents(availableWidth: .infinity) && !AlexandriaReaderLayout.showsContents(availableWidth: .nan), "non-finite geometry cannot claim the sidebar fits")
        check(!AlexandriaReaderLayout.showsContents(availableWidth: -1) && !AlexandriaReaderLayout.showsContents(availableWidth: 0), "invalid or empty widths never squeeze in contents")
        let view = try String(contentsOfFile: "Sources/Silkwire/AlexandriaView.swift", encoding: .utf8)
        let app = try String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)
        check(app.components(separatedBy: "surface: .reader").count - 1 == 1, "source contract: exactly one app host explicitly owns the reader")
        check(view.contains("var surface: AlexandriaSurface = .browser"), "source contract: docks, drawers, Below and Peek default to browsers")
        check(view.contains("if surface == .browser && state.reading") && view.contains("ScrollView { homeView.padding(16) }"), "source contract: browser Welcome overrides page, history, screenshot and editor dispatch")
        check(view.contains("if !compact, displayScreen != .home") && view.contains("switch displayScreen"), "source contract: browser breadcrumbs and back controls match its displayed screen")
        check(view.contains("AlexandriaReaderLayout.showsContents(availableWidth: geometry.size.width)"), "source contract: actual available width decides contents, not text's intrinsic ideal width")
        check(view.contains("if fits && contentsVisible") && view.contains("contentsVisible.toggle()"), "source contract: the left contents sidebar is visible by default and can be toggled")
        check(view.contains(".popover(isPresented: $contentsPopover") && view.contains("contentsMenu(current)"), "source contract: narrow readers retain both folder sidebar popover and quick page menu")
        check(view.contains("state.go(.page(id)); contentsPopover = false"), "source contract: selecting a page dismisses compact contents")
        check(view.contains(".frame(width: AlexandriaReaderLayout.contentsWidth)"), "source contract: rendered contents width matches its layout budget")
        print("AlexandriaPresentationTests: \(checks) checks, \(failures) failures; state and source contracts, not rendered UI")
        if failures > 0 { exit(1) }
    }
}
