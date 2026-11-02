import Foundation

@main struct ComposerHeightTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        check(SiloLayout.defaultComposerHeight > 82, "the writing space starts taller than before")
        check(SiloLayout.clampedComposer(10) == SiloLayout.minimumComposerHeight, "it can't be dragged too short")
        check(SiloLayout.clampedComposer(5000) == SiloLayout.maximumComposerHeight, "it can't be dragged taller than its limit")
        check(SiloLayout.clampedComposer(.nan) == SiloLayout.defaultComposerHeight, "bad values fall back to the default")
        let app = (try? String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)) ?? ""
        check(app.contains("@AppStorage(\"composer.fieldHeight\")"), "the chosen height is remembered")
        check(app.contains("HeightGrip().offset(y: -6).gesture(composerResizeGesture)"), "the composer's top edge has a visible drag grip")
        check(!app.contains(".frame(height: 82)"), "no fixed 82-point writing space remains")
        check(app.contains("You're viewing an archived conversation. It's read-only.") && app.contains("Restore to continue"), "archived conversations opened from search explain themselves and offer Restore")
        print("PASS: \(count) composer height and archived-view checks")
    }
}
