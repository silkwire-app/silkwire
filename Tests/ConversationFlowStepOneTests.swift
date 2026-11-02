import Foundation

// Conversation flow, step 1: no empty reply cards, one calm thinking line, and
// "Replying" vs "Working" kept apart. Pure rules, no window needed.
@main struct ConversationFlowStepOneTests {
    static var failures = 0
    static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS: " + name) } else { failures += 1; print("FAIL: " + name) }
    }
    static func main() {
        let agents: Set<String> = ["Eve", "Claude", "Codex"]
        func pending(_ author: String, _ text: String, _ state: String, attachments: Int = 0) -> Bool {
            TranscriptFlow.isEmptyPending(author, text: text, state: state, attachments: attachments, agentNames: agents)
        }
        check(pending("Eve", "", "queued"), "a queued teammate with no words gets no card")
        check(pending("Codex", "  \n", "streaming"), "a streaming teammate with only whitespace gets no card")
        check(!pending("Eve", "Hi", "streaming"), "a card appears with its first words")
        check(!pending("Claude", "", "completed"), "finished replies are never hidden here")
        check(!pending("Claude", "", "failed"), "failed replies stay visible so problems are seen")
        check(!pending("Jason", "", "queued"), "Jason's own messages are never hidden")
        check(!pending("Builder", "", "streaming"), "builder rows are not treated as teammate replies")
        check(!pending("Eve", "", "streaming", attachments: 1), "a reply carrying an attachment is shown")

        check(TranscriptFlow.thinkingText([]) == "", "no one thinking means no line")
        check(TranscriptFlow.thinkingText(["Eve"]) == "Eve is thinking…", "one teammate")
        check(TranscriptFlow.thinkingText(["Eve", "Claude"]) == "Eve and Claude are thinking…", "two teammates")
        check(TranscriptFlow.thinkingText(["Eve", "Claude", "Codex"]) == "Eve, Claude and Codex are thinking…", "three teammates")
        check(TranscriptFlow.thinkingText(["Eve", "Eve", "Codex"]) == "Eve and Codex are thinking…", "names are not repeated")

        for talking in ["", "Starting reply", "Eve is replying…", "Codex is replying.", "Checking Codex included usage.", "Thinking"] {
            check(SeatPhase.label(talking) == "Replying", "talking shows Replying: '\(talking)'")
        }
        for working in ["Running build", "Running tests", "Editing SilkwireApp.swift", "Reading project files", "Computer: shell command", "Searching the project"] {
            check(SeatPhase.label(working) == "Working", "real work shows Working: '\(working)'")
        }
        check(SeatPhase.isConversational("Checking Codex included usage."), "usage checks are plumbing, never shown as work")

        print(failures == 0 ? "PASS: ConversationFlowStepOneTests all checks" : "FAIL: \(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
