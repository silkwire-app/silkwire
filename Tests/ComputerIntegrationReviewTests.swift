import AppKit

@MainActor final class ReviewWindowDriver: ComputerDriving {
    var backendName = "synthetic review"
    var lastSyntheticEvent = Date.distantPast
    var onCapture: (() -> Void)?
    var onPerform: (() -> Void)?
    var captures = 0
    var performed = 0
    var destination = ComputerTarget(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "New Message")
    func target(for request: ComputerRequest) -> ComputerTarget {
        request.x == 100 ? destination : ComputerTarget(appName: "Test Editor", bundleID: "test.editor", windowTitle: "Fixture")
    }
    func screenshot(app: String?, window: String?) async throws -> ComputerScreenshot {
        captures += 1
        try await Task.sleep(for: .milliseconds(10))
        onCapture?()
        return ComputerScreenshot(png: Data([137,80,78,71]), frame: CGRect(x: 0,y: 0,width: 200,height: 100), scale: 1, backend: backendName)
    }
    func perform(_ request: ComputerRequest, shouldContinue: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
        guard shouldContinue() else { return ["interrupted": true] }
        performed += 1; onPerform?()
        return ["performed": request.summary]
    }
}

@main struct ComputerIntegrationReviewTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appendingPathComponent("ComputerReview-" + UUID().uuidString)
        try files.createDirectory(at: fixture, withIntermediateDirectories: true)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures += 1 }; print((value ? "PASS: " : "FAIL: ") + label)
        }
        func request(_ json: String) throws -> ComputerRequest { try ComputerRequest.parse("<<COMPUTER " + json + ">>")! }
        func make(_ name: String) -> (ComputerControlCenter, ReviewWindowDriver) {
            let driver = ReviewWindowDriver()
            return (ComputerControlCenter(root: fixture.appendingPathComponent(name), driver: driver, live: false, initialIdle: 3600), driver)
        }
        func run(_ center: ComputerControlCenter, _ json: String) async throws -> ComputerOutcome {
            await center.perform(try request(json), agent: "claude", conversationID: "fixture", projectRoots: [], progress: { _ in })
        }

        // Additional cases from Claude's overlapping review, using synthetic strings only.
        for token in ["github_pat_" + String(repeating: "a", count: 25), "xoxb-" + String(repeating: "b", count: 20), "AKIA" + String(repeating: "C", count: 16), "AIza" + String(repeating: "D", count: 32), "rk-" + String(repeating: "E", count: 20), "pk-" + String(repeating: "F", count: 20), "secret_key=synthetic-value", "passwd=synthetic-value"] {
            check(!HostLane.redact(token).contains(token), "additional recognized secret format is removed")
        }
        for path in ["~/.config/gh/hosts.yml", "~/.config/claude/auth.json", "~/.config/openclaw/auth.json", fixture.appendingPathComponent("Computer Control/Keys/silkwire-agents").path] {
            let context = ComputerActionContext(request: try ComputerRequest.validate(["action": "read", "path": path]))
            check(AskFirstPolicy.evaluate(context, settings: ComputerAccessSettings()).needsApproval, "additional known credential path asks first")
        }
        let (direct, directDriver) = make("direct")
        directDriver.onCapture = { direct.humanInput() }
        let shot = try await run(direct, #"{"action":"screenshot"}"#)
        check(shot.image == nil && shot.result["interrupted"] as? Bool == true && direct.recent.first?.screenshot == nil, "takeover during direct capture discards model and audit image")

        let (delayed, delayedDriver) = make("delayed")
        delayedDriver.onPerform = { delayed.humanInput() }
        let clicked = try await run(delayed, #"{"action":"click","x":1,"y":1}"#)
        check(clicked.image == nil && clicked.result["interrupted"] as? Bool == true && delayedDriver.captures == 0, "takeover before automatic capture prevents capture entirely")

        let (capture, captureDriver) = make("capture")
        captureDriver.onCapture = { capture.humanInput(); capture.letThemDrive() }
        let captured = try await run(capture, #"{"action":"click","x":1,"y":1}"#)
        check(captured.image == nil && captured.result["interrupted"] as? Bool == true, "a new invitation cannot revive a capture crossed by human input")

        var arbiter = DriveArbiter(lastHumanInput: Date.distantPast)
        let now = Date(); arbiter.request("claude", at: now); arbiter.letThemDrive(at: now)
        check(arbiter.humanInput(at: now.addingTimeInterval(0.01)) && !arbiter.mayAct("claude", at: now.addingTimeInterval(0.02)), "keyboard input cancels invitation during mouse hand-off grace")

        let (failedStart, _) = make("failed-start")
        try files.createDirectory(at: failedStart.root.appendingPathComponent("tasks.json"), withIntermediateDirectories: false)
        let started = try await run(failedStart, #"{"action":"task","state":"start","title":"Cannot persist"}"#)
        check(started.result["ok"] as? Bool == false && failedStart.continuableTasks("fixture").isEmpty && failedStart.notice != nil, "failed task save never acknowledges durability or dispatches automatic work")

        try files.removeItem(at: failedStart.root.appendingPathComponent("tasks.json")) // Synthetic blocked destination.
        let retried = try await run(failedStart, #"{"action":"task","state":"start","title":"Retry after repair"}"#)
        check(retried.result["ok"] as? Bool == true && failedStart.tasks.count == 1 && failedStart.tasks[0].state == "running", "failed start leaves no phantom task preventing retry after storage repair")

        let (failedContinue, _) = make("failed-continue")
        _ = try await run(failedContinue, #"{"action":"task","state":"start","title":"Persist once"}"#)
        let task = failedContinue.tasks[0]
        try files.moveItem(at: failedContinue.root.appendingPathComponent("tasks.json"), to: failedContinue.root.appendingPathComponent("original-tasks.json"))
        try files.createDirectory(at: failedContinue.root.appendingPathComponent("tasks.json"), withIntermediateDirectories: false)
        check(!failedContinue.noteContinuation(task.id) && failedContinue.continuableTasks("fixture").isEmpty, "failed continuation checkpoint blocks autonomous work")
        failedContinue.stopTask(task.id)
        check(failedContinue.tasks.first?.state == "stopped" && failedContinue.notice != nil, "Stop remains stopped in memory and reports failed persistence")

        let (audit, _) = make("audit")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        try files.createDirectory(at: audit.auditDirectory.appendingPathComponent(formatter.string(from: Date()) + ".jsonl"), withIntermediateDirectories: false)
        let audited = try await run(audit, #"{"action":"wait","seconds":0}"#)
        check(audit.notice?.contains("audit") == true && audited.result["auditWarning"] != nil, "audit write failure is visible in the UI and action result")

        let (drag, dragDriver) = make("drag")
        let dragging = Task { try await run(drag, #"{"action":"drag","from":[1,1],"to":[100,100]}"#) }
        for _ in 0..<50 { if !drag.pending.isEmpty || dragDriver.performed > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        check(drag.pending.first?.ruleTitle == "Sending email or messages" && dragDriver.performed == 0, "drop destination receives its own ask-first check")
        for approval in drag.pending { drag.resolve(approval.id, allow: false) }
        _ = try await dragging.value

        let projects = fixture.appendingPathComponent("Projects"), outside = fixture.appendingPathComponent("Outside")
        try files.createDirectory(at: projects, withIntermediateDirectories: true); try files.createDirectory(at: outside, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: projects.appendingPathComponent("linked"), withDestinationURL: outside)
        var context = ComputerActionContext(request: try request(#"{"action":"write","path":"/tmp/unused","content":"x"}"#), projectFolders: [projects.path], destinationExists: true)
        check(!AskFirstPolicy.inside(projects.appendingPathComponent("linked/new.txt").path, context), "outside-project checks resolve directory symlinks even for new destinations")
        context.request = try request(#"{"action":"read","path":"~/.codex/auth.json"}"#)
        check(AskFirstPolicy.evaluate(context, settings: ComputerAccessSettings()).needsApproval, "known Codex auth file asks before reading")
        context.request = try request(#"{"action":"read","path":"~/.claude/.credentials.json"}"#)
        check(AskFirstPolicy.evaluate(context, settings: ComputerAccessSettings()).needsApproval, "known Claude credential file asks before reading")
        let synthetic = "synthetic-review-token-" + UUID().uuidString
        let auth = fixture.appendingPathComponent("fake-auth.json")
        try Data(("{\"access_token\":\"" + synthetic + "\",\"plain\":\"keep-me\"}").utf8).write(to: auth)
        var read = ComputerRequest(action: .read); read.path = auth.path
        let readResult = try HostLane.read(read)
        check(!(readResult["text"] as? String ?? "").contains(synthetic) && readResult["redacted"] as? Bool == true && (readResult["text"] as? String ?? "").contains("keep-me"), "synthetic credential fields are redacted and incomplete file reads are flagged")
        var shell = ComputerRequest(action: .shell); shell.command = "cat '" + auth.path + "'"; shell.cwd = fixture.path
        let shellResult = try await HostLane.shell(shell, logDirectory: fixture.appendingPathComponent("shell-output"))
        check(!(shellResult["stdout"] as? String ?? "").contains(synthetic) && shellResult["redacted"] as? Bool == true, "model-facing shell output redacts synthetic credential fields")
        if let output = shellResult["fullOutput"] as? String {
            check(!(try String(contentsOfFile: output, encoding: .utf8)).contains(synthetic), "saved shell output does not retain raw recognized credentials")
        } else { check(false, "saved shell output receipt exists") }
        let (completeAudit, _) = make("complete-audit")
        let longCommand = "printf AUDIT-OK # " + String(repeating: "review ", count: 40)
        let outcome = await completeAudit.perform(try ComputerRequest.validate(["action": "shell", "command": longCommand, "cwd": fixture.path]), agent: "claude", conversationID: "fixture", projectRoots: [], progress: { _ in })
        let reloaded = ComputerControlCenter(root: completeAudit.root, driver: ReviewWindowDriver(), live: false)
        check(reloaded.recent.first?.command == longCommand && reloaded.recent.first?.exitCode == 0 && reloaded.recent.first?.fullOutput == outcome.result["fullOutput"] as? String, "reopened audit retains full command, exit status and output reference beyond the short summary")
        print("Review checks: \(checks), failures: \(failures)")
        if failures > 0 { exit(1) }
    }
}
