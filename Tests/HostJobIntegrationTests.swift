import Foundation
import Darwin

@MainActor private final class HostGate {
    var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; let old = waiter; waiter = nil; old?.resume() }
}
@MainActor private final class HostFixture {
    let root: URL, source: URL, registry: URL
    let coordinator: HostExecutionCoordinator
    init() throws {
        guard let path = realpath("/private/tmp", nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(path) }
        root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("Silkwire-Host-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); registry = root.appendingPathComponent("registry")
        for url in [root, source, registry] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        coordinator = HostExecutionCoordinator(directory: registry)
    }
    func scope(room: UUID = UUID(), workspace: UUID = UUID()) -> BackgroundWorkScope {
        .init(projectID: UUID(), conversationID: room, workspaceID: workspace, agentID: "codex", sourceRevision: String(repeating: "a", count: 40))
    }
    func storage(_ scope: BackgroundWorkScope) async throws -> BackgroundWorkStorageSession {
        let directory = root.appendingPathComponent(scope.conversationID.uuidString)
        if !FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        return try await BackgroundWorkStorageSession.open(directory: directory, projectID: scope.projectID, conversationID: scope.conversationID)
    }
    func request(_ scope: BackgroundWorkScope, id: UUID = UUID()) -> HostJobRequest {
        .init(operationID: id, scope: scope, workDescription: "Synthetic host work", limits: .init(totalSteps: 2, stepsPerSlice: 2))
    }
    func binding(source: URL? = nil, cancel: @escaping (UUID) -> Void = { _ in }, join: @escaping HostBackgroundExecution.Join) -> HostBackgroundExecution {
        let source = source ?? self.source
        return HostBackgroundExecution(coordinator: coordinator, resolve: { _ in .init(executionRoot: source, conflictRoot: self.source) }, cancel: cancel, join: join)
    }
}

/// Synchronous kernel registration watches this exact controlled fixture process.
/// This is whole-executor evidence only because fixture code creates no descendants
/// or remote requests; PID disappearance alone is never used as verification.
@MainActor private final class HostFixtureExitWitness {
    private let queue: Int32
    private(set) var exited = false
    init(pid: pid_t) throws {
        queue = kqueue()
        guard queue >= 0 else { throw CocoaError(.fileReadUnknown) }
        var registration = kevent64_s()
        registration.ident = UInt64(pid); registration.filter = Int16(EVFILT_PROC)
        registration.flags = UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT); registration.fflags = UInt32(NOTE_EXIT)
        guard Darwin.kevent64(queue, &registration, 1, nil, 0, 0, nil) == 0 else { Darwin.close(queue); throw CocoaError(.fileReadUnknown) }
    }
    func pollExit() -> Bool {
        if exited { return true }
        var event = kevent64_s(), timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let count = Darwin.kevent64(queue, nil, 0, &event, 1, 0, &timeout)
        if count == 1 && event.fflags & UInt32(NOTE_EXIT) != 0 { exited = true }
        return exited
    }
    deinit { Darwin.close(queue) }
}

@main struct HostJobIntegrationTests {
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count > 1 { try await helper(); return }
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1; print("PASS: " + label) } else { failed += 1; print("FAIL: " + label) }
        }
        // Real durable runner + synthetic blocked executor + synthetic whole-executor join.
        do {
            let f = try HostFixture(), a = f.scope(), b = f.scope()
            let operation = HostGate(), child = HostGate()
            var callback: (() -> Bool)?, aReturned = false, bCalls = 0
            let first = try await HostBackgroundJobService.open(storage: f.storage(a), execution: f.binding(join: { _ in
                await child.wait(); return .verified(evidence: "fixture: executor and surviving child explicitly joined")
            }), authorize: { $0 == a }, execute: { context in
                callback = context.mayPerformOperation
                await operation.wait(); aReturned = true
                return .completed(checkpoint: "late completion", summary: "must not deliver after Stop")
            })
            let ar = f.request(a)
            let aid = try await first.submit(ar)
            check(aid == ar.operationID && !aReturned, "submit returns a stable job ID without waiting for blocked execution")
            try await wait { operation.entered }
            let before = first.snapshot(aid)!
            check(before.state == .running && before.pendingOperationID != nil, "running is separate from acceptance; pending identity is durable before dispatch")
            var chatAnswered = false
            await Task { @MainActor in chatAnswered = true }.value
            check(chatAnswered && !aReturned, "independent synthetic chat/control callback completes during execution (not an app/UI demo)")
            let observer = Task { for await _ in first.events() { if Task.isCancelled { break } } }
            observer.cancel(); await Task.yield()
            check(callback?() == true, "closing an observer leaves executor ownership and operation authority intact")
            let alias = f.root.appendingPathComponent("private-worktree")
            try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try await f.coordinator.storage.alias(alias, source: f.source)
            let second = try await HostBackgroundJobService.open(storage: f.storage(b), execution: f.binding(source: alias, join: { _ in .verified(evidence: "fixture: second synchronous executor joined") }), authorize: { $0 == b }, execute: { _ in
                bCalls += 1; return .completed(checkpoint: "separate progress", summary: "Synthetic terminal result")
            })
            let bid = try await second.submit(f.request(b))
            try await wait { second.snapshot(bid)?.pendingOperationID != nil }
            check(bCalls == 0 && second.snapshot(bid)?.state == .queued, "two conversations and private-worktree aliases cannot exceed the shared slot")
            let ack = try await first.stop(aid)
            check(ack.stopRequested && callback?() == false && !aReturned, "Stop ACK immediately fences callbacks while physical work remains blocked")
            let repeatedStop = try await first.stop(aid)
            check(repeatedStop.stopRequested && !aReturned, "repeated Stop is idempotent and does not await physical exit")
            let records = try await f.coordinator.storage.snapshot()
            check(records.filter(\.holdsResources).count == 1 && records.first?.stopRequested == true, "Stop acknowledgement retains the physical slot")
            operation.release(); try await wait { child.entered }
            check(aReturned && bCalls == 0, "logical completion and a surviving child do not release ownership")
            child.release()
            try await wait { second.snapshot(bid)?.state == .completed }
            let terminal = second.snapshot(bid)!
            check(first.snapshot(aid)?.state == .needsReview && first.pendingResults.isEmpty, "delayed completion after Stop cannot publish or revive a result")
            check(terminal.progress == "separate progress" && terminal.completionID == terminal.resultID && terminal.resultID != nil, "progress and durable terminal identity use the existing result seam")
            check(terminal.revision > 1 && second.snapshot(bid) == terminal, "job snapshots have stable identities and monotonic persisted revisions")
            let duplicate = try await second.submit(f.request(b, id: bid))
            check(duplicate == bid && bCalls == 1, "duplicate stable operation ID returns its accepted job without replay")
            let acknowledged = try await second.acknowledgeResult(bid, resultID: terminal.resultID!)
            check(acknowledged && second.pendingResults.isEmpty && second.snapshot(bid)!.revision > terminal.revision, "room/result adapter can acknowledge the exact durable result identity")
            try await first.shutdown(); try await second.shutdown()
        }
        // UI/host teardown while a physical callback remains alive.
        do {
            let f = try HostFixture(), s = f.scope(), gate = HostGate(), joined = HostGate()
            let service = try await HostBackgroundJobService.open(storage: f.storage(s), execution: f.binding(join: { _ in
                await joined.wait(); return .verified(evidence: "fixture: teardown executor and child both joined")
            }), authorize: { _ in true }, execute: { _ in await gate.wait(); return .checkpoint("late") })
            let id = try await service.submit(f.request(s)); try await wait { gate.entered }
            try await service.shutdown()
            gate.release(); try await wait { joined.entered }
            check(try await f.coordinator.storage.snapshot().filter(\.holdsResources).count == 1, "shutdown and late executor callbacks retain ownership until physical join")
            joined.release()
            let deadline = Date().addingTimeInterval(10)
            while try await f.coordinator.storage.snapshot().contains(where: \.holdsResources) {
                guard Date() < deadline else { throw CocoaError(.userCancelled) }; try await Task.sleep(for: .milliseconds(5))
            }
            check(service.snapshot(id)?.resultID == nil, "teardown never delivers a stale result")
        }
        // Unknown physical exit + reopen of actual storage: no automatic scheduling.
        do {
            let f = try HostFixture(), s = f.scope(), request = f.request(s)
            var calls = 0
            var service: HostBackgroundJobService? = try await HostBackgroundJobService.open(storage: f.storage(s), execution: f.binding(join: { _ in .unconfirmed(reason: "fixture: independent whole-executor evidence unavailable") }), authorize: { _ in true }, execute: { _ in calls += 1; return .completed(checkpoint: "unconfirmed", summary: "not a result") })
            _ = try await service!.submit(request)
            try await wait { service?.snapshot(request.operationID)?.state == .needsReview }
            let revision = service!.snapshot(request.operationID)!.revision
            try await service!.shutdown(); await service!.joinLocalExecutors(); service = nil
            await Task.yield()
            let reopenedCoordinator = HostExecutionCoordinator(directory: f.registry)
            check(try await reopenedCoordinator.storage.snapshot().contains { $0.phase == .uncertain && $0.holdsResources }, "fresh host preserves uncertain physical operations without PID/timeout reclamation")
            let reopened = try await HostBackgroundJobService.open(storage: f.storage(s), execution: f.binding(join: { _ in .verified(evidence: "must not be used") }), authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not replay") })
            check(reopened.snapshot(request.operationID)?.state == .needsReview && reopened.snapshot(request.operationID)!.revision >= revision && calls == 1, "reopen retains uncertain pending work and does not replay it")
            try await reopened.shutdown()
        }
        // Foreground admission uses the same coordinator, nested steps inherit it.
        do {
            let f = try HostFixture()
            let parent = try await f.coordinator.admit(operationID: UUID(), conversationID: UUID(), kind: .backgroundJob, authorize: { .init(executionRoot: f.source, conflictRoot: f.source) }, mayOperate: { true })
            let nested = HostBuilderOwnership(coordinator: f.coordinator, conversationID: UUID(), authorize: nil, verifyExit: { _ in .verified(evidence: "fixture: sequential child joined") })
            try await HostExecutionScope.$admission.withValue(parent) {
                try await nested.begin(operationID: UUID(), source: f.source, mayOperate: { true })
                check(try await f.coordinator.storage.snapshot().filter(\.holdsResources).count == 1, "nested sequential Builder inherits the admitted executor instead of recursively acquiring the only slot")
                try await nested.finish(workspaceID: UUID())
            }
            try await f.coordinator.finish(parent, exit: .verified(evidence: "fixture: parent joined after sequential child"))
            let foreground = HostBuilderOwnership(coordinator: f.coordinator, conversationID: UUID(), authorize: nil, verifyExit: { _ in .unconfirmed(reason: "fixture: foreground descendant evidence unavailable") })
            try await foreground.begin(operationID: UUID(), source: f.source, mayOperate: { true })
            do { try await foreground.finish(workspaceID: UUID()); check(false, "unconfirmed foreground exit must not release") } catch { check(true, "unconfirmed foreground exit is reported for review") }
            check(try await f.coordinator.storage.snapshot().filter(\.holdsResources).count == 1, "foreground uses the same durable registry and retains uncertain work")
        }
        // Queue admission is bounded even while the physical executor is blocked.
        do {
            let f = try HostFixture(), scope = f.scope(), gate = HostGate()
            let service = try await HostBackgroundJobService.open(storage: f.storage(scope), execution: f.binding(join: { _ in .verified(evidence: "fixture: bounded-queue executor explicitly joined") }), authorize: { _ in true }, execute: { _ in await gate.wait(); return .checkpoint("stopped") })
            let first = try await service.submit(f.request(scope)); try await wait { gate.entered }
            for _ in 1..<HostBackgroundJobService.maximumQueuedJobs { _ = try await service.submit(f.request(scope)) }
            do { _ = try await service.submit(f.request(scope)); check(false, "queue overflow must refuse") }
            catch { check(true, "bounded queue explicitly refuses excess work while an executor remains blocked") }
            _ = try await service.stop(first); gate.release(); try await service.shutdown()
        }
        // A storage error cannot accept work or dispatch effects. The durable
        // submit identity remains a retry fence even if enqueue never commits.
        do {
            let f = try HostFixture(), scope = f.scope()
            let directory = f.root.appendingPathComponent("fault-ledger")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let storage = try await BackgroundWorkStorageSession.open(directory: directory, projectID: scope.projectID, conversationID: scope.conversationID, fault: { boundary in
                if boundary == .beforeFileSync { throw CocoaError(.fileWriteOutOfSpace) }
            })
            var calls = 0
            let service = try await HostBackgroundJobService.open(storage: storage, execution: f.binding(join: { _ in .verified(evidence: "must not execute") }), authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not execute") })
            do { _ = try await service.submit(f.request(scope)); check(false, "failed acceptance must throw") }
            catch { check(calls == 0, "failed durable acceptance explicitly refuses and never dispatches physical work") }
        }
        // An idempotent Stop must keep surfacing failed registry durability.
        do {
            let f = try HostFixture(), scope = f.scope(), gate = HostGate()
            let host = try await HostBackgroundJobService.open(storage: f.storage(scope), execution: f.binding(join: { _ in .verified(evidence: "fixture: blocked executor explicitly joined after Stop durability failure") }),
                verifyRecovery: { _ in .verified(evidence: "fixture: controlled executor and local callbacks explicitly joined; no descendants or remote work") },
                authorize: { _ in true }, execute: { _ in await gate.wait(); return .checkpoint("stopped") })
            let id = try await host.submit(f.request(scope)); try await wait { gate.entered }
            let ledger = f.registry.appendingPathComponent("ownership.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ledger.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path) }
            for attempt in 1...2 {
                do { _ = try await host.stop(id); check(false, "Stop with failed ownership persistence must throw") }
                catch { check(true, "Stop attempt \(attempt) surfaces failed ownership durability while preserving the fence") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
            gate.release(); await host.joinLocalExecutors()
            let pending = host.snapshot(id)!.pendingOperationID!
            let ticket = try await host.checkPhysicalExit(operationID: pending)
            let release = try await host.reconcilePhysicalExit(ticket)
            if case .released = release { check(host.snapshot(id)?.pendingOperationID == pending && host.snapshot(id)?.state == .needsReview, "independent physical review can recover a failed Stop write after joins without clearing the unresolved outcome") }
            else { check(false, "completed local joins must allow independently verified recovery") }
            try await host.shutdown()
        }
        // Actual host-service owner crash with an independently watched surviving child.
        do {
            let f = try HostFixture(), scope = f.scope(), request = f.request(scope)
            let ledger = f.root.appendingPathComponent(scope.conversationID.uuidString)
            try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let requestFile = f.root.appendingPathComponent("crash-request.json")
            try JSONEncoder().encode(request).write(to: requestFile)
            let owner = Process(); owner.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            owner.arguments = ["--crashing-host-owner", f.registry.path, f.source.path, f.root.path, requestFile.path]
            try owner.run()
            defer { if owner.isRunning { kill(owner.processIdentifier, SIGKILL) } }
            try await wait { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("owner-ready").path) }
            let pid = Int32(try String(contentsOf: f.root.appendingPathComponent("worker.pid"), encoding: .utf8))!
            let witness = try HostFixtureExitWitness(pid: pid)
            defer { if !witness.pollExit() { kill(pid, SIGKILL) } }
            kill(owner.processIdentifier, SIGKILL)
            try await wait { !owner.isRunning }
            check(owner.terminationReason == .uncaughtSignal && owner.terminationStatus == SIGKILL && !witness.pollExit(), "real host owner crashed while its registered physical child survived")
            let coordinator = HostExecutionCoordinator(directory: f.registry)
            var replays = 0, verifications = 0
            let binding = HostBackgroundExecution(coordinator: coordinator, resolve: { _ in .init(executionRoot: f.source, conflictRoot: f.source) }, cancel: { _ in }, join: { _ in .unconfirmed(reason: "must not execute recovered work") })
            let host: any BackgroundJobHost = try await HostBackgroundJobService.open(storage: f.storage(scope), execution: binding,
                verifyRecovery: { record in
                    verifications += 1
                    guard record.owner.conversationID == scope.conversationID, !owner.isRunning,
                          owner.terminationReason == .uncaughtSignal, owner.terminationStatus == SIGKILL,
                          witness.pollExit(), FileManager.default.fileExists(atPath: f.root.appendingPathComponent("worker-exit-protocol").path) else {
                        return .unconfirmed(reason: "Registered controlled child still runs; exact kernel exit event and fixture completion protocol are required.")
                    }
                    return .verified(evidence: "fixture: owner SIGKILL reaped; known sole child exit protocol complete and exact-process kernel NOTE_EXIT observed; fixture creates no descendants or remote work")
                }, authorize: { $0 == scope }, execute: { _ in replays += 1; return .checkpoint("must not replay") })
            let pending = host.snapshot(request.operationID)!.pendingOperationID!
            let checkAlive = try await host.checkPhysicalExit(operationID: pending)
            let refused = try await host.reconcilePhysicalExit(checkAlive)
            if case .retained(_, let reason) = refused { check(!reason.isEmpty, "Release invokes independent verification and refuses to override a surviving child") }
            else { check(false, "surviving child must retain slot") }
            check(try await host.heldPhysicalOperations().count == 1 && replays == 0, "reopen keeps the single slot held without replaying the crashed job")
            var ordinaryChat = false
            await Task { @MainActor in ordinaryChat = true }.value
            let stop = try await host.stop(request.operationID)
            check(ordinaryChat && stop.stopRequested && host.snapshot(request.operationID)?.pendingOperationID == pending, "stuck ownership does not block synthetic ordinary chat, status or Stop")
            try Data().write(to: f.root.appendingPathComponent("worker-release"))
            try await wait { witness.pollExit() }
            let checkGone = try await host.checkPhysicalExit(operationID: pending)
            let released = try await host.reconcilePhysicalExit(checkGone)
            if case .released(let operation, _) = released { check(operation == pending && verifications >= 4, "Release re-verifies and reconciles only after the entire controlled child executor is independently verified gone") }
            else { check(false, "verified physical exit should reconcile") }
            check(try await host.heldPhysicalOperations().isEmpty && host.snapshot(request.operationID)?.pendingOperationID == pending && host.snapshot(request.operationID)?.state == .needsReview && host.pendingResults.isEmpty && replays == 0, "physical release preserves the unresolved logical outcome and never replays or delivers a result")
        }
        // Independent hosts targeting the SAME workspace serialize until #1 joins.
        do {
            let f = try HostFixture()
            func launch(_ name: String) throws -> Process {
                let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                p.arguments = ["--host-helper", f.registry.path, f.source.path, f.root.path, name]
                try p.run(); return p
            }
            let one = try launch("one")
            defer { if one.isRunning { kill(one.processIdentifier, SIGKILL) } }
            try await wait { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("one-entered").path) }
            let two = try launch("two")
            defer { if two.isRunning { kill(two.processIdentifier, SIGKILL) } }
            try await wait { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("two-blocked").path) }
            check(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("two-entered").path), "independent host actually receives shared-slot exhaustion for a different workspace before either executor exits")
            try Data().write(to: f.root.appendingPathComponent("one-release"))
            try await wait { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("two-entered").path) }
            try Data().write(to: f.root.appendingPathComponent("two-release"))
            try await wait { !one.isRunning && !two.isRunning }
            check(one.terminationStatus == 0 && two.terminationStatus == 0, "helper dispatch proceeds only after the first host records a verified physical join")
        }
        print("HostJobIntegrationTests: \(passed) passed, \(failed) failed; synthetic responsiveness only, no app/UI demonstration")
        if failed > 0 { exit(1) }
    }
    @MainActor static func helper() async throws {
        let input = CommandLine.arguments
        if input[1] == "--surviving-worker" {
            let root = URL(fileURLWithPath: input[2])
            try Data().write(to: root.appendingPathComponent("worker-ready"))
            try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("worker-release").path) }
            try Data().write(to: root.appendingPathComponent("worker-exit-protocol"))
            return // This known fixture creates no child, callback or remote request.
        }
        if input[1] == "--crashing-host-owner" {
            let registry = URL(fileURLWithPath: input[2]), source = URL(fileURLWithPath: input[3]), root = URL(fileURLWithPath: input[4])
            let request = try JSONDecoder().decode(HostJobRequest.self, from: Data(contentsOf: URL(fileURLWithPath: input[5])))
            let coordinator = HostExecutionCoordinator(directory: registry), gate = HostGate()
            let binding = HostBackgroundExecution(coordinator: coordinator, resolve: { _ in .init(executionRoot: source, conflictRoot: source) }, cancel: { _ in }, join: { _ in .unconfirmed(reason: "fixture owner is deliberately crashed") })
            let host = try await HostBackgroundJobService.open(storage: BackgroundWorkStorageSession.open(directory: root.appendingPathComponent(request.scope.conversationID.uuidString), projectID: request.scope.projectID, conversationID: request.scope.conversationID), execution: binding, authorize: { $0 == request.scope }, execute: { _ in
                let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = ["--surviving-worker", root.path]
                child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                try child.run()
                try Data(String(child.processIdentifier).utf8).write(to: root.appendingPathComponent("worker.pid"))
                try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("worker-ready").path) }
                try Data().write(to: root.appendingPathComponent("owner-ready"))
                await gate.wait()
                return .checkpoint("must not return before owner crash")
            })
            _ = try await host.submit(request)
            await HostGate().wait()
            return
        }
        let args = CommandLine.arguments, registry = URL(fileURLWithPath: args[2]), source = URL(fileURLWithPath: args[3]), root = URL(fileURLWithPath: args[4]), name = args[5]
        let coordinator = HostExecutionCoordinator(directory: registry)
        try Data().write(to: root.appendingPathComponent(name + "-waiting"))
        let operationID = UUID()
        if name == "two" {
            // Deterministic attempt/response barrier, not a sleep-based assertion
            // that the second process merely has not started dispatching yet.
            while true {
                do {
                    let unexpected = try await coordinator.storage.reserve(.init(executionRoot: source, conflictRoot: source), owner: .init(conversationID: UUID(), kind: .backgroundJob), operationID: operationID)
                    try await coordinator.storage.abandon(unexpected)
                    throw CocoaError(.fileReadCorruptFile)
                } catch PhysicalWorkOwnership.Failure.workspaceBusy {
                    try Data().write(to: root.appendingPathComponent(name + "-blocked")); break
                } catch PhysicalWorkOwnership.Failure.registryBusy {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        let admission = try await coordinator.admit(operationID: operationID, conversationID: UUID(), kind: name == "one" ? .foregroundBuild : .backgroundJob, authorize: { .init(executionRoot: source, conflictRoot: source) }, mayOperate: { true })
        try Data().write(to: root.appendingPathComponent(name + "-entered"))
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent(name + "-release").path) }
        try await coordinator.finish(admission, exit: .verified(evidence: "fixture: independent helper synthetic executor joined"))
    }
}
