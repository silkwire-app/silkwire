import Foundation
import AppKit
import SwiftUI

// Typing performance: keystrokes stay in the text field and are committed to the
// right conversation after a short pause, on Send, or when switching; streamed
// replies redraw less often while someone is typing.
@main struct ComposerIsolationTests {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        final class Box { var text = ""; var writes = 0; var commits: [(String, UUID)] = [] }
        let box = Box()
        let a = UUID(), b = UUID()
        let binding = Binding(get: { box.text }, set: { box.text = $0; box.writes += 1 })
        var composer = NativeComposer(text: binding, enabled: true, addURLs: { _ in }, addImage: { _ in }, send: {}, owner: a, commitDraft: { text, id in box.commits.append((text, id)); if id == a { box.text = text } }, onTyping: {})
        let coordinator = composer.makeCoordinator()
        let field = NSTextView()
        for word in ["H", "He", "Hel", "Hell", "Hello"] {
            field.string = word
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
        }
        check(box.writes == 0, "five keystrokes write nothing to the conversation (no whole-window redraw per key)")
        check(coordinator.pending?.text == "Hello" && coordinator.pending?.owner == a, "typed text is held for the right conversation")
        coordinator.synchronizeText(in: field)
        check(field.string == "Hello", "a redraw while typing never overwrites what's in the field")
        coordinator.commitNow()
        check(box.commits.count == 1 && box.commits[0].0 == "Hello" && box.commits[0].1 == a, "Send/switch commits the latest text once, to its own conversation")
        check(coordinator.pending == nil, "nothing left pending after commit")

        field.string = "Draft for A"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
        let typed = coordinator.takePending()
        check(typed?.owner == a && typed?.text == "Draft for A", "switching hands back A's unsaved typing, labelled for A")
        composer.owner = b
        coordinator.parent = composer
        check(coordinator.pending == nil, "B starts with no stray text from A")

        let wait = expectation(seconds: NativeComposer.commitDelay + 0.3) {
            field.string = "auto"
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
        }
        check(wait && box.commits.last?.0 == "auto" && box.commits.last?.1 == b, "a short pause commits automatically")

        var plain = NativeComposer(text: binding, enabled: true, addURLs: { _ in }, addImage: { _ in }, send: {})
        plain.owner = nil
        let plainCoordinator = plain.makeCoordinator()
        field.string = "legacy"
        plainCoordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
        check(box.text == "legacy", "without an owner the composer still writes directly (other uses unchanged)")

        check(ConversationStore.streamInterval(sinceKeystroke: 0.2) == 250, "while typing, replies redraw at most 4 times a second")
        check(ConversationStore.streamInterval(sinceKeystroke: 5) == 100, "when idle, replies redraw 10 times a second (was 30)")
        check(TranscriptWindow.initial == 25, "conversation draws the newest 25 messages")
        let app = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/Silkwire/SilkwireApp.swift"), encoding: .utf8)
        check(!app.contains("Tall side composer"), "side composer option removed; composer always below")
        check(app.contains("registerFlush:") && app.contains("commitDraft:"), "main composer uses the deferred-commit path")
        print("\(checks - failures) of \(checks) checks passed")
        if failures > 0 { exit(1) }
    }
    /// Runs `action`, then spins the main run loop for `seconds` so delayed work can fire.
    static func expectation(seconds: TimeInterval, _ action: () -> Void) -> Bool {
        action()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        return true
    }
}
