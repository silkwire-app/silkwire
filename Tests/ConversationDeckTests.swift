import Foundation

// Pure navigation/model coverage. Does not claim rendered-column, session-lifetime,
// simultaneous-send, full-app typing latency or memory-reduction acceptance.
@main struct ConversationDeckTests {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), unknown = UUID()
        let available: Set<UUID> = [a, b, c, d]
        var deck = ConversationDeck()
        check(deck.openIDs.isEmpty && deck.focusedID == nil && deck.focusedOrdinal == nil, "empty deck has no active column or ordinal")
        check(!deck.movePrevious() && !deck.moveNext(), "empty arrows do nothing")
        check(deck.displayedIDs(availableWidth: 2000).isEmpty, "empty deck renders no phantom conversation")
        check(deck.open(a, availableIDs: available, activate: false) && deck.focusedID == a, "first background open supplies a focus")
        check(deck.open(b, availableIDs: available, activate: false) && deck.focusedID == a, "background open preserves typing destination")
        check(deck.openIDs == [a, b], "new columns append in opening order")
        check(deck.open(b, availableIDs: available) && deck.openIDs == [a, b] && deck.focusedID == b, "opening an existing column focuses without duplication")
        let beforeInvalid = deck
        check(!deck.open(unknown, availableIDs: available) && deck == beforeInvalid, "unavailable opens are refused without mutation")
        check(!deck.focus(unknown) && deck == beforeInvalid, "unknown focus is refused without mutation")
        check(!deck.close(unknown) && deck == beforeInvalid, "unknown close is refused without mutation")
        check(deck.focusedOrdinal == 2 && deck.previousID == a && deck.nextID == nil, "n of N and neighbours describe focused column")
        check(!deck.moveNext() && deck.focusedID == b, "right arrow never wraps")
        check(deck.movePrevious() && deck.focusedID == a && deck.focusedOrdinal == 1, "left arrow visits previous conversation")
        check(!deck.movePrevious() && deck.focusedID == a, "left arrow never wraps")
        check(deck.moveNext() && deck.focusedID == b, "right arrow visits next conversation")

        deck = ConversationDeck(openIDs: [a, b, a, c, b], focusedID: b)
        check(deck.openIDs == [a, b, c] && deck.focusedID == b, "initial duplicates normalize without changing first-seen order")
        check(ConversationDeck(openIDs: [a, b], focusedID: unknown).focusedID == a, "invalid restored focus falls back to first open column")
        check(ConversationDeck(focusedID: unknown).focusedID == nil, "empty initial state cannot retain a foreign focus")
        check(deck.close(a) && deck.focusedID == b && deck.openIDs == [b, c], "closing an inactive left column preserves focus")
        check(deck.close(b) && deck.focusedID == c, "closing focused column prefers right neighbour")
        check(deck.close(c) && deck.openIDs.isEmpty && deck.focusedID == nil, "closing final column permits empty deck")
        deck = ConversationDeck(openIDs: [a, b, c], focusedID: c)
        check(deck.close(c) && deck.focusedID == b, "closing last column falls back left")
        check(deck.open(c, availableIDs: available) && deck.openIDs == [a, b, c], "reopening a hidden column appends it")

        deck = ConversationDeck(openIDs: [a, b, c], focusedID: b)
        check(deck.displayedIDs(availableWidth: 839) == [b], "automatic narrow view shows only the focused partition")
        check(deck.displayedIDs(availableWidth: 840) == [a, b, c], "automatic layout switches when two minimum columns fit")
        check(deck.resolvedPresentation(availableWidth: 999, minimumColumnWidth: 500) == .focus, "caller can supply a different minimum column width")
        check(deck.resolvedPresentation(availableWidth: 1000, minimumColumnWidth: 500) == .columns, "custom width threshold is inclusive")
        let resizeBefore = deck
        for width in [0.0, 500, 840, 2000, 700, 1200] { _ = deck.displayedIDs(availableWidth: width) }
        check(deck == resizeBefore, "resizing does not reorder columns or retarget focus")
        check([Double.nan, Double.infinity, -1].allSatisfy { deck.resolvedPresentation(availableWidth: $0) == .focus }, "invalid automatic widths fail to focus layout")
        check([0.0, -1, Double.nan, Double.infinity].allSatisfy { deck.resolvedPresentation(availableWidth: 2000, minimumColumnWidth: $0) == .focus }, "invalid minimum widths fail to focus layout")
        deck.presentation = .focus
        check(deck.displayedIDs(availableWidth: 3000) == [b], "explicit focus mode remains single-column on wide screens")
        deck.presentation = .columns
        check(deck.displayedIDs(availableWidth: 300) == [a, b, c], "explicit columns mode survives narrow resize for horizontal scrolling")
        var single = ConversationDeck(openIDs: [a], presentation: .columns)
        check(single.resolvedPresentation(availableWidth: 2000) == .focus && single.presentation == .columns, "single column preserves preferred layout for future opens")
        single.open(b, availableIDs: available, activate: false)
        check(single.resolvedPresentation(availableWidth: 300) == .columns && single.focusedID == a, "opening second column restores explicit columns without focus jump")

        deck = ConversationDeck(openIDs: [a, b, c, d], focusedID: b)
        deck.reconcile(availableIDs: [c, d])
        check(deck.openIDs == [c, d] && deck.focusedID == c, "multiple stale removals choose nearest original right neighbour")
        deck = ConversationDeck(openIDs: [a, b, c, d], focusedID: c)
        deck.reconcile(availableIDs: [a, b])
        check(deck.focusedID == b && deck.openIDs == [a, b], "reconciliation falls back to nearest surviving left neighbour")
        deck = ConversationDeck(openIDs: [a, b, c], focusedID: b)
        deck.reconcile(availableIDs: [b, c, d])
        check(deck.openIDs == [b, c] && deck.focusedID == b, "reconciliation keeps valid focus and does not open other available chats")
        let reconciled = deck
        deck.reconcile(availableIDs: [b, c, d])
        check(deck == reconciled, "reconciliation is idempotent")
        deck.reconcile(availableIDs: [])
        check(deck.openIDs.isEmpty && deck.focusedID == nil, "removing all available conversations leaves no stale destination")
        deck.reconcile(availableIDs: available)
        check(deck.openIDs.isEmpty, "availability alone does not resurrect hidden columns")

        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for mode in ConversationDeckPresentation.allCases {
            let original = ConversationDeck(openIDs: [c, a, b], focusedID: a, presentation: mode)
            let restored = try decoder.decode(ConversationDeck.self, from: encoder.encode(original))
            check(restored == original, "Codable preserves order, focus and " + mode.rawValue + " preference")
        }
        let emptyRestored = try decoder.decode(ConversationDeck.self, from: encoder.encode(ConversationDeck()))
        check(emptyRestored == ConversationDeck(), "empty deck round-trips")
        func decoded(_ object: [String: Any]) throws -> ConversationDeck {
            try decoder.decode(ConversationDeck.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let old = try decoded(["openIDs": [a.uuidString, b.uuidString, a.uuidString], "focusedID": b.uuidString])
        check(old.openIDs == [a, b] && old.focusedID == b && old.presentation == .automatic, "older hints default layout and normalize duplicate IDs")
        let foreign = try decoded(["openIDs": [a.uuidString], "focusedID": unknown.uuidString])
        check(foreign.focusedID == a, "foreign decoded focus cannot become another column")
        func rejects(_ object: [String: Any]) -> Bool {
            do { _ = try decoded(object); return false } catch { return true }
        }
        check(rejects(["version": 2, "openIDs": [a.uuidString]]), "future deck versions are refused rather than silently rewritten")
        check(rejects(["openIDs": ["not-a-uuid"]]), "malformed conversation IDs are refused")
        check(rejects(["openIDs": "wrong type"]), "malformed column arrays are refused")
        check(rejects(["openIDs": [], "presentation": "unknown"]), "unknown layout modes are refused")
        check(rejects(["presentation": "focus"]), "missing required column list is refused")
        let metadata = try JSONSerialization.jsonObject(with: encoder.encode(old)) as! [String: Any]
        check(Set(metadata.keys) == Set(["version", "openIDs", "focusedID", "presentation"]), "saved deck contains only navigation hints, no messages, sessions or permissions")

        var first = Conversation(), second = Conversation()
        first.draft = "Synthetic first draft"; second.draft = "Synthetic second draft"
        first.messages = [Message(author: "Eve", text: "First synthetic history", state: "completed")]
        second.messages = [Message(author: "Eve", text: "Second synthetic history", state: "completed")]
        let firstBytes = try encoder.encode(first), secondBytes = try encoder.encode(second)
        var independent = ConversationDeck(openIDs: [first.id, second.id])
        check(independent.openIDs.count == 2, "same-agent conversations remain distinct by conversation ID")
        independent.moveNext(); independent.close(first.id); independent.close(second.id)
        let firstAfter = try encoder.encode(first), secondAfter = try encoder.encode(second)
        check(firstBytes == firstAfter && secondBytes == secondAfter, "model navigation and hiding cannot modify original histories or drafts")

        // Repeatable stress without accounts, real conversations or random test flakes.
        var seed: UInt64 = 0x51_1C_01, invariantOK = true
        var stress = ConversationDeck()
        let pool = [a, b, c, d]
        for _ in 0..<3000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let id = pool[Int((seed >> 32) % 4)]
            switch Int((seed >> 16) % 7) {
            case 0: stress.open(id, availableIDs: available, activate: true)
            case 1: stress.open(id, availableIDs: available, activate: false)
            case 2: stress.close(id)
            case 3: stress.focus(id)
            case 4: stress.moveNext()
            case 5: stress.movePrevious()
            default: stress.reconcile(availableIDs: Set(pool.filter { $0 != id }))
            }
            invariantOK = invariantOK && Set(stress.openIDs).count == stress.openIDs.count
            invariantOK = invariantOK && (stress.openIDs.isEmpty ? stress.focusedID == nil : stress.focusedID.map { stress.openIDs.contains($0) } == true)
            if let index = stress.focusedIndex {
                invariantOK = invariantOK && stress.focusedOrdinal == index + 1
                invariantOK = invariantOK && stress.previousID == (index > 0 ? stress.openIDs[index - 1] : nil)
                invariantOK = invariantOK && stress.nextID == (index + 1 < stress.openIDs.count ? stress.openIDs[index + 1] : nil)
            }
            let copy = stress
            _ = stress.displayedIDs(availableWidth: Double(seed % 2000))
            invariantOK = invariantOK && stress == copy
            let restored = try decoder.decode(ConversationDeck.self, from: encoder.encode(stress))
            invariantOK = invariantOK && restored == stress
        }
        check(invariantOK, "3,000 deterministic navigation operations preserve identity, focus, arrow and round-trip invariants")
        print("ConversationDeckTests: \(checks) checks, \(failures) failures. Navigation model only; UI and concurrent-session integration remain separate.")
        if failures > 0 { exit(1) }
    }
}
