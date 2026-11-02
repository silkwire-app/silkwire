import Foundation

/// In-memory BackgroundJobHost (contract v1) for tests and synthetic checks. It runs
/// nothing: a test moves each job along. It keeps the contract's shape: durable-style
/// acceptance by operationID, monotonic revisions, one slot, Stop as an immediate
/// fence plus a separate durable acknowledgement, results only via pendingResults
/// until acknowledged, and reopen turning unfinished work into needsReview.
/// Release uses the REAL BackgroundJobHostRecovery over a private D2 registry, so a
/// Release ticket, its fresh re-verification and "retained" reasons are the host's own.
@MainActor final class FakeBackgroundJobHost: BackgroundJobHost {
    struct Job {
        let request: HostJobRequest
        var state: HostJobState = .queued
        var revision: UInt64 = 1
        var progress = ""
        var note = ""
        var pendingOperationID: UUID?
        var completionID: UUID?
        var resultID: UUID?
        var resultAcknowledged = false
        var stopRequested = false
        var stopRecorded = false
    }
    /// The host's durable record across an app restart.
    struct Saved {
        fileprivate let jobs: [UUID: Job]
        fileprivate let order: [UUID]
    }
    private(set) var jobs: [UUID: Job] = [:]
    private(set) var order: [UUID] = []
    private(set) var acknowledgements: [UUID] = []
    private(set) var stopCalls: [UUID] = []
    private var observers: [UUID: AsyncStream<HostJobSnapshot>.Continuation] = [:]
    // Test controls.
    var refuseSubmissions: Error?
    var stopFailure: Error?
    /// Simulates a crash between the room's insert and its acknowledgement.
    var acknowledgementFailure: Error?
    /// When set, submit waits here before its durable acceptance returns.
    var acceptanceGate: (() async -> Void)?
    /// Independent physical-exit evidence for Release (default: unconfirmed).
    var verifier: (PhysicalWorkOwnership.Record) -> HostPhysicalExit = { _ in .unconfirmed(reason: "No independent exit evidence for this synthetic executor.") }

    let coordinator: HostExecutionCoordinator
    private let workspaceRoot: URL
    private var recovery: BackgroundJobHostRecovery!

    /// `ownership`: a private D2 registry directory. `workspace`: any real directory
    /// used as the synthetic held executor's workspace. Both are host-selected paths.
    init(ownership: URL, workspace: URL, restoring saved: Saved? = nil) {
        coordinator = HostExecutionCoordinator(directory: ownership); workspaceRoot = workspace
        if let saved {
            jobs = saved.jobs; order = saved.order
            // Reopen never schedules: unfinished work is needsReview (as the runner does).
            for id in order where [.queued, .running, .stopping].contains(jobs[id]?.state) {
                jobs[id]?.state = .needsReview; jobs[id]?.revision += 1
                jobs[id]?.note = "The app restarted before this job finished; its outcome needs review."
            }
        }
        recovery = BackgroundJobHostRecovery(coordinator: coordinator, verify: { [weak self] record in
            self?.verifier(record) ?? .unconfirmed(reason: "Host closed.")
        })
    }
    var saved: Saved { Saved(jobs: jobs, order: order) }
    func state(_ id: UUID) -> HostJobState? { jobs[id]?.state }
    var requests: [HostJobRequest] { order.compactMap { jobs[$0]?.request } }

    // MARK: BackgroundJobHost
    func submit(_ request: HostJobRequest) async throws -> UUID {
        if let refuseSubmissions { throw refuseSubmissions }
        if let acceptanceGate { await acceptanceGate() }
        if let existing = jobs[request.operationID] {
            // Duplicate identity never replays.
            guard existing.request.scope == request.scope, existing.request.workDescription == request.workDescription else { throw BackgroundWorkError.reconciliationRequired }
            return request.operationID
        }
        guard !request.workDescription.isEmpty, request.workDescription.utf8.count <= 240 else { throw BackgroundWorkError.invalidInput }
        jobs[request.operationID] = Job(request: request)
        order.append(request.operationID)
        publish(request.operationID)
        await startNext()
        return request.operationID
    }
    func snapshot(_ jobID: UUID) -> HostJobSnapshot? {
        guard let job = jobs[jobID] else { return nil }
        return HostJobSnapshot(jobID: jobID, originatingConversationID: job.request.scope.conversationID, revision: job.revision, state: job.state,
                               progress: job.progress, note: job.note, pendingOperationID: job.pendingOperationID, completionID: job.completionID,
                               resultID: job.resultID, resultAcknowledged: job.resultAcknowledged)
    }
    func events() -> AsyncStream<HostJobSnapshot> {
        let key = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            observers[key] = continuation
            for id in order { if let value = snapshot(id) { continuation.yield(value) } }
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers.removeValue(forKey: key) } }
        }
    }
    /// Immediate fence. Work that already started keeps running until the test ends it.
    func requestStop(_ jobID: UUID) {
        guard var job = jobs[jobID], [.queued, .running, .stopping].contains(job.state) else { return }
        job.stopRequested = true
        if job.state == .queued {
            // Never dispatched: a deliberately stopped, undispatched job is terminal failed.
            job.state = .failed; job.note = "Stopped before it started. Nothing ran."; job.completionID = UUID()
        } else { job.state = .stopping }
        job.revision += 1; jobs[jobID] = job; publish(jobID)
    }
    func stop(_ jobID: UUID) async throws -> HostJobStopAcknowledgement {
        stopCalls.append(jobID)
        requestStop(jobID)
        if let stopFailure { throw stopFailure }
        guard jobs[jobID] != nil else { throw BackgroundWorkError.unavailable }
        jobs[jobID]?.stopRecorded = true
        return HostJobStopAcknowledgement(jobID: jobID, stopRequested: jobs[jobID]?.stopRequested == true)
    }
    var pendingResults: [BackgroundWorkItem] {
        order.compactMap { id -> BackgroundWorkItem? in
            guard let job = jobs[id], job.state == .completed, let result = job.resultID, !job.resultAcknowledged, !job.stopRequested else { return nil }
            return BackgroundWorkItem(id: id, scope: job.request.scope, sessionID: UUID(), title: job.request.workDescription, limits: job.request.limits,
                                      state: .completed, attempts: 1, checkpoint: job.progress, note: job.note, resultID: result,
                                      hostRevision: job.revision, hostState: .completed, hostCompletionID: job.completionID)
        }
    }
    func acknowledgeResult(_ jobID: UUID, resultID: UUID) async throws -> Bool {
        if let acknowledgementFailure { throw acknowledgementFailure }
        guard let job = jobs[jobID], job.resultID == resultID, job.state == .completed else { return false }
        acknowledgements.append(resultID)
        if !job.resultAcknowledged { jobs[jobID]?.resultAcknowledged = true; jobs[jobID]?.revision += 1; publish(jobID) }
        return true
    }
    func heldPhysicalOperations() async throws -> [HostHeldPhysicalOperation] { try await recovery.held() }
    func checkPhysicalExit(operationID: UUID) async throws -> HostPhysicalExitCheck { try await recovery.check(operationID: operationID) }
    func reconcilePhysicalExit(_ check: HostPhysicalExitCheck) async throws -> HostPhysicalRelease { try await recovery.reconcile(check) }

    // MARK: Test controls (the "runner")
    func progress(_ id: UUID, _ line: String) {
        guard var job = jobs[id], [.running, .stopping].contains(job.state) else { return }
        job.progress = line; job.revision += 1; jobs[id] = job; publish(id)
    }
    /// The executor returned a result. A stopped job never produces one.
    func complete(_ id: UUID, summary: String) async {
        guard var job = jobs[id], job.state == .running else { return }
        let result = UUID()
        job.state = .completed; job.note = summary; job.resultID = result; job.completionID = result; job.pendingOperationID = nil
        job.revision += 1; jobs[id] = job; publish(id)
        await startNext()
    }
    /// The executor ended after Stop (or failed). `uncertain`: its step outcome is unknown.
    func end(_ id: UUID, note: String, uncertain: Bool = false) async {
        guard var job = jobs[id], [.running, .stopping].contains(job.state) else { return }
        job.state = uncertain ? .needsReview : .failed; job.note = note
        if !uncertain { job.completionID = UUID(); job.pendingOperationID = nil }
        job.revision += 1; jobs[id] = job; publish(id)
        await startNext()
    }
    /// The executor's physical exit couldn't be proved: D2 keeps the slot held for
    /// this job's step, exactly as the real host does after an unconfirmed join.
    func holdPhysically(_ id: UUID) async throws {
        guard let operation = jobs[id]?.pendingOperationID, let room = jobs[id]?.request.scope.conversationID else { throw BackgroundWorkError.unavailable }
        let root = workspaceRoot
        let admission = try await coordinator.admit(operationID: operation, conversationID: room, kind: .backgroundJob,
            authorize: { HostAuthorizedWorkspace(executionRoot: root, conflictRoot: root) }, mayOperate: { true })
        do { try await coordinator.finish(admission, exit: .unconfirmed(reason: "Synthetic executor exit unconfirmed.")) }
        catch HostExecutionCoordinator.Failure.physicalExitUnconfirmed {}
    }
    private func publish(_ id: UUID) {
        guard let value = snapshot(id) else { return }
        for observer in observers.values { observer.yield(value) }
    }
    /// One slot: running/stopping work, or any physical hold, keeps the next job queued.
    private func startNext() async {
        let held = ((try? await coordinator.storage.snapshot()) ?? []).contains(where: \.holdsResources)
        guard !held, !order.contains(where: { [.running, .stopping].contains(jobs[$0]?.state) }),
              let next = order.first(where: { jobs[$0]?.state == .queued }) else { return }
        jobs[next]?.state = .running; jobs[next]?.pendingOperationID = UUID(); jobs[next]?.progress = "Started"; jobs[next]?.revision += 1
        publish(next)
    }
    /// After a Release frees the slot, a test may let queued work start.
    func startQueued() async { await startNext() }
}
