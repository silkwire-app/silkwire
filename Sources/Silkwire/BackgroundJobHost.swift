import Foundation

/// Contract v1 for Claude Code's room adapter. These are host calls, not grants
/// obtained by decoding agent fields. Observation never owns executor lifetime.
@MainActor protocol BackgroundJobHost: AnyObject {
    /// Returns after durable acceptance, without awaiting execution or slot availability.
    func submit(_ request: HostJobRequest) async throws -> UUID
    func snapshot(_ jobID: UUID) -> HostJobSnapshot?
    func events() -> AsyncStream<HostJobSnapshot>
    /// Immediate operation fence. Await stop() to observe durable Stop intent.
    func requestStop(_ jobID: UUID)
    func stop(_ jobID: UUID) async throws -> HostJobStopAcknowledgement
    /// Existing durable outbox: insert/deduplicate by resultID, then acknowledge.
    /// The host does not independently post results or provide a second delivery path.
    var pendingResults: [BackgroundWorkItem] { get }
    func acknowledgeResult(_ jobID: UUID, resultID: UUID) async throws -> Bool
    /// Host UI recovery only. A Release gesture requests fresh verification.
    /// Neither call can override uncertainty, replay work or resolve its outcome.
    func heldPhysicalOperations() async throws -> [HostHeldPhysicalOperation]
    func checkPhysicalExit(operationID: UUID) async throws -> HostPhysicalExitCheck
    func reconcilePhysicalExit(_ check: HostPhysicalExitCheck) async throws -> HostPhysicalRelease
}

struct HostHeldPhysicalOperation: Sendable, Equatable {
    let operationID: UUID
    let originatingConversationID: UUID
    let kind: PhysicalWorkOwnership.Kind
    let phase: PhysicalWorkOwnership.Phase
    let stopRequested: Bool
    let reason: String
}

enum HostPhysicalRelease: Sendable, Equatable {
    case released(operationID: UUID, evidence: String)
    case retained(operationID: UUID, reason: String)
}
