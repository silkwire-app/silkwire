import Foundation
import Darwin

/// Fixture parent for the store's descriptor-relative, no-follow path checks.
/// `resolvingSymlinksInPath()` rewrites /private/var and /private/tmp to their
/// /var and /tmp symlinks, which the store correctly refuses. realpath returns
/// the true canonical directory. Prefer the harness-assigned TMPDIR fixture root.
private func canonicalFixtureTemporaryDirectory() throws -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
    guard let path = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}

private struct RunnerDocument: Codable {
    let version: Int
    let projectID: UUID
    let conversationID: UUID
    let snapshot: BackgroundWorkSnapshot
}
@MainActor private final class RunnerFixture {
    let root: URL
    let project = UUID(), room = UUID()
    let limits = BackgroundWorkLimits(totalSteps: 5, stepsPerSlice: 5)
    init(_ parent: URL) throws {
        root = parent.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var primary: URL { root.appendingPathComponent("background-work.json") }
    func scope(workspace: UUID = UUID()) -> BackgroundWorkScope {
        BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: workspace, agentID: "codex", sourceRevision: String(repeating: "a", count: 40))
    }
    func permit(_ scope: BackgroundWorkScope, _ limits: BackgroundWorkLimits? = nil) -> BackgroundWorkPermit {
        BackgroundWorkPermit(scope: scope, limits: limits ?? self.limits)
    }
    func open(fault: @escaping @Sendable (BackgroundWorkStorageBoundary) throws -> Void = { _ in }) async throws -> BackgroundWorkStorageSession {
        try await BackgroundWorkStorageSession.open(directory: root, projectID: project, conversationID: room, fault: fault)
    }
    func document() throws -> RunnerDocument {
        try JSONDecoder().decode(RunnerDocument.self, from: Data(contentsOf: primary))
    }
    func seed(_ snapshot: BackgroundWorkSnapshot) throws {
        try JSONEncoder().encode(RunnerDocument(version: 1, projectID: project, conversationID: room, snapshot: snapshot)).write(to: primary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primary.path)
    }
}
// Only this test latch is unchecked Sendable; all mutable state is locked.
private final class RunnerDiskGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let target: Int
    private let fail: Bool
    private var writes = 0
    private var held = false
    private var released = false
    private var mainThread = false
    init(write: Int, fail: Bool = false) { target = write; self.fail = fail }
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return held }
    var ranOnMainThread: Bool { condition.lock(); defer { condition.unlock() }; return mainThread }
    func hit(_ boundary: BackgroundWorkStorageBoundary) throws {
        guard boundary == .beforeFileSync else { return }
        condition.lock(); defer { condition.unlock() }
        writes += 1
        guard writes == target else { return }
        held = true; mainThread = Thread.isMainThread
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        let deadline = Date().addingTimeInterval(15)
        while !released {
            guard condition.wait(until: deadline) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
// Fails the first ledger write that follows an archive write, simulating a crash
// between the two files. Only this latch is unchecked Sendable; state is locked.
private final class ArchiveCrashGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false, archiveWritten = false, tripped = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    var didTrip: Bool { lock.lock(); defer { lock.unlock() }; return tripped }
    func hit(_ boundary: BackgroundWorkStorageBoundary) throws {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return }
        if boundary == .archiveBeforeReplace { archiveWritten = true; return }
        if boundary == .beforeFileSync, archiveWritten { armed = false; tripped = true; throw CocoaError(.fileWriteOutOfSpace) }
    }
}
private struct RunnerArchiveDocument: Codable {
    let version: Int
    let projectID: UUID
    let conversationID: UUID
    let entries: [BackgroundWorkArchiveEntry]
}
@MainActor private final class RunnerExecutionGate {
    var contexts: [BackgroundWorkContext] = []
    private var continuations: [CheckedContinuation<BackgroundWorkStep, Never>] = []
    func execute(_ context: BackgroundWorkContext) async -> BackgroundWorkStep {
        contexts.append(context)
        return await withCheckedContinuation { continuations.append($0) }
    }
    func release(_ outcome: BackgroundWorkStep = .completed(checkpoint: "late result", summary: "Synthetic result")) {
        let old = continuations; continuations.removeAll()
        for continuation in old { continuation.resume(returning: outcome) }
    }
}
@MainActor private final class RunnerAuthorizationGate {
    var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    func release(_ value: Bool) { let old = continuation; continuation = nil; old?.resume(returning: value) }
}
@MainActor private final class RunnerChatTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var received = 0
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = ProviderIdentity(id: "runner-foreground-fixture", started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws { received += 1 }
    func answer() { eventHandler?(.delta("Synthetic foreground answer")); eventHandler?(.finished(status: "completed", message: nil)) }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: "Synthetic Stop")) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport only") }
}

@main struct BackgroundWorkRunnerTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Synthetic asynchronous runner timed out") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let parent = try canonicalFixtureTemporaryDirectory().appendingPathComponent("BackgroundRunner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }

        // Automatic multi-step progress, actual disk boundaries and same-path reopen.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope()
            var storage: BackgroundWorkStorageSession? = try await fixture.open()
            var calls = 0
            var runner: BackgroundWorkRunner? = try await BackgroundWorkRunner.open(storage: storage!, authorize: { $0 == scope }, execute: { context in
                calls += 1
                let disk = try fixture.document().snapshot.items.first { $0.id == context.item.id }
                check(disk?.pendingStepID == context.stepID && disk?.attempts == calls, "step \(calls) has its exact pending identity physically saved before execution")
                check(context.mayPerformOperation(), "step \(calls) starts behind a current operation fence")
                check(context.item.sessionID != scope.conversationID, "step \(calls) uses a dedicated background session identity")
                if calls == 1 { return .checkpoint("first phase saved") }
                return .completed(checkpoint: "second phase saved", summary: "Ready for review")
            })
            check(calls == 0 && runner!.activeWorkerCount == 0, "opening the awaited runner dispatches no work")
            let id = try await runner!.enqueue(scope: scope, title: "Synthetic continuing job", limits: fixture.limits)
            let wrongPermit = try await runner!.start(id, permit: fixture.permit(fixture.scope()))
            check(!wrongPermit && calls == 0, "runtime admission must name the exact saved scope")
            check(try await runner!.start(id, permit: fixture.permit(scope)), "one host start admits the asynchronous runner")
            try await wait { runner!.activeWorkerCount == 0 && runner!.item(id)?.state == .completed }
            check(calls == 2 && runner!.item(id)?.attempts == 2, "two durable steps finish without another conversation turn or Pass")
            let resultID = runner!.item(id)!.resultID!
            check(runner!.pendingResults.first?.resultID == resultID, "only physically confirmed completion enters the result outbox")
            check(try fixture.document().snapshot.items.first?.resultID == resultID, "the outbox identity is the one on the actual disk")
            try await runner!.shutdown(); runner = nil; storage = nil
            var replayed = 0
            storage = try await fixture.open()
            runner = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in replayed += 1; return .checkpoint("must not replay") })
            check(runner!.pendingResults.first?.resultID == resultID && replayed == 0, "same-path reopen retains undelivered output without executing completed work")
            let restarted = try await runner!.start(id, permit: fixture.permit(scope))
            check(!restarted, "a completed task cannot restart")
            let wrongAck = try await runner!.acknowledgeResult(id, resultID: UUID())
            check(!wrongAck, "acknowledgement cannot name a different result")
            check(try await runner!.acknowledgeResult(id, resultID: resultID), "the exact delivered result is durably acknowledged")
            check(try await runner!.acknowledgeResult(id, resultID: resultID), "duplicate acknowledgement is idempotent")
            try await runner!.shutdown(); runner = nil; storage = nil
            storage = try await fixture.open()
            runner = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in .checkpoint("must not execute") })
            check(runner!.pendingResults.isEmpty && runner!.item(id)?.resultAcknowledged == true, "acknowledgement survives a second actual reopen")
            try await runner!.shutdown(); runner = nil; storage = nil
        }

        // Hold pending-step physical I/O. Foreground chat and immediate Stop still work.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope(), diskGate = RunnerDiskGate(write: 3)
            defer { diskGate.release() }
            let storage = try await fixture.open { try diskGate.hit($0) }
            var calls = 0
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in calls += 1; return .completed(checkpoint: "wrong", summary: "wrong") })
            let id = try await runner.enqueue(scope: scope, title: "Stop during pending save", limits: fixture.limits)
            _ = try await runner.start(id, permit: fixture.permit(scope))
            try await wait { diskGate.entered }
            check(calls == 0 && !diskGate.ranOnMainThread, "a held off-main pending checkpoint prevents executor entry")
            var events: [[String: Any]] = []
            let transport = RunnerChatTransport()
            let room = NativeRoom(emit: { events.append($0) }, factory: { _, _ in transport })
            defer { room.close() }
            await room.dispatch(["action": "connect", "conversationID": scope.conversationID.uuidString.lowercased(), "participants": ["eve"], "projectFolders": [[String: String]]()])
            try await wait { events.contains { $0["type"] as? String == "ready" } }
            let chatID = UUID().uuidString
            await room.dispatch(["action": "send", "requestId": chatID, "text": "Synthetic foreground chat", "targets": ["eve"], "history": [[String: String]](), "historyTotal": 0])
            try await wait { transport.received == 1 }
            transport.answer()
            try await wait { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == chatID } }
            check(calls == 0 && runner.activeWorkerCount == 1, "real NativeRoom foreground chat settles while background checkpoint I/O remains held")
            check(runner.requestCancel(id) && runner.stopRequested(id), "Stop establishes an in-process fence without waiting for the storage mutex")
            var stoppedDurably = false
            let stopping = Task { @MainActor in stoppedDurably = try await runner.cancel(id) }
            try await wait { runner.queuedMutationCount > 0 }
            check(!stoppedDurably, "an in-process Stop is not falsely reported as a durable checkpoint")
            var excluded = false
            do { _ = try await fixture.open() }
            catch BackgroundWorkStoreError.alreadyOpen { excluded = true }
            catch {}
            check(excluded, "held checkpoint and queued Stop retain kernel writer exclusion")
            diskGate.release(); try await stopping.value
            try await wait { runner.activeWorkerCount == 0 }
            let disk = try fixture.document().snapshot.items.first
            check(stoppedDurably && calls == 0 && disk?.state == .cancelled, "Stop persists after the held write and never enters the fenced executor")
            check(disk?.attempts == 1 && disk?.pendingStepID != nil, "Stop conservatively preserves the already-written uncertain step identity")
            try await runner.shutdown()
        }

        // The hardest race: Stop while completed output is physically being saved.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope(), diskGate = RunnerDiskGate(write: 4)
            defer { diskGate.release() }
            let storage = try await fixture.open { try diskGate.hit($0) }
            var context: BackgroundWorkContext?
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { value in
                context = value; return .completed(checkpoint: "late completed bytes", summary: "must not escape Stop")
            })
            let id = try await runner.enqueue(scope: scope, title: "Stop versus output save", limits: fixture.limits)
            _ = try await runner.start(id, permit: fixture.permit(scope))
            try await wait { diskGate.entered }
            check(runner.pendingResults.isEmpty && runner.item(id)?.state == .running, "unconfirmed completion is not published while its physical save is held")
            check(runner.requestCancel(id) && context?.mayPerformOperation() == false, "Stop immediately invalidates an executor fence during completion I/O")
            let stopping = Task { @MainActor in try await runner.cancel(id) }
            try await wait { runner.queuedMutationCount > 0 }
            diskGate.release()
            check(try await stopping.value, "accepted Stop wins over a completion checkpoint that was still in flight")
            try await wait { runner.activeWorkerCount == 0 }
            let disk = try fixture.document().snapshot.items.first
            check(runner.pendingResults.isEmpty && disk?.state == .cancelled && disk?.resultID == nil, "late completed bytes cannot resurrect stopped work or leak a result")
            try await runner.shutdown()
        }

        // Cancelling a start caller is not the same thing as cancelling a saved job.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope(), diskGate = RunnerDiskGate(write: 2)
            defer { diskGate.release() }
            let storage = try await fixture.open { try diskGate.hit($0) }
            var calls = 0
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("") })
            let id = try await runner.enqueue(scope: scope, title: "Cancelled start caller", limits: fixture.limits)
            let starting = Task { @MainActor in try await runner.start(id, permit: fixture.permit(scope)) }
            try await wait { diskGate.entered }; starting.cancel(); diskGate.release()
            let started = try await starting.value
            let disk = try fixture.document().snapshot.items.first
            check(!started && calls == 0 && runner.activeWorkerCount == 0, "cancelling a start during its save cannot launch a background executor")
            check(disk?.state == .paused && disk?.pause == .host, "cancelled start admission leaves a durable paused job, not phantom running work")
            try await runner.shutdown()
        }

        // Reentrant mutations are serialized logically; external snapshots cannot race them.
        do {
            let fixture = try RunnerFixture(parent), diskGate = RunnerDiskGate(write: 1)
            defer { diskGate.release() }
            let storage = try await fixture.open { try diskGate.hit($0) }
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in .checkpoint("") })
            let first = Task { @MainActor in try await runner.enqueue(scope: fixture.scope(), title: "First queued mutation", limits: fixture.limits) }
            try await wait { diskGate.entered }
            let second = Task { @MainActor in try await runner.enqueue(scope: fixture.scope(), title: "Second queued mutation", limits: fixture.limits) }
            try await wait { runner.queuedMutationCount == 1 }
            diskGate.release()
            let ids = [try await first.value, try await second.value]
            check(Set(runner.snapshot.items.map(\.id)) == Set(ids), "queued logical mutations retain both tasks rather than overwriting a stale snapshot")
            check(try Set(fixture.document().snapshot.items.map(\.id)) == Set(ids), "both serialized admissions are present on the disk")
            do { _ = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in .checkpoint("") }); check(false, "a storage session cannot attach a second runner") }
            catch BackgroundWorkStoreError.alreadyAttached { check(true, "a storage session cannot attach a second runner") }
            do { _ = try await storage.save(runner.snapshot, basedOn: 2); check(false, "unowned snapshot saves cannot bypass an attached runner") }
            catch BackgroundWorkStoreError.alreadyAttached { check(true, "unowned snapshot saves cannot bypass an attached runner") }
            do { _ = try await storage.saveForRunner(runner.snapshot, basedOn: 2, owner: UUID()); check(false, "a different runtime owner cannot write the runner's ledger") }
            catch BackgroundWorkStoreError.unavailable { check(true, "a different runtime owner cannot write the runner's ledger") }
            do { _ = try await runner.enqueue(scope: fixture.scope(), title: "", limits: fixture.limits); check(false, "invalid admission is rejected before physical persistence") }
            catch BackgroundWorkError.invalidInput { check(true, "invalid admission is rejected before physical persistence") }
            let state = await storage.state()
            check(!runner.storageFailed && !state.storageFailed && state.generation == 2, "rejected ownership or schema input does not poison confirmed storage")
            try await runner.shutdown()
        }

        // Stop does not wait for authorization to return, and late admission is fenced.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope(), gate = RunnerAuthorizationGate()
            let storage = try await fixture.open()
            var calls = 0
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in await gate.wait() }, execute: { _ in calls += 1; return .checkpoint("") })
            let id = try await runner.enqueue(scope: scope, title: "Stop during authorization", limits: fixture.limits)
            _ = try await runner.start(id, permit: fixture.permit(scope))
            try await wait { gate.continuation != nil }
            check(try await runner.cancel(id), "Stop reaches durable storage while authorization is suspended")
            check(runner.activeWorkerCount == 1, "a non-returned authorization worker still holds its physical slot")
            gate.release(true); try await wait { runner.activeWorkerCount == 0 }
            check(calls == 0 && runner.item(id)?.state == .cancelled, "late authorization cannot dispatch stopped work")
            try await runner.shutdown()
        }

        // A cancelled non-cooperative executor holds workspace exclusivity until return.
        do {
            let fixture = try RunnerFixture(parent), workspace = UUID(), gate = RunnerExecutionGate()
            let scope = fixture.scope(workspace: workspace), otherScope = fixture.scope()
            let storage = try await fixture.open()
            let runner = try await BackgroundWorkRunner.open(storage: storage, maxConcurrent: 2, authorize: { _ in true }, execute: { context in
                if context.item.scope.workspaceID == workspace { return await gate.execute(context) }
                return .completed(checkpoint: "other workspace", summary: "Independent result")
            })
            let first = try await runner.enqueue(scope: scope, title: "Held physical executor", limits: fixture.limits)
            let second = try await runner.enqueue(scope: scope, title: "Same workspace successor", limits: fixture.limits)
            let other = try await runner.enqueue(scope: otherScope, title: "Disjoint workspace", limits: fixture.limits)
            _ = try await runner.start(first, permit: fixture.permit(scope))
            try await wait { gate.contexts.count == 1 }
            check(try await runner.cancel(first), "Stop can commit while a non-cooperative executor remains suspended")
            check(!gate.contexts[0].mayPerformOperation() && runner.activeWorkerCount == 1, "Stop fences operations but retains the physical worker slot")
            let overlapped = try await runner.start(second, permit: fixture.permit(scope))
            check(!overlapped, "workspace exclusivity cannot be released merely by requesting Stop")
            check(try await runner.start(other, permit: fixture.permit(otherScope)), "an unrelated workspace can continue while cancelled work winds down")
            try await wait { runner.item(other)?.state == .completed }
            gate.release(); try await wait { runner.activeWorkerCount == 0 }
            check(runner.item(first)?.state == .cancelled && runner.pendingResults.allSatisfy { $0.id != first }, "late non-cooperative completion cannot replace a saved cancellation")
            check(try await runner.start(second, permit: fixture.permit(scope)), "workspace ownership becomes available only after the old executor returns")
            try await wait { gate.contexts.count == 2 }; gate.release()
            try await wait { runner.activeWorkerCount == 0 }
            check(runner.item(second)?.state == .completed, "a fresh successor does not inherit the old cancellation fence")
            try await runner.shutdown()
        }

        // Physical failures before and after synthetic execution never publish success.
        for failedWrite in [3, 4] {
            let fixture = try RunnerFixture(parent), scope = fixture.scope(), diskGate = RunnerDiskGate(write: failedWrite, fail: true)
            let storage = try await fixture.open { try diskGate.hit($0) }
            var calls = 0
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in calls += 1; return .completed(checkpoint: "not confirmed", summary: "not confirmed") })
            let id = try await runner.enqueue(scope: scope, title: "Injected physical failure", limits: fixture.limits)
            _ = try await runner.start(id, permit: fixture.permit(scope))
            try await wait { runner.storageFailed && runner.activeWorkerCount == 0 }
            check(calls == (failedWrite == 3 ? 0 : 1), "physical failure \(failedWrite) fences execution at the intended boundary")
            check(runner.pendingResults.isEmpty && runner.item(id)?.resultID == nil, "physical failure \(failedWrite) cannot publish an unconfirmed result")
            let disk = try fixture.document().snapshot.items.first
            check(disk?.state == .running && (failedWrite == 3 || disk?.pendingStepID != nil), "physical failure \(failedWrite) retains the prior durable recovery evidence")
            do { _ = try await runner.enqueue(scope: scope, title: "Must refuse", limits: fixture.limits); check(false, "physical failure \(failedWrite) prevents further admissions") }
            catch { check(true, "physical failure \(failedWrite) prevents further admissions") }
            do { try await runner.shutdown(); check(false, "shutdown reports the existing storage failure \(failedWrite)") }
            catch BackgroundWorkError.storage { check(true, "shutdown reports the existing storage failure \(failedWrite)") }
        }

        // Saturation is bounded and cannot turn an immediate Stop into a fake
        // durable acknowledgement. The host can retry once capacity is available.
        do {
            let fixture = try RunnerFixture(parent), diskGate = RunnerDiskGate(write: 2)
            defer { diskGate.release() }
            let storage = try await fixture.open { try diskGate.hit($0) }
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in .checkpoint("must not run") })
            let existing = try await runner.enqueue(scope: fixture.scope(), title: "Existing queued job", limits: fixture.limits)
            let held = Task { @MainActor in try await runner.enqueue(scope: fixture.scope(), title: "Held admission", limits: fixture.limits) }
            try await wait { diskGate.entered }
            var queued: [Task<UUID, Error>] = []
            for index in 0..<BackgroundWorkRunner.maximumQueuedMutations {
                queued.append(Task { @MainActor in try await runner.enqueue(scope: fixture.scope(), title: "Bounded queued admission \(index)", limits: fixture.limits) })
            }
            try await wait { runner.queuedMutationCount == BackgroundWorkRunner.maximumQueuedMutations }
            do { _ = try await runner.enqueue(scope: fixture.scope(), title: "Overflow", limits: fixture.limits); check(false, "host-lane saturation is an explicit busy, try-again error") }
            catch BackgroundWorkError.busy { check(true, "host-lane saturation is an explicit busy, try-again error") }
            check(!runner.storageFailed, "a full host lane is never reported as a storage failure")
            check(runner.requestCancel(existing) && runner.stopRequested(existing), "an immediate Stop fence is accepted even when the mutation queue is full")
            do { _ = try await runner.cancel(existing); check(false, "a saturated durable Stop reports busy rather than claiming success") }
            catch BackgroundWorkError.busy { check(true, "a saturated durable Stop reports busy rather than claiming success") }
            diskGate.release()
            var ids = [existing, try await held.value]
            for task in queued { ids.append(try await task.value) }
            let savedIDs = try Set(fixture.document().snapshot.items.map(\.id))
            check(savedIDs == Set(ids) && ids.count == BackgroundWorkRunner.maximumQueuedMutations + 2, "draining the bounded queue loses no accepted mutation and admits no overflow")
            check(try await runner.cancel(existing), "the host can durably retry an already-fenced Stop after queue capacity returns")
            check(runner.item(existing)?.state == .cancelled && !runner.storageFailed, "capacity handling preserves a usable ledger and the eventual terminal Stop")
            try await runner.shutdown()
        }

        // Stop persistence itself can fail. Never report it as durable, but the
        // operation fence must still prevent every late executor operation/result.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope(), diskGate = RunnerDiskGate(write: 4, fail: true), gate = RunnerExecutionGate()
            defer { gate.release() }
            let storage = try await fixture.open { try diskGate.hit($0) }
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: gate.execute)
            let id = try await runner.enqueue(scope: scope, title: "Stop storage failure", limits: fixture.limits)
            _ = try await runner.start(id, permit: fixture.permit(scope))
            try await wait { gate.contexts.count == 1 }
            do { _ = try await runner.cancel(id); check(false, "failed Stop persistence is reported to its caller") }
            catch BackgroundWorkError.storage { check(true, "failed Stop persistence is reported to its caller") }
            check(runner.storageFailed && !gate.contexts[0].mayPerformOperation(), "failed Stop persistence still invalidates every in-process operation fence")
            let disk = try fixture.document().snapshot.items.first
            check(disk?.state == .running && disk?.pendingStepID == gate.contexts[0].stepID, "failed Stop preserves the exact uncertain disk boundary rather than forging cancellation")
            gate.release(); try await wait { runner.activeWorkerCount == 0 }
            check(runner.pendingResults.isEmpty && runner.item(id)?.resultID == nil, "late completion after failed Stop cannot publish output")
            do { try await runner.shutdown(); check(false, "shutdown also reports a failed Stop ledger") }
            catch BackgroundWorkError.storage { check(true, "shutdown also reports a failed Stop ledger") }
        }

        // A thrown executor may have performed an operation. Keep its exact step
        // for independent host reconciliation, never assume the error means retry.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope()
            let storage = try await fixture.open()
            var calls = 0
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in
                calls += 1; throw nativeFailure("Synthetic uncertain executor outcome")
            })
            let id = try await runner.enqueue(scope: scope, title: "Uncertain thrown outcome", limits: fixture.limits)
            _ = try await runner.start(id, permit: fixture.permit(scope))
            try await wait { runner.activeWorkerCount == 0 }
            let item = runner.item(id)!
            check(calls == 1 && item.pause == .reconciliation && item.pendingStepID != nil && !runner.storageFailed, "a thrown executor pauses durably for exact-step reconciliation without automatic retry")
            check(try fixture.document().snapshot.items.first?.pendingStepID == item.pendingStepID, "the thrown executor's uncertain step remains on the actual disk")
            do { try await runner.reconcile(id, stepID: item.pendingStepID!, permit: fixture.permit(fixture.scope()), outcome: .checkpoint("wrong scope")); check(false, "reconciliation cannot cross a runtime scope boundary") }
            catch { check(true, "reconciliation cannot cross a runtime scope boundary") }
            try await runner.reconcile(id, stepID: item.pendingStepID!, permit: fixture.permit(scope), outcome: .completed(checkpoint: "independent fixture evidence", summary: "Host reconciled outcome"))
            check(calls == 1 && runner.pendingResults.first?.id == id && runner.item(id)?.attempts == 1, "host reconciliation can record independently verified completion without replaying the executor")
            try await runner.shutdown()
        }

        // Revalidate permission after a slow durable pending checkpoint.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope(), diskGate = RunnerDiskGate(write: 3)
            defer { diskGate.release() }
            let storage = try await fixture.open { try diskGate.hit($0) }
            var allowed = true, calls = 0
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in allowed }, execute: { _ in calls += 1; return .completed(checkpoint: "freshly admitted", summary: "Synthetic result") })
            let id = try await runner.enqueue(scope: scope, title: "Revocation during disk wait", limits: fixture.limits)
            _ = try await runner.start(id, permit: fixture.permit(scope))
            try await wait { diskGate.entered }; allowed = false; diskGate.release()
            try await wait { runner.activeWorkerCount == 0 }
            let item = runner.item(id)!
            check(calls == 0 && item.pause == .reconciliation && item.pendingStepID != nil, "revocation during a checkpoint save is rechecked before executor entry")
            do { _ = try await runner.start(id, permit: fixture.permit(scope)); check(false, "saved uncertain work cannot bypass reconciliation") }
            catch BackgroundWorkError.reconciliationRequired { check(true, "saved uncertain work cannot bypass reconciliation") }
            do { try await runner.reconcile(id, stepID: UUID(), permit: fixture.permit(scope), outcome: .checkpoint("wrong")); check(false, "reconciliation must name the exact uncertain step") }
            catch { check(true, "reconciliation must name the exact uncertain step") }
            try await runner.reconcile(id, stepID: item.pendingStepID!, permit: fixture.permit(scope), outcome: .checkpoint("fixture confirms no executor was invoked"))
            check(runner.item(id)?.pause == .host && calls == 0, "host reconciliation is durable but never automatically restarts execution")
            allowed = true
            _ = try await runner.start(id, permit: fixture.permit(scope))
            try await wait { runner.activeWorkerCount == 0 }
            check(calls == 1 && runner.item(id)?.attempts == 2, "fresh host admission after reconciliation retains consumed lifetime attempts")
            try await runner.shutdown()
        }

        // Bounded slices do not reset the lifetime budget.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope(), limits = BackgroundWorkLimits(totalSteps: 3, stepsPerSlice: 2)
            let storage = try await fixture.open()
            var calls = 0
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("phase \(calls)") })
            let id = try await runner.enqueue(scope: scope, title: "Bounded continuation", limits: limits)
            _ = try await runner.start(id, permit: fixture.permit(scope, limits))
            try await wait { runner.activeWorkerCount == 0 }
            check(calls == 2 && runner.item(id)?.pause == .sliceLimit, "a slice limit creates a durable pause after its bounded automatic steps")
            _ = try await runner.start(id, permit: fixture.permit(scope, limits))
            try await wait { runner.activeWorkerCount == 0 }
            check(calls == 3 && runner.item(id)?.pause == .stepLimit, "resuming cannot reset the saved lifetime budget")
            let exhausted = try await runner.start(id, permit: fixture.permit(scope, limits))
            let expanded = try await runner.start(id, permit: fixture.permit(scope, fixture.limits))
            check(!exhausted && !expanded && calls == 3, "exhaustion or an expanded runtime permit cannot execute another step")
            try await runner.shutdown()
        }

        // Shutdown persists a previously accepted immediate Stop, even if its
        // separate cancel() call has not reached the logical queue yet.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope(), diskGate = RunnerDiskGate(write: 4)
            defer { diskGate.release() }
            let storage = try await fixture.open { try diskGate.hit($0) }
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in .completed(checkpoint: "racing shutdown", summary: "must not escape") })
            let id = try await runner.enqueue(scope: scope, title: "Stop then shutdown", limits: fixture.limits)
            _ = try await runner.start(id, permit: fixture.permit(scope))
            try await wait { diskGate.entered }
            check(runner.requestCancel(id), "an immediate Stop is accepted before shutdown begins")
            let shuttingDown = Task { @MainActor in try await runner.shutdown() }
            try await wait { runner.closing }
            check(runner.pendingResults.isEmpty, "shutdown suppresses publication while awaiting a physical checkpoint")
            diskGate.release(); try await shuttingDown.value
            try await wait { runner.activeWorkerCount == 0 }
            let disk = try fixture.document().snapshot.items.first
            check(runner.closed && disk?.state == .cancelled && disk?.resultID == nil, "shutdown durably retains the accepted Stop instead of reviving late output")
        }

        // A saved running step opens paused with its exact uncertainty, never replayed.
        do {
            let fixture = try RunnerFixture(parent), scope = fixture.scope()
            var item = BackgroundWorkItem(id: UUID(), scope: scope, sessionID: UUID(), title: "Synthetic crash recovery", limits: fixture.limits)
            item.state = .running; item.attempts = 1; item.pendingStepID = UUID(); item.checkpoint = "last confirmed progress"
            try fixture.seed(BackgroundWorkSnapshot(version: 1, items: [item]))
            let storage = try await fixture.open()
            var calls = 0
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not replay") })
            let restored = runner.item(item.id)
            check(calls == 0 && restored?.pause == .reconciliation && restored?.pendingStepID == item.pendingStepID, "crash recovery opens paused with the exact pending step and no replay")
            check(restored?.attempts == 1 && restored?.checkpoint == item.checkpoint, "crash recovery retains attempts and confirmed progress")
            check(try fixture.document().snapshot == runner.snapshot, "the runner exposes the same recovered snapshot that was physically saved")
            try await runner.shutdown()
        }

        // Bounded ledger (review D4). Helpers shared by the cases below.
        func archive(_ fixture: RunnerFixture) throws -> RunnerArchiveDocument? {
            let url = fixture.root.appendingPathComponent("background-work.archive.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(RunnerArchiveDocument.self, from: Data(contentsOf: url))
        }
        func reopen(_ fixture: RunnerFixture, fault: @escaping @Sendable (BackgroundWorkStorageBoundary) throws -> Void = { _ in }) async throws -> BackgroundWorkStorageSession {
            // An old session keeps its writer lock until it is deallocated.
            let deadline = Date().addingTimeInterval(5)
            while true {
                do { return try await fixture.open(fault: fault) }
                catch BackgroundWorkStoreError.alreadyOpen where Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            }
        }
        let largeCheckpoint = String(repeating: "/", count: 8_000) + String(repeating: "x", count: 8_000)
        let oneStep = BackgroundWorkLimits(totalSteps: 1, stepsPerSlice: 1)

        // Capacity runs out: admission pauses with a clear reason; nothing fails closed.
        do {
            let fixture = try RunnerFixture(parent)
            let storage = try await fixture.open()
            var calls = 0
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in
                calls += 1; return .completed(checkpoint: largeCheckpoint, summary: "Large unacknowledged result")
            })
            var completed: [UUID] = [], refused: UUID?, refusal: Error?
            for _ in 0..<120 {
                let scope = fixture.scope()
                let id = try await runner.enqueue(scope: scope, title: "Large result held for delivery", limits: oneStep)
                do { _ = try await runner.start(id, permit: fixture.permit(scope, oneStep)) }
                catch { refused = id; refusal = error; break }
                try await wait { runner.activeWorkerCount == 0 }
                if runner.item(id)?.state == .completed { completed.append(id) } else { break }
            }
            check((refusal as? BackgroundWorkError) == .ledgerFull && runner.admissionHold == .ledgerFull,
                  "a full ledger refuses admission with ledgerFull and a visible hold (after \(completed.count) undelivered results)")
            check(!runner.storageFailed && runner.pendingResults.count == completed.count, "a full ledger never fails closed and keeps every undelivered result")
            let held = refused.flatMap { runner.item($0) }
            check(held?.state == .queued && held?.attempts == 0 && calls == completed.count, "the refused job is left exactly as queued and never executed")
            for id in completed { _ = try await runner.acknowledgeResult(id, resultID: runner.item(id)!.resultID!) }
            let restarted = try await runner.start(refused!, permit: fixture.permit(fixture.scope(), oneStep)) // wrong scope: must refuse
            check(!restarted, "a stale permit still cannot start the held job")
            let scope = held!.scope
            check(try await runner.start(refused!, permit: fixture.permit(scope, oneStep)), "after results are acknowledged, admission makes room and starts the held job")
            try await wait { runner.activeWorkerCount == 0 }
            check(runner.admissionHold == nil && runner.item(refused!)?.state == .completed, "the hold clears once an admission fits")
            let saved = try archive(fixture)
            check(saved != nil && runner.archivedItems.count == completed.count && saved?.entries.count == completed.count, "acknowledged results moved to the archive file to make room")
            check(runner.archivedItems.allSatisfy { $0.state == .completed && $0.resultAcknowledged }, "only acknowledged results were archived")
            let first = completed[0]
            let firstInLedger = try fixture.document().snapshot.items.contains { $0.id == first }
            check(runner.item(first)?.state == .completed && !firstInLedger, "an archived item is still visible to the host but no longer in the ledger")
            check(try await runner.acknowledgeResult(first, resultID: runner.item(first)!.resultID!), "acknowledging an archived result again is idempotent")
            check(!(try await runner.start(first, permit: fixture.permit(runner.item(first)!.scope, oneStep))), "archived history can never be started")
            let size = (try FileManager.default.attributesOfItem(atPath: fixture.primary.path)[.size] as? Int) ?? Int.max
            check(size <= BackgroundWorkRunner.ledgerBudgetBytes, "the ledger document stayed within its bound (\(size) bytes)")
            try await runner.shutdown()
        }

        // Archive retention is bounded, and archived work never replays after reopening.
        do {
            let fixture = try RunnerFixture(parent)
            var storage: BackgroundWorkStorageSession? = try await fixture.open()
            var calls = 0
            var runner: BackgroundWorkRunner? = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not run") })
            var order: [UUID] = [], neverHeld = true
            let total = BackgroundWorkStorageSession.maximumArchivedItems + 44
            for index in 0..<total {
                let id = try await runner!.enqueue(scope: fixture.scope(), title: "Cancelled history \(index)", limits: fixture.limits)
                if runner!.admissionHold != nil { neverHeld = false }
                _ = try await runner!.cancel(id); order.append(id)
            }
            check(neverHeld && runner!.snapshot.items.count < total, "the \(BackgroundWorkRunner.maximumLedgerItems)-item limit is relieved by archiving cancelled items, not by refusing work")
            let moved = try await runner!.archiveSettledItems()
            let saved = try archive(fixture)
            check(moved > 0 && runner!.snapshot.items.isEmpty, "explicit archiving empties the ledger of settled items")
            check(saved?.entries.count == BackgroundWorkStorageSession.maximumArchivedItems && runner!.archivedItems.count == BackgroundWorkStorageSession.maximumArchivedItems,
                  "archive retention is bounded to \(BackgroundWorkStorageSession.maximumArchivedItems) entries")
            let kept = Set(saved?.entries.map(\.item.id) ?? [])
            // The 257th admission archived the first 256 cancellations in one pass; the
            // explicit pass archived the last 44. Retention drops from the oldest pass.
            let firstPass = Set(order.prefix(BackgroundWorkRunner.maximumLedgerItems)), lastPass = Set(order.dropFirst(BackgroundWorkRunner.maximumLedgerItems))
            check(lastPass.isSubset(of: kept) && firstPass.subtracting(kept).count == lastPass.count, "retention drops entries from the oldest archive pass first")
            check(zip(saved?.entries ?? [], (saved?.entries ?? []).dropFirst()).allSatisfy { $0.sequence < $1.sequence }, "archive entries keep a strictly increasing retention order")
            try await runner!.shutdown(); runner = nil; storage = nil
            storage = try await reopen(fixture)
            runner = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not run") })
            check(runner!.snapshot.items.isEmpty && runner!.archivedItems.count == BackgroundWorkStorageSession.maximumArchivedItems, "reopening restores the archive as history, not as ledger work")
            let newest = order.last!
            check(!(try await runner!.start(newest, permit: fixture.permit(runner!.item(newest)!.scope))) && calls == 0, "reopened archive entries can never be started or replayed")
            try await runner!.shutdown()
        }

        // A crash between the archive and ledger writes cannot revive or duplicate work.
        do {
            let fixture = try RunnerFixture(parent), gate = ArchiveCrashGate()
            var storage: BackgroundWorkStorageSession? = try await fixture.open { try gate.hit($0) }
            var calls = 0
            var runner: BackgroundWorkRunner? = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not run") })
            let scope = fixture.scope()
            let id = try await runner!.enqueue(scope: scope, title: "Cancelled before crash", limits: fixture.limits)
            _ = try await runner!.cancel(id)
            gate.arm()
            do { _ = try await runner!.archiveSettledItems(); check(false, "a failed ledger write after archiving reports storage failure") }
            catch BackgroundWorkError.storage { check(gate.didTrip && runner!.storageFailed, "a failed ledger write after archiving reports storage failure") }
            let archivedIDs = try archive(fixture)?.entries.map(\.item.id), ledgerIDs = try fixture.document().snapshot.items.map(\.id)
            check(archivedIDs == [id] && ledgerIDs == [id], "the crash leaves the settled item in both files")
            runner = nil; storage = nil
            storage = try await reopen(fixture)
            runner = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not run") })
            check(runner!.item(id)?.state == .cancelled && runner!.archivedItems.isEmpty, "on reopen the ledger copy is authoritative and the duplicate is not double-listed")
            check(!(try await runner!.start(id, permit: fixture.permit(scope))) && calls == 0, "the duplicated settled item can never run")
            let movedAgain = try await runner!.archiveSettledItems(), finalIDs = try archive(fixture)?.entries.map(\.item.id)
            check(movedAgain == 1 && finalIDs == [id] && runner!.snapshot.items.isEmpty, "the next archive pass completes the move without duplicating the entry")
            try await runner!.shutdown()
        }

        // An outcome larger than the per-item reservation is refused like any
        // invalid outcome: that step needs reconciliation, the runner stays healthy.
        do {
            let fixture = try RunnerFixture(parent)
            let storage = try await fixture.open()
            var oversized = true
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in
                // Control characters encode as \u0001: six bytes each.
                oversized ? .completed(checkpoint: String(repeating: "\u{1}", count: 16_000), summary: "") : .completed(checkpoint: "small", summary: "ok")
            })
            let scope = fixture.scope()
            let id = try await runner.enqueue(scope: scope, title: "Oversized outcome", limits: oneStep)
            _ = try await runner.start(id, permit: fixture.permit(scope, oneStep))
            try await wait { runner.activeWorkerCount == 0 }
            let item = runner.item(id)
            check(item?.state == .paused && item?.pause == .reconciliation && item?.pendingStepID != nil && !runner.storageFailed,
                  "an outcome over the per-item bound pauses that step for reconciliation without failing closed")
            oversized = false
            let next = fixture.scope()
            let other = try await runner.enqueue(scope: next, title: "Normal outcome", limits: oneStep)
            _ = try await runner.start(other, permit: fixture.permit(next, oneStep))
            try await wait { runner.activeWorkerCount == 0 }
            check(runner.item(other)?.state == .completed, "other work continues normally afterwards")
            try await runner.shutdown()
        }

        // A job stopped mid-step keeps its uncertain step in the ledger until the
        // host records broker evidence; only then may it move to the archive.
        do {
            let fixture = try RunnerFixture(parent), gate = RunnerExecutionGate()
            let storage = try await fixture.open()
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { await gate.execute($0) })
            let scope = fixture.scope()
            let id = try await runner.enqueue(scope: scope, title: "Stopped mid-step", limits: oneStep)
            _ = try await runner.start(id, permit: fixture.permit(scope, oneStep))
            try await wait { gate.contexts.count == 1 }
            let step = gate.contexts[0].stepID
            _ = try await runner.cancel(id)
            var early = false
            do { try await runner.reconcileStopped(id, stepID: step, scope: scope, evidence: .notPerformed(note: "too early")) }
            catch BackgroundWorkError.unavailable { early = true }
            check(early && runner.unresolvedItems.isEmpty, "a stopped step cannot be reconciled while its physical worker is still running")
            gate.release()
            try await wait { runner.activeWorkerCount == 0 }
            check(runner.unresolvedItems.map(\.id) == [id], "the stopped job is listed as unresolved evidence")
            check(try await runner.archiveSettledItems() == 0 && runner.archivedItems.isEmpty, "an unresolved stopped step is never archived")
            var refusals = 0
            for (stepID, otherScope) in [(UUID(), scope), (step, fixture.scope())] {
                do { try await runner.reconcileStopped(id, stepID: stepID, scope: otherScope, evidence: .notPerformed(note: "wrong")) }
                catch BackgroundWorkError.unavailable { refusals += 1 }
            }
            check(refusals == 2, "stopped-step reconciliation must name the exact step and scope")
            var oversized = false
            do { try await runner.reconcileStopped(id, stepID: step, scope: scope, evidence: .performed(checkpoint: String(repeating: "x", count: 20_000), note: "")) }
            catch BackgroundWorkError.invalidInput { oversized = true }
            check(oversized && runner.item(id)?.pendingStepID == step, "invalid evidence changes nothing")
            try await runner.reconcileStopped(id, stepID: step, scope: scope, evidence: .performed(checkpoint: "broker shows one file written", note: "Host verified the step's effect."))
            let item = runner.item(id), disk = try fixture.document().snapshot.items.first { $0.id == id }
            check(item?.state == .cancelled && item?.pendingStepID == nil && item?.resultID == nil && item?.checkpoint == "broker shows one file written" && item?.attempts == 1,
                  "recorded evidence resolves the step while the job stays cancelled with no result")
            check(disk == item && runner.pendingResults.isEmpty && runner.unresolvedItems.isEmpty, "the resolution is physically saved and publishes nothing")
            check(!(try await runner.start(id, permit: fixture.permit(scope, oneStep))) && gate.contexts.count == 1, "a reconciled stopped job never restarts")
            var again = false
            do { try await runner.reconcileStopped(id, stepID: step, scope: scope, evidence: .notPerformed(note: "twice")) }
            catch BackgroundWorkError.unavailable { again = true }
            check(again, "a resolved step cannot be reconciled twice")
            check(try await runner.archiveSettledItems() == 1 && runner.archivedItems.map(\.id) == [id], "once resolved, the stopped job moves to the archive")
            // Broker evidence that the stopped step never ran is recorded the same way.
            let paused = fixture.scope()
            let pausedID = try await runner.enqueue(scope: paused, title: "Stopped before any operation", limits: oneStep)
            _ = try await runner.start(pausedID, permit: fixture.permit(paused, oneStep))
            try await wait { gate.contexts.count == 2 }
            _ = runner.requestCancel(pausedID)
            gate.release()
            try await wait { runner.activeWorkerCount == 0 }
            _ = try await runner.cancel(pausedID)
            try await runner.reconcileStopped(pausedID, stepID: gate.contexts[1].stepID, scope: paused, evidence: .notPerformed(note: "Broker shows no operation."))
            check(runner.item(pausedID)?.pendingStepID == nil && runner.item(pausedID)?.note == "Broker shows no operation.", "evidence that a step never ran is recorded the same way")
            try await runner.shutdown()
        }

        // Unresolved evidence that blocks reclamation holds admissions with a clear
        // reason and is never discarded to make room.
        do {
            let fixture = try RunnerFixture(parent)
            var items: [BackgroundWorkItem] = []
            for index in 0..<BackgroundWorkRunner.maximumLedgerItems {
                var item = BackgroundWorkItem(id: UUID(), scope: fixture.scope(), sessionID: UUID(), title: "Stopped \(index)", limits: oneStep)
                item.state = .cancelled; item.attempts = 1; item.pendingStepID = UUID()
                items.append(item)
            }
            try fixture.seed(BackgroundWorkSnapshot(version: 1, items: items))
            let storage = try await fixture.open()
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in .checkpoint("must not run") })
            let before = try Data(contentsOf: fixture.primary)
            var refusal: Error?
            do { _ = try await runner.enqueue(scope: fixture.scope(), title: "Needs room", limits: oneStep) } catch { refusal = error }
            check((refusal as? BackgroundWorkError) == .ledgerFull && runner.admissionHold == .unresolvedEvidence,
                  "admission is refused with an unresolved-evidence hold when only stopped steps block reclamation")
            check(try Data(contentsOf: fixture.primary) == before && runner.unresolvedItems.count == items.count && !runner.storageFailed,
                  "the refusal discards nothing and changes nothing on disk")
            let first = items[0]
            try await runner.reconcileStopped(first.id, stepID: first.pendingStepID!, scope: first.scope, evidence: .notPerformed(note: "Broker shows no operation."))
            let admitted = try await runner.enqueue(scope: fixture.scope(), title: "Fits after reconciliation", limits: oneStep)
            check(runner.admissionHold == nil && runner.item(admitted)?.state == .queued, "reconciling one stopped step frees room and clears the hold")
            check(runner.archivedItems.map(\.id) == [first.id] && runner.unresolvedItems.count == items.count - 1,
                  "only the reconciled item was archived; the other uncertain steps stay in the ledger")
            try await runner.shutdown()
        }

        // An archive written by 9cea7e0 may hold a stopped job's uncertain step.
        // Opening moves it back to the ledger (ledger first) instead of trimming it.
        do {
            func archived(_ fixture: RunnerFixture, _ entries: [BackgroundWorkArchiveEntry]) throws {
                let url = fixture.root.appendingPathComponent("background-work.archive.json")
                try JSONEncoder().encode(RunnerArchiveDocument(version: 1, projectID: fixture.project, conversationID: fixture.room, entries: entries)).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            func stopped(_ fixture: RunnerFixture) -> BackgroundWorkItem {
                var item = BackgroundWorkItem(id: UUID(), scope: fixture.scope(), sessionID: UUID(), title: "Archived by 9cea7e0", limits: oneStep)
                item.state = .cancelled; item.attempts = 1; item.pendingStepID = UUID(); return item
            }
            func history(_ fixture: RunnerFixture) -> BackgroundWorkItem {
                var item = BackgroundWorkItem(id: UUID(), scope: fixture.scope(), sessionID: UUID(), title: "Resolved history", limits: oneStep)
                item.state = .cancelled; return item
            }
            // Only in the archive: moved back into the ledger.
            let fixture = try RunnerFixture(parent), evidence = stopped(fixture), resolved = history(fixture)
            try fixture.seed(BackgroundWorkSnapshot(version: 1, items: []))
            try archived(fixture, [BackgroundWorkArchiveEntry(sequence: 1, item: evidence), BackgroundWorkArchiveEntry(sequence: 2, item: resolved)])
            var storage: BackgroundWorkStorageSession? = try await fixture.open()
            var runner: BackgroundWorkRunner? = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in .checkpoint("must not run") })
            check(try fixture.document().snapshot.items == [evidence] && archive(fixture)?.entries.map(\.item.id) == [resolved.id],
                  "an archived uncertain step is moved back into the ledger on open")
            check(runner!.unresolvedItems.map(\.id) == [evidence.id] && runner!.archivedItems.map(\.id) == [resolved.id], "the runner lists it as unresolved evidence again")
            try await runner!.shutdown(); runner = nil; storage = nil
            // In both files (a crash between the two writes): the archive copy is dropped.
            let both = try RunnerFixture(parent), copy = stopped(both)
            try both.seed(BackgroundWorkSnapshot(version: 1, items: [copy]))
            try archived(both, [BackgroundWorkArchiveEntry(sequence: 1, item: copy)])
            storage = try await both.open()
            check(try both.document().snapshot.items == [copy] && archive(both)?.entries.isEmpty == true, "a duplicate left by a crash is finished without losing the ledger copy")
            storage = nil
            // No room in the ledger: refuse, change nothing.
            let full = try RunnerFixture(parent), stranded = stopped(full)
            try full.seed(BackgroundWorkSnapshot(version: 1, items: (0..<BackgroundWorkRunner.maximumLedgerItems).map { _ in history(full) }))
            try archived(full, [BackgroundWorkArchiveEntry(sequence: 1, item: stranded)])
            let ledgerBytes = try Data(contentsOf: full.primary), archiveBytes = try Data(contentsOf: full.root.appendingPathComponent("background-work.archive.json"))
            var refused = false
            do { _ = try await full.open() } catch BackgroundWorkStoreError.unresolvedEvidence { refused = true }
            let unchanged = try Data(contentsOf: full.primary) == ledgerBytes && Data(contentsOf: full.root.appendingPathComponent("background-work.archive.json")) == archiveBytes
            check(refused && unchanged,
                  "if the evidence does not fit back in the ledger, open refuses with unresolvedEvidence and changes nothing")
        }

        print("BackgroundWorkRunnerTests: \(passed) passed, \(failed) failed; synthetic executors, transports and isolated files only")
        if failed > 0 { throw nativeFailure("Asynchronous background runner regressions failed") }
    }
}
