import Foundation
import AppKit
import Darwin

// Background work, chat side, end to end: the real ConversationStore and NativeRoom,
// a real private trusted workspace on a synthetic Git repository, scripted teammates,
// and FakeBackgroundJobHost (contract v1) as the work host. No command, provider or
// network runs: the fake host only records the request, and this test moves each job.
@MainActor final class JobRoomTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    let agent: String
    let script: (String, String) -> String
    init(_ agent: String, script: @escaping (String, String) -> String) { self.agent = agent; self.script = script }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: "job-room-fixture-" + agent, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        try? await Task.sleep(for: .milliseconds(15))
        eventHandler?(.delta(script(agent, text)))
        eventHandler?(.finished(status: "completed", message: nil))
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: "Synthetic Stop")) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport only") }
}
/// Holds the host's durable acceptance until the test lets it through.
@MainActor final class AcceptanceGate {
    var holding = false, waiting = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pass() async { guard holding else { return }; waiting = true; await withCheckedContinuation { waiter = $0 }; waiting = false }
    func open() { holding = false; let old = waiter; waiter = nil; old?.resume() }
}

@main struct BackgroundJobRoomTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let files = FileManager.default
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func waitFor(_ seconds: Double = 20, _ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                guard Date() < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
        func marker(_ args: [String: Any]) -> String { "<<WORK_PROJECT " + ((try? nativeJSON(args)) ?? "{}") + ">>" }
        /// Jason's current message inside a teammate prompt (history repeats earlier ones).
        func current(_ prompt: String) -> String {
            guard let range = prompt.range(of: "CURRENT REQUEST FROM JASON:", options: .backwards) else { return "" }
            return String(prompt[range.upperBound...])
        }

        // Project folder grants compare bookmark paths after resolvingSymlinksInPath(), as
        // the Project access suites do; use that same form for the grant and the sandbox.
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? files.temporaryDirectory
        let root = tmp.resolvingSymlinksInPath().appendingPathComponent("BackgroundJobRoom-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let source = stage.sources.appendingPathComponent("fixture")
        let home = root.appendingPathComponent("fixture-home")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        for name in ["README.md", "codex.txt", "claude.txt", "eve.txt"] { try Data("synthetic \(name)\n".utf8).write(to: source.appendingPathComponent(name)) }
        try Data("output/\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
        let gitEnvironment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
        for args in [["init"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "-c", "commit.gpgsign=false", "commit", "-m", "Synthetic background job source"]] {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: source, environment: gitEnvironment)
            guard result.exitCode == 0 else { print("FAIL: synthetic Git preparation"); exit(1) }
        }
        // The host's own D2 registry: a canonical private directory, as the host suites use.
        let hostRoot = try NativeTemporaryDirectory.createWorkspace()
        defer { try? files.removeItem(at: hostRoot) }
        let ownership = hostRoot.appendingPathComponent("registry"), executorRoot = hostRoot.appendingPathComponent("executor")
        try files.createDirectory(at: executorRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Keep this test off the app-global registry (~/Library/Application Support/Silkwire Host
        // Ownership): NativeRoom builds its trusted workspaces with the default .application
        // coordinator, so every teammate request here runs beneath a parent admission from a
        // PRIVATE coordinator, which trusted begin inherits instead of admitting globally.
        // One per teammate: an inherited admission carries one nested workspace at a time.
        var parents: [String: (HostExecutionCoordinator, HostExecutionAdmission)] = [:]
        for agent in agents {
            let coordinator = HostExecutionCoordinator(directory: hostRoot.appendingPathComponent("parent-registry-" + agent))
            parents[agent] = (coordinator, try await coordinator.admit(operationID: UUID(), conversationID: UUID(), kind: .foregroundBuild,
                authorize: { HostAuthorizedWorkspace(executionRoot: source, conflictRoot: source) }, mayOperate: { true }))
        }
        /// The teammate asked to begin work in this message, else Codex.
        func parent(for text: String) -> HostExecutionAdmission { parents[agents.first { text.contains("RUN-CHECKS-" + $0) } ?? "codex"]!.1 }

        let library = root.appendingPathComponent("library")
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        var project = Project(); project.name = "Synthetic background jobs"; project.trustedStaging = true
        project.folders = [ProjectFolder(name: "Fixture source", path: source.path, bookmark: try source.bookmarkData(), builderAllowed: true)]
        var room = Conversation(); room.projectID = project.id; room.recipient = "codex"; room.title = "Background jobs"
        try JSONEncoder().encode(ConversationWorkspace(activeID: room.id, conversations: [room], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))

        // Scripted teammates. A run request is the only long work; begin stays in the turn.
        var open: Set<String> = [], beginning: Set<String> = []
        let runChecks: [String: Any] = ["action": "run", "checks": [["name": "build", "command": "swift build"], ["name": "test", "command": "swift test"]]]
        let script: (String, String) -> String = { agent, prompt in
            let who = names[agent] ?? agent
            if prompt.hasPrefix("TRUSTED STAGING HOST RESULT") {
                if prompt.contains("\"ok\":false") { return who + " noted that the request was refused." }
                // Only a begin result leads to the run; any other host result ends the reply.
                guard beginning.remove(agent) != nil else { return who + " wrapped up." }
                open.insert(agent); return marker(runChecks)
            }
            let request = current(prompt)
            if request.contains("Your background job finished") { return who + " explains: the result is in the receipt above." }
            if request.contains("PASS-ALL") { return "PASS" }
            if request.contains("RUN-CHECKS-" + agent) {
                if open.contains(agent) { return marker(runChecks) }
                beginning.insert(agent)
                return marker(["action": "begin", "folderId": project.folders![0].id.uuidString.lowercased(), "paths": [agent + ".txt"], "taskTitle": "Synthetic checks for " + who])
            }
            if request.contains("EDIT-NOW-" + agent) { return marker(["action": "write", "path": agent + ".txt", "content": "edited\n", "expectedSha256": NSNull()]) }
            return who + " chat reply."
        }
        // Host wiring, as the app supplies it: the registered host and a fresh scope resolver.
        let gate = AcceptanceGate()
        var scopeCalls: [(UUID, UUID, String)] = []
        let scopeResolver: HostJobCommandRouter.Scope = { conversation, workspace, agent in
            scopeCalls.append((conversation, workspace, agent))
            return BackgroundWorkScope(projectID: project.id, conversationID: conversation, workspaceID: workspace, agentID: agent, sourceRevision: String(repeating: "b", count: 40))
        }
        var transports: [String: JobRoomTransport] = [:]
        let host = FakeBackgroundJobHost(ownership: ownership, workspace: executorRoot)
        host.acceptanceGate = { await gate.pass() }
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in
            let value = JobRoomTransport(agent, script: script); transports[agent] = value; return value
        }, workspaceSandbox: stage, backgroundJobs: .init(host: { _ in host }, scope: scopeResolver))
        guard store.storageError == nil else { print("FAIL: library: " + (store.storageError ?? "")); exit(1) }
        await store.start()
        check(await waitFor { !store.connecting && agents.allSatisfy { store.seats[$0]?.state == "connected" } }, "the synthetic team connects")
        check(store.trustedStagingAvailable && store.jobDesk != nil, "trusted Staging and the background job desk are both on")

        func send(_ recipients: String, _ text: String) async -> Bool {
            guard await waitFor(20, { !store.busy }) else { return false }
            store.conversation.recipient = recipients; store.conversation.draft = text
            HostExecutionScope.$admission.withValue(parent(for: text)) { store.send() }
            return await waitFor { !store.busy && store.conversation.messages.contains { $0.author == "Jason" && $0.text == text && $0.state == "sent" } }
        }
        func card(_ id: UUID?, _ source: ConversationStore? = nil) -> BackgroundJobCard? { (source ?? store).conversation.backgroundJobs?.first { $0.id == id } }
        func receipts(_ messages: [Message], _ resultID: UUID?) -> [Message] {
            guard let key = resultID?.uuidString.lowercased() else { return [] }
            return messages.filter { $0.author == BackgroundJobText.resultAuthor && $0.requestId == key }
        }
        func replies(to text: String) -> [Message] {
            guard let request = store.conversation.messages.last(where: { $0.author == "Jason" && $0.text == text })?.requestId else { return [] }
            return store.conversation.messages.filter { $0.requestId == request && $0.author != "Jason" }
        }
        func onDisk(_ directory: URL) -> Conversation? {
            (try? JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: directory.appendingPathComponent("workspace.json"))))?.conversations.first
        }
        /// Owners who finished a Silkwire follow-up turn about a background result.
        func explained() -> [String] {
            store.conversation.messages.filter { $0.author == "Silkwire" && $0.detail == BackgroundJobText.followUpDetail }.flatMap { request in
                store.conversation.messages.filter { $0.requestId == request.requestId && $0.author != "Silkwire" && $0.state == "completed" }.map(\.author)
            }
        }

        // 1. Release the floor. Codex's turn waits only for the host's durable acceptance.
        gate.holding = true
        let firstAsk = "RUN-CHECKS-codex: build and test the fixture, please."
        store.conversation.recipient = "codex"; store.conversation.draft = firstAsk
        HostExecutionScope.$admission.withValue(parent(for: firstAsk)) { store.send() }
        check(await waitFor { gate.waiting }, "the run reaches the host's submit")
        let pendingCard = store.conversation.backgroundJobs?.first
        check(pendingCard?.phase == .submitting && pendingCard?.stateLabel == "Handing off…" && store.busy, "until the host accepts, the card says Handing off… and the turn is open")
        check(onDisk(library)?.backgroundJobs?.first?.id == pendingCard?.id, "the card is on disk before the host accepts the job")
        gate.open()
        check(await waitFor { !store.busy }, "Codex's turn ends as soon as the host accepts")
        let job1 = pendingCard?.id
        let request1 = host.requests.first
        check(host.requests.count == 1 && request1?.operationID == job1 && request1?.workDescription == "Run build and test checks", "the host got the room's operationID and a plain-English description")
        let codexWorkspace = store.trustedReceipts.values.first { $0["owner"] as? String == "codex" }?["id"] as? String
        check(request1?.scope.workspaceID.uuidString == codexWorkspace && request1?.scope.agentID == "codex" && request1?.scope.conversationID == store.conversation.id && scopeCalls.count == 1, "the scope came from the host resolver for Codex's own workspace")
        check(job1.flatMap { store.jobDesk?.requestedWork(job: $0, conversationID: store.conversation.id) }?.contains("\"swift test\"") == true, "the host's Plan can read the exact requested run (as quoted data)")
        check(job1.flatMap { host.state($0) } == .running && card(job1)?.phase == .running && card(job1)?.stateLabel == "Running", "the card shows who, what and Running")
        let ack = replies(to: firstAsk).last
        check(ack?.author == "Codex" && ack?.state == "completed" && ack?.text == BackgroundJobText.acknowledgement("Run build and test checks") && ack?.text.contains("\n") == false, "Codex answers with a one-line acknowledgement")
        check(transports["codex"]?.prompts.first?.contains("BACKGROUND RUNS") == true, "teammates are told that run steps go to the background")
        if job1 == nil || request1 == nil { for m in store.conversation.messages { print("Transcript: \(m.author) [\(m.state)] \(m.text.prefix(200)) \(m.detail ?? "")") } }

        // 2. The room keeps talking: Jason messages everyone; the others reply.
        let chat = "CHAT-1: quick check-in while Codex's build runs."
        check(await send("eve,claude,codex", chat), "Jason's message goes through while the job runs")
        check(replies(to: chat).filter { $0.state == "completed" }.count == 3 && replies(to: chat).contains { $0.author == "Eve" && $0.text == "Eve chat reply." }, "Eve, Claude and Codex all reply during the job")
        check(job1.flatMap { host.state($0) } == .running && card(job1)?.phase == .running, "the job is still running after the chat round")
        check(store.trustedReceipts.values.contains { $0["owner"] as? String == "codex" && $0["finishedAt"] != nil } && !store.trustedReceipts.values.contains { $0["owner"] as? String == "codex" && $0["finishedAt"] == nil },
              "handing off finished Codex's workspace (an open workspace holds the one work slot); the job builds its committed revision")
        store.setOpenFloor(true)
        let openChat = "CHAT-2: open floor while the build runs."
        check(await send("eve,claude,codex", openChat), "an open-floor message goes through while the job runs")
        check(replies(to: openChat).filter { $0.state == "completed" }.count == 3 && job1.flatMap { host.state($0) } == .running, "all three answer on the open floor; the job keeps running")
        let passAll = "PASS-ALL: anything to add?"
        check(await send("eve,claude,codex", passAll), "an open-floor message everyone passes on completes")
        let quiet = replies(to: passAll)
        let passLines = quiet.filter { $0.detail == "Passed" }
        check(Set(passLines.map(\.author)) == ["Eve", "Claude", "Codex"] && passLines.allSatisfy { $0.text == ConversationStore.passedText }, "each teammate's pass is its own quiet line")
        check(quiet.filter { $0.author == "Silkwire" }.count == 1 && quiet.contains { $0.author == "Silkwire" && $0.text == BackgroundJobText.everyonePassed && $0.detail == BackgroundJobText.everyonePassedDetail } && quiet.count == 4, "and one quiet line says everyone passed")

        // 2b. Edits wait for the job; nothing new reaches the host.
        check(await send("codex", "EDIT-NOW-codex"), "a teammate edit request during the job completes its turn")
        check(transports["codex"]?.prompts.last?.contains("your background job is still using this workspace") == true && host.requests.count == 1, "edits to a workspace in use are refused, and no job is created")
        check(transports["codex"]?.prompts.last.map { !$0.contains(BackgroundJobText.everyonePassed) } ?? false, "the quiet line is never sent to teammates as history")

        // 3. One slot: a second delegation (on the open floor) queues on its own card.
        let secondAsk = "RUN-CHECKS-claude: run your checks too."
        check(await send("eve,claude", secondAsk), "on the open floor, Claude's turn ends when it delegates a second job")
        let job2 = host.order.count > 1 ? host.order[1] : nil
        if job2 == nil {
            for m in store.conversation.messages.suffix(8) { print("Transcript: \(m.author) [\(m.state)] \(m.text.prefix(300)) \(m.detail ?? "")") }
            print("Status: \(store.status) busy=\(store.busy)")
        }
        check(job2.flatMap { host.state($0) } == .queued && card(job2)?.stateLabel == "Queued", "the second job shows as queued on its own card")
        check(replies(to: secondAsk).first { $0.author == "Claude" }?.text == BackgroundJobText.acknowledgement("Run build and test checks") && replies(to: secondAsk).first { $0.author == "Eve" }?.text == "Eve chat reply.", "Claude acknowledges in one line while Eve talks in the same round")
        check(card(job1)?.phase == .running, "the first job keeps running beside the queued card")
        check(await send("eve", "RUN-CHECKS-eve: and yours."), "a third delegation also returns at once")
        let job3 = host.order.count > 2 ? host.order[2] : nil
        check(card(job3)?.phase == .queued, "a third job queues behind the same slot")

        // 4. Stop: a fence now, durable intent separately, "Stopping…" until the snapshot records the end.
        if let job1 { store.stopBackgroundJob(job1) }
        check(card(job1)?.stopRequested == true && card(job1)?.stateLabel == "Stopping…" && job1.flatMap { host.state($0) } == .stopping, "Stop fences at once and the card says Stopping…")
        check(await waitFor { card(job1)?.stopRecorded == true && host.stopCalls == [job1].compactMap { $0 } }, "the durable Stop acknowledgement is recorded on the card")
        try? await Task.sleep(for: .milliseconds(300))
        check(card(job1)?.stateLabel == "Stopping…" && card(job1)?.phase == .stopping, "an acknowledged Stop alone never shows Stopped")
        if let job1 { await host.end(job1, note: "Stopped by the host.") }
        check(await waitFor { card(job1)?.stateLabel == "Stopped" }, "Stopped once the host records the end and holds nothing")
        check(store.conversation.messages.allSatisfy { $0.author != BackgroundJobText.resultAuthor }, "a stopped job posts no result")
        check(await waitFor { card(job2)?.phase == .running }, "the queued job starts when the slot frees")

        // 5. The result posts once. Its acknowledgement then fails: a crash between insert and acknowledge.
        host.acknowledgementFailure = BackgroundWorkError.storage
        if let job2 { await host.complete(job2, summary: "build: passed (exit 0). test: passed, 12 tests (exit 0).") }
        let result2 = job2.flatMap { host.jobs[$0]?.resultID }
        check(await waitFor { receipts(store.conversation.messages, result2).count == 1 && card(job2)?.phase == .completed }, "the completed job's result is posted to the room")
        check(receipts(store.conversation.messages, result2).first?.text.contains("Claude · Run build and test checks · Completed") == true && receipts(store.conversation.messages, result2).first?.text.contains("12 tests") == true, "the receipt says who, what, and the host's evidence")
        check(await waitFor { receipts(onDisk(library)?.messages ?? [], result2).count == 1 }, "the receipt is on disk")
        store.reattachBackgroundJobs() // A repeated poll of pendingResults before acknowledgement.
        try? await Task.sleep(for: .milliseconds(200))
        check(receipts(store.conversation.messages, result2).count == 1 && card(job2)?.resultAcknowledged == false && host.pendingResults.count == 1, "repeated polls never post twice; the result stays pending while acknowledging fails")
        check(await waitFor { explained() == ["Claude"] && !store.busy }, "Claude gets a short follow-up turn to explain the result")
        check(transports["claude"]?.prompts.contains { current($0).contains("Your background job finished") && $0.contains("12 tests") } == true, "the follow-up quotes the host's result")
        check(await waitFor { card(job3)?.phase == .running }, "the third job runs once the second has finished")
        var holdError: Error?
        if let job3 { do { try await host.holdPhysically(job3) } catch { holdError = error } } // its executor's exit will not be provable
        check(holdError == nil, "the synthetic executor holds the physical slot")

        // 6. Restart: cards return; the result is acknowledged without a second post; running work needs review.
        check(await waitFor { !store.busy }, "the room is idle before the simulated quit")
        store.shutdown()
        let restarted = root.appendingPathComponent("restarted")
        try files.createDirectory(at: restarted, withIntermediateDirectories: true)
        try files.copyItem(at: library.appendingPathComponent("workspace.json"), to: restarted.appendingPathComponent("workspace.json"))
        let host2 = FakeBackgroundJobHost(ownership: ownership, workspace: executorRoot, restoring: host.saved)
        let reopened = ConversationStore(directory: restarted, transportFactory: { agent, _ in JobRoomTransport(agent, script: { _, _ in "ok" }) }, workspaceSandbox: stage, backgroundJobs: .init(host: { _ in host2 }, scope: scopeResolver))
        check(reopened.conversation.backgroundJobs?.count == 3, "all three cards come back after the restart")
        check(await waitFor { host2.acknowledgements == [result2].compactMap { $0 } && card(job2, reopened)?.resultAcknowledged == true }, "after the restart the pending result is acknowledged")
        check(receipts(reopened.conversation.messages, result2).count == 1, "the crash between insert and acknowledge never posts a second receipt")
        check(await waitFor { card(job3, reopened)?.phase == .needsReview && card(job3, reopened)?.physicalHold != nil }, "work running at the quit shows Needs review and may still be running")
        check(card(job3, reopened)?.stateLabel == "Needs review" && card(job3, reopened)?.mayRelease == true && card(job3, reopened)?.resultID == nil, "never done: Release is offered, no result is posted")
        check(card(job1, reopened)?.stateLabel == "Stopped" && card(job2, reopened)?.stateLabel == "Completed", "finished cards keep their final state")

        // 7. Release asks for fresh verification. Without evidence it stays held, and says why.
        if let job3 { reopened.releaseBackgroundJob(job3) }
        check(await waitFor { card(job3, reopened)?.releasing == false && card(job3, reopened)?.releaseNote?.hasPrefix("Still held") == true }, "Release without proof is retained")
        check(card(job3, reopened)?.releaseNote?.contains("No independent exit evidence") == true && card(job3, reopened)?.physicalHold != nil, "the card shows the host's reason and keeps the hold")
        host2.verifier = { _ in .verified(evidence: "fixture: exact executor exit observed") }
        if let job3 { reopened.releaseBackgroundJob(job3) }
        check(await waitFor { card(job3, reopened)?.releaseNote?.hasPrefix("Released") == true && card(job3, reopened)?.physicalHold == nil }, "with fresh evidence the host releases the slot")
        let stillHeld = (try? await host2.heldPhysicalOperations())?.count
        check(card(job3, reopened)?.phase == .needsReview && stillHeld == 0, "release frees the slot but never claims the job's outcome")
        try? await Task.sleep(for: .milliseconds(200))
        check(reopened.conversation.messages.filter { $0.author == BackgroundJobText.resultAuthor }.count == 1, "one completed job, one receipt")
        reopened.shutdown()

        // 8. Another restart: cards and receipts are unchanged, nothing posts twice.
        let again = root.appendingPathComponent("again")
        try files.createDirectory(at: again, withIntermediateDirectories: true)
        try files.copyItem(at: restarted.appendingPathComponent("workspace.json"), to: again.appendingPathComponent("workspace.json"))
        let host3 = FakeBackgroundJobHost(ownership: ownership, workspace: executorRoot, restoring: host2.saved)
        let third = ConversationStore(directory: again, transportFactory: { agent, _ in JobRoomTransport(agent, script: { _, _ in "ok" }) }, workspaceSandbox: stage, backgroundJobs: .init(host: { _ in host3 }, scope: scopeResolver))
        try? await Task.sleep(for: .milliseconds(300))
        check(third.conversation.backgroundJobs?.map(\.stateLabel) == ["Stopped", "Completed", "Needs review"], "cards keep their states across another restart")
        check(third.conversation.messages.filter { $0.author == BackgroundJobText.resultAuthor }.count == 1 && host3.acknowledgements.isEmpty, "no receipt is posted or acknowledged twice")
        third.shutdown()

        for (coordinator, admission) in parents.values { try? await coordinator.finish(admission, exit: .verified(evidence: "fixture: no executor ran under the test's parent admission")) }
        // An existing registry this runner may not read (a sandboxed runner can see the file but
        // not open it) is reported as not checked, never as a pass or a failure.
        let appRegistry = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Silkwire Host Ownership/ownership.json")
        if !files.fileExists(atPath: appRegistry.path) {
            check(true, "this run wrote nothing to the app-global ownership registry")
        } else if let text = try? String(contentsOf: appRegistry, encoding: .utf8) {
            check(!text.contains(root.lastPathComponent), "this run wrote nothing to the app-global ownership registry")
        } else {
            print("NOTE: the app-global ownership registry exists but this runner can't read it; not checked")
        }
        print("BackgroundJobRoomTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
