import Foundation

// Conversation flow, step 2 (Jason: "cache the stream until the full comment is received,
// THEN display it nice and clean"): unfinished replies get no card, finished cards take
// their place below everything already showing, and nothing ever moves above you.
@main struct ConversationFlowStepTwoTests {
    static var failures = 0
    static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS: " + name) } else { failures += 1; print("FAIL: " + name) }
    }
    static func main() {
        let agents: Set<String> = ["Eve", "Claude", "Codex"]
        func held(_ author: String, _ state: String, _ text: String = "") -> Bool { TranscriptFlow.isHeld(author, state: state, agentNames: agents, text: text) }

        check(held("Eve", "queued"), "a queued reply is held")
        check(held("Codex", "streaming"), "a reply with no words yet is held (never an empty bubble)")
        check(held("Codex", "streaming", "  \n"), "whitespace alone is still no words")
        check(!held("Codex", "streaming", "Here's"), "once words arrive the reply types in live (Jason, Nov 2)")
        check(!held("Claude", "completed"), "a finished reply is shown")
        check(!held("Claude", "failed"), "a failed reply is shown so problems are seen")
        check(!held("Eve", "stopped"), "a stopped reply is shown")
        check(!held("Jason", "sending"), "Jason's own message is never held")
        check(!held("Builder", "streaming"), "builder rows are not teammate replies")

        // Saved seat order is Trace, Claude, Eve; they finish Eve, Claude, Trace.
        let old1 = UUID(), old2 = UUID(), jason = UUID(), codex = UUID(), claude = UUID(), eve = UUID()
        let saved = [old1, old2, jason, codex, claude, eve]
        let baseline: Set<UUID> = [old1, old2]
        var revealed: [UUID: Int] = [:]
        func reveal(_ visible: [UUID]) {
            var n = revealed.values.max() ?? 0
            for id in TranscriptFlow.newlyVisible(visible, baseline: baseline, revealed: revealed) { n += 1; revealed[id] = n }
        }
        func shown(_ visible: [UUID]) -> [UUID] {
            TranscriptFlow.displayOrder(saved.filter { visible.contains($0) && TranscriptFlow.isPlaced($0, baseline: baseline, revealed: revealed) }, id: { $0 }, revealed: revealed)
        }

        reveal([old1, old2, jason])
        check(shown([old1, old2, jason]) == [old1, old2, jason], "your message goes right below the conversation")
        reveal([old1, old2, jason, eve])
        check(shown([old1, old2, jason, eve]) == [old1, old2, jason, eve], "first to finish speaks first")
        reveal([old1, old2, jason, claude, eve])
        check(shown([old1, old2, jason, claude, eve]) == [old1, old2, jason, eve, claude], "second goes below the first, never above it")
        reveal(saved)
        check(shown(saved) == [old1, old2, jason, eve, claude, codex], "third goes last, not in seat order")
        let before = revealed
        reveal(saved)
        check(revealed == before, "nothing re-sorts once placed")

        check(TranscriptFlow.isPlaced(UUID(), baseline: nil, revealed: [:]), "before the first baseline everything finished is drawn")
        check(!TranscriptFlow.isPlaced(UUID(), baseline: baseline, revealed: revealed), "a row without a place yet isn't drawn in the wrong spot")

        print(failures == 0 ? "PASS: ConversationFlowStepTwoTests all checks" : "FAIL: \(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
