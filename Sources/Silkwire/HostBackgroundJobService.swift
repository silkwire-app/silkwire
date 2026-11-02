import Foundation
import CryptoKit

enum HostJobState: String, Codable, Sendable { case queued, running, stopping, completed, failed, needsReview }
struct HostJobRequest: Codable, Sendable {
    let operationID: UUID
    let scope: BackgroundWorkScope
    let workDescription: String // bounded by runner to 240 UTF-8 bytes
    let limits: BackgroundWorkLimits
}
struct HostJobSnapshot: Sendable, Equatable {
    let jobID: UUID
    let originatingConversationID: UUID
    let revision: UInt64
    let state: HostJobState
    let progress: String
    let note: String
    let pendingOperationID: UUID?
    let completionID: UUID?
    let resultID: UUID?
    let resultAcknowledged: Bool
}
struct HostJobStopAcknowledgement: Sendable { let jobID: UUID; let stopRequested: Bool }

/// Production caller adapter around the durable runner. No turn or observer owns
/// execution. Host adapters supply grants, execution and independent join evidence.
@MainActor final class HostBackgroundJobService: BackgroundJobHost {
    var physicalCoordinator: HostExecutionCoordinator { execution.coordinator }
    static let contractVersion = 1
    static let maximumQueuedJobs = 64
    private let recovery: BackgroundJobHostRecovery
    private let runner: BackgroundWorkRunner
    private let execution: HostBackgroundExecution
    private let authorize: BackgroundWorkEngine.Authorize
    private var pump: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<HostJobSnapshot>.Continuation] = [:]
    private var accepting = 0
    private var closed = false
    private init(runner: BackgroundWorkRunner, execution: HostBackgroundExecution, verifyRecovery: @escaping BackgroundJobHostRecovery.Verify, authorize: @escaping BackgroundWorkEngine.Authorize) {
        recovery = BackgroundJobHostRecovery(coordinator: execution.coordinator, verify: verifyRecovery)
        self.runner = runner; self.execution = execution; self.authorize = authorize
        runner.onChange = { [weak self] in self?.changed() }
    }
    static func open(storage: BackgroundWorkStorageSession, execution: HostBackgroundExecution,
                     verifyRecovery: @escaping BackgroundJobHostRecovery.Verify = { _ in .unconfirmed(reason: "No independent host physical-exit verifier is configured; ownership remains held.") },
                     authorize: @escaping BackgroundWorkEngine.Authorize,
                     execute: @escaping BackgroundWorkEngine.Execute) async throws -> HostBackgroundJobService {
        let runner = try await BackgroundWorkRunner.open(storage: storage, maxConcurrent: 1, hostExecution: execution, authorize: authorize, execute: execute)
        // Restored items are paused, never automatically scheduled or replayed.
        return HostBackgroundJobService(runner: runner, execution: execution, verifyRecovery: verifyRecovery, authorize: authorize)
    }
    func submit(_ request: HostJobRequest) async throws -> UUID {
        guard !closed, accepting + runner.snapshot.items.filter({ [.queued, .running].contains($0.state) }).count < Self.maximumQueuedJobs else { throw BackgroundWorkError.busy }
        accepting += 1; defer { accepting -= 1 }
        guard await authorize(request.scope) else { throw HostExecutionCoordinator.Failure.permissionChanged }
        // Pure validation precedes the durable identity claim.
        let validation = BackgroundWorkItem(id: request.operationID, scope: request.scope, sessionID: UUID(), title: request.workDescription, limits: request.limits)
        try BackgroundWorkEngine.validateSnapshot(.init(version: 1, items: [validation]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined()
        let claimed = try await execution.coordinator.storage.claimJob(request.operationID, fingerprint: fingerprint)
        if !claimed {
            guard let existing = runner.item(request.operationID), existing.hostRevision != nil else { throw BackgroundWorkError.reconciliationRequired }
            return existing.id
        }
        let id = try await runner.enqueue(scope: request.scope, title: request.workDescription, limits: request.limits, operationID: request.operationID, hostManaged: true)
        schedule()
        return id // No executor await. Acceptance is the completed durable enqueue.
    }
    func snapshot(_ jobID: UUID) -> HostJobSnapshot? {
        guard let item = runner.item(jobID), let revision = item.hostRevision else { return nil }
        return HostJobSnapshot(jobID: item.id, originatingConversationID: item.scope.conversationID,
            revision: revision, state: item.hostState ?? .needsReview, progress: item.checkpoint, note: item.note,
            pendingOperationID: item.pendingStepID, completionID: item.hostCompletionID,
            resultID: item.resultID, resultAcknowledged: item.resultAcknowledged)
    }
    /// Bounded per-observer buffers; revision gaps tell an adapter to refresh snapshot.
    /// Termination merely removes the observer. It cannot stop work.
    func events() -> AsyncStream<HostJobSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            observers[id] = continuation
            for item in runner.snapshot.items { if let value = snapshot(item.id) { continuation.yield(value) } }
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers.removeValue(forKey: id) } }
        }
    }
    func requestStop(_ id: UUID) { _ = runner.requestCancel(id) }
    func stop(_ id: UUID) async throws -> HostJobStopAcknowledgement {
        requestStop(id)
        let stopped = try await runner.cancel(id)
        return HostJobStopAcknowledgement(jobID: id, stopRequested: stopped || runner.stopRequested(id))
    }
    var pendingResults: [BackgroundWorkItem] { runner.pendingResults }
    func acknowledgeResult(_ id: UUID, resultID: UUID) async throws -> Bool {
        try await runner.acknowledgeResult(id, resultID: resultID)
    }
    func heldPhysicalOperations() async throws -> [HostHeldPhysicalOperation] { try await recovery.held() }
    func checkPhysicalExit(operationID: UUID) async throws -> HostPhysicalExitCheck { try await recovery.check(operationID: operationID) }
    func reconcilePhysicalExit(_ check: HostPhysicalExitCheck) async throws -> HostPhysicalRelease { try await recovery.reconcile(check) }
    func joinLocalExecutors() async { await runner.joinLocalExecutors() }
    func shutdown() async throws {
        closed = true
        // Runner fences all workers but retains their owning tasks until joins end.
        try await runner.shutdown()
        await pump?.value; pump = nil
        for observer in observers.values { observer.finish() }; observers.removeAll()
    }
    private func changed() {
        for item in runner.snapshot.items {
            if let value = snapshot(item.id) { for observer in observers.values { observer.yield(value) } }
        }
    }
    private func schedule() {
        guard pump == nil, !closed else { return }
        pump = Task { @MainActor in
            // This strong host lifetime survives submit return, room switches and observers.
            while !self.closed && !self.runner.storageFailed {
                for item in self.runner.snapshot.items where item.state == .queued {
                    do { _ = try await self.runner.start(item.id, permit: .init(scope: item.scope, limits: item.limits)) }
                    catch { break } // Durable runner failure/hold stays visible, never replayed.
                }
                let pending = self.runner.snapshot.items.contains { $0.state == .queued }
                if !pending && self.runner.activeWorkerCount == 0 { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            self.pump = nil
        }
    }
}
