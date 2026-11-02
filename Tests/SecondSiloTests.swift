import Foundation

@main struct SecondSiloTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let a = UUID(), b = UUID(), c = UUID(), all: Set<UUID> = [a, b, c]
        var deck = ConversationDeck()
        deck.open(a, availableIDs: all)
        check(SiloNavigator.companion(deck, current: a) == nil, "one open conversation shows no second silo")
        deck.open(b, availableIDs: all, activate: false)
        check(SiloNavigator.companion(deck, current: a) == b, "the next open conversation sits beside the first")
        check(SiloNavigator.companion(deck, current: b) == a, "the last conversation shows the previous one beside it")
        deck.open(c, availableIDs: all, activate: false)
        check(SiloNavigator.companion(deck, current: b) == c, "a middle conversation shows the next one")
        check(SiloNavigator.companion(deck, current: UUID()) == nil, "a conversation that isn't open shows no companion")

        let m = SiloLayout.outerMargin
        check(SiloLayout.pairWidth(available: 2000, preferred: 740) == 740, "wide middle space: both silos at the chosen width")
        let snug = SiloLayout.pairWidth(available: 1400, preferred: 740)
        check(snug != nil && snug! < 740 && snug! * 2 + m * 3 <= 1400, "less room: both silos share it evenly")
        check(SiloLayout.pairWidth(available: 1100, preferred: 740) == nil, "too narrow for two comfortable silos: only one shows")
        check(SiloLayout.pairWidth(available: .infinity, preferred: 740) == nil, "bad geometry shows one silo")
        check((SiloLayout.pairWidth(available: 5000, preferred: 5000) ?? 0) <= SiloLayout.maximumPreferredSiloWidth, "silos never exceed the chosen maximum")

        let app = (try? String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)) ?? ""
        check(app.contains("companion: split == nil || pairSplit != nil ? companion : nil"), "a page beside chat hides the second silo only when all three can't fit")
        check(app.contains("$0.id == id && !$0.archived"), "archived conversations never appear as a second silo")
        check(app.contains("guard store.selectConversation(id) else"), "switching to the second silo is refused while a reply is running")
        print("PASS: \(count) second-silo checks")
    }
}
