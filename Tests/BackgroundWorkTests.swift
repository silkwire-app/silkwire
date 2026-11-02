import Foundation
import Darwin

@MainActor private final class WorkEngineStore {
    var value: BackgroundWorkSnapshot?
    var writes = 0
    var failAt: Set<Int> = []
    let file: URL?
    init(file: URL? = nil) { self.file = file }
    func save(_ snapshot: BackgroundWorkSnapshot) throws {
        writes += 1
        if failAt.contains(writes) { throw CocoaError(.fileWriteOutOfSpace) }
        let bytes = try JSONEncoder().encode(snapshot)
        if let file { try bytes.write(to: file, options: .atomic) }
        value = try JSONDecoder().decode(BackgroundWorkSnapshot.self, from: bytes)
    }
}
@MainActor private final class WorkEngineGate {
    struct Slot { let context: BackgroundWorkContext; let continuation: CheckedContinuation<BackgroundWorkStep, Never> }
    var slots: [Slot] = []
    func run(_ context: BackgroundWorkContext) async -> BackgroundWorkStep {
        await withCheckedContinuation { slots.append(Slot(context: context, continuation: $0)) }
    }
    func release(_ outcome: BackgroundWorkStep = .completed(checkpoint: "verified", summary: "Synthetic result")) {
        let old = slots; slots.removeAll()
        for item in old { item.continuation.resume(returning: outcome) }
    }
}
@MainActor private final class WorkEngineAuthorizationGate {
    var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    func release(_ allowed: Bool) { let old = continuation; continuation = nil; old?.resume(returning: allowed) }
}
@MainActor private final class WorkEngineChatTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var received = 0
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let result = ProviderIdentity(id: "background-engine-chat-fixture", started: false)
        self.identity = result; return result
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws { received += 1 }
    func answer() { eventHandler?(.delta("Synthetic foreground answer")); eventHandler?(.finished(status: "completed", message: nil)) }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: "Synthetic Stop")) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport only") }
}

@main struct BackgroundWorkTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body(); check(false, label) } catch { check(true, label) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Synthetic background engine checkpoint timed out") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let limits = BackgroundWorkLimits(totalSteps: 5, stepsPerSlice: 5)
        func scope(agent: String = "codex", project: UUID = UUID(), room: UUID = UUID(), workspace: UUID = UUID(), revision: String = String(repeating: "a", count: 40)) -> BackgroundWorkScope {
            BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: workspace, agentID: agent, sourceRevision: revision)
        }
        func permit(_ scope: BackgroundWorkScope, _ limits: BackgroundWorkLimits? = nil) -> BackgroundWorkPermit {
            BackgroundWorkPermit(scope: scope, limits: limits ?? BackgroundWorkLimits(totalSteps: 5, stepsPerSlice: 5))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundWork-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Automatic continuation, save-before-execute, independent foreground chat,
        // actual synthetic disk reopen, and a deduplicatable result outbox.
        do {
            let store = WorkEngineStore(file: root.appendingPathComponent("engine.json")), gate = WorkEngineGate(), s = scope()
            var calls = 0
            let engine = try BackgroundWorkEngine(save: store.save, authorize: { $0 == s }, execute: { context in
                calls += 1
                let disk = try JSONDecoder().decode(BackgroundWorkSnapshot.self, from: Data(contentsOf: store.file!))
                check(disk.items.first?.pendingStepID == context.stepID && disk.items.first?.attempts == calls, "step \(calls) is durably recorded before executor invocation")
                check(context.mayPerformOperation(), "step \(calls) has a current cancellation fence")
                if context.item.checkpoint.isEmpty { return .checkpoint("phase one saved") }
                return await gate.run(context)
            })
            let id = try engine.enqueue(scope: s, title: "Synthetic private work", limits: limits)
            check(try engine.start(id, permit: permit(s)), "host admission starts an independent background task")
            check(calls == 0 && engine.item(id)?.state == .running, "start returns before the asynchronous executor runs")
            try await wait { gate.slots.count == 1 }
            check(calls == 2 && engine.item(id)?.checkpoint == "phase one saved", "checkpoint automatically continues without another chat turn or Pass")
            let context = gate.slots[0].context
            check(context.item.sessionID != s.conversationID && context.item.scope == s, "background context keeps an isolated session key and exact scope")

            var events: [[String: Any]] = []
            let transport = WorkEngineChatTransport()
            let room = NativeRoom(emit: { events.append($0) }, factory: { _, _ in transport })
            defer { room.close() }
            await room.dispatch(["action": "connect", "conversationID": s.conversationID.uuidString.lowercased(), "participants": ["eve"], "projectFolders": [[String: String]]()])
            try await wait { events.contains { $0["type"] as? String == "ready" } }
            let chatID = UUID().uuidString
            await room.dispatch(["action": "send", "requestId": chatID, "text": "Synthetic foreground chat", "targets": ["eve"], "history": [[String: String]](), "historyTotal": 0])
            try await wait { transport.received == 1 }
            transport.answer()
            try await wait { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == chatID } }
            check(engine.item(id)?.state == .running && context.mayPerformOperation(), "real NativeRoom foreground chat finishes while a separate engine step remains pending")
            gate.release(.completed(checkpoint: "phase two saved", summary: "Ready for review"))
            try await wait { engine.activeWorkerCount == 0 }
            check(engine.item(id)?.state == .completed && engine.item(id)?.attempts == 2, "background completion is saved with an exact step count")
            check(!context.mayPerformOperation(), "completion invalidates the old step fence")
            let resultID = engine.item(id)!.resultID!
            check(engine.pendingResults.count == 1, "completed work enters the durable result outbox")
            try engine.shutdown()
            let saved = try JSONDecoder().decode(BackgroundWorkSnapshot.self, from: Data(contentsOf: store.file!))
            var replayed = 0
            let reopened = try BackgroundWorkEngine(restoring: saved, save: store.save, authorize: { _ in true }, execute: { _ in replayed += 1; return .checkpoint("must not run") })
            check(reopened.pendingResults.first?.resultID == resultID && replayed == 0, "reopen retains the result identity without replaying completed work")
            check(!(try reopened.start(id, permit: permit(s))), "completed work cannot restart")
            check(!(try reopened.acknowledgeResult(id, resultID: UUID())), "wrong result acknowledgements are refused")
            check(try reopened.acknowledgeResult(id, resultID: resultID), "host can durably acknowledge the exact delivered result")
            check(try reopened.acknowledgeResult(id, resultID: resultID), "duplicate acknowledgement is idempotent")
            try reopened.shutdown()
            let again = try BackgroundWorkEngine(restoring: store.value!, save: store.save, authorize: { _ in true }, execute: { _ in .checkpoint("") })
            check(again.pendingResults.isEmpty, "acknowledged results remain acknowledged after reopen")
            try again.shutdown()
        }

        // Cancellation while permission lookup is suspended cannot race into work.
        do {
            let store = WorkEngineStore(), authorization = WorkEngineAuthorizationGate(), s = scope()
            var executed = 0
            let engine = try BackgroundWorkEngine(save: store.save, authorize: { _ in await authorization.wait() }, execute: { _ in executed += 1; return .completed(checkpoint: "", summary: "wrong") })
            let id = try engine.enqueue(scope: s, title: "Cancel before authorization", limits: limits)
            _ = try engine.start(id, permit: permit(s))
            try await wait { authorization.continuation != nil }
            check(try engine.cancel(id), "Stop is saved while authorization is pending")
            authorization.release(true)
            try await wait { engine.activeWorkerCount == 0 }
            check(executed == 0 && store.value?.items.first?.state == .cancelled, "late authorization cannot start a cancelled task")
            try engine.shutdown()
            let reopened = try BackgroundWorkEngine(restoring: store.value!, save: store.save, authorize: { _ in true }, execute: { _ in executed += 1; return .checkpoint("") })
            check(!(try reopened.start(id, permit: permit(s))) && executed == 0, "cancelled tasks stay terminal across restart")
            try reopened.shutdown()
        }

        // An executor that ignores Task cancellation cannot publish a late result
        // or free its physical concurrency slot before it actually finishes.
        do {
            let store = WorkEngineStore(), gate = WorkEngineGate(), a = scope(), b = scope(agent: "eve")
            let engine = try BackgroundWorkEngine(maxConcurrent: 1, save: store.save, authorize: { _ in true }, execute: gate.run)
            let first = try engine.enqueue(scope: a, title: "First work", limits: limits)
            let second = try engine.enqueue(scope: b, title: "Second work", limits: limits)
            _ = try engine.start(first, permit: permit(a)); try await wait { gate.slots.count == 1 }
            let old = gate.slots[0].context
            check(try engine.cancel(first), "in-flight cancellation is persisted")
            check(!old.mayPerformOperation() && engine.item(first)?.state == .cancelled, "cancellation immediately fences further broker operations")
            check(!(try engine.start(second, permit: permit(b))) && engine.activeWorkerCount == 1, "non-cooperative cancelled work retains its concurrency slot")
            gate.release(); try await wait { engine.activeWorkerCount == 0 }
            check(engine.item(first)?.state == .cancelled && engine.pendingResults.isEmpty, "late executor completion cannot resurrect cancelled work or post a result")
            check(try engine.start(second, permit: permit(b)), "the slot becomes available only after the old executor returns")
            try await wait { gate.slots.count == 1 }; gate.release(); try await wait { engine.activeWorkerCount == 0 }
            check(engine.item(second)?.state == .completed, "another task completes without inheriting the cancelled task state")
            try engine.shutdown()
        }

        // Interrupted side-effect boundaries require exact host reconciliation.
        do {
            let store = WorkEngineStore(), s = scope()
            var calls = 0
            let engine = try BackgroundWorkEngine(save: store.save, authorize: { _ in true }, execute: { _ in
                calls += 1
                if calls == 1 { throw CocoaError(.fileReadUnknown) }
                return .completed(checkpoint: "after verified recovery", summary: "Synthetic result")
            })
            let id = try engine.enqueue(scope: s, title: "Uncertain step", limits: limits)
            _ = try engine.start(id, permit: permit(s)); try await wait { engine.activeWorkerCount == 0 }
            let pending = engine.item(id)!.pendingStepID!
            check(engine.item(id)?.pause == .reconciliation && engine.item(id)?.attempts == 1, "a thrown executor retains the uncertain step and consumed attempt")
            rejects("uncertain work is never blindly restarted") { _ = try engine.start(id, permit: permit(s)) }
            rejects("reconciliation must name the exact pending step") { try engine.reconcile(id, stepID: UUID(), permit: permit(s), outcome: .checkpoint("wrong")) }
            rejects("reconciliation cannot target another project or workspace") { try engine.reconcile(id, stepID: pending, permit: permit(scope()), outcome: .checkpoint("wrong")) }
            try engine.reconcile(id, stepID: pending, permit: permit(s), outcome: .checkpoint("host verified outcome"))
            check(engine.item(id)?.pendingStepID == nil && engine.item(id)?.pause == .host && calls == 1, "host reconciliation saves progress without automatically executing more work")
            _ = try engine.start(id, permit: permit(s)); try await wait { engine.activeWorkerCount == 0 }
            check(calls == 2 && engine.item(id)?.state == .completed, "fresh host admission continues only after reconciliation")
            try engine.shutdown()
        }

        // Capture a real saved running boundary, then retire the old engine and
        // simulate reopening that crash snapshot. No live library is involved.
        do {
            let store = WorkEngineStore(), gate = WorkEngineGate(), s = scope()
            let old = try BackgroundWorkEngine(save: store.save, authorize: { _ in true }, execute: gate.run)
            let id = try old.enqueue(scope: s, title: "Crash boundary", limits: limits)
            _ = try old.start(id, permit: permit(s)); try await wait { gate.slots.count == 1 }
            let crash = try JSONDecoder().decode(BackgroundWorkSnapshot.self, from: JSONEncoder().encode(store.value!))
            let fence = gate.slots[0].context
            try old.shutdown(); check(!fence.mayPerformOperation(), "shutdown invalidates old executor fences before any resume")
            gate.release(); try await wait { old.activeWorkerCount == 0 }
            var replay = 0
            let reopened = try BackgroundWorkEngine(restoring: crash, save: store.save, authorize: { _ in true }, execute: { _ in replay += 1; return .checkpoint("") })
            check(reopened.item(id)?.pause == .reconciliation && reopened.item(id)?.pendingStepID == crash.items[0].pendingStepID, "a crash preserves the exact uncertain step identity")
            check(replay == 0 && reopened.activeWorkerCount == 0, "loading saved work never dispatches or revives it automatically")
            rejects("crash-restored work cannot bypass reconciliation") { _ = try reopened.start(id, permit: permit(s)) }
            try reopened.shutdown()
            let writes = store.writes
            rejects("future snapshot versions are rejected") { _ = try BackgroundWorkEngine(restoring: BackgroundWorkSnapshot(version: 2, items: crash.items), save: store.save, authorize: { _ in true }, execute: { _ in .checkpoint("") }) }
            rejects("duplicate saved task identities are rejected") { _ = try BackgroundWorkEngine(restoring: BackgroundWorkSnapshot(version: 1, items: [crash.items[0], crash.items[0]]), save: store.save, authorize: { _ in true }, execute: { _ in .checkpoint("") }) }
            var corrupt = crash.items[0]; corrupt.attempts = -1
            rejects("negative saved attempts are rejected") { _ = try BackgroundWorkEngine(restoring: BackgroundWorkSnapshot(version: 1, items: [corrupt]), save: store.save, authorize: { _ in true }, execute: { _ in .checkpoint("") }) }
            let collision = BackgroundWorkItem(id: UUID(), scope: s, sessionID: s.conversationID, title: "Not isolated", limits: limits)
            rejects("a background key cannot be the originating chat key") { _ = try BackgroundWorkEngine(restoring: BackgroundWorkSnapshot(version: 1, items: [collision]), save: store.save, authorize: { _ in true }, execute: { _ in .checkpoint("") }) }
            check(store.writes == writes, "invalid saved input is not overwritten with an empty ledger")
        }

        // A slice limit is a pause, not a fake provider disconnect. The lifetime
        // count remains bounded even if the host admits another slice.
        do {
            let store = WorkEngineStore(), s = scope(), small = BackgroundWorkLimits(totalSteps: 3, stepsPerSlice: 2)
            var calls = 0
            let engine = try BackgroundWorkEngine(save: store.save, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("checkpoint \(calls)") })
            let id = try engine.enqueue(scope: s, title: "Bounded slices", limits: small)
            _ = try engine.start(id, permit: permit(s, small)); try await wait { engine.activeWorkerCount == 0 }
            check(calls == 2 && engine.item(id)?.pause == .sliceLimit && engine.item(id)?.checkpoint == "checkpoint 2", "step-slice exhaustion pauses with saved progress")
            _ = try engine.start(id, permit: permit(s, small)); try await wait { engine.activeWorkerCount == 0 }
            check(calls == 3 && engine.item(id)?.pause == .stepLimit && engine.item(id)?.attempts == 3, "resuming a slice cannot reset lifetime attempts")
            check(!(try engine.start(id, permit: permit(s, small))) && calls == 3, "exhausted lifetime limits prevent further executor calls")
            check(!(try engine.start(id, permit: permit(s, limits))), "a runtime permit cannot expand the saved task limit")
            try engine.shutdown()
        }

        // Fresh grants are checked between steps; saved tasks are not grants.
        do {
            let store = WorkEngineStore(), s = scope()
            var grantChecks = 0, calls = 0
            var allowed = true
            let engine = try BackgroundWorkEngine(save: store.save, authorize: { _ in grantChecks += 1; return allowed }, execute: { _ in calls += 1; allowed = false; return .checkpoint("checkpoint before revocation") })
            let id = try engine.enqueue(scope: s, title: "Current permissions", limits: limits)
            check(!(try engine.start(id, permit: permit(scope()))), "a permit for another scope cannot start this work")
            _ = try engine.start(id, permit: permit(s)); try await wait { engine.activeWorkerCount == 0 }
            check(calls == 1 && grantChecks == 2 && engine.item(id)?.pause == .revoked, "revoked permission stops the next step without discarding its checkpoint")
            check(engine.item(id)?.checkpoint == "checkpoint before revocation" && engine.item(id)?.pendingStepID == nil, "permission pause retains a clean recovery boundary")
            try engine.shutdown()
        }

        // Failure injection at enqueue, before execution, after execution and Stop.
        do {
            let store = WorkEngineStore(), s = scope(); store.failAt = [1]
            let engine = try BackgroundWorkEngine(save: store.save, authorize: { _ in true }, execute: { _ in .checkpoint("") })
            rejects("failed enqueue persistence refuses the task") { _ = try engine.enqueue(scope: s, title: "No durable record", limits: limits) }
            check(engine.storageFailed && engine.snapshot.items.isEmpty && engine.activeWorkerCount == 0, "enqueue storage failure cannot create phantom work")
        }
        for failWrite in [3, 4] {
            let store = WorkEngineStore(), s = scope(); store.failAt = [failWrite]
            var calls = 0
            let engine = try BackgroundWorkEngine(save: store.save, authorize: { _ in true }, execute: { _ in calls += 1; return .completed(checkpoint: "done", summary: "must save first") })
            let id = try engine.enqueue(scope: s, title: "Injected storage failure", limits: limits)
            _ = try engine.start(id, permit: permit(s)); try await wait { engine.activeWorkerCount == 0 }
            check(engine.storageFailed && calls == (failWrite == 3 ? 0 : 1), "write failure \(failWrite) fences execution at the correct boundary")
            check(engine.pendingResults.isEmpty && engine.item(id)?.state != .completed, "write failure \(failWrite) never publishes an unpersisted success")
            let diskState = store.value!
            let recoveredStore = WorkEngineStore()
            let recovered = try BackgroundWorkEngine(restoring: diskState, save: recoveredStore.save, authorize: { _ in true }, execute: { _ in .checkpoint("") })
            check(recovered.item(id)?.pause == (failWrite == 3 ? .restart : .reconciliation), "write failure \(failWrite) reopens at a safe non-executing boundary")
            try recovered.shutdown()
        }
        do {
            let store = WorkEngineStore(), s = scope(), gate = WorkEngineGate()
            let engine = try BackgroundWorkEngine(save: store.save, authorize: { _ in true }, execute: gate.run)
            let id = try engine.enqueue(scope: s, title: "Stop storage failure", limits: limits)
            _ = try engine.start(id, permit: permit(s)); try await wait { gate.slots.count == 1 }
            let fence = gate.slots[0].context
            store.failAt = [store.writes + 1]
            rejects("Stop persistence failure is reported rather than claimed durable") { _ = try engine.cancel(id) }
            check(engine.storageFailed && !fence.mayPerformOperation(), "failed Stop persistence still invalidates in-process operation fences")
            gate.release(); try await wait { engine.activeWorkerCount == 0 }
            check(engine.pendingResults.isEmpty && store.value?.items.first?.pendingStepID != nil, "late completion after storage failure cannot erase the uncertain disk boundary")
        }

        // Several agents can run independently without sharing provider-session keys.
        do {
            let store = WorkEngineStore(), gate = WorkEngineGate(), a = scope(), b = scope(agent: "claude"), c = scope(agent: "eve")
            let engine = try BackgroundWorkEngine(maxConcurrent: 2, save: store.save, authorize: { _ in true }, execute: gate.run)
            let first = try engine.enqueue(scope: a, title: "First agent", limits: limits)
            let second = try engine.enqueue(scope: b, title: "Second agent", limits: limits)
            let third = try engine.enqueue(scope: c, title: "Third agent", limits: limits)
            _ = try engine.start(first, permit: permit(a)); _ = try engine.start(second, permit: permit(b))
            try await wait { gate.slots.count == 2 }
            check(Set(gate.slots.map { $0.context.item.sessionID }).count == 2, "parallel work has distinct dedicated session keys")
            check(!(try engine.start(third, permit: permit(c))), "host concurrency capacity cannot be overbooked")
            gate.release(); try await wait { engine.activeWorkerCount == 0 }
            check(engine.item(first)?.state == .completed && engine.item(second)?.state == .completed && engine.item(third)?.state == .queued, "parallel completion cannot advance an unrelated queued task")
            try engine.shutdown()
        }
        do {
            let store = WorkEngineStore()
            let engine = try BackgroundWorkEngine(save: store.save, authorize: { _ in true }, execute: { _ in .checkpoint("") })
            rejects("invalid revision cannot become a saved work scope") { _ = try engine.enqueue(scope: scope(revision: "not a revision"), title: "Invalid", limits: limits) }
            rejects("empty titles are rejected") { _ = try engine.enqueue(scope: scope(), title: "  ", limits: limits) }
            rejects("zero step budgets are rejected") { _ = try engine.enqueue(scope: scope(), title: "Invalid", limits: BackgroundWorkLimits(totalSteps: 0, stepsPerSlice: 0)) }
            try engine.shutdown()
        }
        // Workspace exclusivity also applies when spare global capacity exists,
        // and remains held until a cancelled, non-cooperative executor returns.
        do {
            let store = WorkEngineStore(), gate = WorkEngineGate(), s = scope()
            let engine = try BackgroundWorkEngine(maxConcurrent: 3, save: store.save, authorize: { _ in true }, execute: gate.run)
            let first = try engine.enqueue(scope: s, title: "One workspace owner", limits: limits)
            let second = try engine.enqueue(scope: s, title: "Same workspace again", limits: limits)
            _ = try engine.start(first, permit: permit(s)); try await wait { gate.slots.count == 1 }
            check(!(try engine.start(second, permit: permit(s))), "two tasks cannot execute against the same private workspace concurrently")
            _ = try engine.cancel(first)
            check(!(try engine.start(second, permit: permit(s))), "cancelling does not release workspace exclusivity before the executor returns")
            gate.release(); try await wait { engine.activeWorkerCount == 0 }
            check(try engine.start(second, permit: permit(s)), "workspace ownership can proceed after the old physical worker ends")
            try await wait { gate.slots.count == 1 }; gate.release(); try await wait { engine.activeWorkerCount == 0 }
            try engine.shutdown()
        }
        do {
            let store = WorkEngineStore(), firstScope = scope(), otherScope = scope()
            let first = BackgroundWorkItem(id: UUID(), scope: firstScope, sessionID: otherScope.conversationID, title: "Collision with another chat", limits: limits)
            let second = BackgroundWorkItem(id: UUID(), scope: otherScope, sessionID: UUID(), title: "Other work", limits: limits)
            rejects("a background key cannot collide with another saved task's originating chat") {
                _ = try BackgroundWorkEngine(restoring: BackgroundWorkSnapshot(version: 1, items: [first, second]), save: store.save, authorize: { _ in true }, execute: { _ in .checkpoint("") })
            }
        }
        // Exercise the encoded-ledger limit itself, not just an injected I/O error.
        // Fill with valid, paused synthetic records, leaving 2048 bytes of headroom.
        do {
            let store = WorkEngineStore(), target = 2_097_152 - 2048
            var items: [BackgroundWorkItem] = []
            func size(_ items: [BackgroundWorkItem]) throws -> Int { try JSONEncoder().encode(BackgroundWorkSnapshot(version: 1, items: items)).count }
            while true {
                var item = BackgroundWorkItem(id: UUID(), scope: scope(), sessionID: UUID(), title: "Synthetic capacity fixture", limits: limits)
                item.state = .paused; item.pause = .host; item.checkpoint = String(repeating: "a", count: 16_384)
                if try size(items + [item]) > target { break }
                items.append(item)
            }
            var padding = BackgroundWorkItem(id: UUID(), scope: scope(), sessionID: UUID(), title: "Capacity padding", limits: limits)
            padding.state = .paused; padding.pause = .host
            let room = target - (try size(items + [padding]))
            guard (0...16_384).contains(room), !items.isEmpty else { throw nativeFailure("Capacity fixture construction failed") }
            padding.checkpoint = String(repeating: "a", count: room); items.append(padding)
            let original = BackgroundWorkSnapshot(version: 1, items: items)
            check(try size(items) == target, "capacity fixture has an exact bounded encoded size")
            let engine = try BackgroundWorkEngine(restoring: original, save: store.save, authorize: { _ in true }, execute: { context in
                .completed(checkpoint: context.item.checkpoint, summary: String(repeating: "b", count: 4096))
            })
            let id = items[0].id
            _ = try engine.start(id, permit: permit(items[0].scope)); try await wait { engine.activeWorkerCount == 0 }
            check(engine.storageFailed && engine.item(id)?.pendingStepID != nil, "ledger size exhaustion latches a storage fence and retains the uncertain step")
            check(engine.pendingResults.isEmpty && store.value?.items.first(where: { $0.id == id })?.state == .running, "capacity exhaustion never publishes an unsaved success or discards history")
        }
        print("Background work engine: \(passed) passed, \(failed) failed; synthetic execution and isolated fixtures only")
        if failed > 0 { exit(1) }
    }
}
