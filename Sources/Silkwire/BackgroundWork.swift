import Foundation

// Private-work engine, deliberately separate from NativeRoom's foreground Turn.
// No provider, computer, billing or installation capability is created here.
// The host supplies durable storage, fresh grant checks and a scoped executor.
struct BackgroundWorkScope: Codable, Equatable, Sendable {
    let projectID: UUID
    let conversationID: UUID
    let workspaceID: UUID
    let agentID: String
    let sourceRevision: String
    fileprivate var valid: Bool {
        !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && agentID.utf8.count <= 128 &&
        sourceRevision.utf8.count == 40 && sourceRevision.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
struct BackgroundWorkLimits: Codable, Equatable, Sendable {
    let totalSteps: Int
    let stepsPerSlice: Int
    fileprivate var valid: Bool { (1...10_000).contains(totalSteps) && (1...totalSteps).contains(stepsPerSlice) }
}
// Runtime-only host input, NOT decoded from an agent message or a saved task.
// It is only an admission constraint; the executor must still use the real broker.
struct BackgroundWorkPermit {
    let scope: BackgroundWorkScope
    let limits: BackgroundWorkLimits
}
struct BackgroundWorkItem: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case queued, running, paused, completed, cancelled }
    enum Pause: String, Codable, Sendable { case restart, reconciliation, sliceLimit, stepLimit, revoked, host }
    let id: UUID
    let scope: BackgroundWorkScope
    // Dedicated background session key, never the originating chat's session key.
    let sessionID: UUID
    let title: String
    let limits: BackgroundWorkLimits
    var state: State = .queued
    var pause: Pause?
    var attempts = 0
    var checkpoint = ""
    var note = ""
    var pendingStepID: UUID?
    var resultID: UUID?
    var resultAcknowledged = false
    // Optional v1 host metadata keeps old saved ledgers decodable.
    var hostRevision: UInt64?
    var hostState: HostJobState?
    var hostCompletionID: UUID?
    fileprivate var valid: Bool {
        scope.valid && limits.valid && sessionID != scope.conversationID && sessionID != id &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 240 &&
        (0...limits.totalSteps).contains(attempts) && checkpoint.utf8.count <= 16_384 && note.utf8.count <= 4096 &&
        ((state == .paused) == (pause != nil)) &&
        (pendingStepID == nil || (attempts > 0 && [State.running, .paused, .cancelled].contains(state))) &&
        (state != .queued || (attempts == 0 && pendingStepID == nil)) &&
        ((state == .completed) == (resultID != nil)) && (!resultAcknowledged || state == .completed)
    }
}
struct BackgroundWorkSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let items: [BackgroundWorkItem]
}
enum BackgroundWorkStep: Equatable, Sendable {
    case checkpoint(String)
    case completed(checkpoint: String, summary: String)
    case paused(checkpoint: String, note: String)
}
/// HOST-recorded broker evidence for the uncertain step of a STOPPED job. It never
/// restarts the job or creates a result; it only resolves what that step did.
enum BackgroundWorkStoppedStep: Equatable, Sendable {
    case notPerformed(note: String)
    case performed(checkpoint: String, note: String)
}
// busy: the runner's host-call queue is full; nothing changed, try again.
// ledgerFull: admission refused because the bounded ledger has no room; nothing changed.
enum BackgroundWorkError: Error { case invalidInput, invalidSnapshot, unavailable, reconciliationRequired, capacity, storage, busy, ledgerFull }

@MainActor struct BackgroundWorkContext {
    let item: BackgroundWorkItem
    let stepID: UUID
    // The executor checks this immediately before EVERY broker operation. Actual
    // broker grants/ask-first rules must also be rechecked, including after awaits.
    let mayPerformOperation: () -> Bool
}

// One host-owned instance per ledger. Main-actor serialization covers this
// process only: storage must not have concurrent writer processes or replicas.
@MainActor final class BackgroundWorkEngine {
    typealias Save = (BackgroundWorkSnapshot) throws -> Void
    typealias Authorize = (BackgroundWorkScope) async -> Bool
    typealias Execute = (BackgroundWorkContext) async throws -> BackgroundWorkStep
    private struct Worker { let lease: UUID; let task: Task<Void, Never> }
    private var values: [UUID: BackgroundWorkItem] = [:]
    private var workers: [UUID: Worker] = [:]
    private var leases: [UUID: UUID] = [:]
    private let save: Save
    private let authorize: Authorize
    private let execute: Execute
    let maxConcurrent: Int
    private(set) var closed = false
    private(set) var storageFailed = false
    var activeWorkerCount: Int { workers.count }
    var snapshot: BackgroundWorkSnapshot {
        BackgroundWorkSnapshot(version: 1, items: values.values.sorted { $0.id.uuidString < $1.id.uuidString })
    }
    var pendingResults: [BackgroundWorkItem] { snapshot.items.filter { $0.state == .completed && !$0.resultAcknowledged } }
    func item(_ id: UUID) -> BackgroundWorkItem? { values[id] }

    init(restoring saved: BackgroundWorkSnapshot? = nil, maxConcurrent: Int = 3,
         save: @escaping Save, authorize: @escaping Authorize, execute: @escaping Execute) throws {
        guard (1...16).contains(maxConcurrent) else { throw BackgroundWorkError.invalidInput }
        self.maxConcurrent = maxConcurrent; self.save = save; self.authorize = authorize; self.execute = execute
        if let saved {
            try Self.validateSnapshot(saved)
            for var item in saved.items {
                if item.state == .running || item.state == .queued {
                    item.state = .paused
                    item.pause = item.pendingStepID == nil ? .restart : .reconciliation
                }
                values[item.id] = item
            }
            // Persist crash recovery before exposing a usable engine. Cancelled and
            // completed tasks remain terminal; nothing starts just because it loaded.
            try Self.validateSize(snapshot)
            try save(snapshot)
        }
    }
    @discardableResult func enqueue(scope: BackgroundWorkScope, title: String, limits: BackgroundWorkLimits) throws -> UUID {
        guard !closed, !storageFailed, scope.valid, limits.valid,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 240 else { throw BackgroundWorkError.invalidInput }
        guard values.count < 256 else { throw BackgroundWorkError.capacity }
        let item = BackgroundWorkItem(id: UUID(), scope: scope, sessionID: UUID(), title: title, limits: limits)
        try commit(item)
        return item.id
    }
    // Returns promptly. The task continues across awaits without a chat turn/Pass.
    // Fresh host permits may tighten, but never expand, the saved lifetime limit.
    @discardableResult func start(_ id: UUID, permit: BackgroundWorkPermit) throws -> Bool {
        guard !closed, !storageFailed, var item = values[id], [.queued, .paused].contains(item.state),
              workers[id] == nil, workers.count < maxConcurrent else { return false }
        guard !workers.keys.contains(where: { values[$0]?.scope.workspaceID == item.scope.workspaceID }),
              permit.scope == item.scope, permit.limits.valid,
              permit.limits.totalSteps <= item.limits.totalSteps,
              permit.limits.stepsPerSlice <= item.limits.stepsPerSlice else { return false }
        guard item.pendingStepID == nil else { throw BackgroundWorkError.reconciliationRequired }
        guard item.attempts < permit.limits.totalSteps else {
            item.state = .paused; item.pause = .stepLimit; try commit(item); return false
        }
        item.state = .running; item.pause = nil
        try commit(item)
        let lease = UUID(); leases[id] = lease
        let job = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(id, lease: lease, limits: permit.limits)
        }
        workers[id] = Worker(lease: lease, task: job)
        return true
    }
    // Persist the terminal fence BEFORE signalling cooperative cancellation. A
    // non-cooperative executor keeps its concurrency slot until it really returns.
    @discardableResult func cancel(_ id: UUID) throws -> Bool {
        guard !closed, !storageFailed, var item = values[id], ![.completed, .cancelled].contains(item.state) else { return false }
        item.state = .cancelled; item.pause = nil
        try commit(item)
        leases.removeValue(forKey: id); workers[id]?.task.cancel()
        return true
    }
    @discardableResult func pause(_ id: UUID) throws -> Bool {
        guard !closed, !storageFailed, var item = values[id], ![.completed, .cancelled].contains(item.state) else { return false }
        item.state = .paused; item.pause = item.pendingStepID == nil ? .host : .reconciliation
        try commit(item)
        leases.removeValue(forKey: id); workers[id]?.task.cancel()
        return true
    }
    // HOST ONLY: resolve the exact uncertain step using independently recorded
    // broker evidence. Never infer success from an agent's summary or rerun blindly.
    func reconcile(_ id: UUID, stepID: UUID, permit: BackgroundWorkPermit, outcome: BackgroundWorkStep) throws {
        guard !closed, !storageFailed, workers[id] == nil, var item = values[id],
              item.state == .paused, item.pause == .reconciliation, item.pendingStepID == stepID,
              permit.scope == item.scope, permit.limits.valid,
              permit.limits.totalSteps <= item.limits.totalSteps,
              permit.limits.stepsPerSlice <= item.limits.stepsPerSlice else { throw BackgroundWorkError.unavailable }
        try apply(outcome, to: &item)
        if item.state == .running { item.state = .paused; item.pause = .host }
        try commit(item)
    }
    // The transcript must deduplicate by resultID BEFORE acknowledging. This is a
    // durable outbox, not a claim of exactly-once delivery across two storage files.
    @discardableResult func acknowledgeResult(_ id: UUID, resultID: UUID) throws -> Bool {
        guard !closed, !storageFailed, var item = values[id], item.state == .completed, item.resultID == resultID else { return false }
        if item.resultAcknowledged { return true }
        item.resultAcknowledged = true; try commit(item); return true
    }
    func shutdown() throws {
        guard !closed else { return }
        var next = values
        for (id, var item) in next where item.state == .running || item.state == .queued {
            item.state = .paused; item.pause = item.pendingStepID == nil ? .restart : .reconciliation
            next[id] = item
        }
        defer { closed = true; leases.removeAll(); for worker in workers.values { worker.task.cancel() } }
        try persist(next)
    }
    private func current(_ id: UUID, _ lease: UUID) -> Bool {
        !closed && !storageFailed && leases[id] == lease && values[id]?.state == .running
    }
    private func run(_ id: UUID, lease: UUID, limits: BackgroundWorkLimits) async {
        defer {
            if workers[id]?.lease == lease { workers.removeValue(forKey: id) }
            if leases[id] == lease { leases.removeValue(forKey: id) }
        }
        var slice = 0
        while current(id, lease), var item = values[id] {
            do {
                if item.attempts >= limits.totalSteps || slice >= limits.stepsPerSlice {
                    item.state = .paused; item.pause = item.attempts >= limits.totalSteps ? .stepLimit : .sliceLimit
                    try commit(item); return
                }
                let allowed = await authorize(item.scope)
                guard current(id, lease) else { return }
                guard allowed else {
                    item.state = .paused; item.pause = .revoked; try commit(item); return
                }
                let stepID = UUID()
                item.pendingStepID = stepID; item.attempts += 1
                try commit(item) // Crash boundary: save before invoking the executor.
                let context = BackgroundWorkContext(item: item, stepID: stepID, mayPerformOperation: { [weak self] in
                    self?.current(id, lease) == true && self?.values[id]?.pendingStepID == stepID
                })
                let outcome = try await execute(context)
                guard current(id, lease), var latest = values[id], latest.pendingStepID == stepID else { return }
                try apply(outcome, to: &latest)
                try commit(latest) // Save completed step before considering another.
                slice += 1
                if latest.state != .running { return }
                await Task.yield()
            } catch {
                guard current(id, lease), var latest = values[id] else { return }
                // A throw may follow an actual side effect. Retain the pending ID;
                // permission to retry is never inferred from an error or timeout.
                latest.state = .paused; latest.pause = latest.pendingStepID == nil ? .host : .reconciliation
                latest.note = "Step outcome needs host review; nothing was automatically replayed."
                try? commit(latest)
                return
            }
        }
    }
    private func apply(_ outcome: BackgroundWorkStep, to item: inout BackgroundWorkItem) throws {
        switch outcome {
        case .checkpoint(let text): item.checkpoint = text; item.state = .running; item.pause = nil; item.note = ""
        case .completed(let text, let summary):
            item.checkpoint = text; item.note = summary; item.state = .completed; item.pause = nil; item.resultID = UUID()
        case .paused(let text, let note): item.checkpoint = text; item.note = note; item.state = .paused; item.pause = .host
        }
        item.pendingStepID = nil
        guard item.valid else { throw BackgroundWorkError.invalidInput }
    }
    private func commit(_ item: BackgroundWorkItem) throws {
        guard item.valid else { throw BackgroundWorkError.invalidInput }
        var next = values; next[item.id] = item
        try persist(next)
    }
    /// Pure shared validation: callable by a non-main storage owner without creating
    /// an engine, executing work, or weakening the original restart invariants.
    nonisolated static func validateSnapshot(_ saved: BackgroundWorkSnapshot) throws {
        guard saved.version == 1, saved.items.count <= 256,
              Set(saved.items.map(\.id)).count == saved.items.count,
              Set(saved.items.map(\.sessionID)).count == saved.items.count,
              !saved.items.contains(where: { item in saved.items.contains { $0.scope.conversationID == item.sessionID } }),
              saved.items.allSatisfy(\.valid) else { throw BackgroundWorkError.invalidSnapshot }
        try validateSize(saved)
    }
    /// Settled items are finished for good: cancelled, or completed with the result
    /// acknowledged. Only these may leave the ledger for the archive.
    nonisolated static func isSettled(_ item: BackgroundWorkItem) -> Bool {
        item.state == .cancelled || (item.state == .completed && item.resultAcknowledged)
    }
    /// Settled AND resolved. A stopped job that still carries an uncertain pending
    /// step is evidence the host must reconcile, so it stays in the ledger, where
    /// archive retention can never drop it.
    nonisolated static func isArchivable(_ item: BackgroundWorkItem) -> Bool {
        isSettled(item) && item.pendingStepID == nil
    }
    /// Pure archive validation: unique, schema-valid, archivable items only. An
    /// archived item is history, never runnable work or a result to publish.
    /// `allowingUnresolved` only admits an archive written before this rule, so
    /// its unresolved entries can be moved back to the ledger; never for writes.
    nonisolated static func validateArchived(_ items: [BackgroundWorkItem], limit: Int, allowingUnresolved: Bool = false) throws {
        guard items.count <= limit, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.valid && (allowingUnresolved ? isSettled($0) : isArchivable($0)) }) else { throw BackgroundWorkError.invalidSnapshot }
    }
    nonisolated private static func validateSize(_ snapshot: BackgroundWorkSnapshot) throws {
        guard try JSONEncoder().encode(snapshot).count <= 2_097_152 else { throw BackgroundWorkError.capacity }
    }
    private func persist(_ next: [UUID: BackgroundWorkItem]) throws {
        let snapshot = BackgroundWorkSnapshot(version: 1, items: next.values.sorted { $0.id.uuidString < $1.id.uuidString })
        do {
            try Self.validateSize(snapshot)
            try save(snapshot)
        } catch {
            // Stop admitting/committing any further work on an untrustworthy ledger.
            // Do not publish successful progress or clear an uncertain saved step.
            storageFailed = true; leases.removeAll()
            for worker in workers.values { worker.task.cancel() }
            throw BackgroundWorkError.storage
        }
        values = next
    }
}
