import Foundation

/// Host evidence, never a provider reply, Stop ACK, PID test or elapsed timeout.
/// Strict verification covers the whole executor. The separate privateCleanup
/// case carries the approved sandboxed private-work policy and exact identity.
enum HostPhysicalExit: Sendable, Equatable {
    case verified(evidence: String)
    case privateCleanup(HostPrivateCleanupResult)
    var permitsRelease: Bool { if case .unconfirmed = self { return false }; return true }
    case unconfirmed(reason: String)
}

/// Compatibility name: the subject now includes the runtime evidence and attempt identity.
typealias HostExitSubject = HostExitRequest

/// Runtime host input. Resolving a UUID or accepting an agent path is not a grant.
struct HostAuthorizedWorkspace: Sendable, Equatable {
    let executionRoot: URL
    let conflictRoot: URL
}

/// All synchronous registry I/O executes on this actor, outside MainActor.
actor HostOwnershipStorage {
    let directory: URL
    private var value: PhysicalWorkOwnership?
    /// Independent private workspaces run side by side (e.g. three teammates plus one
    /// background job); the registry still refuses two operations on the same or
    /// overlapping workspace, and exclusive operations wait for, and block, all of them.
    static let capacity = 4
    init(directory: URL) { self.directory = directory }
    private func registry() throws -> PhysicalWorkOwnership {
        if let value { return value }
        // Provision only a host-selected location. Existing permissions are never repaired.
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let result = try PhysicalWorkOwnership(directory: directory, capacity: Self.capacity)
        value = result; return result
    }
    func claimJob(_ id: UUID, fingerprint: String) throws -> Bool { try registry().claimHostJob(operationID: id, fingerprint: fingerprint) }
    func reserve(_ workspace: HostAuthorizedWorkspace, owner: PhysicalWorkOwnership.Owner, operationID: UUID) throws -> PhysicalWorkOwnership.Lease {
        let value = try registry()
        try value.registerHostAlias(workspace.executionRoot, conflictRoot: workspace.conflictRoot)
        return try value.reserve(workspace: workspace.executionRoot, owner: owner, operationID: operationID)
    }
    func reserveExclusive(resource: URL, owner: PhysicalWorkOwnership.Owner, operationID: UUID) throws -> PhysicalWorkOwnership.ExclusiveReservation {
        try registry().reserveExclusive(resource: resource, owner: owner, operationID: operationID)
    }
    func withdrawExclusive(_ operationID: UUID) throws { try registry().withdrawExclusive(operationID: operationID) }
    func admissionState() throws -> PhysicalWorkOwnership.AdmissionState { try registry().admissionState() }
    func alias(_ alias: URL, source: URL) throws { try registry().registerHostAlias(alias, conflictRoot: source) }
    func begin(_ lease: PhysicalWorkOwnership.Lease) throws { try registry().beginExecution(lease) }
    func stop(_ lease: PhysicalWorkOwnership.Lease) throws { try registry().requestStop(lease) }
    func abandon(_ lease: PhysicalWorkOwnership.Lease) throws { try registry().abandonBeforeExecution(lease) }
    func finish(_ lease: PhysicalWorkOwnership.Lease, exit: HostPhysicalExit) throws {
        switch exit {
        case .verified(let evidence): try registry().finishAfterPhysicalExit(lease, evidence: evidence)
        case .privateCleanup(let result):
            guard let record = try registry().snapshot().first(where: { $0.operationID == lease.operationID }), !record.owner.kind.isExclusive, HostExecutionIdentity(record) == result.identity else { throw PhysicalWorkOwnership.Failure.invalidInput }
            try registry().finishAfterPhysicalExit(lease, evidence: result.evidence)
        case .unconfirmed(let reason): try registry().markUncertain(lease, evidence: reason)
        }
    }
    func sameExecutionRoot(_ first: URL, _ second: URL) throws -> Bool {
        try PhysicalWorkOwnership.Workspace.canonical(first) == PhysicalWorkOwnership.Workspace.canonical(second)
    }
    func sameConflictRoot(_ workspace: URL, _ source: URL) throws -> Bool {
        try registry().hostConflictRoot(workspace) == registry().hostConflictRoot(source)
    }
    func snapshot() throws -> [PhysicalWorkOwnership.Record] { try registry().snapshot() }
    /// Privileged evidence seam for the recovery lane. No replay or logical reconciliation.
    func reconcile(_ record: PhysicalWorkOwnership.Record, evidence: String) throws {
        try registry().reconcileAfterPhysicalExit(record, evidence: evidence)
    }
}

@MainActor final class HostExecutionAdmission {
    let operationID: UUID
    let kind: PhysicalWorkOwnership.Kind
    let conversationID: UUID
    let workspace: HostAuthorizedWorkspace
    fileprivate let lease: PhysicalWorkOwnership.Lease
    let coordinator: HostExecutionCoordinator
    let physicalEvidence: HostLocalExecutionEvidence
    private(set) var fenced = false
    fileprivate var stopTask: Task<Void, Error>?
    fileprivate var retired = false
    fileprivate(set) var finishing = false
    fileprivate var localJoinComplete = false
    private var securityScopes: [URL] = []
    func retainSecurityScope(_ root: URL) {
        if root.startAccessingSecurityScopedResource() { securityScopes.append(root) }
    }
    fileprivate func releaseSecurityScopes() {
        for root in securityScopes { root.stopAccessingSecurityScopedResource() }; securityScopes.removeAll()
    }
    private(set) var sequentialChild = false
    private(set) var childExitUnconfirmed = false
    private var childExitReason: String?
    func beginSequentialChild() throws {
        try check(); guard !sequentialChild else { throw HostExecutionCoordinator.Failure.queueFull }; sequentialChild = true
    }
    func endSequentialChild(exit: HostPhysicalExit) {
        sequentialChild = false
        if case .unconfirmed(let reason) = exit { childExitUnconfirmed = true; childExitReason = reason; fence() }
    }
    fileprivate var unresolvedChildReason: String { childExitReason ?? "host: nested executor exit unconfirmed" }
    fileprivate init(operationID: UUID, workspace: HostAuthorizedWorkspace, lease: PhysicalWorkOwnership.Lease, coordinator: HostExecutionCoordinator, record: PhysicalWorkOwnership.Record) {
        self.operationID = operationID; self.kind = record.owner.kind; self.conversationID = record.owner.conversationID
        self.workspace = workspace; self.lease = lease; self.coordinator = coordinator
        physicalEvidence = HostLocalExecutionEvidence(identity: .init(record), directory: coordinator.storage.directory, executionRoot: workspace.executionRoot)
    }
    func fence() { fenced = true }
    func check() throws { guard !fenced, !retired, !Task.isCancelled else { throw CancellationError() } }
    /// Call after creation, before publishing a private worktree to any caller.
    func registerPrivateAlias(_ root: URL) async throws {
        try check(); try await coordinator.storage.alias(root, source: workspace.conflictRoot); try check()
    }
}

enum HostExecutionScope {
    /// Sequential nested work inherits this runtime capability. Never encoded in agent input.
    @TaskLocal static var admission: HostExecutionAdmission?
}

/// Process-lifetime owner. No observer/deinit/timeout release; one durable slot across hosts.
@MainActor final class HostExecutionCoordinator {
    enum Failure: Error { case queueFull, permissionChanged, physicalExitUnconfirmed, foreignAdmission }
    // Deliberately independent of library, profile, conversation and workspace IDs.
    static let application = HostExecutionCoordinator(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Silkwire Host Ownership"))
    let storage: HostOwnershipStorage
    private var admitted: [UUID: HostExecutionAdmission] = [:]
    private var uncertain: [UUID: HostExecutionAdmission] = [:]
    private var waiting = 0
    static let maximumWaiting = 64
    init(directory: URL) { storage = HostOwnershipStorage(directory: directory) }
    var activeOperationIDs: Set<UUID> { Set(admitted.keys) }
    func hasOutstandingLocalJoin(_ id: UUID) -> Bool {
        admitted[id].map { !$0.localJoinComplete } ?? false
    }

    /// Pending operation identity MUST already be durable in the caller's ledger.
    /// Authorization runs again after every admission await and immediately before dispatch.
    /// Private workspace work only. `wait: false` refuses at once (with the registry's
    /// reason: limitReached, workspaceBusy, exclusiveHeld, exclusivePending) instead of
    /// waiting, for callers such as a teammate's begin that must not wait inside a turn.
    func admit(operationID: UUID, conversationID: UUID, kind: PhysicalWorkOwnership.Kind,
               authorize: @escaping @MainActor () async throws -> HostAuthorizedWorkspace,
               mayOperate: @escaping @MainActor () -> Bool, wait: Bool = true) async throws -> HostExecutionAdmission {
        guard !kind.isExclusive else { throw PhysicalWorkOwnership.Failure.invalidInput }
        guard waiting < Self.maximumWaiting else { throw Failure.queueFull }
        waiting += 1; defer { waiting -= 1 }
        var lockRetries = 0
        while true {
            try Task.checkCancellation()
            guard mayOperate() else { throw CancellationError() }
            let workspace = try await authorize()
            guard mayOperate(), !Task.isCancelled else { throw CancellationError() }
            let lease: PhysicalWorkOwnership.Lease
            do {
                lease = try await storage.reserve(workspace, owner: .init(conversationID: conversationID, kind: kind), operationID: operationID)
            } catch let failure as PhysicalWorkOwnership.Failure where Self.retryable.contains(failure) {
                // A held lock is momentary; only the registry's answer is a refusal.
                if !wait, failure != .registryBusy { throw failure }
                if !wait { lockRetries += 1; guard lockRetries < 200 else { throw failure } }
                try await Task.sleep(for: .milliseconds(25)); continue
            }
            guard let record = try await storage.snapshot().first(where: { $0.operationID == operationID }) else { throw Failure.foreignAdmission }
            let admission = HostExecutionAdmission(operationID: operationID, workspace: workspace, lease: lease, coordinator: self, record: record)
            admitted[operationID] = admission // Retain through every subsequent await and teardown.
            do {
                let fresh = try await authorize()
                guard fresh == workspace, mayOperate(), !Task.isCancelled else { throw Failure.permissionChanged }
            } catch {
                admission.fence(); admission.localJoinComplete = true
                // No physical dispatch has happened. A failed abandon still retains disk ownership.
                do { try await storage.abandon(lease); admitted.removeValue(forKey: operationID) } catch { throw error }
                throw error
            }
            do { try await storage.begin(lease) }
            catch {
                admission.fence(); admission.localJoinComplete = true
                // begin may have committed before reporting I/O failure. Never guess that it did not.
                throw error
            }
            // Stop during begin persistence cannot dispatch work after its fence.
            guard mayOperate(), !Task.isCancelled else {
                admission.fence()
                try await finish(admission, exit: .verified(evidence: "host: begin committed, dispatch fenced; no executor created"))
                throw CancellationError()
            }
            do {
                guard try await authorize() == workspace, mayOperate(), !Task.isCancelled else { throw Failure.permissionChanged }
            } catch {
                admission.fence()
                try await finish(admission, exit: .verified(evidence: "host: authorization refused before dispatch; no executor created"))
                throw error
            }
            return admission
        }
    }
    private static let retryable: [PhysicalWorkOwnership.Failure] = [.limitReached, .workspaceBusy, .registryBusy, .exclusiveHeld, .exclusivePending]

    /// Exclusive work on shared, machine-wide resources (see docs/safe-parallel-ownership.md).
    /// Queues durably at once, so no NEW private work is admitted from this call on; waits
    /// until every held record (including uncertain ones) is gone; then holds the registry
    /// alone until `finish`. Cancellation or `mayOperate() == false` while waiting withdraws
    /// the queue entry. `resource` is the existing directory it touches (diagnostic).
    func admitExclusive(operationID: UUID, requester: UUID, resource: URL,
                        mayOperate: @escaping @MainActor () -> Bool) async throws -> HostExecutionAdmission {
        guard waiting < Self.maximumWaiting else { throw Failure.queueFull }
        waiting += 1; defer { waiting -= 1 }
        let owner = PhysicalWorkOwnership.Owner(conversationID: requester, kind: .exclusiveOperation)
        let lease: PhysicalWorkOwnership.Lease
        do {
            var granted: PhysicalWorkOwnership.Lease?
            while granted == nil {
                try Task.checkCancellation()
                guard mayOperate() else { throw CancellationError() }
                do {
                    if case .admitted(let value) = try await storage.reserveExclusive(resource: resource, owner: owner, operationID: operationID) {
                        granted = value; continue
                    }
                } catch PhysicalWorkOwnership.Failure.registryBusy {}
                try await Task.sleep(for: .milliseconds(25))
            }
            lease = granted!
        } catch {
            // The queue entry holds no physical work; a failed withdraw only delays new
            // admissions until it is pruned (PhysicalWorkOwnership.waiterLifetime).
            try? await storage.withdrawExclusive(operationID)
            throw error
        }
        let workspace = HostAuthorizedWorkspace(executionRoot: resource, conflictRoot: resource)
        guard let record = try await storage.snapshot().first(where: { $0.operationID == operationID }) else { throw Failure.foreignAdmission }
        let admission = HostExecutionAdmission(operationID: operationID, workspace: workspace, lease: lease, coordinator: self, record: record)
        admitted[operationID] = admission
        guard mayOperate(), !Task.isCancelled else {
            admission.fence(); admission.localJoinComplete = true
            do { try await storage.abandon(lease); admitted.removeValue(forKey: operationID) } catch { throw error }
            throw CancellationError()
        }
        do { try await storage.begin(lease) }
        catch { admission.fence(); admission.localJoinComplete = true; throw error }
        guard mayOperate(), !Task.isCancelled else {
            admission.fence()
            try await finish(admission, exit: .verified(evidence: "host: exclusive begin committed, dispatch fenced; nothing ran"))
            throw CancellationError()
        }
        return admission
    }
    /// Current registry state, for refusal messages.
    func admissionState() async throws -> PhysicalWorkOwnership.AdmissionState { try await storage.admissionState() }
    /// Why NEW private work cannot be admitted now, in plain words, or nil if it can
    /// (subject to its own workspace being free).
    static func privateAdmissionRefusal(_ state: PhysicalWorkOwnership.AdmissionState) -> String? {
        if state.exclusiveHeld != nil {
            return "No workspace was created: an exclusive host operation (such as a Staging install) is running, and nothing else may start until it ends."
        }
        if !state.exclusiveWaiters.isEmpty {
            return "No workspace was created: an exclusive host operation (such as a Staging install) is waiting for running work to end, so new work is held back until it has run."
        }
        let held = state.held
        guard held.count >= state.capacity else { return nil }
        if let stuck = held.first(where: { $0.phase == .uncertain }) {
            return "No workspace was created: all \(state.capacity) work places are in use, and at least one is held by earlier work whose processes aren't proved to have exited. " + (stuck.evidence ?? "Independent exit verification is required.") + " Jason can try Release on its job card."
        }
        return "No workspace was created: all \(state.capacity) work places are in use. Begin again when one finishes."
    }
    /// Privileged recovery seam. Exact durable evidence reconciliation also retires
    /// retained security-scope owners; it never resumes a logical job.
    func reconcileAfterPhysicalExit(_ record: PhysicalWorkOwnership.Record, evidence: String) async throws {
        try await storage.reconcile(record, evidence: evidence)
        if let owner = uncertain.removeValue(forKey: record.operationID) ?? admitted.removeValue(forKey: record.operationID) {
            owner.fence(); owner.retired = true; owner.releaseSecurityScopes()
        }
    }
    /// Fences synchronously. Await stop() to observe the durability outcome.
    func requestStop(_ admission: HostExecutionAdmission) {
        guard admission.coordinator === self, !admission.retired else { return }
        admission.fence()
        guard !admission.finishing else { return } // Whole-executor join already returned; no new Stop I/O may race release.
        if admission.stopTask == nil {
            admission.stopTask = Task { [storage] in try await storage.stop(admission.lease) }
        }
    }
    func stop(_ admission: HostExecutionAdmission) async throws {
        requestStop(admission); try await admission.stopTask?.value
    }
    /// The caller has awaited ALL work and Stop tasks, then supplies independent host evidence.
    func finish(_ admission: HostExecutionAdmission, exit: HostPhysicalExit) async throws {
        guard admission.coordinator === self, admitted[admission.operationID] === admission, !admission.retired else { throw Failure.foreignAdmission }
        admission.fence(); admission.finishing = true
        do { try await admission.stopTask?.value }
        catch { admission.localJoinComplete = true; throw error }
        admission.localJoinComplete = true
        let finalExit: HostPhysicalExit = admission.childExitUnconfirmed || admission.sequentialChild ? .unconfirmed(reason: admission.unresolvedChildReason) : exit
        try await storage.finish(admission.lease, exit: finalExit)
        if finalExit.permitsRelease { admission.releaseSecurityScopes() }
        admission.retired = true
        admitted.removeValue(forKey: admission.operationID)
        if case .unconfirmed = finalExit { uncertain[admission.operationID] = admission }
        if case .unconfirmed = finalExit { throw Failure.physicalExitUnconfirmed }
    }
}
