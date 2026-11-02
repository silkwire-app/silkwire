import Foundation

@main struct SideBySideReaderTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let m = SiloLayout.outerMargin, d = SiloLayout.dividerWidth
        // Chosen chat width, within limits.
        check(SiloLayout.defaultSiloWidth == 740, "chat column defaults to 740 points")
        check(SiloLayout.clampedPreferred(200) == SiloLayout.minimumSiloWidth, "dragging can't make chat too narrow")
        check(SiloLayout.clampedPreferred(5000) == SiloLayout.maximumPreferredSiloWidth, "dragging can't make chat too wide")
        check(SiloLayout.clampedPreferred(.nan) == SiloLayout.defaultSiloWidth, "bad values fall back to the default")
        check(SiloLayout.siloWidth(available: 2000, preferred: 740) == 740, "wide window: chat stays at the chosen width")
        check(SiloLayout.siloWidth(available: 600, preferred: 740) == 600 - m * 2, "narrow window: chat fits inside its margins")

        // Side by side on a wide window: chat keeps its width, the page takes the rest.
        let wide = SiloLayout.sideBySide(total: 1500, preferred: 740)
        check(wide?.chat == 740 + m * 2, "wide window keeps chat at its chosen width beside the page")
        check(wide.map { $0.chat + d + $0.reader } == 1500, "chat, divider and page fill the space exactly")
        check((wide?.reader ?? 0) >= SiloLayout.minimumReaderWidth, "the page gets at least its readable minimum")
        // Tighter: chat gives up width before the page drops below its minimum.
        let tight = SiloLayout.sideBySide(total: 1200, preferred: 740)
        check(tight?.reader == SiloLayout.minimumReaderWidth && (tight?.chat ?? 0) < 740 + m * 2, "tighter window narrows chat, keeps the page readable")
        check((tight?.chat ?? 0) >= SiloLayout.minimumSiloWidth + m * 2, "chat never drops below its minimum beside the page")
        // Too narrow for both: the page opens over the conversation instead.
        check(SiloLayout.sideBySide(total: 900, preferred: 740) == nil, "narrow window falls back to the overlay")
        check(SiloLayout.sideBySide(total: .infinity, preferred: 740) == nil && SiloLayout.sideBySide(total: 0, preferred: 740) == nil, "bad geometry falls back safely")
        // A wider chosen chat still leaves the page readable.
        let big = SiloLayout.sideBySide(total: 1500, preferred: 960)
        check((big?.reader ?? 0) >= SiloLayout.minimumReaderWidth, "a wide chat choice still leaves room for the page")

        // Jason's page: settings including 'author' fold away and the repeated title hides.
        let page = "> project: Collaborative Agent Workspace\n> type: architecture-proposal\n> status: proposed\n> author: Eve\n> created: 2026-10-09\n\n# Architecture and Connection Research\n**A recommendation to challenge**"
        let details = DocumentDetails.split(page)
        check(details.fields.map(\.key) == ["project", "type", "status", "author", "created"], "imported note settings with author fold into Document details")
        check(AlexandriaReading.displayBody(page, title: "Architecture and Connection Research").contains("# Architecture") == false, "the repeated title after settings is hidden")
        check(DocumentDetails.split("> Note: this is a real quote\n> Source: a book\nText").fields.isEmpty, "capitalized quoted prose stays visible")
        check(DocumentDetails.split("> author: Eve\nText").fields.isEmpty, "a single settings-like line stays visible")
        // Codex review: ordinary quoted text stays visible, even beside real settings.
        check(DocumentDetails.split("> type: map\n> status: ok\n> remember: this is a real quote\nText").fields.isEmpty, "an unknown quoted line keeps the whole quotation visible")
        check(DocumentDetails.split("> to do: call Jason\n> author: Eve\nText").fields.isEmpty, "prose-like quoted lines are never folded")
        // Codex review: no second library panel beside the open page.
        let app = (try? String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)) ?? ""
        check(app.components(separatedBy: "library.open && !readerBeside && mode == AlexandriaMode.").count - 1 == 3, "drawer, Below and Peek panels stay hidden while a page is open beside chat")
        check(app.contains("if library.open && mode == AlexandriaMode.dock.rawValue && split == nil"), "the Welcome dock steps aside while a page is open beside chat")
        check(app.contains("readerBeside: split != nil"), "the conversation column is told when the page is beside it")
        // Jason: Alexandria anchored to the rail at its own width, with a gap after chat.
        let roomy = SiloLayout.sideBySide(total: 2400, preferred: 740, preferredReader: 1060)
        check(roomy?.reader == 1060 && (roomy?.gap ?? 0) > 400, "a wide monitor leaves a gap between chat and the page")
        check(roomy.map { $0.chat + $0.gap + d + $0.reader } == 2400, "chat, gap and page fill the window exactly")
        let snug = SiloLayout.sideBySide(total: 1500, preferred: 740, preferredReader: 1060)
        check(snug?.gap == 0 && (snug?.reader ?? 0) >= SiloLayout.minimumReaderWidth, "without spare room the gap closes before the page shrinks below its minimum")
        check(SiloLayout.clampedReader(100) == SiloLayout.minimumReaderWidth && SiloLayout.clampedReader(9999) == SiloLayout.maximumReaderWidth, "page width stays within its limits when dragged")
        // Jason: the narrowest chat was too narrow (pills wrapped).
        check(SiloLayout.minimumSiloWidth >= 600, "chat can't be dragged narrow enough to wrap the composer's teammate pills")
        check(app.components(separatedBy: "ResizeGrip()").count - 1 == 2, "both draggable edges show a visible grip")
        print("PASS: \(count) side-by-side and reader checks")
    }
}
