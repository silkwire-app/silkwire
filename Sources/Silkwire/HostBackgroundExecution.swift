import Foundation

/// Connects the actual runner Execute callback to host ownership. All closures
/// are trusted host adapters; the executor must recheck context at every effect.
@MainActor final class HostBackgroundExecution {
    typealias Resolve = (BackgroundWorkScope) async throws -> HostAuthorizedWorkspace
    typealias Join = (BackgroundWorkContext) async -> HostPhysicalExit
    let coordinator: HostExecutionCoordinator
    private let resolve: Resolve
    private let join: Join
    private let cancel: (UUID) -> Void
    private var active: [UUID: HostExecutionAdmission] = [:]
    init(coordinator: HostExecutionCoordinator, resolve: @escaping Resolve,
         cancel: @escaping (UUID) -> Void, join: @escaping Join) {
        self.coordinator = coordinator; self.resolve = resolve; self.cancel = cancel; self.join = join
    }
    func requestStop(_ id: UUID) {
        if let admission = active[id] {
            coordinator.requestStop(admission)
            if !admission.finishing { cancel(id) }
        } else { cancel(id) }
    }
    func stop(_ id: UUID) async throws {
        requestStop(id)
        if let admission = active[id] { try await coordinator.stop(admission) }
    }
    func execute(_ context: BackgroundWorkContext, authorize: @escaping BackgroundWorkEngine.Authorize, dispatch: BackgroundWorkEngine.Execute,
                 willDispatch: () async throws -> Void) async throws -> BackgroundWorkStep {
        let fresh: () async throws -> HostAuthorizedWorkspace = { [resolve] in
            guard context.mayPerformOperation(), await authorize(context.item.scope), context.mayPerformOperation() else { throw HostExecutionCoordinator.Failure.permissionChanged }
            let workspace = try await resolve(context.item.scope)
            guard context.mayPerformOperation(), await authorize(context.item.scope), context.mayPerformOperation() else { throw HostExecutionCoordinator.Failure.permissionChanged }
            return workspace
        }
        let admission = try await coordinator.admit(operationID: context.stepID,
            conversationID: context.item.scope.conversationID, kind: .backgroundJob,
            authorize: fresh, mayOperate: context.mayPerformOperation)
        active[context.item.id] = admission
        defer { active.removeValue(forKey: context.item.id) }
        let fenced = BackgroundWorkContext(item: context.item, stepID: context.stepID, mayPerformOperation: {
            !admission.fenced && context.mayPerformOperation()
        })
        var dispatched = false
        let outcome: Result<BackgroundWorkStep, Error>
        do {
            try await willDispatch() // Durable running revision, before physical effects.
            try admission.check()
            guard fenced.mayPerformOperation() else { throw CancellationError() }
            // Reauthorize after the running checkpoint await, too.
            guard try await fresh() == admission.workspace else { throw HostExecutionCoordinator.Failure.permissionChanged }
            try admission.check()
            guard fenced.mayPerformOperation() else { throw CancellationError() }
            dispatched = true
            outcome = .success(try await HostExecutionScope.$admission.withValue(admission) { try await dispatch(fenced) })
        } catch { outcome = .failure(error) }
        // Cancellation cannot skip joins. The join callback must await the full
        // provider/broker/delegated executor; returning unknown keeps the slot.
        let exit: HostPhysicalExit
        if dispatched { exit = await Task { await self.join(fenced) }.value }
        else { exit = .verified(evidence: "host: dispatch fenced before executor invocation") }
        try await coordinator.finish(admission, exit: exit)
        return try outcome.get()
    }
}
