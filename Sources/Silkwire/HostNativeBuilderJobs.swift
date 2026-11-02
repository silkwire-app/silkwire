import Foundation

/// Host-approved command plan for the actual non-UI NativeBuilder path. This is
/// runtime input, never decoded from an agent's request or a saved job as a grant.
struct HostNativeBuildPlan {
    let source: URL
    let build: String
    let test: String
    let edit: Bool
}

/// Production execution adapter: starts the real isolated Builder engine beneath
/// the runner's inherited physical admission. Plan/permission/evidence providers
/// belong to the application host. No chat identity or observer is captured.
@MainActor final class HostNativeBuilderJobs {
    typealias Plan = (BackgroundWorkContext) async throws -> HostNativeBuildPlan
    typealias VerifyExit = HostExitVerifier
    private let coordinator: HostExecutionCoordinator
    private let storageRoot: URL
    private let plan: Plan
    private let verifyExit: VerifyExit
    private var engines: [UUID: NativeBuilder] = [:]
    private var receipts: [UUID: [String: Any]] = [:]
    init(coordinator: HostExecutionCoordinator, storageRoot: URL,
         plan: @escaping Plan, verifyExit: @escaping VerifyExit) {
        self.coordinator = coordinator; self.storageRoot = storageRoot
        self.plan = plan; self.verifyExit = verifyExit
    }
    func execute(_ context: BackgroundWorkContext) async throws -> BackgroundWorkStep {
        guard context.mayPerformOperation(), HostExecutionScope.admission != nil else { throw BackgroundWorkError.unavailable }
        let approved = try await plan(context)
        guard context.mayPerformOperation() else { throw CancellationError() }
        let id = context.item.id
        guard engines[id] == nil else { throw BackgroundWorkError.busy }
        let engine = NativeBuilder(onReceipt: { [self] in receipts[id] = $0 }, storageRoot: storageRoot,
            ownership: coordinator, conversationID: context.item.scope.conversationID,
            authorizeSource: { [plan, coordinator] source in
                guard context.mayPerformOperation() else { throw CancellationError() }
                let fresh = try await plan(context)
                guard try await coordinator.storage.sameExecutionRoot(fresh.source, source), fresh.build == approved.build, fresh.test == approved.test, fresh.edit == approved.edit else { throw HostExecutionCoordinator.Failure.permissionChanged }
                guard context.mayPerformOperation() else { throw CancellationError() }
                return .init(executionRoot: source, conflictRoot: source)
            }, verifyPhysicalExit: verifyExit, jobID: id, expectedSourceRevision: context.item.scope.sourceRevision)
        engines[id] = engine
        await engine.start(source: approved.source, task: context.item.title, build: approved.build, test: approved.test, edit: approved.edit)
        guard let receipt = receipts[id], receipt["physicalExitUnconfirmed"] as? Bool != true else { throw HostExecutionCoordinator.Failure.physicalExitUnconfirmed }
        guard context.mayPerformOperation() else { throw CancellationError() }
        guard receipt["status"] as? String == "review" else { throw BackgroundWorkError.reconciliationRequired }
        return .completed(checkpoint: "Native Builder receipt " + (receipt["id"] as? String ?? ""), summary: receipt["message"] as? String ?? "Private build finished; review its durable receipt.")
    }
    func cancel(_ id: UUID) { engines[id]?.stop() }
    func join(_ context: BackgroundWorkContext) async -> HostPhysicalExit {
        // execute() awaits NativeBuilder's complete local finalization. The host
        // verifier still independently establishes all descendant/remote exit.
        guard let request = engines[context.item.id]?.physicalExitRequest,
              request.jobID == context.item.id, request.identity.operationID == context.stepID else {
            return .unconfirmed(reason: "Missing or mismatched job/workspace execution-attempt evidence.")
        }
        let exit = await verifyExit(request)
        engines.removeValue(forKey: context.item.id); receipts.removeValue(forKey: context.item.id)
        return exit
    }
}

/// Dedicated BackgroundAgentSession caller for applications that use model-driven
/// host brokers. Its Handle callback inherits D2 admission and fresh operation fences.
@MainActor final class HostBackgroundAgentJobs {
    private let factory: NativeRoom.Factory
    private let prepare: BackgroundAgentSession.Prepare
    private let handle: BackgroundAgentSession.Handle
    private let verifyExit: HostBackgroundExecution.Join
    private let forbiddenIDs: Set<String>
    private var sessions: [UUID: BackgroundAgentSession] = [:]
    init(factory: @escaping NativeRoom.Factory, forbiddenForegroundProviderIDs: Set<String>,
         prepare: @escaping BackgroundAgentSession.Prepare, handle: @escaping BackgroundAgentSession.Handle,
         verifyExit: @escaping HostBackgroundExecution.Join) {
        self.factory = factory; forbiddenIDs = forbiddenForegroundProviderIDs
        self.prepare = prepare; self.handle = handle; self.verifyExit = verifyExit
    }
    func execute(_ context: BackgroundWorkContext) async throws -> BackgroundWorkStep {
        guard context.mayPerformOperation(), HostExecutionScope.admission != nil else { throw BackgroundWorkError.unavailable }
        let session: BackgroundAgentSession
        if let existing = sessions[context.item.id] { session = existing }
        else {
            session = try BackgroundAgentSession(item: context.item, forbiddenProviderIDs: forbiddenIDs, factory: factory, prepare: prepare, handle: handle)
            sessions[context.item.id] = session
        }
        return try await session.execute(context)
    }
    func cancel(_ id: UUID) { sessions[id]?.invalidate() }
    func join(_ context: BackgroundWorkContext) async -> HostPhysicalExit {
        let exit = await verifyExit(context)
        // Dedicated session identities are never rebound to a foreground room.
        if exit.permitsRelease { sessions.removeValue(forKey: context.item.id) }
        return exit
    }
}
