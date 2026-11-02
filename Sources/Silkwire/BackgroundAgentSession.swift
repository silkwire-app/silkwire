import Foundation

/// Native provider-session boundary for BackgroundWorkRunner.Execute. Runtime host
/// closures supply fresh capabilities/prompt assembly and interpret/broker replies.
/// There is deliberately no default broker, provider factory, live path or saved
/// foreground identity. Constructing this adapter connects or sends nothing.
@MainActor final class BackgroundAgentSession {
    struct Input {
        let prompt: String
        let capabilities: String
    }
    enum Reply {
        case followUp(String) // Host-produced receipt/context, never a new grant.
        case outcome(BackgroundWorkStep)
    }
    typealias Factory = NativeRoom.Factory
    typealias Prepare = (BackgroundWorkContext, String?) async throws -> Input
    // The reply is UNTRUSTED text. A real host implementation must use the actual
    // broker, fresh grants and context.mayPerformOperation before EVERY operation,
    // including after awaits. A model's summary is not evidence of verified work.
    typealias Handle = (String, BackgroundWorkContext) async throws -> Reply

    private final class Response {
        var text = ""
        var result: Result<String, Error>?
        var waiter: CheckedContinuation<String, Error>?
        private var idleConfirmed = false
        private var idleWaiter: CheckedContinuation<Void, Never>?
        private(set) var awaitingIdle = false
        func confirmIdle() {
            idleConfirmed = true; awaitingIdle = false
            let old = idleWaiter; idleWaiter = nil; old?.resume()
        }
        func awaitIdle() async {
            guard !idleConfirmed else { return }
            awaitingIdle = true
            await withCheckedContinuation { idleWaiter = $0 }
        }
        func finish(_ result: Result<String, Error>) {
            guard self.result == nil else { return }
            self.result = result
            let old = waiter; waiter = nil
            old?.resume(with: result)
        }
        func value() async throws -> String {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
    }
    private final class Active {
        let original: BackgroundWorkContext
        var transport: (any NativeAgentTransport)?
        var response: Response?
        var connecting = false
        var submitted = false
        var cancelled = false
        var stopTask: Task<Void, Error>?
        init(_ context: BackgroundWorkContext) { original = context }
    }
    private let itemID: UUID
    private let scope: BackgroundWorkScope
    private let sessionID: UUID
    private let factory: Factory
    private let prepare: Prepare
    private let handle: Handle
    private let forbiddenProviderIDs: Set<String>
    private let maximumExchanges: Int
    private var identity: ProviderIdentity?
    private var active: Active?
    private(set) var closed = false
    var busy: Bool { active != nil }
    static let maximumReplyBytes = 65_536

    init(item: BackgroundWorkItem, maximumExchanges: Int = 8,
         forbiddenProviderIDs: Set<String> = [], factory: @escaping Factory,
         prepare: @escaping Prepare, handle: @escaping Handle) throws {
        try BackgroundWorkEngine.validateSnapshot(BackgroundWorkSnapshot(version: 1, items: [item]))
        guard (1...32).contains(maximumExchanges), agents.contains(item.scope.agentID) else { throw BackgroundWorkError.invalidInput }
        itemID = item.id; scope = item.scope; sessionID = item.sessionID
        self.maximumExchanges = maximumExchanges; self.forbiddenProviderIDs = forbiddenProviderIDs
        self.factory = factory; self.prepare = prepare; self.handle = handle
    }
    func execute(_ context: BackgroundWorkContext) async throws -> BackgroundWorkStep {
        try Task.checkCancellation()
        try BackgroundWorkEngine.validateSnapshot(BackgroundWorkSnapshot(version: 1, items: [context.item]))
        guard !closed, active == nil, context.item.id == itemID, context.item.scope == scope,
              context.item.sessionID == sessionID, context.item.state == .running,
              context.item.pendingStepID == context.stepID, context.mayPerformOperation() else {
            throw BackgroundWorkError.unavailable
        }
        let run = Active(context); active = run
        // Session invalidation also fences the host's broker callback immediately,
        // even before the runner's separate durable Stop has finished saving.
        let scoped = BackgroundWorkContext(item: context.item, stepID: context.stepID, mayPerformOperation: { [weak self, weak run] in
            guard let self, let run else { return false }
            return self.current(run)
        })
        defer { if active === run { active = nil } }
        return try await withTaskCancellationHandler {
            do {
                var followUp: String?
                for _ in 0..<maximumExchanges {
                    try check(run)
                    let input = try await prepare(scoped, followUp)
                    try check(run)
                    guard !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          input.prompt.utf16.count <= 24_000,
                          input.prompt.utf16.count + input.capabilities.utf16.count <= 32_000 else { throw BackgroundWorkError.capacity }
                    let text = try await exchange(input, run: run)
                    try check(run)
                    let reply = try await handle(text, scoped)
                    try check(run)
                    switch reply {
                    case .outcome(let outcome): return outcome
                    case .followUp(let value):
                        guard !value.isEmpty, value.utf16.count <= 24_000 else { throw BackgroundWorkError.capacity }
                        followUp = value
                    }
                }
                throw nativeFailure("Background session reached its bounded host-exchange limit; nothing was automatically replayed.")
            } catch {
                // Any uncertain exchange requires host reconciliation, not an
                // automatic retry using a possibly still-active provider identity.
                closed = true; identity = nil
                // Do not release the runner's physical slot while a real send,
                // connection or Stop acknowledgement is still unwinding.
                cancel(run)
                var stopUnconfirmed = false
                if let stop = run.stopTask {
                    do { try await stop.value }
                    catch { stopUnconfirmed = true }
                }
                // Native Codex/Claude stop() may return after requesting an
                // interruption, BEFORE the provider has actually terminated.
                // Keep the worker/workspace until a confirmed terminal event,
                // or independent runtime-host confirmation of physical idleness.
                if run.submitted, let response = run.response { await response.awaitIdle() }
                retire(run)
                if stopUnconfirmed { throw nativeFailure("Background provider Stop is unconfirmed; host reconciliation is required.") }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self, weak run] in
                if let self, let run { self.cancel(run) }
            }
        }
    }
    /// Runtime host revocation/close: synchronous operation fence, not a durable
    /// job cancellation or proof that a provider has acknowledged Stop.
    func invalidate() {
        closed = true; identity = nil
        if let active { cancel(active) }
    }
    var needsProviderIdleConfirmation: Bool { active?.response?.awaitingIdle == true }
    /// Runtime-host input ONLY, after independently verifying that the exact
    /// provider request/process is no longer active. Never infer this from a
    /// model reply, Stop acknowledgement, timeout, disconnect or task cancellation.
    /// This releases physical ownership, NOT a durable task reconciliation.
    @discardableResult func confirmProviderIdleAfterHostReconciliation(itemID: UUID, stepID: UUID) -> Bool {
        guard let active, active.cancelled, active.submitted,
              active.original.item.id == itemID, active.original.stepID == stepID,
              let response = active.response, response.awaitingIdle else { return false }
        response.confirmIdle()
        return true
    }
    private func current(_ run: Active) -> Bool {
        !closed && active === run && !run.cancelled && run.original.mayPerformOperation()
    }
    private func check(_ run: Active) throws {
        guard current(run), !Task.isCancelled else { throw CancellationError() }
    }
    private func validIdentity(_ value: ProviderIdentity) -> Bool {
        !value.id.isEmpty && value.id.utf8.count <= 1024 && !forbiddenProviderIDs.contains(value.id)
    }
    private func exchange(_ input: Input, run: Active) async throws -> String {
        try check(run)
        // A fresh transport object for each exchange prevents late callbacks from
        // a previous request from being rebound to the next one. Only this
        // adapter's own private identity may be resumed, never a chat identity.
        let transport = factory(scope.agentID, sessionID.uuidString.lowercased())
        guard transport.identity == nil else { throw nativeFailure("Background work requires a fresh, unconnected provider transport.") }
        let response = Response()
        run.transport = transport; run.response = response; run.connecting = true; run.submitted = false; run.stopTask = nil
        transport.eventHandler = { [weak self, weak run, weak response] event in
            guard let self, let run, let response, self.active === run, run.response === response else { return }
            self.receive(event, run: run, response: response)
        }
        let saved = identity
        let connected = try await transport.connect(saved, capabilities: input.capabilities)
        run.connecting = false
        try check(run)
        guard validIdentity(connected), saved == nil || saved?.id == connected.id else {
            throw nativeFailure("Background provider identity is invalid, changed, or belongs to a foreground session.")
        }
        // No await between the last operation fence and submitting this request.
        try check(run); run.submitted = true
        try await transport.send(text: input.prompt, requestID: UUID().uuidString.lowercased(), attachments: [], capabilities: input.capabilities)
        // send() is only an acknowledgement, not a terminal reply. Conversely a
        // terminal event before send() returns cannot release this physical slot.
        try check(run)
        let text = try await response.value()
        try check(run)
        let latest = transport.identity ?? connected
        guard validIdentity(latest), latest.id == connected.id else {
            throw nativeFailure("Background provider changed its session identity unexpectedly.")
        }
        // Only a confirmed terminal reply AND acknowledgement may produce a
        // reusable identity. Do not carry stale run/request/turn recovery tokens
        // into a later connection, or mark a used Claude/Codex session unstarted.
        identity = ProviderIdentity(id: latest.id, started: true, model: latest.model)
        retire(run)
        return text
    }
    private func receive(_ event: NativeAgentEvent, run: Active, response: Response) {
        // Terminal ownership evidence must still arrive after cancellation. It
        // cannot publish text or revive execution, but an interrupt request's
        // acknowledgement alone is not proof the native provider is idle.
        if run.submitted, case .finished(let status, _) = event,
           status == "completed" || status == "interrupted" { response.confirmIdle() }
        guard current(run) else { cancel(run); return }
        guard response.result == nil else { return }
        switch event {
        case .delta, .replace, .finished:
            guard run.submitted else {
                response.finish(.failure(nativeFailure("Unexpected background reply before dispatch; nothing was replayed.")))
                cancel(run); return
            }
        default: break
        }
        switch event {
        case .delta(let text):
            guard text.utf8.count <= Self.maximumReplyBytes - response.text.utf8.count else {
                response.finish(.failure(BackgroundWorkError.capacity)); cancel(run); return
            }
            response.text += text
        case .replace(let text):
            guard text.utf8.count <= Self.maximumReplyBytes else {
                response.finish(.failure(BackgroundWorkError.capacity)); cancel(run); return
            }
            response.text = text
        case .finished(let status, _):
            if status == "completed" { response.finish(.success(response.text)) }
            else { response.finish(.failure(nativeFailure("Background provider ended with \(status); host reconciliation is required."))) }
        case .disconnected:
            response.finish(.failure(nativeFailure("Background provider disconnected; its outcome is unconfirmed.")))
            cancel(run)
        case .recovery:
            response.finish(.failure(nativeFailure("Background recovery needs independent host reconciliation; nothing was replayed.")))
            cancel(run)
        case .identity, .activity: break // Not authority or a terminal result.
        }
    }
    private func cancel(_ run: Active) {
        guard active === run else { return }
        run.cancelled = true
        run.response?.finish(.failure(CancellationError()))
        guard let transport = run.transport else { return }
        if run.connecting { transport.close(); return }
        guard run.submitted, run.stopTask == nil else { return }
        // Unstructured so caller cancellation cannot pretend Stop has returned;
        // execute() always awaits this actual outcome before releasing ownership.
        run.stopTask = Task { try await transport.stop() }
    }
    private func retire(_ run: Active) {
        run.transport?.eventHandler = nil; run.transport?.close()
        run.transport = nil; run.response = nil; run.connecting = false; run.submitted = false
    }
}
