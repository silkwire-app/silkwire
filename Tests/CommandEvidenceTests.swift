import Foundation

// Real sandboxed commands in a synthetic private workspace: a receipt must never
// report success when an intermediate step failed.
@main struct CommandEvidenceTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0
        func check(_ valid: Bool, _ name: String) throws {
            guard valid else { throw nativeFailure("FAIL " + name) }
            passed += 1; print("PASS " + name)
        }
        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-evidence-" + UUID().uuidString)
        let source = fixture.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: source.appendingPathComponent("greeting.txt"))
        let env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        for args in [["init"], ["add", "greeting.txt"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-m", "Fixture"]] {
            guard try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: source, environment: env).exitCode == 0 else { throw nativeFailure("Cannot prepare synthetic Git fixture.") }
        }
        var latest: [String: Any] = [:]
        let builder = NativeBuilder(onReceipt: { latest = $0 }, storageRoot: fixture.appendingPathComponent("runs"), ownership: HostOwnershipDefault.coordinator)
        _ = try await builder.beginTrusted(source: source, task: "Exercise command evidence", owner: "codex")
        func run(_ command: String) async throws -> [String: Any] { try await builder.trustedOperation(["action": "run", "command": command]) }

        // Each shape that previously hid a failing step behind a wrapper exit of 0.
        let semicolon = try await run("false; true")
        try check(semicolon["ok"] as? Bool == false && semicolon["status"] as? String == "unconfirmed" && (semicolon["exitCode"] as? Int32) == 0 && (semicolon["absorbedNonzero"] as? [[String: Any]])?.first?["command"] as? String == "false", "a; b with failing a is unconfirmed, with the absorbed step named")
        let piped = try await run("printf 'build log\\n'; false | /usr/bin/tail -1")
        try check(piped["ok"] as? Bool == false && piped["status"] as? String == "failed" && (piped["exitCode"] as? Int32) == 1, "a | tail with failing a fails (pipefail)")
        let chained = try await run("false && true; true")
        try check(chained["status"] as? String == "unconfirmed", "a && b; c with failing a is unconfirmed")
        let subshell = try await run("(false; true); echo after")
        try check(subshell["status"] as? String == "unconfirmed" && (subshell["output"] as? String) == "after\n", "subshell failure is recorded")
        let substitution = try await run("x=$(false); echo done")
        try check(substitution["status"] as? String == "unconfirmed", "command-substitution failure is recorded")
        let maskedSubstitution = try await run("echo \"$(false)\"")
        try check(maskedSubstitution["status"] as? String == "unconfirmed", "successful caller cannot hide a substitution's final failure")
        let final = try await run("true; exit 4")
        try check(final["status"] as? String == "failed" && (final["exitCode"] as? Int32) == 4, "final nonzero exit fails")
        let conditional = try await run("if false; then echo no; fi; echo yes")
        try check(conditional["status"] as? String == "passed" && conditional["ok"] as? Bool == true, "an if-condition test is not a hidden failure")
        let clean = try await run("printf ok")
        try check(clean["status"] as? String == "passed" && (clean["absorbedNonzero"] as? [[String: Any]])?.isEmpty == true, "clean command passes with empty absorbed list")
        let sigpipe = try await run("/usr/bin/yes | /usr/bin/head -1")
        try check(sigpipe["status"] as? String == "unconfirmed" && (sigpipe["exitCode"] as? Int32) == 141, "SIGPIPE producer is unconfirmed, never passed (got \(sigpipe["status"] ?? "?") exit \(sigpipe["exitCode"] ?? "?"))")

        // Named checks: separate processes, separate exits, later checks still run.
        let checks = try await builder.trustedOperation(["action": "run", "checks": [["name": "build", "command": "printf built > built.txt"], ["name": "unit", "command": "exit 3"], ["name": "lint", "command": "test -f built.txt"]]])
        let results = checks["checks"] as? [[String: Any]] ?? []
        try check(checks["ok"] as? Bool == false && results.map { $0["status"] as? String ?? "" } == ["passed", "failed", "passed"] && (results[1]["exitCode"] as? Int32) == 3, "named checks keep their own results and later checks run after a failure")
        var rejected = try await builder.trustedOperation(["action": "run", "checks": [["name": "a", "command": "true"], ["name": "a", "command": "true"]]])
        try check(rejected["ok"] as? Bool == false && (rejected["error"] as? String)?.contains("unique") == true, "duplicate check names rejected before execution")
        rejected = try await builder.trustedOperation(["action": "run", "command": "true", "checks": [["name": "a", "command": "true"]]])
        try check(rejected["ok"] as? Bool == false, "command and checks together rejected")

        // Latest attempt per command decides; earlier failures stay in history.
        _ = try await builder.trustedOperation(["action": "run", "checks": [["name": "unit", "command": "true"]]])
        let summary = latest["checks"] as? [String: Any] ?? [:]
        try check(summary["failed"] as? Int == 2 && (summary["attempts"] as? Int ?? 0) >= 13, "receipt summary counts latest attempt per command and named check")

        // Tampering with the evidence file can only make a result less certain.
        let tamper = try await run("rm -f \"$TMPDIR\"/check-evidence/*.tsv; true")
        try check(tamper["status"] as? String == "unconfirmed", "removed step record is unconfirmed, not passed")

        let done = try await builder.finishTrusted(summary: "Evidence fixture")
        try check(done["status"] as? String == "review" && (done["message"] as? String)?.contains("failing") == true && (done["message"] as? String)?.contains("Do not treat it as passing") == true, "finish message reports failing checks plainly")
        let text = NativeWorkspaceReceipt.text(done)
        try check(text.contains("### Check · unit") && text.contains("Evidence: bash pipefail + per-step statuses") && text.contains("Absorbed: exit 1 · false"), "receipt text shows checks, evidence and absorbed steps")
        let ari = BuilderSummary.parse(text)
        try check(ari.headline(messageState: "completed") == "Needs attention" && ari.failed > 0 && ari.running > 0, "Ari: unconfirmed and failed checks are not Ready for review")
        try check(ari.commands.contains { $0.command == "false; true" && $0.status == "unconfirmed" }, "Ari: unconfirmed label with exit 0 stays unconfirmed")

        // Ari on legacy and retried receipts.
        let legacy = BuilderSummary.parse("## Staging work · Eve · review\n### Command\nswift Scripts/test.swift; echo done\nStatus: passed · exit 0")
        try check(legacy.passed == 0 && legacy.running == 1 && legacy.headline(messageState: "completed") == "Needs attention", "Ari: legacy compound command without step evidence is unconfirmed")
        let legacySimple = BuilderSummary.parse("## Staging work · Eve · review\n### Command\nswift Scripts/test.swift\nStatus: passed · exit 0")
        try check(legacySimple.passed == 1 && legacySimple.headline(messageState: "completed") == "Ready for review", "Ari: legacy single command keeps its recorded pass")
        let evidenced = BuilderSummary.parse("## Staging work · Eve · review\n### Command\ncd Sources && swift build\nEvidence: bash pipefail + per-step statuses · 0 absorbed nonzero statuses\nStatus: passed · exit 0")
        try check(evidenced.passed == 1, "Ari: compound command with clean step evidence passes")
        let retried = BuilderSummary.parse("## Staging work · Eve · review\n### Command\nswift Scripts/test.swift\nStatus: failed · exit 1\n### Command\nswift Scripts/test.swift\nStatus: passed · exit 0")
        try check(retried.passed == 1 && retried.failed == 0 && retried.commandDescription == "1 commands passed (latest of 2 attempts)" && retried.testDescription.contains("1 passed, 0 failed"), "Ari: latest attempt per command decides, retries disclosed")
        let regressed = BuilderSummary.parse("## Staging work · Eve · review\n### Command\nswift Scripts/test.swift\nStatus: passed · exit 0\n### Command\nswift Scripts/test.swift\nStatus: failed · exit 1")
        try check(regressed.failed == 1 && regressed.headline(messageState: "completed") == "Needs attention", "Ari: a later failure overrides an earlier pass")
        print("\(passed) command evidence checks passed. Synthetic fixture: \(fixture.path)")
    }
}
