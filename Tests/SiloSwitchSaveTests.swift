import Foundation

// Source contract: switching silos must not trigger an extra whole-workspace save
// from the view layer. Recipient changes are saved by the store's toggleRecipient.
@main struct SiloSwitchSaveTests {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let app = try String(contentsOf: root.appendingPathComponent("Sources/Silkwire/SilkwireApp.swift"), encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("Sources/Silkwire/ConversationStore.swift"), encoding: .utf8)
        check(!app.contains("onChange(of: store.conversation.recipient) { _, _ in store.save() }"), "view no longer saves the whole workspace when a switch changes the recipient")
        if let range = store.range(of: "func toggleRecipient") {
            let body = store[range.lowerBound...].prefix(600)
            check(body.contains("save()"), "choosing recipients is still saved by the store")
        } else { check(false, "toggleRecipient exists") }
        if let range = store.range(of: "func selectConversation") {
            let rest = store[range.lowerBound...]
            let body = String(rest.range(of: "func newConversation").map { rest[..<$0.lowerBound] } ?? rest.prefix(1200))
            check(body.components(separatedBy: "save()").count - 1 == 1, "a silo switch performs exactly one save in the store")
        } else { check(false, "selectConversation exists") }
        print("\(checks - failures) of \(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
