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

@MainActor private final class SessionLatch {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        let old = continuation; continuation = nil; old?.resume()
    }
}
@MainActor private final class SessionFlag { var value = true }
@MainActor private final class SessionResult {
    var done = false
    var value: BackgroundWorkStep?
    var error: String?
}
@MainActor private final class SessionTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var connectCalls = 0, sendCalls = 0, stopCalls = 0, closeCalls = 0
    var receivedIdentity: ProviderIdentity?
    var connectCapabilities = "", sendCapabilities = "", prompt = "", requestID = ""
    var forcedID: String?
    var connectGate: SessionLatch?, sendGate: SessionLatch?, stopGate: SessionLatch?
    var connectEvent: NativeAgentEvent?
    var autoReply: String?
    var sendError = false, stopError = false, stopTerminal = true
    var onSend: ((SessionTransport) -> Void)?
    func connect(_ saved: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        connectCalls += 1; receivedIdentity = saved; connectCapabilities = capabilities
        if let connectEvent { eventHandler?(connectEvent) }
        if let connectGate { await connectGate.wait() }
        let value = ProviderIdentity(id: forcedID ?? saved?.id ?? UUID().uuidString.lowercased(), started: saved?.started ?? false, model: "Synthetic provider")
        identity = value
        return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        sendCalls += 1; prompt = text; self.requestID = requestID; sendCapabilities = capabilities
        identity?.started = true; identity?.requestId = requestID
        identity?.runId = "synthetic-old-run"; identity?.turnId = "synthetic-old-turn"
        onSend?(self)
        if let autoReply { answer(autoReply) }
        if let sendGate { await sendGate.wait() }
        if sendError { throw nativeFailure("Synthetic acknowledgement failure") }
    }
    func answer(_ text: String) {
        eventHandler?(.delta(text)); eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws {
        stopCalls += 1
        if let stopGate { await stopGate.wait() }
        if stopError { throw nativeFailure("Synthetic Stop failure") }
        if stopTerminal { eventHandler?(.finished(status: "interrupted", message: "Synthetic Stop")) }
    }
    func stopPrevious() async throws { throw nativeFailure("Not used by synthetic background adapter") }
    func close() { closeCalls += 1 } // Deliberately does NOT release physical test gates.
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport only") }
}
@MainActor private final class SessionPool {
    var transports: [SessionTransport] = []
    var agents: [String] = [], keys: [String] = []
    var configure: (SessionTransport, Int) -> Void = { _, _ in }
    func make(_ agent: String, _ key: String) -> any NativeAgentTransport {
        let transport = SessionTransport()
        configure(transport, transports.count)
        agents.append(agent); keys.append(key); transports.append(transport)
        return transport
    }
}
private struct SessionDocument: Codable {
    let version: Int
    let projectID: UUID
    let conversationID: UUID
    let snapshot: BackgroundWorkSnapshot
}
@MainActor private final class SessionHolder { var value: BackgroundAgentSession? }

@main struct BackgroundAgentSessionTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Synthetic background-session fixture timed out") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }
        func scope() -> BackgroundWorkScope {
            BackgroundWorkScope(projectID: UUID(), conversationID: UUID(), workspaceID: UUID(), agentID: "codex", sourceRevision: String(repeating: "b", count: 40))
        }
        let limits = BackgroundWorkLimits(totalSteps: 4, stepsPerSlice: 4)
        func item(_ s: BackgroundWorkScope? = nil, id: UUID = UUID(), session: UUID = UUID()) -> BackgroundWorkItem {
            BackgroundWorkItem(id: id, scope: s ?? scope(), sessionID: session, title: "Synthetic isolated background work", limits: limits)
        }
        func context(_ base: BackgroundWorkItem, _ suppliedFlag: SessionFlag? = nil) -> BackgroundWorkContext {
            let flag = suppliedFlag ?? SessionFlag()
            var running = base
            running.state = .running; running.attempts = max(1, running.attempts)
            running.pendingStepID = UUID(); running.pause = nil
            return BackgroundWorkContext(item: running, stepID: running.pendingStepID!, mayPerformOperation: { flag.value })
        }
        func adapter(_ base: BackgroundWorkItem, _ pool: SessionPool, maximum: Int = 8,
                     forbidden: Set<String> = [],
                     prepare: @escaping BackgroundAgentSession.Prepare = { _, receipt in
                         .init(prompt: receipt ?? "Synthetic host task", capabilities: "Synthetic current capabilities")
                     },
                     handle: @escaping BackgroundAgentSession.Handle = { _, _ in
                         .outcome(.completed(checkpoint: "Synthetic verified boundary", summary: "For review"))
                     }) throws -> BackgroundAgentSession {
            try BackgroundAgentSession(item: base, maximumExchanges: maximum, forbiddenProviderIDs: forbidden,
                factory: pool.make, prepare: prepare, handle: handle)
        }
        func launch(_ session: BackgroundAgentSession, _ ctx: BackgroundWorkContext, _ result: SessionResult) -> Task<Void, Never> {
            Task { @MainActor in
                do { result.value = try await session.execute(ctx) }
                catch { result.error = error.localizedDescription }
                result.done = true
            }
        }
        func rejects(_ session: BackgroundAgentSession, _ ctx: BackgroundWorkContext) async -> Bool {
            do { _ = try await session.execute(ctx); return false } catch { return true }
        }

        // Admission is exact and constructing a session has no provider effects.
        do {
            let base = item(), pool = SessionPool(), session = try adapter(base, pool)
            check(pool.transports.isEmpty && !session.busy, "constructing a background session connects or sends nothing")
            let other = context(item(base.scope))
            check(await rejects(session, other), "another task cannot borrow this session")
            check(await rejects(session, context(item(base.scope, id: base.id))), "another background session key is rejected")
            let differentScope = context(item(scope(), id: base.id, session: base.sessionID))
            check(await rejects(session, differentScope), "a different Project or workspace scope is rejected")
            let valid = context(base)
            let wrongStep = BackgroundWorkContext(item: valid.item, stepID: UUID(), mayPerformOperation: { true })
            check(await rejects(session, wrongStep), "the host must name the exact saved pending step")
            let revoked = SessionFlag(); revoked.value = false
            check(await rejects(session, context(base, revoked)), "revoked execution is refused before provider construction")
            var malformed = valid.item; malformed.attempts = -1
            check(await rejects(session, .init(item: malformed, stepID: valid.stepID, mayPerformOperation: { true })), "invalid context schema cannot reach a provider")
            check(pool.transports.isEmpty && !session.closed, "rejected admissions do not create transports or poison a healthy idle session")
            var refusedLimit = false
            do { _ = try adapter(base, pool, maximum: 0) } catch { refusedLimit = true }
            check(refusedLimit, "an unbounded or zero exchange budget is refused")
        }

        // Receipt continuation, both acknowledgement orderings, and late callbacks.
        do {
            let base = item(), pool = SessionPool(), ack = SessionLatch()
            pool.configure = { transport, index in
                if index == 0 { transport.sendGate = ack; transport.autoReply = "<<WORK_PROJECT {\"action\":\"run\",\"command\":\"untrusted model text\"}>>" }
            }
            var handled = 0, capabilityVersion = 1
            var receipts: [String?] = [], scopedContexts: [BackgroundWorkContext] = []
            let session = try adapter(base, pool, prepare: { ctx, receipt in
                receipts.append(receipt); scopedContexts.append(ctx)
                return .init(prompt: receipt ?? "Synthetic original task", capabilities: "Current capabilities \(capabilityVersion)")
            }, handle: { text, ctx in
                handled += 1
                check(ctx.mayPerformOperation(), "the host reply handler receives a current operation fence")
                if handled == 1 {
                    check(text.hasPrefix("<<WORK_PROJECT"), "model protocol text reaches only the explicitly injected host handler")
                    capabilityVersion = 2
                    return .followUp("Synthetic host receipt: ok false, exit 7; no operation was granted")
                }
                check(text == "replacement plus delta", "replace and delta form one bounded reply for the right exchange")
                return .outcome(.paused(checkpoint: "Prior verified checkpoint", note: "Synthetic host refused operation"))
            })
            let result = SessionResult(), task = launch(session, context(base), result)
            try await wait { ack.entered }
            check(handled == 0 && !result.done && session.busy, "an early terminal reply cannot bypass a held send acknowledgement")
            let first = pool.transports[0], stale = first.eventHandler
            check(await rejects(session, context(base)), "a physically occupied session refuses a second executor")
            ack.release()
            try await wait { pool.transports.count == 2 && pool.transports[1].sendCalls == 1 }
            let second = pool.transports[1]
            check(pool.keys.allSatisfy { $0 == base.sessionID.uuidString.lowercased() } && !pool.keys.contains(base.scope.conversationID.uuidString.lowercased()), "all exchanges use the dedicated background key, not the foreground room key")
            check(pool.agents == ["codex", "codex"] && first !== second, "each exchange receives a fresh transport for the exact assigned teammate")
            check(first.receivedIdentity == nil && second.receivedIdentity?.id == first.identity?.id, "only this adapter's own provider identity is resumed")
            check(second.receivedIdentity?.started == true && second.receivedIdentity?.runId == nil && second.receivedIdentity?.requestId == nil && second.receivedIdentity?.turnId == nil, "a confirmed session resumes without stale run, request or turn recovery tokens")
            check(second.connectCapabilities == "Current capabilities 2" && second.sendCapabilities == "Current capabilities 2", "the host refreshes capabilities for both reconnect and follow-up dispatch")
            check(receipts.count == 2 && receipts[0] == nil && receipts[1]?.contains("exit 7") == true, "only the host-produced bounded receipt continues the original task")
            check(first.requestID != second.requestID && UUID(uuidString: second.requestID) != nil, "each provider exchange has a distinct native request identity")
            stale?(.delta("foreign stale output")); stale?(.finished(status: "completed", message: nil))
            try await settle()
            check(!result.done && handled == 1, "a retired exchange's captured callback cannot finish the next exchange")
            check(!result.done && session.busy, "a send acknowledgement alone is not a completed provider reply")
            second.eventHandler?(.delta("discarded")); second.eventHandler?(.replace("replacement")); second.eventHandler?(.delta(" plus delta"))
            second.eventHandler?(.finished(status: "completed", message: nil))
            second.eventHandler?(.finished(status: "completed", message: nil))
            await task.value
            check(result.value == .paused(checkpoint: "Prior verified checkpoint", note: "Synthetic host refused operation") && handled == 2, "the exact host outcome is returned once, not a fabricated success for refused work")
            check(!session.busy && scopedContexts.allSatisfy { !$0.mayPerformOperation() }, "completion retires the transport and every exchange's old operation fence")
        }

        // Reject a foreground object without taking ownership or closing it.
        do {
            let base = item(), pool = SessionPool()
            pool.configure = { transport, _ in transport.identity = ProviderIdentity(id: "foreground-owned", started: true) }
            let session = try adapter(base, pool)
            check(await rejects(session, context(base)), "a preconnected foreground transport is never reused for background work")
            let existing = pool.transports[0]
            check(existing.connectCalls == 0 && existing.sendCalls == 0 && existing.closeCalls == 0, "refusing a foreign transport neither dispatches nor closes that foreground session")
        }
        do {
            let base = item(), pool = SessionPool()
            pool.configure = { transport, _ in transport.forcedID = "forbidden-foreground-id" }
            let session = try adapter(base, pool, forbidden: ["forbidden-foreground-id"])
            check(await rejects(session, context(base)), "a fresh connector returning a host-forbidden foreground identity is refused")
            check(pool.transports[0].sendCalls == 0 && session.closed, "an identity collision fences the adapter before any background prompt is sent")
        }
        do {
            let base = item(), pool = SessionPool()
            pool.configure = { transport, index in
                transport.autoReply = "Synthetic terminal"
                if index == 1 { transport.forcedID = "unexpected-other-session" }
            }
            let session = try adapter(base, pool)
            _ = try await session.execute(context(base))
            check(await rejects(session, context(base)), "a provider cannot substitute another session while resuming")
            check(pool.transports.count == 2 && pool.transports[1].sendCalls == 0, "unexpected resumption identity never receives a follow-up prompt")
        }

        // Revocation during preparation or connection waits for physical unwind.
        for stage in 0...1 {
            let base = item(), pool = SessionPool(), gate = SessionLatch()
            var captured: BackgroundWorkContext?
            if stage == 1 { pool.configure = { transport, _ in transport.connectGate = gate } }
            let session = try adapter(base, pool, prepare: { ctx, _ in
                captured = ctx
                if stage == 0 { await gate.wait() }
                return .init(prompt: "Synthetic task", capabilities: "Fresh capabilities")
            })
            let result = SessionResult(), task = launch(session, context(base), result)
            try await wait { gate.entered }
            session.invalidate()
            check(captured?.mayPerformOperation() == false, "revocation stage \(stage) synchronously fences the host context")
            try await settle()
            check(session.busy && !result.done, "revocation stage \(stage) retains ownership until the held preparation or connection returns")
            gate.release(); await task.value
            check(result.value == nil && result.error != nil && pool.transports.allSatisfy { $0.sendCalls == 0 }, "revocation stage \(stage) cannot dispatch after its await returns")
            check(session.closed && !session.busy, "revocation stage \(stage) closes safely rather than retrying an uncertain session")
        }

        // Cancellation at three independently held boundaries.
        for stage in 0...2 {
            let base = item(), pool = SessionPool(), physical = SessionLatch(), stop = SessionLatch()
            var handled = 0, captured: BackgroundWorkContext?
            pool.configure = { transport, _ in
                if stage == 0 { transport.sendGate = physical; transport.autoReply = "Early completed output" }
                if stage == 2 { transport.autoReply = "Output before held host handling" }
                if stage < 2 { transport.stopGate = stop }
            }
            let session = try adapter(base, pool, prepare: { ctx, _ in
                captured = ctx; return .init(prompt: "Synthetic task", capabilities: "Current host capabilities")
            }, handle: { _, _ in
                handled += 1
                if stage == 2 { await physical.wait() }
                return .outcome(.completed(checkpoint: "Late output", summary: "Must not publish"))
            })
            let result = SessionResult(), task = launch(session, context(base), result)
            if stage == 1 { try await wait { pool.transports.first?.sendCalls == 1 } }
            else { try await wait { physical.entered } }
            session.invalidate(); task.cancel()
            check(captured?.mayPerformOperation() == false, "Stop stage \(stage) invalidates broker operations immediately")
            if stage < 2 {
                try await wait { stop.entered }
                check(!result.done && session.busy, "Stop stage \(stage) cannot release its physical slot while provider Stop is held")
                let late = pool.transports[0].eventHandler
                late?(.delta("Late output")); late?(.finished(status: "completed", message: nil))
                stop.release()
                if stage == 0 {
                    try await settle()
                    check(!result.done && session.busy, "a returned Stop still cannot bypass a held original send acknowledgement")
                    physical.release()
                }
            } else {
                try await settle()
                check(!result.done && session.busy, "Stop retains ownership while a non-cooperative host callback physically returns")
                physical.release()
            }
            await task.value
            check(result.value == nil && result.error != nil && !session.busy, "Stop stage \(stage) never returns a late completed outcome")
            check(handled == (stage == 2 ? 1 : 0), "Stop stage \(stage) cannot enter or repeat a fenced host reply handler")
        }

        // A terminal callback is not proof of successful send or safe recovery.
        for mode in 0...4 {
            let base = item(), pool = SessionPool()
            var handled = 0
            pool.configure = { transport, _ in
                switch mode {
                case 0: transport.autoReply = "Early terminal"; transport.sendError = true
                case 1: transport.onSend = { $0.eventHandler?(.recovery(requestID: "old", status: "completed", text: "Old result")) }
                case 2: transport.onSend = { $0.eventHandler?(.disconnected(message: "Synthetic disconnect", uncertain: true)) }
                case 3: transport.onSend = { $0.eventHandler?(.finished(status: "failed", message: "Synthetic provider failure")) }
                default: transport.connectEvent = .finished(status: "completed", message: "Before dispatch")
                }
            }
            let session = try adapter(base, pool, handle: { _, _ in handled += 1; return .outcome(.checkpoint("Must not commit")) })
            check(await rejects(session, context(base)), "uncertain provider boundary \(mode) is reported as failure")
            check(handled == 0 && session.closed, "uncertain provider boundary \(mode) cannot publish or blindly resume recovered text")
            let calls = pool.transports.count
            check(await rejects(session, context(base)), "uncertain provider boundary \(mode) requires host reconciliation before another executor")
            check(pool.transports.count == calls, "uncertain provider boundary \(mode) is not silently retried")
        }
        do {
            let base = item(), pool = SessionPool(), ctx = context(base)
            var captured: BackgroundWorkContext?
            pool.configure = { transport, _ in transport.stopTerminal = false }
            let session = try adapter(base, pool, prepare: { scoped, _ in
                captured = scoped; return .init(prompt: "Synthetic task", capabilities: "Current")
            }), result = SessionResult()
            let task = launch(session, ctx, result)
            try await wait { pool.transports.first?.sendCalls == 1 }
            task.cancel()
            try await wait { session.needsProviderIdleConfirmation }
            check(session.busy && !result.done && captured?.mayPerformOperation() == false, "a returned interruption acknowledgement is not physical provider termination")
            check(!session.confirmProviderIdleAfterHostReconciliation(itemID: UUID(), stepID: ctx.stepID) && !session.confirmProviderIdleAfterHostReconciliation(itemID: base.id, stepID: UUID()), "host idle confirmation cannot name a foreign task or stale step")
            let transport = pool.transports[0]
            transport.eventHandler?(.activity("Synthetic timer fired"))
            transport.eventHandler?(.finished(status: "failed", message: "Synthetic interruption timeout"))
            transport.eventHandler?(.disconnected(message: "Unknown provider state", uncertain: true))
            try await settle()
            check(session.busy && !result.done && session.needsProviderIdleConfirmation, "timeouts, failed terminals and disconnects cannot falsely release physical ownership")
            transport.eventHandler?(.finished(status: "interrupted", message: "Synthetic confirmed terminal"))
            await task.value
            check(result.value == nil && result.error != nil && !session.busy, "the exact post-Stop terminal releases ownership without publishing output")
        }
        do {
            let base = item(), pool = SessionPool(), ctx = context(base)
            pool.configure = { transport, _ in transport.sendError = true; transport.stopError = true }
            let session = try adapter(base, pool), result = SessionResult()
            let task = launch(session, ctx, result)
            try await wait { session.needsProviderIdleConfirmation }
            check(session.busy && !result.done, "a failed Stop preserves the occupied slot until independent host idle evidence")
            check(session.confirmProviderIdleAfterHostReconciliation(itemID: base.id, stepID: ctx.stepID), "independent runtime-host idle reconciliation can release the exact uncertain provider step")
            await task.value
            check(result.error?.contains("Stop is unconfirmed") == true && result.value == nil, "idle reconciliation still reports the failed Stop rather than forging successful cancellation")
            check(!session.confirmProviderIdleAfterHostReconciliation(itemID: base.id, stepID: ctx.stepID), "a retired step cannot be reconciled twice as a current physical owner")
        }

        // All buffers and automatic exchanges are explicitly bounded.
        for mode in 0...6 {
            let base = item(), pool = SessionPool()
            pool.configure = { transport, _ in
                switch mode {
                case 3: transport.onSend = { t in t.eventHandler?(.delta(String(repeating: "x", count: BackgroundAgentSession.maximumReplyBytes))); t.eventHandler?(.delta("overflow")) }
                case 4: transport.onSend = { $0.eventHandler?(.replace(String(repeating: "x", count: BackgroundAgentSession.maximumReplyBytes + 1))) }
                default: transport.autoReply = "Synthetic terminal"
                }
            }
            let session = try adapter(base, pool, maximum: 2, prepare: { _, _ in
                if mode == 0 { return .init(prompt: "", capabilities: "Current") }
                if mode == 1 { return .init(prompt: String(repeating: "p", count: 24_001), capabilities: "") }
                if mode == 2 { return .init(prompt: "p", capabilities: String(repeating: "c", count: 32_000)) }
                return .init(prompt: "Synthetic task", capabilities: "Current")
            }, handle: { _, _ in
                if mode == 5 { return .followUp(String(repeating: "r", count: 24_001)) }
                return .followUp("Synthetic receipt for another bounded exchange")
            })
            check(await rejects(session, context(base)), "bounded input, output or continuation case \(mode) refuses overflow")
            if mode < 3 { check(pool.transports.isEmpty, "oversized or empty prompt case \(mode) is refused before connecting") }
            if mode == 6 { check(pool.transports.count == 2 && pool.transports.allSatisfy { $0.sendCalls == 1 }, "the exchange budget bounds automatic provider submissions without resetting itself") }
        }

        // Actual awaited runner/storage + synthetic native transports, no live providers.
        let root = try canonicalFixtureTemporaryDirectory().appendingPathComponent("BackgroundAgentSession-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func directory() throws -> URL {
            let value = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return value
        }
        func document(_ directory: URL) throws -> BackgroundWorkSnapshot {
            try JSONDecoder().decode(SessionDocument.self, from: Data(contentsOf: directory.appendingPathComponent("background-work.json"))).snapshot
        }
        do {
            let s = scope(), directory = try directory(), pool = SessionPool(), holder = SessionHolder()
            var handled = 0
            pool.configure = { transport, index in
                transport.autoReply = "Synthetic phase \(index + 1)"
                transport.onSend = { _ in
                    do {
                        let saved = try document(directory).items.first
                        check(saved?.state == .running && saved?.pendingStepID != nil && saved?.attempts == index + 1, "actual disk records exact pending native-session step \(index + 1) before dispatch")
                    } catch { check(false, "actual native-session pending step can be read") }
                }
            }
            let storage = try await BackgroundWorkStorageSession.open(directory: directory, projectID: s.projectID, conversationID: s.conversationID)
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { ctx in
                guard let session = holder.value else { throw BackgroundWorkError.unavailable }
                return try await session.execute(ctx)
            })
            let id = try await runner.enqueue(scope: s, title: "Native session integration", limits: limits)
            holder.value = try adapter(runner.item(id)!, pool, handle: { _, ctx in
                handled += 1
                check(ctx.mayPerformOperation(), "the runner's native-session host callback has a current saved-step fence")
                return handled == 1 ? .outcome(.checkpoint("Verified phase one")) : .outcome(.completed(checkpoint: "Verified phase two", summary: "Synthetic host-verified result"))
            })
            let started = try await runner.start(id, permit: .init(scope: s, limits: limits))
            check(started, "one explicit host admission starts the runner-backed native session")
            try await wait { runner.activeWorkerCount == 0 }
            let saved = try document(directory).items.first!
            check(handled == 2 && saved.state == .completed && saved.attempts == 2, "native-session steps continue automatically and finish durably without another chat turn or Pass")
            check(runner.pendingResults.first?.resultID == saved.resultID && saved.resultID != nil, "only the physically saved native-session completion enters the durable result outbox")
            check(pool.transports.count == 2 && pool.transports[1].receivedIdentity?.id == pool.transports[0].identity?.id, "separate runner steps retain only their own confirmed provider session")
            try await runner.shutdown()
        }
        do {
            let s = scope(), directory = try directory(), pool = SessionPool(), holder = SessionHolder()
            let send = SessionLatch(), stop = SessionLatch()
            var handled = 0, captured: BackgroundWorkContext?
            pool.configure = { transport, _ in transport.sendGate = send; transport.stopGate = stop; transport.stopTerminal = false }
            let storage = try await BackgroundWorkStorageSession.open(directory: directory, projectID: s.projectID, conversationID: s.conversationID)
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { ctx in
                guard let session = holder.value else { throw BackgroundWorkError.unavailable }
                return try await session.execute(ctx)
            })
            let id = try await runner.enqueue(scope: s, title: "Stop held native session", limits: limits)
            holder.value = try adapter(runner.item(id)!, pool, prepare: { ctx, _ in
                captured = ctx; return .init(prompt: "Synthetic background task", capabilities: "Current private host capabilities")
            }, handle: { _, _ in handled += 1; return .outcome(.completed(checkpoint: "Late", summary: "Must not publish")) })
            _ = try await runner.start(id, permit: .init(scope: s, limits: limits))
            try await wait { send.entered }
            let foreground = SessionTransport(); foreground.autoReply = "Synthetic foreground answer"
            var events: [[String: Any]] = []
            let room = NativeRoom(emit: { events.append($0) }, factory: { _, _ in foreground })
            defer { room.close() }
            await room.dispatch(["action": "connect", "conversationID": s.conversationID.uuidString.lowercased(), "participants": ["eve"], "projectFolders": [[String: String]]()])
            try await wait { events.contains { $0["type"] as? String == "ready" } }
            let request = UUID().uuidString
            await room.dispatch(["action": "send", "requestId": request, "text": "Synthetic foreground chat", "targets": ["eve"], "history": [[String: String]](), "historyTotal": 0])
            try await wait { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == request } }
            check(runner.activeWorkerCount == 1 && foreground.closeCalls == 0, "real NativeRoom foreground chat settles while an independent background provider acknowledgement is held")
            check(runner.requestCancel(id) && captured?.mayPerformOperation() == false, "runner Stop synchronously invalidates the native-session broker fence")
            let cancelled = try await runner.cancel(id)
            try await wait { stop.entered }
            let saved = try document(directory).items.first!
            check(cancelled && saved.state == .cancelled && saved.pendingStepID != nil, "durable Stop retains the exact uncertain native step while the provider is still physically stopping")
            check(runner.activeWorkerCount == 1 && runner.pendingResults.isEmpty, "a held native provider retains its worker slot and cannot publish early output")
            send.release(); try await settle()
            check(runner.activeWorkerCount == 1, "returning the original send cannot release ownership before provider Stop returns")
            stop.release()
            try await wait { holder.value?.needsProviderIdleConfirmation == true }
            check(runner.activeWorkerCount == 1 && runner.item(id)?.state == .cancelled, "returned send and Stop acknowledgements still retain the actual runner slot until a provider terminal")
            pool.transports[0].answer("Late synthetic completion after acknowledged Stop")
            try await wait { runner.activeWorkerCount == 0 }
            check(handled == 0 && runner.item(id)?.state == .cancelled && runner.pendingResults.isEmpty, "late native completion cannot enter host handling, resurrect a stopped job or leak a result")
            check(foreground.closeCalls == 0 && foreground.stopCalls == 0, "background cancellation leaves the unrelated foreground provider untouched")
            try await runner.shutdown()
        }
        print("BackgroundAgentSessionTests: \(passed) passed, \(failed) failed; injected synthetic native transports and isolated checkpoint files only")
        if failed > 0 { exit(1) }
    }
}
