import Foundation

// Jason: with three or four rooms open, an Alexandria page should slide over the rooms
// instead of pushing two of them away. Geometry checks plus source contracts; the mounted
// animation itself still needs a visual check.
@main struct AlexandriaSlideOverTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let peek = SiloLayout.slideOverRoomsPeek
        // Wide window: the page keeps its chosen width.
        check(SiloLayout.slideOverReaderWidth(available: 2800, preferred: 1060) == 1060, "on a wide window the page keeps its chosen width")
        // Narrower window: the page gives way so a strip of the rooms stays visible.
        let w = SiloLayout.slideOverReaderWidth(available: 1200, preferred: 1060)
        check(w == 1200 - peek, "on a narrower window a strip of the rooms stays visible beside the page")
        // Never narrower than a readable page.
        check(SiloLayout.slideOverReaderWidth(available: 500, preferred: 1060) == SiloLayout.minimumReaderWidth, "the page never gets narrower than its readable minimum")
        check(SiloLayout.slideOverReaderWidth(available: .nan, preferred: 1060) == SiloLayout.minimumReaderWidth, "invalid window geometry falls back safely")
        check(SiloLayout.slideOverReaderWidth(available: 2800, preferred: .infinity) <= SiloLayout.maximumReaderWidth, "an invalid saved width falls back within limits")
        check(SiloLayout.slideOverReaderWidth(available: 2800, preferred: 99_999) == SiloLayout.maximumReaderWidth, "the page never grows past its maximum")

        let app = (try? String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)) ?? ""
        check(app.contains("library.open && library.reading && openSiloConversations.count > 2"), "the page slides over whenever three or more rooms are open")
        check(app.contains("if library.open && library.reading && !readerSlidesOver {"), "rooms are only filtered when the page sits beside one or two rooms, never while it slides over")
        check(app.contains("library.open && library.reading && !readerSlidesOver && companion != nil") && app.contains("library.open && library.reading && !readerSlidesOver ? SiloLayout.sideBySide("), "sliding over never uses the side-by-side layout that shrinks the rooms")
        check(app.contains(".transition(.move(edge: .trailing).combined(with: .opacity))"), "the page slides in from the right")
        check(app.contains("split == nil && !readerSlidesOver {"), "the full-cover page for narrow windows doesn't also appear while sliding over")
        print("PASS: \(count) Alexandria slide-over checks (rendered animation not verified)")
    }
}
