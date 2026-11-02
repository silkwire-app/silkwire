import Foundation

/// The single application-host injection point. It owns no room/Turn/UI object,
/// opens no library and starts no provider. Register each opened host once at
/// library bootstrap; pass router(scope:) into NativeRoom's backgroundJobs argument
/// using the separately supplied room-host-insertion.patch. Never instantiate one
/// registry per room: all registered hosts and foreground Builder use the same D2
/// HostExecutionCoordinator.application (or the same explicitly injected test host).
@MainActor final class BackgroundJobHostInjection {
    static let application = BackgroundJobHostInjection()
    let ownership: HostExecutionCoordinator
    init(ownership: HostExecutionCoordinator? = nil) { self.ownership = ownership ?? .application }
    private var hosts: [UUID: any BackgroundJobHost] = [:]
    func register(_ host: HostBackgroundJobService, originatingConversationID: UUID) throws {
        guard host.physicalCoordinator === ownership else { throw PhysicalWorkOwnership.Failure.configurationMismatch }
        if let existing = hosts[originatingConversationID] {
            guard existing === host else { throw BackgroundWorkError.busy }
            return
        }
        hosts[originatingConversationID] = host // Process lifetime, independent of room selection.
    }
    /// Concrete production bootstrap for real non-UI Builder execution. Its
    /// coordinator is the SAME one foreground Builder receives from this host.
    func openNativeBuilderHost(originatingConversationID: UUID, storage: BackgroundWorkStorageSession,
        builderStorageRoot: URL, authorize: @escaping BackgroundWorkEngine.Authorize,
        resolve: @escaping HostBackgroundExecution.Resolve, plan: @escaping HostNativeBuilderJobs.Plan,
        verifyExit: @escaping HostNativeBuilderJobs.VerifyExit,
        verifyRecovery: @escaping BackgroundJobHostRecovery.Verify) async throws -> any BackgroundJobHost {
        if let existing = hosts[originatingConversationID] { return existing }
        let native = HostNativeBuilderJobs(coordinator: ownership, storageRoot: builderStorageRoot, plan: plan, verifyExit: verifyExit)
        let execution = HostBackgroundExecution(coordinator: ownership, resolve: resolve, cancel: native.cancel, join: native.join)
        let host = try await HostBackgroundJobService.open(storage: storage, execution: execution, verifyRecovery: verifyRecovery, authorize: authorize, execute: native.execute)
        try register(host, originatingConversationID: originatingConversationID)
        return host
    }
    /// The dedicated-session route uses the actual host broker callbacks and
    /// keeps foreground provider IDs forbidden in background transports.
    func openAgentHost(originatingConversationID: UUID, storage: BackgroundWorkStorageSession,
        authorize: @escaping BackgroundWorkEngine.Authorize, resolve: @escaping HostBackgroundExecution.Resolve,
        factory: @escaping NativeRoom.Factory, forbiddenForegroundProviderIDs: Set<String>,
        prepare: @escaping BackgroundAgentSession.Prepare, handle: @escaping BackgroundAgentSession.Handle,
        verifyExit: @escaping HostBackgroundExecution.Join,
        verifyRecovery: @escaping BackgroundJobHostRecovery.Verify) async throws -> any BackgroundJobHost {
        if let existing = hosts[originatingConversationID] { return existing }
        let native = HostBackgroundAgentJobs(factory: factory, forbiddenForegroundProviderIDs: forbiddenForegroundProviderIDs,
            prepare: prepare, handle: handle, verifyExit: verifyExit)
        let execution = HostBackgroundExecution(coordinator: ownership, resolve: resolve, cancel: native.cancel, join: native.join)
        let host = try await HostBackgroundJobService.open(storage: storage, execution: execution, verifyRecovery: verifyRecovery, authorize: authorize, execute: native.execute)
        try register(host, originatingConversationID: originatingConversationID)
        return host
    }
    func host(for originatingConversationID: UUID) throws -> any BackgroundJobHost {
        guard let host = hosts[originatingConversationID] else { throw BackgroundWorkError.unavailable }
        return host
    }
    func router(scope: @escaping HostJobCommandRouter.Scope) -> HostJobCommandRouter {
        HostJobCommandRouter(scope: scope, service: { [self] in try host(for: $0) })
    }
}
