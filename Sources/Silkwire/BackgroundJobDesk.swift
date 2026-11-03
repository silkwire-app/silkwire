import Foundation

/// Chat side of background work (contract v1, BackgroundJobHost). It hands a teammate's
/// long step to the host, keeps that conversation's job card in step with the host's
/// snapshots, posts each completed result exactly once, and drives the verification-only
/// Release action. It runs, stops, releases and owns nothing itself.
@MainActor final class BackgroundJobDesk {
    /// Host wiring supplied by the application: the host registered for a conversation
    /// (BackgroundJobHostInjection.host(for:)) and the same fresh scope resolver the
    /// HostJobCommandRouter uses. Neither accepts agent-supplied paths or scopes.
    struct Wiring {
        let host: (UUID) throws -> any BackgroundJobHost
        let scope: HostJobCommandRouter.Scope
        /// Opens this conversation's host if it isn't open yet (BackgroundJobBootstrap.open).
        var open: ((UUID) async throws -> Void)? = nil
        /// Library bootstrap, called once the store has loaded its conversations.
        var attach: ((ConversationStore) async -> Void)? = nil
        /// The D2 registry and trusted-workspace exit verifier the room and Builder share
        /// with the hosts, so foreground and background work use one slot.
        var ownership: HostExecutionCoordinator? = nil
        var verifyForegroundExit: HostExitVerifier? = nil
        /// The router NativeRoom takes (room-host-insertion.patch): same host and scope.
        @MainActor var router: HostJobCommandRouter {
            let host = self.host, open = self.open
            return HostJobCommandRouter(scope: scope, service: { conversationID in
                try await open?(conversationID)
                return try host(conversationID)
            })
        }
    }
    enum Submission { case accepted(BackgroundJobCard), refused(String) }

    private let wiring: Wiring
    private weak var store: ConversationStore?
    private var subscriptions: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Results inserted but not yet known durable: never acknowledged meanwhile.
    private var delivering: Set<UUID> = []
    init(wiring: Wiring, store: ConversationStore) { self.wiring = wiring; self.store = store }
    deinit { for task in subscriptions.values { task.cancel() } }

    /// Saves the card, then awaits the host's durable acceptance (never execution).
    func submit(conversationID: UUID, agent: String, workspaceID: UUID, args: [String: Any], originRequestID: String) async -> Submission {
        guard let store, store.savedConversation(conversationID) != nil else { return .refused("No operation ran: this conversation is no longer open.") }
        let card = BackgroundJobCard(id: UUID(), agent: agent, title: BackgroundJobText.title(args), originRequestID: originRequestID,
                                     work: (try? nativeJSON(args)) ?? "{}", workspaceID: workspaceID)
        store.updateConversation(conversationID) { room in
            var cards = room.backgroundJobs ?? []
            cards.append(card)
            // Keep the newest; only finished, settled cards are ever dropped.
            while cards.count > BackgroundJobText.maximumCards, let old = cards.firstIndex(where: { $0.isEnded && !$0.holdsWorkspace && ($0.resultID == nil || $0.resultAcknowledged) }) { cards.remove(at: old) }
            room.backgroundJobs = cards
        }
        // The card is on disk before the host can accept, so a crash never hides accepted work.
        guard await store.saveDurably() else {
            update(card.id, in: conversationID) { $0.phase = .notAccepted; $0.note = "Not started: this conversation couldn't be saved." }
            return .refused("No operation ran: this conversation couldn't be saved.")
        }
        do {
            try await wiring.open?(conversationID)
            let host = try wiring.host(conversationID)
            subscribe(host)
            let scope = try await wiring.scope(conversationID, workspaceID, agent)
            guard scope.conversationID == conversationID, scope.workspaceID == workspaceID, scope.agentID == agent else { throw HostExecutionCoordinator.Failure.permissionChanged }
            let accepted = try await host.submit(HostJobRequest(operationID: card.id, scope: scope, workDescription: card.title, limits: .init(totalSteps: 1, stepsPerSlice: 1)))
            guard accepted == card.id else { throw BackgroundWorkError.reconciliationRequired }
            if let snapshot = host.snapshot(card.id) { apply(snapshot, in: conversationID) }
            else { update(card.id, in: conversationID) { $0.phase = .queued } }
            // A Stop pressed while the submission was in flight applies now.
            if self.card(card.id, in: conversationID)?.stopRequested == true { requestStop(card.id, host: host, conversationID: conversationID) }
            Task { @MainActor [weak self] in await self?.refreshHolds(host, conversationID: conversationID) }
            store.saveSoon()
            return .accepted(self.card(card.id, in: conversationID) ?? card)
        } catch {
            let reason = Self.describe(error)
            let review = (error as? BackgroundWorkError) == .reconciliationRequired
            update(card.id, in: conversationID) { $0.phase = review ? .needsReview : .notAccepted; $0.note = reason; $0.endedAt = Date(); $0.physicalChecked = true }
            store.saveSoon()
            return .refused((review ? "The work host needs review before this run can be trusted: " : "No operation ran: the work host did not accept this run. ") + reason)
        }
    }
    /// The teammate's workspace is still in use by its work here (or may be, physically).
    func hasWorkInProgress(agent: String, conversationID: UUID) -> Bool {
        store?.savedConversation(conversationID)?.backgroundJobs?.contains { $0.agent == agent && $0.holdsWorkspace } == true
    }
    /// The teammate's exact WORK_PROJECT JSON for this job: quoted request data the
    /// application host's Plan/Prepare callback may read and must validate. Not a grant.
    func requestedWork(job: UUID, conversationID: UUID) -> String? { card(job, in: conversationID)?.work }
    /// The requester and workspace on the job's card, with its exact request.
    func requestedJob(job: UUID, conversationID: UUID) -> (agent: String, workspaceID: UUID, work: String)? {
        card(job, in: conversationID).map { ($0.agent, $0.workspaceID, $0.work) }
    }
    /// The command bridge refused to plan this job: show its plain reason on the card.
    func noteRefusal(_ job: UUID, conversationID: UUID, reason: String) {
        update(job, in: conversationID) { $0.refusal = limitedUTF16(reason, to: 400) }
        store?.saveSoon()
    }
    /// Card Stop: fence now, then record the durable acknowledgement separately.
    func stop(_ job: UUID, conversationID: UUID) {
        guard let card = card(job, in: conversationID), card.mayStop else { return }
        update(job, in: conversationID) { $0.stopRequested = true }
        store?.saveSoon()
        guard card.phase != .submitting, let host = try? wiring.host(conversationID) else { return } // submit applies it on acceptance
        requestStop(job, host: host, conversationID: conversationID)
    }
    private func requestStop(_ job: UUID, host: any BackgroundJobHost, conversationID: UUID) {
        host.requestStop(job)
        if let snapshot = host.snapshot(job) { apply(snapshot, in: conversationID) }
        Task { @MainActor [weak self] in
            do {
                let acknowledgement = try await host.stop(job)
                self?.update(job, in: conversationID) { $0.stopRecorded = acknowledgement.stopRequested; $0.stopError = nil }
            } catch {
                self?.update(job, in: conversationID) { $0.stopError = "Stop wasn't recorded durably: " + Self.describe(error) }
            }
            if let snapshot = host.snapshot(job) { self?.apply(snapshot, in: conversationID) }
            self?.store?.saveSoon()
        }
    }
    /// Release: ask the host to verify the physical exit afresh. It may say "retained"
    /// with a reason, which the card shows. Nothing is ever forced.
    func release(_ job: UUID, conversationID: UUID) {
        guard let card = card(job, in: conversationID), card.mayRelease, let operation = card.operationID,
              let host = try? wiring.host(conversationID) else { return }
        update(job, in: conversationID) { $0.releasing = true; $0.releaseNote = "Checking that the work really ended…" }
        Task { @MainActor [weak self] in
            var note: String
            do {
                let check = try await host.checkPhysicalExit(operationID: operation)
                switch try await host.reconcilePhysicalExit(check) {
                case .released(_, let evidence): note = "Released · " + evidence
                case .retained(_, let reason): note = "Still held · " + reason
                }
            } catch { note = "Still held · couldn't verify: " + Self.describe(error) }
            self?.update(job, in: conversationID) { $0.releasing = false; $0.releaseNote = limitedUTF16(note, to: 400) }
            await self?.refreshHolds(host, conversationID: conversationID)
        }
    }
    /// After launch, or once the app has registered hosts: re-attach every card that
    /// still needs the host (running work, unacknowledged results, physical holds).
    func restore(_ conversations: [Conversation]) {
        for room in conversations {
            let cards = (room.backgroundJobs ?? []).filter { !$0.isEnded || $0.holdsWorkspace || !$0.physicalChecked || ($0.phase == .completed && !$0.resultAcknowledged) }
            guard !cards.isEmpty, let host = try? wiring.host(room.id) else { continue }
            subscribe(host)
            for card in cards {
                if let snapshot = host.snapshot(card.id) { apply(snapshot, in: room.id); continue }
                update(card.id, in: room.id) { card in
                    if card.phase == .submitting {
                        card.phase = .notAccepted; card.note = "The app closed before the work host accepted this run. Nothing ran."
                    } else if !card.isEnded {
                        card.phase = .unknown; card.note = "The work host has no record of this job."
                    }
                    card.endedAt = card.endedAt ?? Date()
                }
            }
            deliverResults(host)
            Task { @MainActor [weak self] in await self?.refreshHolds(host, conversationID: room.id) }
        }
        store?.saveSoon()
    }
    func close() { for task in subscriptions.values { task.cancel() }; subscriptions = [:] }

    // MARK: Host events
    private func subscribe(_ host: any BackgroundJobHost) {
        let key = ObjectIdentifier(host)
        guard subscriptions[key] == nil else { return }
        let stream = host.events()
        // Observation never owns the work: ending this loop cancels nothing.
        subscriptions[key] = Task { @MainActor [weak self, weak host] in
            for await event in stream {
                guard let self, let host, !Task.isCancelled else { return }
                // Events may be dropped or repeated: the current snapshot is authoritative.
                let latest = host.snapshot(event.jobID) ?? event
                guard self.card(latest.jobID, in: latest.originatingConversationID) != nil else { continue }
                let wasEnded = self.card(latest.jobID, in: latest.originatingConversationID)?.isEnded == true
                self.apply(latest, in: latest.originatingConversationID)
                if latest.state == .completed { self.deliverResults(host) }
                if [.failed, .needsReview].contains(latest.state), !wasEnded, BackgroundJobText.isReportedFailure(latest.note) { self.announceEnding(latest) }
                if [.completed, .failed, .needsReview].contains(latest.state), !wasEnded {
                    await self.refreshHolds(host, conversationID: latest.originatingConversationID)
                    // The slot may have changed hands: refresh every conversation's queued cards.
                    for room in self.store?.conversations ?? [] where room.id != latest.originatingConversationID && room.backgroundJobs?.contains(where: { $0.phase == .queued }) == true {
                        await self.refreshHolds(host, conversationID: room.id)
                    }
                }
            }
        }
    }
    private func apply(_ snapshot: HostJobSnapshot, in conversationID: UUID) {
        guard let card = card(snapshot.jobID, in: conversationID), snapshot.revision >= card.revision else { return }
        let phase = BackgroundJobCard.Phase(snapshot.state)
        update(snapshot.jobID, in: conversationID) { card in
            if phase.isEndedPhase, !card.isEnded { card.physicalChecked = false; card.endedAt = Date() }
            card.phase = phase; card.revision = snapshot.revision
            card.progress = limitedUTF16(snapshot.progress, to: 240); card.note = limitedUTF16(snapshot.note, to: 1000)
            if let operation = snapshot.pendingOperationID { card.operationID = operation }
            card.completionID = snapshot.completionID ?? card.completionID
            if card.startedAt == nil, [.running, .stopping, .completed].contains(phase) { card.startedAt = Date() }
            if phase != .queued { card.waiting = nil }
            if snapshot.resultAcknowledged { card.resultAcknowledged = true }
        }
        store?.saveSoon()
    }
    /// A job that ends without success gets one plain line in its room, and its owner a
    /// short turn to explain, instead of only a quiet card. Keyed by job, so a repeated or
    /// replayed event never posts twice. Only live transitions announce: old jobs that
    /// ended before this launch keep their cards and don't flood the room.
    private func announceEnding(_ snapshot: HostJobSnapshot) {
        guard let store, let card = card(snapshot.jobID, in: snapshot.originatingConversationID),
              let room = store.savedConversation(snapshot.originatingConversationID) else { return }
        let key = "ended-" + snapshot.jobID.uuidString.lowercased()
        guard !room.messages.contains(where: { $0.author == BackgroundJobText.resultAuthor && $0.requestId == key }) else { return }
        let text = BackgroundJobText.ended(card, note: snapshot.note)
        var notice = Message(author: BackgroundJobText.resultAuthor, text: text, state: "completed", requestId: key, detail: "Background job ended · host evidence")
        notice.unread = true
        store.updateConversation(room.id) { room in room.messages.append(notice); room.updatedAt = Date() }
        store.saveSoon()
        store.backgroundJobFinished(card, receipt: text, conversationID: room.id)
    }
    /// Inserts each pending result once (keyed by resultID), saves, THEN acknowledges.
    private func deliverResults(_ host: any BackgroundJobHost) {
        guard let store else { return }
        for item in host.pendingResults {
            guard let resultID = item.resultID, !delivering.contains(resultID),
                  let card = card(item.id, in: item.scope.conversationID), let room = store.savedConversation(item.scope.conversationID) else { continue }
            let key = resultID.uuidString.lowercased()
            if room.messages.contains(where: { $0.author == BackgroundJobText.resultAuthor && $0.requestId == key }) {
                // Already in the transcript (on disk): only the acknowledgement was missing.
                acknowledge(item.id, resultID: resultID, host: host, conversationID: room.id)
                continue
            }
            let summary = item.note.isEmpty ? item.checkpoint : item.note
            let text = BackgroundJobText.receipt(card, summary: summary)
            var receipt = Message(author: BackgroundJobText.resultAuthor, text: text, state: "completed", requestId: key, detail: "Background job result · host evidence")
            receipt.unread = true
            delivering.insert(resultID)
            store.updateConversation(room.id) { room in
                room.messages.append(receipt); room.updatedAt = Date()
                if let index = room.backgroundJobs?.firstIndex(where: { $0.id == item.id }) { room.backgroundJobs![index].resultID = resultID }
            }
            var settled = card; settled.resultID = resultID
            Task { @MainActor [weak self, weak store] in
                guard let self, let store else { return }
                // Unsaved: stay in `delivering`, so this session never acknowledges it.
                guard await store.saveDurably() else { return }
                self.delivering.remove(resultID)
                self.acknowledge(item.id, resultID: resultID, host: host, conversationID: room.id)
                store.backgroundJobFinished(settled, receipt: text, conversationID: room.id)
            }
        }
    }
    private func acknowledge(_ job: UUID, resultID: UUID, host: any BackgroundJobHost, conversationID: UUID) {
        Task { @MainActor [weak self] in
            // A failure leaves the host's result pending; the next poll or launch retries.
            guard (try? await host.acknowledgeResult(job, resultID: resultID)) == true else { return }
            self?.update(job, in: conversationID) { $0.resultAcknowledged = true }
            self?.store?.saveSoon()
        }
    }
    private func refreshHolds(_ host: any BackgroundJobHost, conversationID: UUID) async {
        let everything: [HostHeldPhysicalOperation]
        do { everything = try await host.heldPhysicalOperations() }
        catch { return } // Unknown: cards stay unchecked ("Stopping…"), never "Stopped".
        let held = everything.filter { $0.originatingConversationID == conversationID }
        let cards = store?.savedConversation(conversationID)?.backgroundJobs ?? []
        // A queued job waits for the one slot. Say what holds it when that's known.
        let stuck = everything.first { $0.phase == .uncertain }
        let runningHere = cards.first { [.running, .stopping].contains($0.phase) }
        for card in cards where card.phase == .queued {
            let reason: String?
            if let runningHere { reason = "Waiting for the work slot: \(names[runningHere.agent] ?? runningHere.agent)'s job is running." }
            else if let stuck { reason = "Waiting for the work slot, which earlier work still holds: " + stuck.reason }
            else if !everything.isEmpty { reason = "Waiting for the work slot." }
            else { reason = nil }
            if card.waiting != reason { update(card.id, in: conversationID) { $0.waiting = reason.map { limitedUTF16($0, to: 400) } } }
        }
        for card in cards where card.isEnded || card.physicalHold != nil {
            let hold = card.operationID.flatMap { operation in held.first { $0.operationID == operation } }
            update(card.id, in: conversationID) { card in
                card.physicalChecked = true
                card.physicalHold = hold.map { limitedUTF16($0.reason, to: 400) }
            }
        }
        store?.saveSoon()
    }

    // MARK: Card storage
    private func card(_ job: UUID, in conversationID: UUID) -> BackgroundJobCard? {
        store?.savedConversation(conversationID)?.backgroundJobs?.first { $0.id == job }
    }
    private func update(_ job: UUID, in conversationID: UUID, _ change: (inout BackgroundJobCard) -> Void) {
        store?.updateConversation(conversationID) { room in
            guard let index = room.backgroundJobs?.firstIndex(where: { $0.id == job }) else { return }
            change(&room.backgroundJobs![index])
        }
    }
    static func describe(_ error: Error) -> String {
        switch error {
        case BackgroundWorkError.busy: return "The work queue is full. Try again when a job finishes."
        case BackgroundWorkError.unavailable: return "The work host isn't available for this conversation."
        case BackgroundWorkError.reconciliationRequired: return "This job's identity was already used; it needs review."
        case BackgroundWorkError.invalidInput: return "The work request was invalid."
        case BackgroundWorkError.storage: return "The work host couldn't save its record."
        case HostExecutionCoordinator.Failure.permissionChanged: return "Permissions changed, so the work host refused it."
        case HostExecutionCoordinator.Failure.queueFull: return "Too many jobs are waiting for the work slot."
        default: return NativeBuilder.scrub(error.localizedDescription)
        }
    }
}

private extension BackgroundJobCard.Phase {
    var isEndedPhase: Bool { [.completed, .failed, .needsReview].contains(self) }
}
