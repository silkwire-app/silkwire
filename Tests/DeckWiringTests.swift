import Foundation

// Pure checks for how the window drives Codex's ConversationDeck: syncing with
// whatever is on screen, sliding with the arrows, refusals while a reply runs,
// closing a silo and restoring after a restart. Does not render SwiftUI.
@main struct DeckWiringTests {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        let team = UUID(), eve = UUID(), claude = UUID(), codex = UUID(), archived = UUID()
        let available: Set<UUID> = [team, eve, claude, codex]

        var deck = SiloNavigator.synced(ConversationDeck(), current: team, available: available)
        check(deck.openIDs == [team] && deck.focusedID == team, "first launch opens the conversation on screen as a silo")
        check(SiloNavigator.label(deck) == nil, "one silo shows no arrows")

        deck = SiloNavigator.synced(deck, current: eve, available: available)
        deck = SiloNavigator.synced(deck, current: claude, available: available)
        check(deck.openIDs == [team, eve, claude] && deck.focusedID == claude, "opening conversations from the sidebar adds silos in order")
        check(SiloNavigator.label(deck) == "3 of 3", "label shows position, n of N")

        deck = SiloNavigator.synced(deck, current: team, available: available)
        check(deck.openIDs == [team, eve, claude] && deck.focusedID == team, "choosing an already open conversation focuses it without duplicating")

        check(SiloNavigator.target(deck, .previous) == nil, "left arrow at the first silo goes nowhere")
        check(SiloNavigator.target(deck, .next) == eve, "right arrow targets the silo to the right")

        let before = deck
        check(!SiloNavigator.commit(&deck, to: eve, switched: false) && deck == before, "refused switch (reply running) leaves the arrows where they were")
        check(SiloNavigator.commit(&deck, to: eve, switched: true) && deck.focusedID == eve && SiloNavigator.label(deck) == "2 of 3", "completed switch moves focus")

        guard let closed = SiloNavigator.closing(deck, current: eve) else { check(false, "closing a middle silo is possible"); return }
        check(closed.deck.openIDs == [team, claude] && closed.show == claude, "closing a silo slides to its right-hand neighbour")
        check(available.contains(eve), "closing a silo never archives or deletes the conversation")
        let single = SiloNavigator.synced(ConversationDeck(), current: team, available: available)
        check(SiloNavigator.closing(single, current: team) == nil, "the only silo cannot be closed")

        var withArchived = SiloNavigator.synced(ConversationDeck(), current: team, available: available.union([archived]))
        withArchived = SiloNavigator.synced(withArchived, current: archived, available: available.union([archived]))
        withArchived = SiloNavigator.synced(withArchived, current: team, available: available.union([archived]))
        let afterArchive = SiloNavigator.synced(withArchived, current: team, available: available)
        check(afterArchive.openIDs == [team], "archived or deleted conversations drop out of the silos")
        let onScreenArchived = SiloNavigator.synced(ConversationDeck(), current: archived, available: available)
        check(onScreenArchived.focusedID == archived, "whatever is on screen is always an open silo")

        let saved = SiloNavigator.encode(deck)
        let restored = SiloNavigator.decode(saved)
        check(restored == deck, "silos and position survive a restart")
        check(SiloNavigator.decode("not json") == ConversationDeck() && SiloNavigator.decode("") == ConversationDeck(), "damaged or missing saved silos start fresh without crashing")
        let stale = SiloNavigator.synced(restored, current: team, available: [team, claude])
        check(stale.openIDs == [team, claude] && stale.focusedID == team, "restored silos for removed conversations are dropped")

        print("\(checks - failures) of \(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
