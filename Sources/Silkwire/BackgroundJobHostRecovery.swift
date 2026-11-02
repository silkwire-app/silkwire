import Foundation

/// An unencoded runtime check ticket. Only this recovery owner can issue it;
/// reconciliation validates object identity, exact record and fresh host evidence.
@MainActor final class HostPhysicalExitCheck {
    let operationID: UUID
    let verdict: HostPhysicalExit
    fileprivate let record: PhysicalWorkOwnership.Record
    fileprivate init(record: PhysicalWorkOwnership.Record, verdict: HostPhysicalExit) {
        operationID = record.operationID; self.record = record; self.verdict = verdict
    }
}

@MainActor final class BackgroundJobHostRecovery {
    typealias Verify = (PhysicalWorkOwnership.Record) async -> HostPhysicalExit
    private let coordinator: HostExecutionCoordinator
    private let verify: Verify
    private var issued: [UUID: HostPhysicalExitCheck] = [:]
    init(coordinator: HostExecutionCoordinator, verify: @escaping Verify) {
        self.coordinator = coordinator; self.verify = verify
    }
    func held() async throws -> [HostHeldPhysicalOperation] {
        try await coordinator.storage.snapshot().filter(\.holdsResources).map {
            HostHeldPhysicalOperation(operationID: $0.operationID, originatingConversationID: $0.owner.conversationID,
                kind: $0.owner.kind, phase: $0.phase, stopRequested: $0.stopRequested,
                reason: $0.evidence ?? "Physical executor may still be running; independent exit verification is required.")
        }
    }
    func check(operationID: UUID) async throws -> HostPhysicalExitCheck {
        guard let record = try await coordinator.storage.snapshot().first(where: { $0.operationID == operationID && $0.holdsResources }) else { throw BackgroundWorkError.unavailable }
        let verdict: HostPhysicalExit
        if coordinator.hasOutstandingLocalJoin(operationID) {
            verdict = .unconfirmed(reason: "The local executor has not finished its physical join.")
        } else { verdict = await verify(record) }
        let ticket = HostPhysicalExitCheck(record: record, verdict: verdict)
        // Bounded independently of records; a newer check replaces the old ticket.
        if issued.count >= 64 { issued.removeAll() }
        issued[operationID] = ticket
        return ticket
    }
    func reconcile(_ check: HostPhysicalExitCheck) async throws -> HostPhysicalRelease {
        guard issued[check.operationID] === check else { throw BackgroundWorkError.unavailable }
        issued.removeValue(forKey: check.operationID)
        guard !coordinator.hasOutstandingLocalJoin(check.operationID) else {
            return .retained(operationID: check.operationID, reason: "The local executor has not finished its physical join.")
        }
        guard let fresh = try await coordinator.storage.snapshot().first(where: { $0.operationID == check.operationID }), fresh == check.record, fresh.holdsResources else {
            return .retained(operationID: check.operationID, reason: "Ownership changed after the check; refresh and verify again.")
        }
        // Release always requests FRESH independent evidence, even if check was verified.
        let answer = await verify(fresh)
        if case .privateCleanup(let result) = answer,
           fresh.owner.kind.isExclusive || result.identity != HostExecutionIdentity(fresh) {
            return .retained(operationID: fresh.operationID, reason: "Private cleanup answer belongs to another attempt or cannot authorize exclusive work.")
        }
        switch answer {
        case .unconfirmed(let reason):
            return .retained(operationID: fresh.operationID, reason: reason)
        case .privateCleanup(let result):
            guard !coordinator.hasOutstandingLocalJoin(fresh.operationID) else {
                return .retained(operationID: fresh.operationID, reason: "A local physical join is still outstanding.")
            }
            try await coordinator.reconcileAfterPhysicalExit(fresh, evidence: result.evidence)
            return .released(operationID: fresh.operationID, evidence: result.evidence)
        case .verified(let evidence):
            guard !coordinator.hasOutstandingLocalJoin(fresh.operationID) else {
                return .retained(operationID: fresh.operationID, reason: "A local physical join is still outstanding.")
            }
            try await coordinator.reconcileAfterPhysicalExit(fresh, evidence: evidence)
            return .released(operationID: fresh.operationID, evidence: evidence)
        }
    }
}
