import Foundation
import AppKit
import CoreGraphics

// Computer control end to end through the store, native room and control center,
// with synthetic teammates and a synthetic screen. Host shell commands are real
// (local only, no network). No real pointer, keyboard or screen is touched.
@MainActor final class ScriptedComputerTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    var images: [Int] = []
    var replies: [String] = []
    var hangOnEmpty = false
    init(_ replies: [String] = []) { self.replies = replies }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false); self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text); images.append(attachments.filter(\.isImage).count)
        if replies.isEmpty && hangOnEmpty { return }
        let reply = replies.isEmpty ? "Nothing more to do." : replies.removeFirst()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(5))
            self?.eventHandler?(.delta(reply)); self?.eventHandler?(.finished(status: "completed", message: nil))
        }
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport") }
}

@MainActor final class SyntheticComputerDriver: ComputerDriving {
    var backendName = "synthetic"
    var lastSyntheticEvent = Date.distantPast
    var performed: [String] = []
    var active = 0, maxActive = 0
    var onType: ((Int) -> Void)?
    var app = ComputerTarget(appName: "TextEdit", bundleID: "com.apple.TextEdit", windowTitle: "Untitled")
    /// Fires inside screenshot(), so a test can simulate Jason taking the wheel mid-capture.
    var onScreenshot: (() -> Void)?
    /// A test can map a drop point to an app, to check both drag endpoints.
    var appAt: ((Double) -> ComputerTarget)?
    let png: Data
    init() {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        png = try! NativeComputerDriver.encode(context.makeImage()!, frame: CGRect(x: 0, y: 0, width: 64, height: 32), backend: "synthetic").png
    }
    func target(for request: ComputerRequest) -> ComputerTarget {
        if let appAt, let x = request.x { return appAt(x) }
        return request.app.map { ComputerTarget(appName: $0, bundleID: nil, windowTitle: request.window) } ?? app
    }
    func screenshot(app: String?, window: String?) async throws -> ComputerScreenshot {
        onScreenshot?()
        return ComputerScreenshot(png: png, frame: CGRect(x: 0, y: 0, width: 64, height: 32), scale: 1, backend: "synthetic")
    }
    func perform(_ request: ComputerRequest, shouldContinue: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
        active += 1; maxActive = max(maxActive, active); defer { active -= 1 }
        if request.action == .type, let text = request.text {
            for index in text.indices.map({ text.distance(from: text.startIndex, to: $0) }) {
                onType?(index)
                guard shouldContinue() else { performed.append("typed \(index)"); return ["interrupted": true, "performed": "typed \(index) of \(text.count) characters"] }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        performed.append(request.summary)
        return ["performed": request.summary]
    }
}

@main struct ComputerRoomTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func wait(_ label: String, seconds: Double = 30, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/tests/ComputerRoom-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ComputerRoom-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var project = Project(); project.name = "Synthetic computer control"
        var conversation = Conversation(); conversation.projectID = project.id; conversation.recipient = "claude"
        try JSONEncoder().encode(ConversationWorkspace(activeID: conversation.id, conversations: [conversation], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))
        let controlRoot = root.appendingPathComponent("Computer Control")
        let driver = SyntheticComputerDriver()
        // Jason has been away an hour, so the idle wait is already satisfied.
        let center = ComputerControlCenter(root: controlRoot, driver: driver, live: false, initialIdle: 3600)
        var transports: [String: ScriptedComputerTransport] = [:]
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in
            let transport = ScriptedComputerTransport(); transports[agent] = transport; return transport
        }, workspaceSandbox: stage, computer: center)
        guard store.storageError == nil else { print("FAIL: library"); exit(1) }
        await store.start()
        try await wait("connection") { !store.connecting && agents.allSatisfy { store.seats[$0]?.state == "connected" } }
        let roomID = store.conversation.id.uuidString.lowercased()
        func send(_ text: String, to recipients: String, _ scripts: [String: [String]]) {
            for (agent, replies) in scripts { transports[agent]?.replies = replies }
            store.conversation.recipient = recipients
            store.conversation.draft = text
            store.send()
        }
        func visible() -> [String] { store.conversation.messages.filter { names.values.contains($0.author) }.map(\.text) }

        // 1. Screenshot round trip: the image goes back to the agent, nothing raw is shown.
        send("Look at my screen.", to: "claude", ["claude": [#"<<COMPUTER {"action":"screenshot","reason":"See what is open"}>>"#, "I can see the synthetic screen."]])
        try await wait("screenshot turn") { !store.busy }
        let claude = transports["claude"]!
        check(claude.prompts.first?.contains("COMPUTER CONTROL (Silkwire Staging; Jason authorized this for you)") == true, "enabled teammates receive the COMPUTER capability")
        check(claude.prompts.count == 2 && claude.prompts[1].contains("COMPUTER RESULT") && claude.prompts[1].contains("imagePixelsPerPoint"), "the host result returns to the same teammate")
        check(claude.images == [0, 1], "the screenshot is attached to the follow-up as an image")
        check(visible().last == "I can see the synthetic screen." && !visible().contains { $0.contains("<<COMPUTER") }, "the marker never appears in the transcript")
        let shot = center.recent.first
        check(shot?.action == "screenshot" && shot?.outcome == "done" && shot?.agent == "claude" && shot?.reason == "See what is open", "the audit log records the action, teammate, outcome and reason")
        check(shot.flatMap { center.screenshotURL($0) }.map { FileManager.default.fileExists(atPath: $0.path) } == true, "the audit log keeps the screenshot file")
        let auditFiles = (try? FileManager.default.contentsOfDirectory(atPath: center.auditDirectory.path).filter { $0.hasSuffix(".jsonl") }) ?? []
        check(auditFiles.count == 1, "audit entries are appended to a dated JSON Lines file")

        // 2. The unsandboxed lane: a real login shell as Jason, outside any workspace.
        let outside = scratch.appendingPathComponent("written-outside.txt").path
        send("Check the host shell.", to: "claude", ["claude": ["<<COMPUTER " + String(data: try JSONSerialization.data(withJSONObject: ["action": "shell", "command": "echo HOST-LANE-OK > '\(outside)'; cat '\(outside)'; test -d \"$HOME/Library\" && echo HOME-READABLE", "cwd": scratch.path]), encoding: .utf8)! + ">>", "The shell works."]])
        try await wait("shell turn") { !store.busy }
        let shellPrompt = claude.prompts.last ?? ""
        check(shellPrompt.contains("HOST-LANE-OK") && shellPrompt.contains("HOME-READABLE") && shellPrompt.contains("\"exitCode\":0"), "shell commands run as Jason with home access and report exit codes")
        check((try? String(contentsOfFile: outside, encoding: .utf8)) == "HOST-LANE-OK\n", "the shell lane writes outside any private workspace")
        check(shellPrompt.contains("fullOutput"), "the complete output is saved for the agent to read")

        // 3. Ask first: denied requests never run; approved ones run once.
        center.update { $0.rules.append(AskFirstRule(id: "custom-test", title: "Synthetic marker files", phrases: ["silk-ask-marker"])) }
        let denied = scratch.appendingPathComponent("silk-ask-marker-denied").path
        send("Try the denied marker.", to: "claude", ["claude": ["<<COMPUTER {\"action\":\"shell\",\"command\":\"touch '\(denied)'\"}>>", "Understood; I skipped it."]])
        try await wait("approval request") { center.pending.count == 1 }
        check(store.busy && center.pending.first?.ruleTitle == "Synthetic marker files" && center.pending.first?.conversationID == roomID, "the request waits for Jason with its rule and conversation")
        check(center.pending.first?.detail.contains("silk-ask-marker-denied") == true, "Jason sees the exact command before deciding")
        center.resolve(center.pending[0].id, allow: false)
        try await wait("denied turn") { !store.busy }
        check(!FileManager.default.fileExists(atPath: denied), "a denied command never runs")
        check(claude.prompts.last?.contains("\"denied\":true") == true && claude.prompts.last?.contains("Do not retry it another way") == true, "the teammate learns Jason said no")
        check(center.recent.first?.outcome == "denied" && center.recent.first?.rule == "Synthetic marker files", "the denial is audited with its rule")

        let allowed = scratch.appendingPathComponent("silk-ask-marker-allowed").path
        send("Try the allowed marker.", to: "claude", ["claude": ["<<COMPUTER {\"action\":\"shell\",\"command\":\"touch '\(allowed)' && echo ALLOWED-RAN\"}>>", "It ran."]])
        try await wait("second approval") { center.pending.count == 1 }
        center.resolve(center.pending[0].id, allow: true)
        try await wait("allowed turn") { !store.busy }
        check(FileManager.default.fileExists(atPath: allowed) && claude.prompts.last?.contains("ALLOWED-RAN") == true, "an approved command runs")
        check(claude.prompts.last?.contains("\"approvedByJason\":true") == true && center.recent.first?.outcome == "approved", "approval is reported and audited")

        send("Read my Keychain password.", to: "claude", ["claude": [#"<<COMPUTER {"action":"shell","command":"security find-generic-password -s silkwire-test -w"}>>"#, "I did not read it."]])
        try await wait("keychain approval") { center.pending.count == 1 }
        check(center.pending.first?.ruleTitle == "Keychain or password-manager access", "Keychain access asks under the built-in rule")
        center.resolve(center.pending[0].id, allow: false)
        try await wait("keychain turn") { !store.busy }

        // 4. A teammate Jason switched off gets no capability and is refused if it tries anyway.
        center.update { $0.enabledAgents["codex"] = false }
        store.disconnect(); store.connect()
        try await wait("reconnect") { !store.connecting && agents.allSatisfy { store.seats[$0]?.state == "connected" } }
        let codex = transports["codex"]!
        send("Codex, click something.", to: "codex", ["codex": [#"<<COMPUTER {"action":"click","x":5,"y":5}>>"#, "Computer control is off for me."]])
        try await wait("disabled turn") { !store.busy }
        check(codex.prompts.first?.contains("COMPUTER CONTROL") == false, "a switched-off teammate is not offered computer control")
        check(codex.prompts.last?.contains("turned off computer control for Codex") == true && !driver.performed.contains("Click at (5, 5)"), "a switched-off teammate's request is refused and nothing happens")
        check(center.recent.first?.outcome == "refused", "the refusal is audited")
        center.update { $0.enabledAgents["codex"] = true }
        store.disconnect(); store.connect()
        try await wait("reconnect again") { !store.connecting && agents.allSatisfy { store.seats[$0]?.state == "connected" } }
        let claude2 = transports["claude"]!

        // 5. Durable task: Silkwire keeps the teammate going between replies without Pass.
        send("Do the long job.", to: "claude", ["claude": [#"<<COMPUTER {"action":"task","state":"start","title":"Synthetic long job"}>>"#, #"<<COMPUTER {"action":"screenshot"}>>"#, "Progress: halfway there.", #"<<COMPUTER {"action":"task","state":"done","note":"Everything checks out."}>>"#, "Finished: everything checks out."]])
        try await wait("durable task", seconds: 40) { !store.busy && visible().last == "Finished: everything checks out." }
        let continuations = store.conversation.messages.filter { $0.author == "Silkwire" && $0.detail == ConversationStore.taskContinuation }
        check(continuations.count == 1 && continuations[0].state == "sent", "one automatic task continuation was sent without Pass")
        check(!store.relayActive && store.conversation.messages.filter { $0.author == "Jason" && $0.text.hasPrefix("Pass") }.isEmpty, "Jason never pressed Pass")
        check(visible().contains("Progress: halfway there."), "the progress reply stays visible to Jason")
        let task = center.tasks.last
        check(task?.title == "Synthetic long job" && task?.state == "done" && task?.steps == 1 && task?.continuations == 1 && task?.finishedAt != nil, "the task records steps, continuations and completion")
        check(claude2.prompts.contains { $0.contains("Automatic task continuation from Silkwire") && $0.contains("Synthetic long job") }, "the continuation names the task")
        let savedTasks = try JSONDecoder.iso8601.decode([AgentTask].self, from: Data(contentsOf: controlRoot.appendingPathComponent("tasks.json")))
        check(savedTasks.last?.state == "done", "tasks are saved to disk")
        check(ComputerTaskRow.elapsed(65) == "1:05" && ComputerTaskRow.elapsed(3725) == "1:02:05", "elapsed time is shown as minutes and hours")

        // 6. Takeover mid-typing pauses at once; Let them drive resumes before the idle wait.
        center.update { $0.idleSeconds = 30 }
        driver.onType = { index in if index == 3 { center.humanInput() } }
        send("Type for me.", to: "claude", ["claude": [#"<<COMPUTER {"action":"type","text":"hello world"}>>"#, #"<<COMPUTER {"action":"click","x":7,"y":9}>>"#, "Done after resuming."]])
        try await wait("takeover") { driver.performed.contains("typed 3") }
        driver.onType = nil
        try await wait("paused before the click") {
            guard case .paused(let agent, _) = center.wheel, agent == "claude" else { return false }
            return claude2.prompts.last?.contains("\"interrupted\":true") == true
        }
        check(claude2.prompts.last?.contains("\"interrupted\":true") == true && claude2.prompts.last?.contains("typed 3 of 11") == true, "the teammate learns Jason took over and how far it got")
        check(center.recent.first?.outcome == "interrupted", "the takeover is audited as interrupted")
        try await Task.sleep(for: .milliseconds(400))
        check(!driver.performed.contains("Click at (7, 9)") && store.busy, "the next screen action waits instead of acting")
        center.letThemDrive()
        try await wait("resumed turn") { !store.busy }
        check(driver.performed.contains("Click at (7, 9)") && visible().last == "Done after resuming.", "Let them drive resumes the waiting teammate")
        check(center.wheel == .none, "the wheel is released when the reply ends")

        // 7. One teammate drives at a time; the other waits its turn.
        center.letThemDrive()
        store.setOpenFloor(true)
        driver.maxActive = 0
        send("Both of you, click around.", to: "claude,codex", ["claude": [#"<<COMPUTER {"action":"click","x":1,"y":1}>>"#, #"<<COMPUTER {"action":"click","x":2,"y":2}>>"#, "Claude done."], "codex": [#"<<COMPUTER {"action":"click","x":3,"y":3}>>"#, #"<<COMPUTER {"action":"click","x":4,"y":4}>>"#, "Codex done."]])
        try await wait("open floor drive", seconds: 40) { !store.busy }
        check(driver.maxActive == 1, "screen actions never overlap between teammates")
        check(["Click at (1, 1)", "Click at (2, 2)", "Click at (3, 3)", "Click at (4, 4)"].allSatisfy(driver.performed.contains), "both teammates finish their clicks")
        let order = driver.performed.filter { ["Click at (1, 1)", "Click at (2, 2)", "Click at (3, 3)", "Click at (4, 4)"].contains($0) }
        let first = order.first.map { ["Click at (1, 1)", "Click at (2, 2)"].contains($0) } ?? false
        check(first ? order == ["Click at (1, 1)", "Click at (2, 2)", "Click at (3, 3)", "Click at (4, 4)"] : order == ["Click at (3, 3)", "Click at (4, 4)", "Click at (1, 1)", "Click at (2, 2)"], "a driver keeps the wheel for its whole reply before the next takes over")
        store.setOpenFloor(false)

        // 8. Stop from the banner ends a running shell command and the task.
        let marker = "31.\(Int.random(in: 1000...9999))"
        send("Run the slow one.", to: "claude", ["claude": [#"<<COMPUTER {"action":"task","state":"start","title":"Slow job"}>>"#, "<<COMPUTER {\"action\":\"shell\",\"command\":\"sleep \(marker)\"}>>", "Should not get here."]])
        try await wait("slow command running") { center.current["claude"]?.contains("sleep") == true }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        center.stopDriving()
        try await wait("stopped", seconds: 10) { !store.busy }
        check(Date().timeIntervalSince(started) < 5, "Stop returns within seconds")
        check(center.tasks.last?.title == "Slow job" && center.tasks.last?.state == "stopped", "Stop ends the durable task")
        check(!visible().contains("Should not get here."), "nothing continues after Stop")
        try await Task.sleep(for: .seconds(2.5))
        let survivors = try await NativeProcess.run(executable: "/usr/bin/pgrep", arguments: ["-f", "sleep " + marker], directory: scratch, environment: ["PATH": "/usr/bin:/bin"])
        check(survivors.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the stopped command's process is gone")
        check(center.recent.contains { $0.summary.contains("sleep " + marker) && $0.outcome == "stopped" }, "the stopped command is audited")

        // 8b. Review regressions.
        send("How do I click?", to: "claude", ["claude": ["Put the <<COMPUTER {\"action\":\"click\",\"x\":1,\"y\":1}>> marker on its own line when you want a click."]])
        try await wait("inline mention") { !store.busy }
        check(visible().last?.hasPrefix("Put the <<COMPUTER") == true, "a reply that only quotes the marker mid-line stays visible")
        let before = claude2.prompts.count
        send("Recover from typos.", to: "claude", ["claude": ["<<COMPUTER {oops", #"<<COMPUTER {"action":"nope"}>>"#, #"<<COMPUTER {"action":"screenshot"}>>"#, "Recovered."]])
        try await wait("corrections") { !store.busy }
        // One turn prompt plus a follow-up after each of the three requests.
        check(visible().last == "Recovered." && claude2.prompts.count == before + 4 && claude2.images.last == 1, "two malformed requests get corrections and the next valid one runs (\(claude2.prompts.count - before) prompts, last reply \(visible().last ?? "none"))")

        let stoppable = "32.\(Int.random(in: 1000...9999))"
        send("Run the stoppable one.", to: "claude", ["claude": [#"<<COMPUTER {"action":"task","state":"start","title":"Stoppable job"}>>"#, "<<COMPUTER {\"action\":\"shell\",\"command\":\"sleep \(stoppable)\"}>>", "Should not run either."]])
        try await wait("stoppable running") { center.current["claude"]?.contains("sleep") == true }
        try await Task.sleep(for: .milliseconds(300))
        center.stopTask(center.activeTask("claude", roomID)!.id)
        try await wait("task stop ends the reply", seconds: 10) { !store.busy }
        check(center.tasks.last?.title == "Stoppable job" && center.tasks.last?.state == "stopped" && !visible().contains("Should not run either."), "a task's own Stop also stops its teammate's live reply")
        try await Task.sleep(for: .seconds(2.5))
        let leftovers = try await NativeProcess.run(executable: "/usr/bin/pgrep", arguments: ["-f", "sleep " + stoppable], directory: scratch, environment: ["PATH": "/usr/bin:/bin"])
        check(leftovers.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the task Stop ends its running command")

        func direct(_ args: [String: Any], _ agent: String) async -> [String: Any] {
            await center.perform(try! ComputerRequest.validate(args), agent: agent, conversationID: roomID, projectRoots: [], progress: { _ in }).result
        }
        _ = await direct(["action": "task", "state": "start", "title": "Codex chore"], "codex")
        center.update { $0.enabledAgents["codex"] = false }
        check(!center.continuableTasks(roomID).contains { $0.agent == "codex" }, "a switched-off teammate's task is not continued")
        check(await direct(["action": "task", "state": "start", "title": "Another"], "codex")["ok"] as? Bool == false, "a switched-off teammate cannot start a task")
        check(await direct(["action": "task", "state": "done", "note": "Closed while off."], "codex")["ok"] as? Bool == true && center.activeTask("codex", roomID) == nil, "a switched-off teammate can still close its task")
        center.update { $0.enabledAgents["codex"] = true }

        _ = await direct(["action": "task", "state": "start", "title": "Budget job"], "eve")
        let budget = center.activeTask("eve", roomID)!.id
        for _ in 0..<ComputerControlCenter.continuationLimit { _ = center.noteContinuation(budget) }
        check(!center.noteContinuation(budget) && center.tasks.first { $0.id == budget }?.state == "blocked", "a task pauses after the automatic-continuation limit")
        center.noteJasonMessage(roomID)
        check(center.tasks.first { $0.id == budget }?.continuations == 0, "Jason's message gives the task a fresh budget")
        _ = await direct(["action": "task", "state": "progress", "note": "Back on it."], "eve")
        check(center.tasks.first { $0.id == budget }?.state == "running" && center.noteContinuation(budget), "progress resumes a blocked task and continuation works again")
        _ = await direct(["action": "task", "state": "done", "note": "Budget job finished."], "eve")

        // Finding 1: a screenshot taken while Jason grabs the wheel is discarded, image and all.
        center.update { $0.idleSeconds = 20 }
        driver.onScreenshot = { center.humanInput() }
        send("Peek at the screen.", to: "claude", ["claude": [#"<<COMPUTER {"action":"screenshot"}>>"#, "Understood, waiting for you."]])
        try await wait("discarded capture") { !store.busy }
        driver.onScreenshot = nil
        check(claude2.prompts.last?.contains("\"interrupted\":true") == true && claude2.images.last == 0, "a capture taken as Jason takes the wheel returns no image")
        check(center.recent.first?.action == "screenshot" && center.recent.first?.outcome == "interrupted" && center.recent.first?.screenshot == nil, "the discarded capture saved no screenshot to the audit log")
        center.humanInput(); try await Task.sleep(for: .milliseconds(50))

        // Finding 7: a drag that drops into a messaging app asks, even when it starts somewhere safe.
        center.letThemDrive()
        driver.appAt = { x in x >= 500 ? ComputerTarget(appName: "Mail", bundleID: "com.apple.mail") : ComputerTarget(appName: "TextEdit", bundleID: "com.apple.TextEdit") }
        send("Drag this over.", to: "claude", ["claude": [#"<<COMPUTER {"action":"drag","from":[10,10],"to":[900,400]}>>"#, "I did not drop it."]])
        try await wait("drag approval") { center.pending.count == 1 }
        check(center.pending.first?.ruleTitle == "Sending email or messages", "a drag into Mail asks under the messaging rule by its drop point")
        center.resolve(center.pending[0].id, allow: false)
        try await wait("drag denied") { !store.busy }
        check(!driver.performed.contains { $0.hasPrefix("Drag") }, "the denied drag never ran")
        driver.appAt = nil

        // Finding 3: a task that cannot be saved is not started and promises nothing durable.
        let blockedRoot = root.appendingPathComponent("blocked-tasks")
        try FileManager.default.createDirectory(at: blockedRoot.appendingPathComponent("Audit/Screens"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blockedRoot.appendingPathComponent("tasks.json"), withIntermediateDirectories: true) // a directory where the file must go
        let blockedCenter = ComputerControlCenter(root: blockedRoot, driver: SyntheticComputerDriver(), live: false, initialIdle: 3600)
        let startResult = await blockedCenter.perform(try! ComputerRequest.validate(["action": "task", "state": "start", "title": "Won't persist"]), agent: "claude", conversationID: roomID, projectRoots: [], progress: { _ in }).result
        check(startResult["ok"] as? Bool == false && (startResult["error"] as? String)?.contains("could not save") == true, "a task that cannot be saved is refused, not acknowledged as durable")
        check(blockedCenter.tasks.isEmpty && blockedCenter.notice != nil, "no running task is left behind and Jason is warned")

        // Finding 4: an action whose audit entry cannot be written is flagged, not shown as durable.
        let auditRoot = root.appendingPathComponent("blocked-audit")
        try FileManager.default.createDirectory(at: auditRoot.appendingPathComponent("Audit/Screens"), withIntermediateDirectories: true)
        let dateName = { () -> String in let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) + ".jsonl" }()
        try FileManager.default.createDirectory(at: auditRoot.appendingPathComponent("Audit/" + dateName), withIntermediateDirectories: true) // a directory blocks the log file
        let auditCenter = ComputerControlCenter(root: auditRoot, driver: SyntheticComputerDriver(), live: false, initialIdle: 3600)
        _ = await auditCenter.perform(try! ComputerRequest.validate(["action": "wait", "seconds": 0]), agent: "claude", conversationID: roomID, projectRoots: [], progress: { _ in }).result
        check(auditCenter.notice?.contains("audit log") == true && auditCenter.recent.first?.detail?.contains("NOT SAVED TO AUDIT LOG") == true, "an unwritable audit entry is flagged in memory and warned, never presented as durable")

        // Connections: an own-branch push proceeds; a disconnected server refuses ssh end to end.
        let pushProbe = scratch.appendingPathComponent("push-probe")
        _ = await direct(["action": "shell", "command": "echo would-push > \(pushProbe.path)"], "claude") // sanity: shell lane works
        check(FileManager.default.fileExists(atPath: pushProbe.path), "the shell lane still runs ordinary commands")
        center.setConnection(AskFirstPolicy.server, connected: false)
        let blocked = await direct(["action": "shell", "command": "ssh deploy@vps 'uptime'"], "claude")
        check(blocked["ok"] as? Bool == false && blocked["disconnected"] as? String == AskFirstPolicy.server, "a disconnected server refuses ssh, with no command run")
        check(center.recent.first?.outcome == "refused" && center.recent.first?.rule == AskFirstPolicy.server, "the refusal is audited against the server connection")
        center.setConnection(AskFirstPolicy.server, connected: true)
        // With the server connected but no dedicated key, ssh is still refused (never Jason's key).
        let noKey = await direct(["action": "shell", "command": "ssh deploy@vps 'uptime'"], "claude")
        check(noKey["ok"] as? Bool == false && noKey["disconnected"] as? String == AskFirstPolicy.server, "ssh is refused until a dedicated agent key exists")
        center.createAgentKey()
        try await wait("agent key created", seconds: 20) { center.agentKey != nil }
        // A bogus host so nothing real is contacted; a short timeout keeps the test quick.
        let withKey = await direct(["action": "shell", "command": "ssh -o BatchMode=yes -o ConnectTimeout=3 -i '\(center.agentKey!.privateKeyPath)' deploy@silkwire-agent-test.invalid 'echo hi'", "timeout": 15], "claude")
        check(withKey["disconnected"] == nil && withKey["ok"] as? Bool == true, "with a dedicated key, ssh is allowed to run (not refused by policy)")
        check(center.connectionConnected(AskFirstPolicy.github), "GitHub stays connected by default")

        // 9. Restart: a task left running resumes when its conversation reconnects.
        transports["claude"]?.hangOnEmpty = true
        send("Start the overnight job.", to: "claude", ["claude": [#"<<COMPUTER {"action":"task","state":"start","title":"Overnight job"}>>"#, "Started; more soon."]])
        try await wait("continuation pending", seconds: 20) { store.conversation.messages.filter { $0.detail == ConversationStore.taskContinuation }.count == 2 && store.busy }
        let snapshot = try Data(contentsOf: library.appendingPathComponent("workspace.json"))
        store.disconnect(persist: false)
        let reopenedLibrary = root.appendingPathComponent("library-reopened")
        try FileManager.default.createDirectory(at: reopenedLibrary, withIntermediateDirectories: true)
        try snapshot.write(to: reopenedLibrary.appendingPathComponent("workspace.json"))
        let reopenedCenter = ComputerControlCenter(root: controlRoot, driver: driver, live: false, initialIdle: 3600)
        let pending = reopenedCenter.tasks.last
        check(pending?.title == "Overnight job" && pending?.state == "running" && pending?.resumeAfterRestart == true, "a running task survives the restart and is marked for resuming")
        var reopenedTransports: [String: ScriptedComputerTransport] = [:]
        let reopened = ConversationStore(directory: reopenedLibrary, transportFactory: { agent, _ in
            let transport = ScriptedComputerTransport(agent == "claude" ? [#"<<COMPUTER {"action":"task","state":"done","note":"Overnight job finished after the restart."}>>"#, "Overnight job finished after the restart."] : [])
            reopenedTransports[agent] = transport; return transport
        }, workspaceSandbox: stage, computer: reopenedCenter)
        await reopened.start()
        try await wait("resumed after restart", seconds: 20) { !reopened.connecting && !reopened.busy && reopenedCenter.tasks.last?.state == "done" }
        check(reopenedTransports["claude"]?.prompts.first?.contains("Silkwire restarted or reconnected while this task was running") == true, "the resumed teammate is told about the restart")
        check(reopened.conversation.messages.last { $0.author == "Claude" }?.text == "Overnight job finished after the restart.", "the task finishes after the restart without Jason")
        reopened.disconnect()
        store.disconnect()

        print("ComputerRoomTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
