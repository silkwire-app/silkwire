import Foundation

@main struct BuilderSummaryTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            print("PASS: \(name)")
        }
        let receipt = """
        ## Staging work · Eve · review

        Task: Fix tables in the chat renderer
        Branch: silkwire/ABC123
        Base: b76049a

        ### Command
        swift Scripts/test.swift MarkdownTableTests
        Status: passed · exit 0
        ````text
        PASS: headers parsed
        Status: failed · this line is log output, not a command result
        ````

        ### Command
        swift Scripts/build.swift --verification
        Status: failed · exit 1
        ````text
        error: something broke
        ````

        Task finished.
        """
        let summary = BuilderSummary.parse(receipt)
        check(summary.owner == "Eve", "owner read from heading")
        check(summary.task == "Fix tables in the chat renderer", "task read")
        check(summary.branch == "silkwire/ABC123", "branch read")
        check(summary.passed == 1 && summary.failed == 1 && summary.running == 0, "command results counted outside log fences only")
        check(summary.commands.map(\.command) == ["swift Scripts/test.swift MarkdownTableTests", "swift Scripts/build.swift --verification"], "commands paired with their status")
        let compact = BuilderSummary.compact(receipt)
        check(compact.contains("Eve") && compact.contains("→ failed") && compact.contains("→ passed"), "compact history keeps owner and results")
        check(!compact.contains("something broke") && !compact.contains("PASS: headers parsed"), "compact history omits raw logs")
        let running = BuilderSummary.parse("## Staging work · Claude · active\n\nTask: Build\n\n### Command\nswift Scripts/build.swift\nStatus: running · exit not recorded")
        check(running.owner == "Claude" && running.running == 1, "in-progress command recognized")
        let longTask = BuilderSummary.compact("## Staging work · Codex · review\n\nTask: " + String(repeating: "x", count: 500))
        check(longTask.count < 400, "long tasks are trimmed in agent history")
        check(summary.commandDescription.contains("commands") && !summary.commandDescription.contains("checks"), "commands are not mislabeled as tests")
        check(summary.testDescription.contains("1 passed, 0 failed"), "standalone test results separate from builds")
        check(summary.headline(messageState: "completed") == "Needs attention", "failed command blocks ready state")
        let empty = BuilderSummary.parse("Unknown receipt")
        check(empty.headline(messageState: "completed") == "Needs attention", "unknown receipt is not ready")
        let reviewed = BuilderSummary.parse("## Staging work · Eve · review")
        check(reviewed.headline(messageState: "cancelled") == "Stopped", "cancelled message stopped")
        check(reviewed.headline(messageState: "future-state") == "Needs attention", "unknown message state not ready")
        check(reviewed.headline(messageState: "completed") == "Ready for review" && reviewed.commandDescription == "No commands recorded", "review does not invent test evidence")
        let inconsistent = BuilderSummary.parse("## Staging work · Eve · review\n### Command\nswift Scripts/test.swift\nStatus: passed · exit 1")
        check(inconsistent.failed == 1, "nonzero exit overrides passed label")
        let missing = BuilderSummary.parse("## Staging work · Eve · review\n### Command\nswift Scripts/test.swift\nStatus: passed · exit not recorded")
        check(missing.passed == 0 && missing.headline(messageState: "completed") == "Needs attention", "missing exit never passes")
        let old = BuilderSummary.parse("## Builder · review\n### test\nCommand: swift Scripts/test.swift\nResult: passed · exit 0")
        check(old.passed == 1 && old.testDescription.contains("1 passed"), "legacy Builder receipt format supported")
        let fenced = BuilderSummary.parse("## Staging work · Eve · review\n````text\n```\nStatus: failed · exit 1\n````")
        check(fenced.commands.isEmpty, "short nested fence does not expose log statuses")
        let named = BuilderSummary.parse("## Staging work · Eve · review\n### Check · unit\nswift Scripts/test.swift\nStatus: failed · exit 1\n### Check · integration\nswift Scripts/test.swift\nStatus: passed · exit 0")
        check(named.distinct == 2 && named.failed == 1 && named.passed == 1 && named.headline(messageState: "completed") == "Needs attention", "different named checks cannot hide a failure behind the same command")
        check(named.testDescription.contains("1 passed, 1 failed"), "test result summary uses named check identities")
        let retry = BuilderSummary.parse("## Staging work · Eve · review\n### Check · unit\nswift Scripts/test.swift OldTests\nStatus: failed · exit 1\n### Check · unit\nswift Scripts/test.swift NewTests\nStatus: passed · exit 0")
        check(retry.distinct == 1 && retry.failed == 0 && retry.passed == 1 && retry.testDescription.contains("1 passed, 0 failed"), "retry of a named check matches host semantics when its command changes")
        check(BuilderSummary.compact("Previous build finished for review.") == "Previous build finished for review.", "non-receipt Builder text is kept, not replaced by an unknown receipt summary")
        // A failed side step redone before a passing build and test is not "Needs attention".
        let redone = BuilderSummary.parse("## Staging work · Claude · review\n### Check · peek\npython3 - <<'EOF'\nStatus: failed · exit 1\n### Check · build\nswift Scripts/build.swift --staging\nStatus: passed · exit 0\n### Check · test\nswift Scripts/test.swift AlexandriaTests\nStatus: passed · exit 0")
        check(redone.failed == 0 && redone.superseded == 1 && redone.headline(messageState: "completed") == "Ready for review" && redone.commandDescription.contains("1 earlier step redone"), "a side step redone before a passing build and test no longer needs attention")
        let lateFail = BuilderSummary.parse("## Staging work · Claude · review\n### Check · build\nswift Scripts/build.swift --staging\nStatus: passed · exit 0\n### Check · test\nswift Scripts/test.swift AlexandriaTests\nStatus: passed · exit 0\n### Check · peek\npython3 - <<'EOF'\nStatus: failed · exit 1")
        check(lateFail.failed == 1 && lateFail.headline(messageState: "completed") == "Needs attention", "a failure after the last build and test still needs attention")
        let noTest = BuilderSummary.parse("## Staging work · Claude · review\n### Check · peek\npython3 - <<'EOF'\nStatus: failed · exit 1\n### Check · build\nswift Scripts/build.swift --staging\nStatus: passed · exit 0")
        check(noTest.failed == 1 && noTest.headline(messageState: "completed") == "Needs attention", "without a passing test run, earlier failures still need attention")
        let failedTest = BuilderSummary.parse("## Staging work · Claude · review\n### Check · test\nswift Scripts/test.swift A\nStatus: failed · exit 1\n### Check · build\nswift Scripts/build.swift --staging\nStatus: passed · exit 0\n### Check · test2\nswift Scripts/test.swift B\nStatus: passed · exit 0")
        check(failedTest.failed == 1 && failedTest.superseded == 0, "a failed test run is never treated as redone")
        print("PASS: Builder summary and recorded-review regression checks")
    }
}
