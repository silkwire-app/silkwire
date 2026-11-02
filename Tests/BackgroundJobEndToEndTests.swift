import Foundation
import AppKit
import Darwin

// Background work switched on, end to end, with the REAL host service:
// the real ConversationStore, NativeRoom and trusted private workspaces on a synthetic
// Git repository; BackgroundJobBootstrap opening a real HostBackgroundJobService
// (BackgroundWorkRunner, HostBackgroundExecution, BackgroundJobHostRecovery) over a
// per-conversation BackgroundWorkStorageSession under the Staging library; and the
// command bridge as the Plan callback. Only the executor is a stub: it asks the bridge
// for the plan, records it, and waits for the test to finish it. One private D2
// registry is shared by the room's workspaces and the host, as in the app.
// No command, provider or network runs.

@MainActor final class E2ETransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    let agent: String
    let script: (String, String) -> String
    init(_ agent: String, script: @escaping (String, String) -> String) { self.agent = agent; self.script = script }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: "e2e-fixture-" + agent, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        try? await Task.sleep(for: .milliseconds(10))
        eventHandler?(.delta(script(agent, text)))
        eventHandler?(.finished(status: "completed", message: nil))
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: "Synthetic Stop")) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport only") }
}

/// The stub executor behind the real host. It plans through the command bridge exactly as
/// HostNativeBuilderJobs does, then waits until the test finishes it or Stop fences it.
@MainActor final class StubExecutor {
    var plans: [UUID: HostNativeBuildPlan] = [:]
    var started: [UUID] = []
    var outcomes: [UUID: String] = [:]
    var cancelled: Set<UUID> = []
    /// Joins held open (a stopped executor that hasn't been seen to exit yet).
    var joinHeld: Set<UUID> = []
    var joining: Set<UUID> = []
    /// Per-job exit answers; default is the fixture's verified exit.
    var exits: [UUID: () async -> HostPhysicalExit] = [:]
    func execute(_ context: BackgroundWorkContext, plan: (BackgroundWorkContext) async throws -> HostNativeBuildPlan) async throws -> BackgroundWorkStep {
        let id = context.item.id
        let approved = try await plan(context)
        plans[id] = approved; started.append(id)
        while outcomes[id] == nil {
            guard context.mayPerformOperation() else { throw CancellationError() }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard context.mayPerformOperation() else { throw CancellationError() }
        return .completed(checkpoint: "stub executor " + id.uuidString.lowercased(), summary: outcomes[id] ?? "")
    }
    func cancel(_ id: UUID) { cancelled.insert(id) }
    func join(_ context: BackgroundWorkContext) async -> HostPhysicalExit {
        let id = context.item.id
        joining.insert(id); defer { joining.remove(id) }
        while joinHeld.contains(id) { try? await Task.sleep(for: .milliseconds(10)) }
        if let exit = exits[id] { return await exit() }
        return .verified(evidence: "fixture: the stub executor returned and started no process")
    }
    func finish(_ id: UUID?, summary: String) { if let id { outcomes[id] = summary } }
}

/// The real service seen through the desk, with one switch: acknowledgements can fail,
/// to stand in for a crash between the durable insert and the acknowledgement.
@MainActor final class AcknowledgementSwitch: BackgroundJobHost {
    let real: any BackgroundJobHost
    var failAcknowledgements = false
    init(_ real: any BackgroundJobHost) { self.real = real }
    func submit(_ request: HostJobRequest) async throws -> UUID { try await real.submit(request) }
    func snapshot(_ jobID: UUID) -> HostJobSnapshot? { real.snapshot(jobID) }
    func events() -> AsyncStream<HostJobSnapshot> { real.events() }
    func requestStop(_ jobID: UUID) { real.requestStop(jobID) }
    func stop(_ jobID: UUID) async throws -> HostJobStopAcknowledgement { try await real.stop(jobID) }
    var pendingResults: [BackgroundWorkItem] { real.pendingResults }
    func acknowledgeResult(_ jobID: UUID, resultID: UUID) async throws -> Bool {
        if failAcknowledgements { throw BackgroundWorkError.storage }
        return try await real.acknowledgeResult(jobID, resultID: resultID)
    }
    func heldPhysicalOperations() async throws -> [HostHeldPhysicalOperation] { try await real.heldPhysicalOperations() }
    func checkPhysicalExit(operationID: UUID) async throws -> HostPhysicalExitCheck { try await real.checkPhysicalExit(operationID: operationID) }
    func reconcilePhysicalExit(_ check: HostPhysicalExitCheck) async throws -> HostPhysicalRelease { try await real.reconcilePhysicalExit(check) }
}

@main struct BackgroundJobEndToEndTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let files = FileManager.default
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func waitFor(_ seconds: Double = 15, _ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                guard Date() < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
        func marker(_ args: [String: Any]) -> String { "<<WORK_PROJECT " + ((try? nativeJSON(args)) ?? "{}") + ">>" }
        func current(_ prompt: String) -> String {
            guard let range = prompt.range(of: "CURRENT REQUEST FROM JASON:", options: .backwards) else { return "" }
            return String(prompt[range.upperBound...])
        }
        let appRegistry = HostOwnershipDefault.testRegistry
        let appRegistryBefore = files.fileExists(atPath: appRegistry.path)

        // Synthetic Project source (a committed Git repository) inside the Staging sources.
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? files.temporaryDirectory
        let root = tmp.resolvingSymlinksInPath().appendingPathComponent("BackgroundJobE2E-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let source = stage.sources.appendingPathComponent("fixture")
        let home = root.appendingPathComponent("fixture-home")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("synthetic source\n".utf8).write(to: source.appendingPathComponent("README.md"))
        try Data("output/\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
        let gitEnvironment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
        for args in [["init"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "-c", "commit.gpgsign=false", "commit", "-m", "Synthetic source"]] {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: source, environment: gitEnvironment)
            guard result.exitCode == 0 else { print("FAIL: synthetic Git preparation"); exit(1) }
        }
        func head(_ directory: URL) async -> String {
            ((try? await NativeProcess.run(executable: "/usr/bin/git", arguments: ["rev-parse", "HEAD"], directory: directory, environment: gitEnvironment))?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let library = root.appendingPathComponent("library")
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        var project = Project(); project.name = "Synthetic background jobs"; project.trustedStaging = true
        project.folders = [ProjectFolder(name: "Fixture source", path: source.path, bookmark: try source.bookmarkData(), builderAllowed: true)]
        var room = Conversation(); room.projectID = project.id; room.recipient = "codex"; room.title = "Background jobs, switched on"
        try JSONEncoder().encode(ConversationWorkspace(activeID: room.id, conversations: [room], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))
        let folderID = project.folders![0].id.uuidString.lowercased()

        // Scripted teammates: each request queues the steps that follow each host result.
        var steps: [String: [String]] = [:], changes = 0
        let runChecks: [String: Any] = ["action": "run", "checks": [["name": "build", "command": "swift build"], ["name": "test", "command": "swift test"]]]
        let script: (String, String) -> String = { agent, prompt in
            let who = names[agent] ?? agent
            if prompt.hasPrefix("TRUSTED STAGING HOST RESULT") {
                guard var queue = steps[agent], !queue.isEmpty else { return who + " wrapped up." }
                let next = queue.removeFirst(); steps[agent] = queue
                switch next {
                case "write":
                    changes += 1
                    return marker(["action": "write", "path": "\(agent)-change-\(changes).txt", "content": "change \(changes) by \(who)\n", "expectedSha256": NSNull()])
                case "checkpoint": return marker(["action": "checkpoint", "summary": who + "'s candidate"])
                case "run": return marker(runChecks)
                default: return next
                }
            }
            let request = current(prompt)
            if request.contains("Your background job finished") {
                // A finished teammate reply about a job result: memory markers in it must be captured.
                let note = agent == "codex" ? " <<REMEMBER " + ((try? nativeJSON(["kind": "decision", "text": "E2E: Codex's background build and test passed"])) ?? "") + ">>" : ""
                return who + " explains: the result is in the receipt above." + note
            }
            if request.contains("PASS-ALL") { return "PASS" }
            let begin = marker(["action": "begin", "folderId": folderID, "taskTitle": "Synthetic work for " + who])
            if request.contains("RUN-CHECKS-" + agent) { steps[agent] = ["write", "checkpoint", "run"]; return begin }
            if request.contains("PREP-" + agent) { steps[agent] = ["write", "checkpoint", who + " prepared a candidate."]; return begin }
            if request.contains("DIRTY-" + agent) { steps[agent] = ["write", "run"]; return begin }
            if request.contains("RERUN-" + agent) { return marker(runChecks) }
            if request.contains("BEGIN-" + agent) { steps[agent] = []; return begin }
            return who + " chat reply."
        }

        // The app's bootstrap, with a private injection/registry and the stub executor.
        let registry = try NativeTemporaryDirectory.createWorkspace()
        defer { try? files.removeItem(at: registry) }
        let stub = StubExecutor()
        var recoveryVerdict: () -> HostPhysicalExit = { .unconfirmed(reason: BackgroundJobExitVerification.unconfirmedReason) }
        var opened: [UUID: HostBackgroundJobService] = [:]
        func bootstrap(_ coordinator: HostExecutionCoordinator) -> BackgroundJobBootstrap {
            let verification = BackgroundJobExitVerification(
                verifyExit: { _ in .verified(evidence: "unused: the stub executor's own join supplies exit evidence") },
                verifyRecovery: { _ in recoveryVerdict() },
                verifyForegroundExit: { _ in .verified(evidence: "fixture: synthetic trusted workspace ran no commands; its host Git operations were awaited") })
            let injection = BackgroundJobHostInjection(ownership: coordinator)
            return BackgroundJobBootstrap(injection: injection, verification: verification, opener: { conversationID, storage, _, bridge in
                let execution = HostBackgroundExecution(coordinator: coordinator, resolve: { try await bridge.resolve($0) }, cancel: { stub.cancel($0) }, join: { await stub.join($0) })
                let service = try await HostBackgroundJobService.open(storage: storage, execution: execution, verifyRecovery: verification.verifyRecovery,
                    authorize: { await bridge.authorize($0) }, execute: { try await stub.execute($0, plan: { try await bridge.plan($0) }) })
                try injection.register(service, originatingConversationID: conversationID)
                opened[conversationID] = service
                return service
            })
        }
        let coordinator = HostExecutionCoordinator(directory: registry.appendingPathComponent("ownership"))
        let jobs = bootstrap(coordinator)
        var proxy: AcknowledgementSwitch?
        func wiring(_ jobs: BackgroundJobBootstrap) -> BackgroundJobDesk.Wiring {
            let base = jobs.wiring
            return BackgroundJobDesk.Wiring(host: { id in
                let real = try base.host(id)
                if let proxy, proxy.real === real { return proxy }
                let made = AcknowledgementSwitch(real); proxy = made; return made
            }, scope: base.scope, open: base.open, attach: base.attach, ownership: base.ownership, verifyForegroundExit: base.verifyForegroundExit)
        }
        var transports: [String: E2ETransport] = [:]
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in
            let value = E2ETransport(agent, script: script); transports[agent] = value; return value
        }, workspaceSandbox: stage, backgroundJobs: wiring(jobs))
        guard store.storageError == nil else { print("FAIL: library: " + (store.storageError ?? "")); exit(1) }
        let conversationID = store.conversation.id

        // Library bootstrap opened this conversation's host and its ledger.
        check(await waitFor { opened[conversationID] != nil }, "library bootstrap opens the conversation's host")
        if opened[conversationID] == nil {
            print("Open failures: \(jobs.openFailures)")
            do { try await jobs.open(conversationID) } catch { print("Open error: \(error)") }
            print("Room: \(String(describing: store.backgroundJobRoom(conversationID))) storage: \(String(describing: try? store.backgroundJobStorage(conversationID)))")
            exit(1)
        }
        let ledger = ((try? store.backgroundJobStorage(conversationID)) ?? stage.library).appendingPathComponent("ledger")
        let teamWorkspaces = store.workspaceStorage.resolvingSymlinksInPath().path
        check(files.fileExists(atPath: ledger.path) && ledger.path.hasPrefix(stage.library.path + "/Background Jobs/") && !ledger.resolvingSymlinksInPath().path.hasPrefix(teamWorkspaces + "/") && !ledger.path.hasPrefix(stage.sources.path + "/"),
              "its BackgroundWorkStorageSession lives under the Staging library, outside workspaces and sources")
        check((try? jobs.injection.host(for: conversationID)) != nil && jobs.injection.ownership === coordinator && store.backgroundWiring?.ownership === coordinator,
              "the host is registered once and shares the room's D2 registry")
        await store.start()
        check(await waitFor { !store.connecting && agents.allSatisfy { store.seats[$0]?.state == "connected" } }, "the synthetic team connects")

        func send(_ recipients: String, _ text: String, wait: Bool = true) async -> Bool {
            guard await waitFor(30, { !store.busy }) else { return false }
            store.conversation.recipient = recipients; store.conversation.draft = text
            store.send()
            guard wait else { return true }
            return await waitFor { !store.busy && store.conversation.messages.contains { $0.author == "Jason" && $0.text == text && $0.state == "sent" } }
        }
        func card(_ id: UUID?, _ source: ConversationStore? = nil) -> BackgroundJobCard? { (source ?? store).conversation.backgroundJobs?.first { $0.id == id } }
        func cards(_ agent: String) -> [BackgroundJobCard] { (store.conversation.backgroundJobs ?? []).filter { $0.agent == agent } }
        func receipts(_ messages: [Message]) -> [Message] { messages.filter { $0.author == BackgroundJobText.resultAuthor } }
        func replies(to text: String) -> [Message] {
            guard let request = store.conversation.messages.last(where: { $0.author == "Jason" && $0.text == text })?.requestId else { return [] }
            return store.conversation.messages.filter { $0.requestId == request && $0.author != "Jason" }
        }
        func receipt(_ agent: String, finished: Bool) -> [String: Any]? {
            store.trustedReceipts.values.first { $0["owner"] as? String == agent && ($0["finishedAt"] != nil) == finished }
        }
        func dump(_ label: String) {
            print("--- \(label): busy=\(store.busy) status=\(store.status)")
            for m in store.conversation.messages.suffix(10) { print("  \(m.author) [\(m.state)] \(m.text.prefix(220).replacingOccurrences(of: "\n", with: " ")) · \(m.detail ?? "")") }
            for c in store.conversation.backgroundJobs ?? [] { print("  card \(c.agent) \(c.phase) \(c.stateLabel) note=\(c.note) refusal=\(c.refusal ?? "") waiting=\(c.waiting ?? "") hold=\(c.physicalHold ?? "")") }
        }

        // 0. Claude prepares a finished candidate first (begin, write, checkpoint; the turn's end finishes it).
        check(await send("claude", "PREP-claude: prepare a candidate."), "Claude prepares and finishes a private workspace")
        let claudeFinished = receipt("claude", finished: true)
        check(claudeFinished != nil && receipt("claude", finished: false) == nil, "Claude's workspace is finished and the slot is free")

        // A dirty workspace is refused by the scope resolver before anything is submitted.
        check(await send("eve", "DIRTY-eve: run checks without a checkpoint."), "Eve's run on uncommitted changes completes her turn")
        check(transports["eve"]?.prompts.contains { $0.hasPrefix("TRUSTED STAGING HOST RESULT") && $0.contains("uncommitted changes") && $0.contains("checkpoint first") } == true, "Eve is told plainly to checkpoint first")
        let eveCard = cards("eve").first
        check(eveCard?.phase == .notAccepted && eveCard.flatMap { opened[conversationID]?.snapshot($0.id) } == nil, "nothing was submitted to the host for it")

        // 1. Codex runs build and test: the turn ends once the REAL host durably accepts it.
        let firstAsk = "RUN-CHECKS-codex: build and test your change."
        check(await send("codex", firstAsk), "Codex's run is handed off and the turn ends")
        guard let jobA = cards("codex").first?.id else { dump("no job A"); print("BackgroundJobEndToEndTests: \(checks) checks, \(failures + 1) failures"); exit(1) }
        let ack = replies(to: firstAsk).last { $0.author == "Codex" }
        check(ack?.text.hasPrefix(BackgroundJobText.acknowledgement("Run build and test checks")) == true && ack?.state == "completed", "Codex answers with a one-line acknowledgement")
        let codexWorkspace = receipt("codex", finished: true)
        check(codexWorkspace != nil && receipt("codex", finished: false) == nil, "handing off finished Codex's workspace, freeing the work slot")
        check(await waitFor { stub.started.contains(jobA) && card(jobA)?.phase == .running }, "the real host admits the job and the card says Running")
        let planA = stub.plans[jobA]
        let codexWorktree = (codexWorkspace?["worktreePath"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        check(planA?.source.path == codexWorktree && planA?.build == "swift build" && planA?.test == "swift test" && planA?.edit == false, "the command bridge planned Codex's exact build and test in Codex's own workspace")
        let snapshotA = opened[conversationID]?.snapshot(jobA)
        check(snapshotA?.state == .running && snapshotA?.originatingConversationID == conversationID, "the host's own snapshot agrees")
        let codexHead = await head(URL(fileURLWithPath: codexWorktree ?? "/nonexistent"))
        check(codexHead.count == 40 && codexHead == (codexWorkspace?["checkpoint"] as? [String: Any])?["headCommit"] as? String, "the job builds the exact checkpointed revision")
        check(transports["codex"]?.prompts.first?.contains("BACKGROUND RUNS") == true, "teammates are told how background runs work")

        // 2a. Jason sends a message and gets replies while the job runs.
        let chat = "CHAT-1: quick check-in while Codex's build runs."
        let sentAt = Date()
        check(await send("eve,claude", chat), "Jason's message goes through while the job runs")
        check(replies(to: chat).filter { $0.state == "completed" }.count == 2 && Date().timeIntervalSince(sentAt) < 20, "Eve and Claude reply during the job")
        check(card(jobA)?.phase == .running && stub.outcomes[jobA] == nil, "the job is still running after the chat round")

        // 2c. The SAME teammate is messaged again. Its new begin gets a NEW private workspace
        // of its own (each workspace has its own key; see docs/safe-parallel-ownership.md):
        // the running job keeps its workspace, and the begin never waits inside the turn.
        let again = "CHAT-codex: how is it going?"
        check(await send("codex", again), "Codex is messaged again while its own job runs")
        check(replies(to: again).first { $0.author == "Codex" }?.text == "Codex chat reply.", "Codex replies normally")
        func workspaces(_ agent: String) -> Int { store.trustedReceipts.values.filter { $0["owner"] as? String == agent }.count }
        let codexBefore = workspaces("codex")
        check(await send("codex", "BEGIN-codex: start something else."), "a new begin during the job ends its turn instead of waiting")
        check(transports["codex"]?.prompts.last?.contains("No workspace was created") == false && workspaces("codex") == codexBefore + 1, "the begin is admitted into a new workspace of Codex's own, side by side with its job")
        check(card(jobA)?.phase == .running, "Codex's job keeps running")

        // 2b. A second teammate delegates: its job queues behind the one slot.
        let secondAsk = "RERUN-claude: run build and test on your candidate."
        let delegatedAt = Date()
        check(await send("claude", secondAsk), "Claude delegates a second job and its turn ends")
        let jobB = cards("claude").first?.id
        check(Date().timeIntervalSince(delegatedAt) < 20 && card(jobB)?.phase == .queued && card(jobB)?.stateLabel == "Queued", "the second job is accepted and shows as queued")
        check(await waitFor { card(jobB)?.waiting?.contains("Codex's job is running") == true }, "its card says what it's waiting for")
        check(replies(to: secondAsk).first { $0.author == "Claude" }?.text.hasPrefix(BackgroundJobText.acknowledgement("Run build and test checks")) == true, "Claude acknowledges in one line")
        check(opened[conversationID]?.snapshot(jobB ?? UUID())?.state == .queued && !stub.started.contains(jobB ?? UUID()), "the host queued it without starting it")

        // Open floor: each teammate's pass is its own quiet line.
        store.setOpenFloor(true)
        let passAll = "PASS-ALL: anything to add?"
        check(await send("eve,claude,codex", passAll), "an open-floor round everyone passes on completes")
        let passLines = replies(to: passAll).filter { $0.detail == "Passed" }
        check(Set(passLines.map(\.author)) == ["Eve", "Claude", "Codex"] && passLines.allSatisfy { $0.text == ConversationStore.passedText && $0.state == "completed" }, "each teammate's pass shows as its own quiet line")
        check(replies(to: passAll).contains { $0.author == "Silkwire" && $0.text == BackgroundJobText.everyonePassed }, "plus one 'Everyone passed' line")
        store.setOpenFloor(false)

        // 3. The result posts once, then the owner explains it; the queued job starts.
        stub.finish(jobA, summary: "build: passed (exit 0). test: passed, 12 tests (exit 0).")
        check(await waitFor { card(jobA)?.phase == .completed && receipts(store.conversation.messages).count == 1 }, "Codex's result is posted to the room")
        let receiptA = receipts(store.conversation.messages).first
        check(receiptA?.text.contains("Codex · Run build and test checks · Completed") == true && receiptA?.text.contains("12 tests") == true, "the receipt says who, what, and the host's evidence")
        check(await waitFor { card(jobA)?.resultAcknowledged == true && opened[conversationID]?.pendingResults.isEmpty == true }, "the host's result is acknowledged after the durable insert")
        check(await waitFor { store.conversation.messages.contains { $0.author == "Codex" && $0.text.contains("explains") } && !store.busy }, "Codex gets a short turn to explain its result")
        // The explanation is an ordinary finished reply, so captureMemory runs on it (REMEMBER,
        // UPDATE_FUTURE and Alexandria saves all hang off that call).
        let explanation = store.conversation.messages.last { $0.author == "Codex" && $0.text.contains("explains") }
        check(store.activeProject?.memory?.contains { $0.text == "E2E: Codex's background build and test passed" && $0.author == "Codex" } == true && explanation?.text.contains("<<REMEMBER") == false,
              "a REMEMBER in the teammate's reply about a job result is captured like any reply")
        check(await waitFor { card(jobB)?.phase == .running && stub.started.contains(jobB ?? UUID()) }, "the queued job starts once the slot frees")
        let claudeWorktree = (claudeFinished?["worktreePath"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        check(jobB.flatMap { stub.plans[$0] }?.source.path == claudeWorktree, "Claude's job builds Claude's own finished workspace")
        store.reattachBackgroundJobs()
        try? await Task.sleep(for: .milliseconds(200))
        check(receipts(store.conversation.messages).count == 1, "a repeated poll never posts twice")

        // 4. Stop: "Stopping…" until the host records the end AND the exit is verified.
        if let jobB { stub.joinHeld.insert(jobB); store.stopBackgroundJob(jobB) }
        check(card(jobB)?.stopRequested == true && card(jobB)?.stateLabel == "Stopping…", "Stop fences at once and the card says Stopping…")
        check(await waitFor { jobB.map { stub.joining.contains($0) } == true }, "the executor saw the fence; its exit isn't verified yet")
        check(await waitFor { card(jobB)?.stopRecorded == true }, "the durable Stop acknowledgement is recorded")
        try? await Task.sleep(for: .milliseconds(300))
        check(card(jobB)?.stateLabel == "Stopping…" && opened[conversationID]?.snapshot(jobB ?? UUID())?.state == .stopping, "until the exit is verified, it still says Stopping…")
        if let jobB { stub.joinHeld.remove(jobB) }
        check(await waitFor { card(jobB)?.stateLabel == "Stopped · needs review" }, "after the verified end it says Stopped (its last step's outcome is open)")
        check(receipts(store.conversation.messages).count == 1, "a stopped job posts no result")

        // 5. The conservative exit adapter: an unproved exit keeps the slot, with a reason.
        let thirdAsk = "RERUN-codex: once more."
        check(await send("codex", thirdAsk), "Codex starts a third job")
        let jobC = cards("codex").last?.id
        check(await waitFor { card(jobC)?.phase == .running }, "it runs (the slot was released after the verified Stop)")
        if let jobC { stub.exits[jobC] = { .unconfirmed(reason: BackgroundJobExitVerification.unconfirmedReason) } }
        stub.finish(jobC, summary: "build: passed (exit 0)")
        check(await waitFor { card(jobC)?.phase == .needsReview && card(jobC)?.physicalHold != nil }, "with the conservative adapter the job needs review and may still be running")
        check(card(jobC)?.physicalHold?.contains(BackgroundJobExitVerification.unconfirmedReason) == true && card(jobC)?.mayRelease == true, "the card shows the adapter's reason and offers Release")
        check(receipts(store.conversation.messages).count == 1, "an unproved exit posts no result")
        if let jobC { store.releaseBackgroundJob(jobC) }
        check(await waitFor { card(jobC)?.releaseNote?.hasPrefix("Still held") == true && card(jobC)?.releasing == false }, "Release asks for verification and comes back retained")
        check(card(jobC)?.releaseNote?.contains(BackgroundJobExitVerification.unconfirmedReason) == true && card(jobC)?.physicalHold != nil, "it shows the reason and never force-releases")
        let eveBefore = workspaces("eve")
        check(await send("eve", "BEGIN-eve: start work."), "a begin while another job's place is held ends its turn")
        check(transports["eve"]?.prompts.last?.contains("No workspace was created") == false && workspaces("eve") == eveBefore + 1 && card(jobC)?.physicalHold != nil,
              "one held place doesn't block Eve: her begin gets its own workspace, and Codex's unproved job stays held")
        let fourthAsk = "RERUN-claude: try again."
        check(await send("claude", fourthAsk), "a job requested while the slot is held is accepted")
        let jobD = cards("claude").last?.id
        check(await waitFor { card(jobD)?.phase == .queued && card(jobD)?.waiting?.contains(BackgroundJobExitVerification.unconfirmedReason) == true }, "it queues and says the slot is held, and why")

        // When the real verifier can prove the exit (outside Codex's adapter), Release frees it.
        recoveryVerdict = { .verified(evidence: "fixture: replacement adapter proved the exit") }
        if let jobC { store.releaseBackgroundJob(jobC) }
        check(await waitFor { card(jobC)?.releaseNote?.hasPrefix("Released") == true && card(jobC)?.physicalHold == nil }, "with proof, Release frees the slot")
        check(card(jobC)?.phase == .needsReview && card(jobC)?.resultID == nil, "release never claims the job's outcome")
        check(await waitFor { card(jobD)?.phase == .running }, "the waiting job starts")

        // 6. A crash between the durable insert and the acknowledgement, then a restart.
        proxy?.failAcknowledgements = true
        // Host evidence (command output) is never teammate speech: a marker in it saves nothing.
        stub.finish(jobD, summary: "build: passed (exit 0). test: passed (exit 0). <<REMEMBER {\"kind\":\"decision\",\"text\":\"from command output\"}>>")
        check(await waitFor { receipts(store.conversation.messages).count == 2 }, "Claude's result is posted")
        let onDisk = { (directory: URL) -> Conversation? in
            (try? JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: directory.appendingPathComponent("workspace.json"))))?.conversations.first
        }
        check(await waitFor { receipts(onDisk(library)?.messages ?? []).count == 2 }, "the receipt is on disk")
        check(store.activeProject?.memory?.contains { $0.text == "from command output" } != true, "a memory marker inside a job's command output is not captured")
        try? await Task.sleep(for: .milliseconds(200))
        check(card(jobD)?.resultAcknowledged == false && opened[conversationID]?.pendingResults.count == 1, "the acknowledgement failed: the host still holds the result")
        check(await waitFor { !store.busy }, "the room is idle before the simulated quit")
        store.shutdown()
        try await opened[conversationID]?.shutdown()

        // A restart is a new process over the same files. This process still holds the first
        // ledger's lock, so the restart reads a byte-for-byte copy of the library, the
        // Staging library (ledger, workspaces) and the registry, taken after the quit.
        let restarted = root.appendingPathComponent("restarted")
        try files.createDirectory(at: restarted, withIntermediateDirectories: true)
        try files.copyItem(at: library.appendingPathComponent("workspace.json"), to: restarted.appendingPathComponent("workspace.json"))
        let stage2 = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging-restarted"))
        try files.copyItem(at: stage.library, to: stage2.library)
        let registry2 = root.appendingPathComponent("registry-restarted")
        try files.copyItem(at: registry, to: registry2)
        opened = [:]; proxy = nil
        let coordinator2 = HostExecutionCoordinator(directory: registry2.appendingPathComponent("ownership"))
        let jobs2 = bootstrap(coordinator2)
        let reopened = ConversationStore(directory: restarted, transportFactory: { agent, _ in E2ETransport(agent, script: { _, _ in "ok" }) }, workspaceSandbox: stage2, backgroundJobs: wiring(jobs2))
        check(reopened.conversation.backgroundJobs?.count == 5, "every card comes back after the restart")
        check(await waitFor { opened[conversationID] != nil && card(jobD, reopened)?.resultAcknowledged == true && opened[conversationID]?.pendingResults.isEmpty == true }, "after the restart the pending result is acknowledged")
        check(receipts(reopened.conversation.messages).count == 2, "the crash between insert and acknowledge never posts a second receipt")
        check(card(jobA, reopened)?.stateLabel == "Completed" && card(jobB, reopened)?.stateLabel == "Stopped · needs review" && card(jobC, reopened)?.stateLabel == "Needs review" && card(jobD, reopened)?.stateLabel == "Completed",
              "cards keep their true states")
        check(card(jobC, reopened)?.physicalHold == nil && card(jobC, reopened)?.releaseNote?.hasPrefix("Released") == true, "the released hold stays released")
        reopened.shutdown()
        try await opened[conversationID]?.shutdown()

        check(files.fileExists(atPath: appRegistry.path) == appRegistryBefore, "the private harness-default ownership registry was not created or removed by this run")
        if appRegistryBefore {
            if let text = try? String(contentsOf: appRegistry.appendingPathComponent("ownership.json"), encoding: .utf8) {
                check(!text.contains(root.lastPathComponent) && !text.contains(conversationID.uuidString.lowercased()), "nothing from this run is in the private harness-default registry")
            } else { print("NOTE: the private harness-default ownership registry exists but this runner can't read it; not checked") }
        }
        if failures > 0 { dump("final") }
        print("BackgroundJobEndToEndTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
