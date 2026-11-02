import Foundation

/// A Builder Run owns this independently of its UI. A nested sequential builder
/// borrows the admitted executor; it never recursively acquires the sole slot.
@MainActor final class HostBuilderOwnership {
    let coordinator: HostExecutionCoordinator
    let conversationID: UUID
    private let authorize: ((URL) async throws -> HostAuthorizedWorkspace)?
    private let verifyExit: HostExitVerifier?
    private(set) var inherited = false
    private(set) var lastExit: HostPhysicalExit?
    private(set) var admission: HostExecutionAdmission?
    init(coordinator: HostExecutionCoordinator, conversationID: UUID,
         authorize: ((URL) async throws -> HostAuthorizedWorkspace)?,
         verifyExit: HostExitVerifier?) {
        self.coordinator = coordinator; self.conversationID = conversationID
        self.authorize = authorize; self.verifyExit = verifyExit
    }
    func begin(operationID: UUID, source: URL, mayOperate: @escaping () -> Bool) async throws {
        lastExit = nil
        let granted: () async throws -> HostAuthorizedWorkspace = { [authorize] in
            if let authorize { return try await authorize(source) }
            // Direct native callers supply the source, never an agent JSON path.
            // Production grant-bearing callers inject a fresh permission check.
            return HostAuthorizedWorkspace(executionRoot: source, conflictRoot: source)
        }
        if let parent = HostExecutionScope.admission {
            try parent.check()
            let workspace = try await granted()
            guard mayOperate(), try await parent.coordinator.storage.sameConflictRoot(workspace.executionRoot, parent.workspace.conflictRoot) else {
                throw HostExecutionCoordinator.Failure.permissionChanged
            }
            try parent.beginSequentialChild()
            admission = parent; inherited = true
        } else {
            admission = try await coordinator.admit(operationID: operationID, conversationID: conversationID,
                kind: .foregroundBuild, authorize: granted, mayOperate: mayOperate)
        }
        admission?.physicalEvidence.enableLocalTracking()
        admission?.retainSecurityScope(source)
    }
    func adopt(_ value: HostExecutionAdmission, source: URL, inherited: Bool) async throws {
        lastExit = nil
        try value.check()
        // The host's authorization names the admitted workspace this source runs in (for a
        // trusted private workspace, its own private key; the source itself is only read).
        let key = try await authorize?(source).executionRoot ?? source
        try value.check()
        guard try await value.coordinator.storage.sameConflictRoot(key, value.workspace.conflictRoot) else { throw HostExecutionCoordinator.Failure.permissionChanged }
        try value.check()
        if inherited { try value.beginSequentialChild() }
        admission = value; value.physicalEvidence.enableLocalTracking(); self.inherited = inherited; value.retainSecurityScope(source)
    }
    func reauthorize(source: URL) async throws {
        guard let admission else { throw BackgroundWorkError.unavailable }
        try admission.check()
        if let authorize {
            let fresh = try await authorize(source)
            guard try await admission.coordinator.storage.sameConflictRoot(fresh.executionRoot, admission.workspace.conflictRoot) else {
                throw HostExecutionCoordinator.Failure.permissionChanged
            }
            guard try await authorize(source) == fresh else { throw HostExecutionCoordinator.Failure.permissionChanged }
            try admission.check()
        }
    }
    func stop() { if let admission { admission.coordinator.requestStop(admission) } }
    func finish(workspaceID: UUID, jobID: UUID? = nil, joinLocalStop: (() async -> Void)? = nil) async throws {
        guard let admission else { return }
        // Real commands can detach descendants or leave remote work. NativeProcess
        // leader/pipe completion is deliberately NOT upgraded to whole-executor proof.
        await joinLocalStop?()
        let request = HostExitRequest(workspaceID: workspaceID, jobID: jobID, evidence: admission.physicalEvidence, inherited: inherited)
        var exit = await verifyExit?(request) ?? .unconfirmed(reason: "host: Builder whole-executor exit has no independent verifier")
        if case .privateCleanup(let result) = exit,
           result.identity != request.identity || result.workspaceID != request.workspaceID || result.jobID != request.jobID {
            exit = .unconfirmed(reason: "Private cleanup answer does not match this exact execution, workspace and job.")
        }
        lastExit = exit
        if inherited {
            admission.endSequentialChild(exit: exit)
            if case .unconfirmed = exit { throw HostExecutionCoordinator.Failure.physicalExitUnconfirmed }
        } else { try await admission.coordinator.finish(admission, exit: exit) }
        self.admission = nil
    }
}
