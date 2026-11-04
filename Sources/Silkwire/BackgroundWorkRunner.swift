import Foundation

/// Awaited-storage successor to the synchronous BackgroundWorkEngine contract.
/// The host supplies current admission, a dedicated-session executor and an
/// already-open private storage session. This type selects no app-library path,
/// invokes no real provider on its own and treats no saved task as a permission.
@MainActor final class BackgroundWorkRunner {
    typealias Authorize = BackgroundWorkEngine.Authorize
    typealias Execute = BackgroundWorkEngine.Execute
    private struct Worker { let lease: UUID; let task: Task<Void, Never> }
    private let storage: BackgroundWorkStorageSession
    private let storageOwner: UUID
    private let authorize: Authorize
    private let execute: Execute
    private let hostExecution: HostBackgroundExecution?
    var onChange: (() -> Void)?
    func workerActive(_ id: UUID) -> Bool { workers[id] != nil }
    private var generation: UInt64
    private var values: [UUID: BackgroundWorkItem]
    private var workers: [UUID: Worker] = [:]
    private var leases: [UUID: UUID] = [:]
    private var stopRequests: Set<UUID> = []
    // Explicit FIFO lanes for LOGICAL mutations. Actor scheduling is not FIFO.
    // The mutex is held through a physical save, never through provider awaits.
    // Host calls are bounded and refused with .busy when their lane is full. A
    // worker's own transitions (pending step, finished step, failure record) are
    // never refused and are normally served first: each worker has at most one
    // outstanding, so that lane is bounded by maxConcurrent. A full host lane is
    // never storage. Fairness: after workerGrantsPerHostGrant consecutive worker
    // grants that passed over a waiting host call, the oldest host call goes next,
    // so continuously stepping workers cannot hold a Stop or admission forever,
    // and a worker transition still waits behind at most one host call per turn.
    private var mutating = false
    private var hostWaiters: [CheckedContinuation<Void, Never>] = []
    private var workerWaiters: [CheckedContinuation<Void, Never>] = []
    private var workerGrantsPastHost = 0
    static let maximumQueuedMutations = 64
    static let workerGrantsPerHostGrant = 4
    let maxConcurrent: Int
    private(set) var closing = false
    private(set) var closed = false
    private(set) var storageFailed = false
    var activeWorkerCount: Int { workers.count }
    var queuedMutationCount: Int { hostWaiters.count + workerWaiters.count }
    var queuedWorkerTransitionCount: Int { workerWaiters.count }
    var snapshot: BackgroundWorkSnapshot { Self.snapshot(values) }
    var pendingResults: [BackgroundWorkItem] {
        guard !closed, !closing, !storageFailed else { return [] }
        return snapshot.items.filter { $0.state == .completed && !$0.resultAcknowledged && !stopRequests.contains($0.id) }
    }
    /// Ledger item, or settled history from the archive (never runnable).
    func item(_ id: UUID) -> BackgroundWorkItem? { values[id] ?? archived[id] }
    func stopRequested(_ id: UUID) -> Bool { stopRequests.contains(id) }
    /// Ledger items whose exact step is uncertain and awaits host evidence: paused
    /// for reconciliation, or stopped mid-step. Never archived, so never trimmed.
    var unresolvedItems: [BackgroundWorkItem] {
        snapshot.items.filter { $0.pendingStepID != nil && $0.state != .running && workers[$0.id] == nil }
    }

    // Bounded ledger. Growth only happens to a RUNNING item (its next checkpoint)
    // or through host reconciliation, so admission reserves that room up front:
    // a started item reserves maximumEncodedItemBytes, and every item keeps
    // transitionSlackBytes for host-written notes, pauses and step identities.
    // Applied outcomes larger than the per-item bound are refused (the step is
    // left for reconciliation, as for any invalid outcome). Settled items move
    // to a bounded archive file when admission needs the room.
    enum AdmissionHold: Equatable, Sendable {
        /// No room to reserve more work. Acknowledge results or stop jobs, then
        /// retry. Running work keeps the room it reserved when it started.
        case ledgerFull
        /// Stopped jobs with uncertain steps hold the room this admission needs.
        /// They are never discarded to make room: reconcile them with
        /// reconcileStopped (see unresolvedItems), then retry.
        case unresolvedEvidence
    }
    static let maximumEncodedItemBytes = 49_152
    static let transitionSlackBytes = 1_024
    static let ledgerOverheadBytes = 4_096
    static let maximumLedgerItems = 256
    static var ledgerBudgetBytes: Int { BackgroundWorkStorageSession.maximumBytes }
    /// Set when an admission was refused for room; cleared by the next one that fits.
    private(set) var admissionHold: AdmissionHold?
    private var archived: [UUID: BackgroundWorkItem] = [:]
    var archivedItems: [BackgroundWorkItem] { archived.values.sorted { $0.id.uuidString < $1.id.uuidString } }

    private init(storage: BackgroundWorkStorageSession, owner: UUID, generation: UInt64,
                 snapshot: BackgroundWorkSnapshot, archived: [BackgroundWorkItem], maxConcurrent: Int,
                 authorize: @escaping Authorize, execute: @escaping Execute, hostExecution: HostBackgroundExecution?) {
        self.storage = storage; storageOwner = owner; self.generation = generation
        let ledger = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        values = ledger
        // After a crash between the archive and ledger writes an item can be in
        // both files. The ledger copy is authoritative.
        self.archived = Dictionary(archived.filter { ledger[$0.id] == nil }.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        self.maxConcurrent = maxConcurrent; self.authorize = authorize; self.execute = execute; self.hostExecution = hostExecution
    }
    static func open(storage: BackgroundWorkStorageSession, maxConcurrent: Int = 3,
                     hostExecution: HostBackgroundExecution? = nil,
                     authorize: @escaping Authorize, execute: @escaping Execute) async throws -> BackgroundWorkRunner {
        try Task.checkCancellation()
        guard (1...16).contains(maxConcurrent) else { throw BackgroundWorkError.invalidInput }
        let claim = try await storage.claimRunner()
        guard !claim.state.storageFailed else { throw BackgroundWorkError.storage }
        let saved = claim.state.snapshot ?? BackgroundWorkSnapshot(version: 1, items: [])
        try BackgroundWorkEngine.validateSnapshot(saved)
        var restored = saved.items
        for index in restored.indices where restored[index].state == .running || restored[index].state == .queued {
            restored[index].state = .paused
            restored[index].pause = restored[index].pendingStepID == nil ? .restart : .reconciliation
            if let revision = restored[index].hostRevision {
                guard revision < UInt64.max else { throw BackgroundWorkError.storage }
                restored[index].hostRevision = revision + 1; restored[index].hostState = .needsReview
            }
        }
        // Storage open may already have converted running/queued to paused.
        for index in restored.indices where restored[index].hostRevision != nil && [.queued, .running, .stopping].contains(restored[index].hostState) {
            guard let revision = restored[index].hostRevision, revision < UInt64.max else { throw BackgroundWorkError.storage }
            restored[index].hostRevision = revision + 1; restored[index].hostState = .needsReview
        }
        let initial = BackgroundWorkSnapshot(version: 1, items: restored)
        var generation = claim.state.generation
        if initial != saved {
            // Await the true physical result even if this caller is cancelled.
            let expectedGeneration = generation
            generation = try await Task { try await storage.saveForRunner(initial, basedOn: expectedGeneration, owner: claim.id) }.value
        }
        return BackgroundWorkRunner(storage: storage, owner: claim.id, generation: generation,
            snapshot: initial, archived: claim.state.archived, maxConcurrent: maxConcurrent, authorize: authorize, execute: execute, hostExecution: hostExecution)
    }

    @discardableResult func enqueue(scope: BackgroundWorkScope, title: String, limits: BackgroundWorkLimits, operationID: UUID = UUID(), hostManaged: Bool = false) async throws -> UUID {
        try Task.checkCancellation()
        try await acquire(); defer { release() }
        try Task.checkCancellation()
        try available()
        if let existing = item(operationID) {
            guard existing.scope == scope, existing.title == title, existing.limits == limits else { throw BackgroundWorkError.invalidInput }
            return existing.id
        }
        var item = BackgroundWorkItem(id: operationID, scope: scope, sessionID: UUID(), title: title, limits: limits)
        if hostManaged { item.hostRevision = 1; item.hostState = .queued }
        do { try BackgroundWorkEngine.validateSnapshot(BackgroundWorkSnapshot(version: 1, items: [item])) }
        catch { throw BackgroundWorkError.invalidInput }
        // A queued item cannot grow until it is started, which reserves its own room.
        guard try await makeRoom({ ledger in
            var next = ledger; next[item.id] = item
            return next.count <= Self.maximumLedgerItems && Self.worstCaseBytes(next) <= Self.ledgerBudgetBytes
        }) else { throw BackgroundWorkError.ledgerFull }
        var next = values; next[item.id] = item
        do { try BackgroundWorkEngine.validateSnapshot(Self.snapshot(next)) }
        catch { throw BackgroundWorkError.invalidInput }
        try await persist(next)
        return item.id
    }
    @discardableResult func start(_ id: UUID, permit: BackgroundWorkPermit) async throws -> Bool {
        try Task.checkCancellation()
        try await acquire(); defer { release() }
        try Task.checkCancellation()
        try available()
        guard var item = values[id], [.queued, .paused].contains(item.state),
              !stopRequests.contains(id), workers[id] == nil, workers.count < maxConcurrent,
              item.hostRevision == nil || hostExecution != nil,
              !workers.keys.contains(where: { values[$0]?.scope.workspaceID == item.scope.workspaceID }),
              Self.permits(permit, item) else { return false }
        guard item.pendingStepID == nil else { throw BackgroundWorkError.reconciliationRequired }
        guard item.attempts < permit.limits.totalSteps else {
            item.state = .paused; item.pause = .stepLimit; try await commit(item); return false
        }
        // Reserve this item's worst-case growth before it can run. Refusal leaves
        // the item exactly as it was and pauses admissions with a clear reason.
        guard try await makeRoom({ Self.worstCaseBytes($0, reserving: id) <= Self.ledgerBudgetBytes }) else {
            throw BackgroundWorkError.ledgerFull
        }
        item.state = .running; item.pause = nil
        try await commit(item)
        // Stop/shutdown can arrive while the start checkpoint is on disk.
        guard !closed, !closing, !storageFailed, !stopRequests.contains(id) else { return false }
        if Task.isCancelled {
            item.state = .paused; item.pause = .host
            try await commit(item)
            return false
        }
        let lease = UUID(); leases[id] = lease
        let job = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(id, lease: lease, limits: permit.limits)
        }
        workers[id] = Worker(lease: lease, task: job)
        return true
    }

    /// Immediate IN-PROCESS fence, callable by a UI action before creating a Task.
    /// The host must still await cancel() and report any durability failure.
    /// This is not an acknowledgement that a cancelled state reached the disk.
    @discardableResult func requestCancel(_ id: UUID) -> Bool {
        guard !closed, !closing, !storageFailed, let item = values[id],
              ![.completed, .cancelled].contains(item.state) else { return false }
        stopRequests.insert(id); hostExecution?.requestStop(id); leases.removeValue(forKey: id); workers[id]?.task.cancel(); onChange?()
        return true
    }
    @discardableResult func cancel(_ id: UUID) async throws -> Bool {
        let requested = requestCancel(id)
        guard requested || stopRequests.contains(id) else { return false }
        // Deliberately do not discard a Stop because its caller was cancelled.
        try await acquire(); defer { release() }
        guard !closed, !storageFailed else { throw BackgroundWorkError.unavailable }
        guard var item = values[id] else {
            if archived[id] != nil { return false } // Already settled and archived.
            throw BackgroundWorkError.unavailable
        }
        guard item.state != .cancelled else {
            // Idempotence must not hide a previously failed ownership Stop write.
            try await hostExecution?.stop(id); return false
        }
        // A completion save may have been in flight when Stop fenced this item.
        // It must not escape as a result or win over that already-accepted Stop.
        item.state = .cancelled; item.pause = nil; item.resultID = nil; item.resultAcknowledged = false
        if item.hostRevision != nil {
            item.hostState = workers[id] == nil ? (item.pendingStepID == nil ? .failed : .needsReview) : .stopping
            if workers[id] == nil && item.pendingStepID == nil { item.hostCompletionID = item.hostCompletionID ?? UUID() }
        }
        item.note = "Stopped by the host."
        try await commit(item)
        try await hostExecution?.stop(id)
        return true
    }
    func reconcile(_ id: UUID, stepID: UUID, permit: BackgroundWorkPermit, outcome: BackgroundWorkStep) async throws {
        try Task.checkCancellation()
        try await acquire(); defer { release() }
        try available()
        guard workers[id] == nil, !stopRequests.contains(id), var item = values[id],
              item.state == .paused, item.pause == .reconciliation, item.pendingStepID == stepID,
              Self.permits(permit, item) else { throw BackgroundWorkError.unavailable }
        try apply(outcome, to: &item)
        if item.state == .running { item.state = .paused; item.pause = .host }
        // Reconciliation can grow a paused item, so it must fit beside the room
        // already reserved for running work.
        let reconciled = item
        guard try await makeRoom({ ledger in
            var next = ledger; next[id] = reconciled
            return Self.worstCaseBytes(next) <= Self.ledgerBudgetBytes
        }) else { throw BackgroundWorkError.ledgerFull }
        try await commit(item)
    }
    /// HOST ONLY: resolve the exact uncertain step of a STOPPED job from
    /// independently recorded broker evidence. The job stays cancelled: nothing
    /// restarts, replays or publishes a result. Its physical worker must have
    /// returned. Only once resolved may the item move to the bounded archive.
    func reconcileStopped(_ id: UUID, stepID: UUID, scope: BackgroundWorkScope, evidence: BackgroundWorkStoppedStep) async throws {
        try Task.checkCancellation()
        try await acquire(); defer { release() }
        try available()
        guard workers[id] == nil, var item = values[id], item.state == .cancelled,
              item.pendingStepID == stepID, item.scope == scope else { throw BackgroundWorkError.unavailable }
        switch evidence {
        case .notPerformed(let note): item.note = note
        case .performed(let checkpoint, let note): item.checkpoint = checkpoint; item.note = note
        }
        item.pendingStepID = nil
        do { try BackgroundWorkEngine.validateSnapshot(BackgroundWorkSnapshot(version: 1, items: [item])) }
        catch { throw BackgroundWorkError.invalidInput }
        guard Self.encodedSize(item) <= Self.maximumEncodedItemBytes else { throw BackgroundWorkError.invalidInput }
        let reconciled = item
        guard try await makeRoom({ ledger in
            var next = ledger; next[id] = reconciled
            return Self.worstCaseBytes(next) <= Self.ledgerBudgetBytes
        }) else { throw BackgroundWorkError.ledgerFull }
        try await commit(item)
    }
    @discardableResult func acknowledgeResult(_ id: UUID, resultID: UUID) async throws -> Bool {
        try Task.checkCancellation()
        try await acquire(); defer { release() }
        try available()
        if values[id] == nil, let settled = archived[id] {
            return settled.state == .completed && settled.resultID == resultID && settled.resultAcknowledged
        }
        guard !stopRequests.contains(id), var item = values[id], item.state == .completed, item.resultID == resultID else { return false }
        if item.resultAcknowledged { return true }
        // Transcript insertion must already be durable and deduplicated by resultID.
        item.resultAcknowledged = true; try await commit(item); return true
    }
    /// Moves acknowledged and cancelled items whose workers have physically
    /// returned into the bounded archive. A stopped job with an uncertain step
    /// stays in the ledger until reconcileStopped resolves it. Admission does this
    /// on its own when it needs room; a host may also call it, for example after
    /// acknowledging results.
    @discardableResult func archiveSettledItems() async throws -> Int {
        try Task.checkCancellation()
        try await acquire(); defer { release() }
        try available()
        return try await archiveSettledLocked()
    }
    /// Explicit local callback join; not independent descendant/remote exit evidence.
    func joinLocalExecutors() async {
        let pending = Array(workers.values).map(\.task)
        for task in pending { await task.value }
    }
    func shutdown() async throws {
        guard !closed else { return }
        closing = true; leases.removeAll()
        for (id, worker) in workers { hostExecution?.requestStop(id); worker.task.cancel() }
        try await acquire(); defer { release() }
        guard !closed else { return }
        defer { closed = true }
        guard !storageFailed else { throw BackgroundWorkError.storage }
        var next = values
        for (id, var item) in next {
            if stopRequests.contains(id) {
                item.state = .cancelled; item.pause = nil; item.resultID = nil; item.resultAcknowledged = false
                item.note = "Stopped by the host."
            } else if item.state == .queued || item.state == .running {
                item.state = .paused; item.pause = item.pendingStepID == nil ? .restart : .reconciliation
            }
            if item.hostRevision != nil && [.queued, .running, .stopping].contains(item.hostState) {
                item.hostState = workers[id] == nil ? .needsReview : .stopping
            }
            next[id] = item
        }
        try await persist(next)
    }

    private func available() throws {
        guard !closed, !closing, !storageFailed else { throw BackgroundWorkError.unavailable }
    }
    private static func permits(_ permit: BackgroundWorkPermit, _ item: BackgroundWorkItem) -> Bool {
        permit.scope == item.scope && permit.limits.totalSteps > 0 && permit.limits.stepsPerSlice > 0 &&
        permit.limits.stepsPerSlice <= permit.limits.totalSteps &&
        permit.limits.totalSteps <= item.limits.totalSteps && permit.limits.stepsPerSlice <= item.limits.stepsPerSlice
    }
    private func current(_ id: UUID, _ lease: UUID) -> Bool {
        !closed && !closing && !storageFailed && !stopRequests.contains(id) && leases[id] == lease && values[id]?.state == .running
    }
    private func run(_ id: UUID, lease: UUID, limits: BackgroundWorkLimits) async {
        await runSteps(id, lease: lease, limits: limits)
        if var item = values[id], item.hostRevision != nil, stopRequests.contains(id), !closed, !storageFailed {
            await acquireForWorker()
            item = values[id] ?? item
            // A pending step after Stop still needs logical outcome reconciliation.
            item.hostState = item.pendingStepID == nil ? .failed : .needsReview
            if item.pendingStepID == nil { item.hostCompletionID = item.hostCompletionID ?? UUID() }
            do { try await commit(item) } catch { failClosed() }
            release()
        }
        if workers[id]?.lease == lease { workers.removeValue(forKey: id) }
        if leases[id] == lease { leases.removeValue(forKey: id) }
        onChange?()
    }
    private func runSteps(_ id: UUID, lease: UUID, limits: BackgroundWorkLimits) async {
        var slice = 0
        while current(id, lease) {
            do {
                guard let context = try await prepareStep(id, lease: lease, limits: limits, slice: slice) else { return }
                // Permissions can change during a slow pending-step save. Recheck
                // after that await too; the executor still checks the actual broker.
                let allowed = await authorize(context.item.scope)
                guard current(id, lease) else { return }
                guard allowed else { await recordFailure(id, lease: lease, note: "Permission changed before execution; host reconciliation is required."); return }
                let outcome: BackgroundWorkStep
                if let hostExecution {
                    outcome = try await hostExecution.execute(context, authorize: authorize, dispatch: execute, willDispatch: {
                        await self.acquireForWorker(); defer { self.release() }
                        guard self.current(id, lease), var item = self.values[id] else { throw CancellationError() }
                        item.hostState = .running; try await self.commit(item)
                    })
                } else { outcome = try await execute(context) }
                guard current(id, lease) else { return }
                let more = try await finishStep(id, lease: lease, stepID: context.stepID, outcome: outcome)
                guard more else { return }
                slice += 1
                await Task.yield()
            } catch BackgroundWorkError.ledgerFull {
                // Refused before any I/O: the last saved state is unchanged.
                await recordFailure(id, lease: lease, note: "The ledger had no room to save this step; nothing was automatically replayed.")
                return
            } catch let failure as BackgroundWorkReportedFailure {
                // Same review pause as any failure, but keep the real reason.
                await recordFailure(id, lease: lease, note: failure.note)
                return
            } catch {
                await recordFailure(id, lease: lease, note: "Step outcome needs host review; nothing was automatically replayed.")
                return
            }
        }
    }
    private func prepareStep(_ id: UUID, lease: UUID, limits: BackgroundWorkLimits, slice: Int) async throws -> BackgroundWorkContext? {
        await acquireForWorker()
        guard current(id, lease), var item = values[id] else { release(); return nil }
        if item.attempts >= limits.totalSteps || slice >= limits.stepsPerSlice {
            item.state = .paused; item.pause = item.attempts >= limits.totalSteps ? .stepLimit : .sliceLimit
            if item.hostRevision != nil { item.hostState = .needsReview }
            do { try await commit(item); release(); return nil }
            catch { release(); throw error }
        }
        let scope = item.scope
        release()
        let allowed = await authorize(scope)
        guard current(id, lease) else { return nil }
        await acquireForWorker(); defer { release() }
        guard current(id, lease), var latest = values[id] else { return nil }
        guard allowed else {
            latest.state = .paused; latest.pause = .revoked
            if latest.hostRevision != nil { latest.hostState = .needsReview }; try await commit(latest); return nil
        }
        let stepID = UUID()
        latest.pendingStepID = stepID; latest.attempts += 1
        if latest.hostRevision != nil { latest.hostState = .queued }
        try await commit(latest) // Must physically finish BEFORE executor entry.
        guard current(id, lease), values[id]?.pendingStepID == stepID else { return nil }
        return BackgroundWorkContext(item: latest, stepID: stepID, mayPerformOperation: { [weak self] in
            self?.current(id, lease) == true && self?.values[id]?.pendingStepID == stepID
        })
    }
    private func finishStep(_ id: UUID, lease: UUID, stepID: UUID, outcome: BackgroundWorkStep) async throws -> Bool {
        await acquireForWorker(); defer { release() }
        guard current(id, lease), var item = values[id], item.pendingStepID == stepID else { return false }
        try apply(outcome, to: &item)
        try await commit(item) // No result or next step before physical completion.
        return current(id, lease)
    }
    private func recordFailure(_ id: UUID, lease: UUID, note: String) async {
        guard current(id, lease) else { return }
        await acquireForWorker(); defer { release() }
        guard current(id, lease), var item = values[id] else { return }
        item.state = .paused; item.pause = item.pendingStepID == nil ? .host : .reconciliation; item.note = note
        if item.hostRevision != nil { item.hostState = .needsReview }
        do { try await commit(item) } catch { failClosed() }
    }
    private func apply(_ outcome: BackgroundWorkStep, to item: inout BackgroundWorkItem) throws {
        switch outcome {
        case .checkpoint(let text): item.checkpoint = text; item.state = .running; item.pause = nil; item.note = ""
        case .completed(let text, let summary):
            item.checkpoint = text; item.note = summary; item.state = .completed; item.pause = nil; item.resultID = UUID()
        case .paused(let text, let note): item.checkpoint = text; item.note = note; item.state = .paused; item.pause = .host
        }
        item.pendingStepID = nil
        if item.hostRevision != nil {
            switch item.state {
            case .completed: item.hostState = .completed; item.hostCompletionID = item.resultID
            case .running: item.hostState = .running
            default: item.hostState = .needsReview
            }
        }
        try BackgroundWorkEngine.validateSnapshot(BackgroundWorkSnapshot(version: 1, items: [item]))
        // The admission reservation is only sound if no outcome exceeds it.
        guard Self.encodedSize(item) <= Self.maximumEncodedItemBytes else { throw BackgroundWorkError.invalidInput }
    }
    private func commit(_ item: BackgroundWorkItem) async throws {
        var item = item
        if let revision = values[item.id]?.hostRevision {
            guard revision < UInt64.max else { throw BackgroundWorkError.storage }
            item.hostRevision = revision + 1
        }
        var next = values; next[item.id] = item
        try await persist(next)
    }
    private static func snapshot(_ values: [UUID: BackgroundWorkItem]) -> BackgroundWorkSnapshot {
        BackgroundWorkSnapshot(version: 1, items: values.values.sorted { $0.id.uuidString < $1.id.uuidString })
    }
    private static func encodedSize(_ item: BackgroundWorkItem) -> Int {
        (try? JSONEncoder().encode(item).count) ?? ledgerBudgetBytes + 1
    }
    /// Worst-case ledger bytes if every running item (and `reserving`) grows to
    /// the per-item bound and every item takes one more host transition.
    private static func worstCaseBytes(_ items: [UUID: BackgroundWorkItem], reserving extra: UUID? = nil) -> Int {
        items.values.reduce(ledgerOverheadBytes) { total, item in
            let grows = item.state == .running || item.id == extra
            return total + max(encodedSize(item), grows ? maximumEncodedItemBytes : 0) + transitionSlackBytes
        }
    }
    /// Under the mutex. Archives settled, resolved items only when an admission
    /// needs the room. Returns false and holds admissions when it still does not
    /// fit, naming unresolved stopped steps when only they stand in the way.
    private func makeRoom(_ admits: ([UUID: BackgroundWorkItem]) -> Bool) async throws -> Bool {
        if admits(values) { admissionHold = nil; return true }
        if try await archiveSettledLocked() > 0, admits(values) { admissionHold = nil; return true }
        let blocking = values.filter { $0.value.state == .cancelled && $0.value.pendingStepID != nil }
        admissionHold = !blocking.isEmpty && admits(values.filter { blocking[$0.key] == nil }) ? .unresolvedEvidence : .ledgerFull
        return false
    }
    /// Under the mutex. Never archives an item whose worker has not physically
    /// returned (its workspace reservation is keyed by the ledger item), nor an
    /// unresolved step (archive retention could drop that evidence).
    private func archiveSettledLocked() async throws -> Int {
        let ids = Set(values.values.filter { BackgroundWorkEngine.isArchivable($0) && workers[$0.id] == nil }.map(\.id))
        guard !ids.isEmpty else { return 0 }
        let expected = generation
        let result: (generation: UInt64, archived: [BackgroundWorkItem])
        do {
            result = try await Task { [storage, storageOwner] in
                try await storage.compactForRunner(archiving: ids, basedOn: expected, owner: storageOwner)
            }.value
        } catch { failClosed(); throw BackgroundWorkError.storage }
        generation = result.generation
        for id in ids { values.removeValue(forKey: id); stopRequests.remove(id) }
        archived = Dictionary(result.archived.filter { values[$0.id] == nil }.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        return ids.count
    }
    private func persist(_ next: [UUID: BackgroundWorkItem]) async throws {
        var next = next
        for (id, var item) in next {
            if let prior = values[id], let revision = prior.hostRevision, item != prior {
                guard revision < UInt64.max else { throw BackgroundWorkError.storage }
                item.hostRevision = revision + 1; next[id] = item
            }
        }
        let nextSnapshot = Self.snapshot(next), expected = generation
        do {
            // One awaited, non-cancelled commit Task while holding the logical
            // mutex. NOT fire-and-forget: caller cancellation cannot erase a
            // physical outcome or make an executor run before its checkpoint.
            generation = try await Task { [storage, storageOwner] in
                try await storage.saveForRunner(nextSnapshot, basedOn: expected, owner: storageOwner)
            }.value
        } catch BackgroundWorkError.capacity {
            // Refused by a pure size check before any I/O: nothing changed on disk.
            // Hold admissions instead of fencing the runner or claiming a storage fault.
            admissionHold = .ledgerFull; throw BackgroundWorkError.ledgerFull
        } catch { failClosed(); throw BackgroundWorkError.storage }
        values = next; onChange?()
    }
    private func failClosed() {
        storageFailed = true; leases.removeAll()
        for (id, worker) in workers { hostExecution?.requestStop(id); worker.task.cancel() }
    }
    /// Host calls only. A full host lane is "busy, try again", never a storage fault.
    private func acquire() async throws {
        if !mutating { mutating = true; workerGrantsPastHost = 0; return }
        guard hostWaiters.count < Self.maximumQueuedMutations else { throw BackgroundWorkError.busy }
        await withCheckedContinuation { hostWaiters.append($0) }
    }
    /// A worker's own transitions. Never refused, so a burst of host calls cannot
    /// stop a finished step from being saved. Bounded by maxConcurrent workers.
    private func acquireForWorker() async {
        if !mutating { mutating = true; return }
        await withCheckedContinuation { workerWaiters.append($0) }
    }
    /// Worker-first with a bounded fairness turn for the oldest host call. The
    /// worker lane is never refused, so its capacity guarantee is unchanged.
    private func release() {
        if !hostWaiters.isEmpty && (workerWaiters.isEmpty || workerGrantsPastHost >= Self.workerGrantsPerHostGrant) {
            workerGrantsPastHost = 0; hostWaiters.removeFirst().resume()
        } else if !workerWaiters.isEmpty {
            if !hostWaiters.isEmpty { workerGrantsPastHost += 1 }
            workerWaiters.removeFirst().resume()
        } else { mutating = false }
    }
}
