import Foundation

@main struct SiloColumnLayoutTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let margin = SiloLayout.outerMargin
        check(SiloLayout.roomWidth(available: 2560, columns: 4, preferred: 520) == 520, "four medium rooms use 520 points rather than the former 600-point floor")
        check(SiloLayout.roomWidth(available: 1000, columns: 4, preferred: 520) == 460, "narrow windows retain four readable rooms through horizontal overflow")
        check(SiloLayout.roomWidth(available: .nan, columns: 4, preferred: 520) == 0, "invalid room geometry is refused")
        check(SiloLayout.roomWidth(available: 1000, columns: 0, preferred: 520) == 0, "an empty room list has no phantom column")
        check(SiloLayout.clampedRoomWidth(.infinity) == SiloLayout.defaultRoomWidth, "invalid preferred width uses the default")
        check(SiloLayout.clampedRoomWidth(100) == 460 && SiloLayout.clampedRoomWidth(5000) == SiloLayout.maximumPreferredSiloWidth, "dragging remains within readable room limits")
        for count in 1...4 {
            for available in stride(from: CGFloat(500), through: 3500, by: 100) {
                let width = SiloLayout.roomWidth(available: available, columns: count, preferred: 740)
                check(width >= 460 && width <= 740, "room width never crushes text or exceeds the selected width")
                if available >= 460 * CGFloat(count) + margin * CGFloat(count + 1) {
                    check(width * CGFloat(count) + margin * CGFloat(count + 1) <= available + 0.001, "rooms fit without overflow whenever their minimum widths fit")
                }
            }
        }
        // Wide windows: the silo stops at its maximum and the rest stays open on the right.
        check(SiloLayout.siloWidth(available: 1600) == SiloLayout.maximumSiloWidth, "a wide window caps the silo at its maximum width")
        check(1600 - SiloLayout.siloWidth(available: 1600) - margin * 2 > 600, "a wide window leaves open space to the right")
        // Narrower windows: the silo fills what is there, inside its margins.
        check(SiloLayout.siloWidth(available: 700) == 700 - margin * 2, "a narrower window fills the space inside the margins")
        check(SiloLayout.maximumSiloWidth >= 820 + 40, "the maximum fits an 820-point message plus padding")
        check(CGFloat(SiloLayout.minimumColumnWidth) < SiloLayout.maximumSiloWidth, "the minimum column width is below the maximum")
        // Opening Alexandria's dock narrows the space but never recenters: the width is
        // unchanged until the space is smaller than the silo itself.
        check(SiloLayout.siloWidth(available: 1600) == SiloLayout.siloWidth(available: 1600 - 380), "docking Alexandria on a wide window leaves the silo the same width")
        // Bad geometry never produces a negative or infinite width.
        check(SiloLayout.siloWidth(available: 0) == 0 && SiloLayout.siloWidth(available: -50) == 0, "no negative widths")
        check(SiloLayout.siloWidth(available: .infinity) == 0 && SiloLayout.siloWidth(available: .nan) == 0, "non-finite geometry is refused")
        // Header bands line up across the window.
        check(SiloLayout.headerRowHeight > 0 && SiloLayout.headerVerticalPadding > 0, "chat and Alexandria headers share a row height and padding")

        // The reader hides a first heading that repeats the page title; nothing else changes.
        check(AlexandriaReading.displayBody("# Product Map\nEverything here", title: "Product Map") == "Everything here", "repeated title heading hidden")
        check(AlexandriaReading.displayBody("\n## product map \nText", title: "Product Map") == "\nText", "case and spacing differences still match")
        check(AlexandriaReading.displayBody("---\ntype: map\n---\n# Product Map\nText", title: "Product Map") == "---\ntype: map\n---\nText", "front matter kept; heading after it hidden")
        check(AlexandriaReading.displayBody("> type: map\n> status: ok\n# Product Map\nText", title: "Product Map") == "> type: map\n> status: ok\nText", "quoted settings kept; heading after them hidden")
        check(AlexandriaReading.displayBody("# Overview\nText", title: "Product Map") == "# Overview\nText", "a different first heading is kept")
        check(AlexandriaReading.displayBody("Intro\n# Product Map", title: "Product Map") == "Intro\n# Product Map", "only a heading at the very top is hidden")
        check(AlexandriaReading.displayBody("### Product Map\nText", title: "Product Map") == "### Product Map\nText", "smaller headings are not treated as the title")
        check(AlexandriaReading.displayBody("# Product Map", title: "") == "# Product Map", "untitled pages are unchanged")
        print("PASS: \(count) silo column and reader checks")
    }
}
