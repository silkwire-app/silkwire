import Foundation
import Darwin

/// Staging install and rollback are machine-wide work: they run only in the exclusive
/// lane of `HostExecutionCoordinator` (docs/staging-install-exclusive.md).
///
/// - Admission waits for every held private workspace job, background job and preview
///   (including uncertain ones), and refuses when the caller gives up. It never stops,
///   kills or orphans running work. From the moment it queues, new private work waits.
/// - The installer runs on a host-joined task that is always awaited, even after
///   cancellation; the lane is finished only after it returns, success or failure.
/// - The lane is released only with evidence that the install's ENTIRE workload has
///   ended (`StagingInstallWorkload`): no live descendant of the installer, no orphan that
///   may be one, and no process carrying the install's tag. The installer launches no
///   child process by design (`StagingInstallScope`); the kernel scan is what proves it,
///   including after a crash. Single-purpose hosts (the helper, Try This Build) also
///   watch their own process for forks and name any fork in the evidence.
/// - A durable journal names the exact installer process (audit token) and its kernel
///   lineage BEFORE admission. If that process dies mid-install, `recoverInterrupted`
///   releases the lane only after the kernel shows that exact process gone AND the
///   lineage scan finds nothing left of its workload. A journal without lineage (lost,
///   unreadable, or from an older build) keeps the lane held, with the reason.
@MainActor final class StagingInstallLane {
    enum Action: String, Codable, Sendable { case install, rollback }
    enum Failure: Error, LocalizedError {
        case refused(String)
        var errorDescription: String? { if case .refused(let text) = self { return text }; return nil }
    }
    struct Journal: Codable, Equatable, Sendable {
        /// 3: lineage carries the responsible process's kernel unique ID. Version 2 (never
        /// installed) recorded it as a PID, which can be reused, so it proves nothing.
        var version = 3
        let operationID: UUID
        let action: Action
        let host: HostProcessToken
        let createdAt: Date
        /// Latest reason the lane stayed held when the installer returned. Informational:
        /// recovery re-checks the workload and releases once it is proved ended.
        var unconfirmed: String?
        /// Kernel lineage recorded before any installer code ran (version 2). Without it
        /// the workload can never be proved ended, so recovery keeps the lane held.
        var lineage: StagingInstallWorkload.Lineage?
    }
    enum Recovery: Equatable, Sendable {
        case released(UUID, evidence: String)
        case retained(UUID, reason: String)
    }

    let coordinator: HostExecutionCoordinator
    let observeSelfForks: Bool
    /// The kernel scan; tests inject failures through `StagingInstallWorkload.inspect`.
    var workload: StagingInstallWorkload
    /// Why each install lane recovery could not release is still held, for the UI.
    private(set) var heldReasons: [UUID: String] = [:]
    private var running: Set<UUID> = []
    private var recovering: Task<[Recovery], Never>?
    private var watching: Task<Void, Never>?
    /// Set when the last recovery pass could not read the registry (no verdict at all).
    private(set) var lastRecoveryFailure: String?
    init(coordinator: HostExecutionCoordinator, observeSelfForks: Bool = false, workload: StagingInstallWorkload = .init()) {
        self.coordinator = coordinator; self.observeSelfForks = observeSelfForks; self.workload = workload
    }

    /// Runs `body` (the installer call) as one exclusive operation. `mayOperate` is
    /// polled while waiting; returning false (or cancelling) withdraws the request.
    /// Once admitted, `body` always runs to completion and is always joined.
    func run<T: Sendable>(_ action: Action, operationID: UUID = UUID(), requester: UUID, resource: URL? = nil,
                          mayOperate: @escaping @MainActor () -> Bool = { true },
                          status: @escaping @MainActor (String) -> Void = { _ in },
                          body: @escaping @Sendable () throws -> T) async throws -> T {
        guard !running.contains(operationID) else { throw Failure.refused("This install is already running.") }
        running.insert(operationID); defer { running.remove(operationID) }
        // Provision the registry, then release any lane a crashed installer left behind.
        _ = try await coordinator.admissionState()
        for case .retained(_, let reason) in await recoverInterrupted() { status("An earlier Staging install still holds the lane: " + reason) }
        let lineage: StagingInstallWorkload.Lineage
        do { lineage = try StagingInstallWorkload.lineage() }
        catch { throw Failure.refused("Cannot record the installer's process lineage, so its exit could never be proved. Nothing was installed. " + Self.describe(error)) }
        var journal = Journal(operationID: operationID, action: action, host: try HostProcessToken.read(getpid()), createdAt: Date(), lineage: lineage)
        try Self.save(journal, in: directory)
        var watch: SelfForkWatch?
        if observeSelfForks {
            do { watch = try SelfForkWatch() }
            catch { Self.remove(operationID, in: directory); throw error }
        }
        let resource = resource.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? directory
        let reporter = Task { @MainActor [coordinator, weak self] in
            var last = "", polls = 0
            while !Task.isCancelled {
                if let state = try? await coordinator.admissionState() {
                    // A dead installer's lane is re-checked while we wait, so it frees itself
                    // as soon as its workload is proved ended.
                    var reason: String?
                    if let held = state.exclusiveHeld, held.operationID != operationID {
                        if polls % 8 == 0 { _ = await self?.recoverInterrupted() }
                        reason = self?.heldReasons[held.operationID]
                    }
                    let text = Self.waitingText(state, for: operationID, action: action.rawValue, heldReason: reason) ?? ""
                    if !text.isEmpty, text != last { status(text) }
                    last = text
                }
                polls += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        let admission: HostExecutionAdmission
        do {
            admission = try await coordinator.admitExclusive(operationID: operationID, requester: requester, resource: resource, mayOperate: mayOperate)
            reporter.cancel()
        } catch {
            reporter.cancel()
            // Keep the journal only if a record could still be held (begin I/O failure).
            if (try? await coordinator.storage.snapshot().first { $0.operationID == operationID }?.holdsResources) != true {
                Self.remove(operationID, in: directory)
            }
            if error is CancellationError { throw Failure.refused("The \(action.rawValue) was cancelled while running work finished. Nothing was changed.") }
            throw error
        }
        // Narrow the window to the lane itself (still before any installer code). If this
        // cannot be saved, the earlier, wider watermark stays in force: also sound.
        if let admitted = try? StagingInstallWorkload.watermark() {
            var refined = journal
            refined.lineage?.startWatermark = max(lineage.startWatermark, admitted.unique)
            refined.lineage?.startVersion = max(lineage.startVersion, admitted.version)
            if refined != journal, (try? Self.save(refined, in: directory, replacing: true)) != nil { journal = refined }
        }
        // That refinement forked a counter probe (killed and reaped already): drop its
        // fork event, so the watch reports only forks made from here on.
        let drainFailure = watch?.forkObserved().flatMap { $0.contains("failed") ? $0 : nil }
        status("Running the Staging \(action.rawValue) exclusively; new Silkwire work waits until it finishes.")
        // Anything started inside the lane inherits the tag (setenv/getenv share libc's environ lock).
        setenv(StagingInstallWorkload.tagKey, operationID.uuidString, 1)
        // Joined unconditionally: cancelling the caller never abandons a running installer.
        let outcome = await Task.detached(priority: .userInitiated) {
            StagingInstallScope.$exclusiveOperation.withValue(operationID) { Result { try body() } }
        }.value
        unsetenv(StagingInstallWorkload.tagKey)
        let result = (try? outcome.get()) == nil ? "failed" : "succeeded"
        // Read the fork watch before the counter probe below, which is itself a fork.
        let forkNote = drainFailure ?? watch.map { $0.forkObserved() ?? "Kernel observed no fork of the installer process." }
        watch = nil
        // This host lives on after the call: its later children are not install work.
        if let returned = try? StagingInstallWorkload.watermark(), journal.lineage != nil {
            var marked = journal; marked.lineage?.returnedWatermark = returned.unique
            if (try? Self.save(marked, in: directory, replacing: true)) != nil { journal = marked }
        }
        let verdict = await settle(journal, hostAlive: true)
        let exit: HostPhysicalExit
        switch verdict {
        case .ended(let evidence):
            exit = .verified(evidence: "Staging \(action.rawValue) \(operationID): the installer ran in-process on a host-joined task and returned (\(result)); it launches no child process inside the exclusive lane by design. " + (forkNote.map { $0 + " " } ?? "") + evidence)
        case .survivors, .unprovable:
            let reason = (forkNote.map { $0 + " " } ?? "") + Self.heldText(verdict)
            var held = journal; held.unconfirmed = reason
            try? Self.save(held, in: directory, replacing: true)
            heldReasons[operationID] = reason
            exit = .unconfirmed(reason: reason)
        }
        do { try await coordinator.finish(admission, exit: exit) }
        catch {
            let detail = result == "failed" ? " The \(action.rawValue) itself failed: " + Self.describe(outcome) : " The \(action.rawValue) itself \(result)."
            if case .unconfirmed(let reason) = exit {
                keepRecovering()
                throw Failure.refused("The Staging \(action.rawValue) ended, but its exclusive lane is still held: \(reason) It is released automatically once that is proved.\(detail)")
            }
            throw Failure.refused("The Staging \(action.rawValue) ended, but its exclusive lane is still held: \(Self.describe(error)).\(detail)")
        }
        Self.remove(operationID, in: directory)
        return try outcome.get()
    }

    /// Short-lived strays get a moment to exit before the lane is left held.
    private func settle(_ journal: Journal, hostAlive: Bool) async -> StagingInstallWorkload.Verdict {
        guard let lineage = journal.lineage else { return .unprovable("The install journal has no process lineage.") }
        let scope = StagingInstallWorkload.Scope(host: journal.host, lineage: lineage, tag: journal.operationID.uuidString, hostAlive: hostAlive)
        let workload = workload, clock = ContinuousClock(), grace = clock.now.advanced(by: .seconds(3))
        while true {
            let verdict = await Task.detached(priority: .userInitiated) { await workload.verify(scope) }.value
            guard case .survivors = verdict, clock.now < grace else { return verdict }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    nonisolated static func heldText(_ verdict: StagingInstallWorkload.Verdict) -> String {
        switch verdict {
        case .ended: return ""
        case .survivors(let list):
            let named = list.prefix(4).map(\.text).joined(separator: "; ") + (list.count > 4 ? "; and \(list.count - 4) more" : "")
            return "\(list.count) process\(list.count == 1 ? "" : "es") from the install may still be running: \(named). The lane stays held until \(list.count == 1 ? "it exits" : "they exit")."
        case .unprovable(let why): return "Its processes cannot be proved to have exited: \(why) The lane stays held."
        }
    }

    /// Re-runs recovery every 2 s while an install lane is still held, so the lane frees
    /// itself once its workload is proved ended (bounded to 30 minutes per start). A pass
    /// that can't read the registry is retried, never taken to mean nothing is held.
    func keepRecovering() {
        guard watching == nil else { return }
        watching = Task { @MainActor [weak self] in
            let clock = ContinuousClock(), stop = clock.now.advanced(by: .seconds(1800))
            while clock.now < stop, !Task.isCancelled, let lane = self {
                let results = await lane.recoverInterrupted()
                let held = results.contains(where: { if case .retained = $0 { return true }; return false })
                guard held || lane.lastRecoveryFailure != nil else { break }
                try? await Task.sleep(for: .seconds(2))
            }
            if !Task.isCancelled { self?.watching = nil }
        }
    }
    func stopRecovering() { watching?.cancel(); watching = nil }

    /// Plain words for what an install (operation `id`) is still waiting for, or nil.
    /// Running jobs and finished-but-unproved ones are named separately: only Release
    /// on a job card frees the latter. Running work is never stopped for an install.
    /// `heldReason` is why recovery keeps an earlier install's lane held, if known.
    nonisolated static func waitingText(_ state: PhysicalWorkOwnership.AdmissionState, for id: UUID, action: String, heldReason: String? = nil) -> String? {
        let others = state.held.filter { $0.operationID != id }
        let ahead = state.exclusiveWaiters.prefix { $0.operationID != id }.count
        if let heldReason, others.contains(where: \.exclusive) { return "Waiting for an earlier Staging install that still holds the lane. " + heldReason }
        if others.contains(where: \.exclusive) || ahead > 0 { return "Waiting for another Staging install or exclusive host operation to finish…" }
        guard !others.isEmpty else { return nil }
        let unproved = others.filter { $0.phase == .uncertain }.count, running = others.count - unproved
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running Silkwire job\(running == 1 ? "" : "s") to finish") }
        if unproved > 0 { parts.append("\(unproved) finished job\(unproved == 1 ? "" : "s") whose processes aren't proved to have exited (use Release on \(unproved == 1 ? "its" : "their") job card\(unproved == 1 ? "" : "s"))") }
        return "Waiting for " + parts.joined(separator: " and ") + " before the \(action) starts. Running work is never stopped for an install."
    }

    /// Releases exclusive install lanes whose whole workload is proved ended: the exact
    /// installer process is gone (or returned, for a host that lives on), and the kernel
    /// lineage scan finds no descendant, possible orphan or tagged process. A live
    /// installer, an uninspectable process, a mismatched or missing journal, a journal
    /// without lineage, or any survivor keeps the lane held, with the reason. Never
    /// touches non-install records.
    @discardableResult func recoverInterrupted() async -> [Recovery] {
        if let recovering { return await recovering.value }
        let task = Task { @MainActor in await self.recoverOnce() }
        recovering = task
        let results = await task.value
        recovering = nil
        return results
    }
    private func recoverOnce() async -> [Recovery] {
        var results: [Recovery] = []
        let snapshot: [PhysicalWorkOwnership.Record]
        do { snapshot = try await coordinator.storage.snapshot(); lastRecoveryFailure = nil }
        catch { lastRecoveryFailure = Self.describe(error); return results }
        let journals = Self.journals(in: directory)
        func retain(_ id: UUID, _ reason: String) { results.append(.retained(id, reason: reason)); heldReasons[id] = reason }
        // A held exclusive record with no readable journal: its evidence was lost.
        for record in snapshot where record.holdsResources && record.owner.kind.isExclusive && !journals.contains(where: { $0.operationID == record.operationID }) {
            let id = record.operationID
            guard !running.contains(id), !coordinator.activeOperationIDs.contains(id) else { continue }
            retain(id, "No readable install journal survives for this exclusive operation (\(Self.ownerText(record))), so nothing proves that its installer and every process it started have exited. The lane stays held.")
        }
        for journal in journals {
            let id = journal.operationID
            guard !running.contains(id), !coordinator.activeOperationIDs.contains(id) else { continue }
            let liveness = Self.liveness(journal.host)
            guard let record = snapshot.first(where: { $0.operationID == id }), record.holdsResources else {
                // Finished, abandoned, or never admitted: drop the journal once its writer is gone.
                if liveness == .gone { Self.remove(id, in: directory) }
                heldReasons[id] = nil
                continue
            }
            guard record.owner.kind.isExclusive else { retain(id, "The install journal does not match the held exclusive record. The lane stays held."); continue }
            guard journal.version >= 3, let lineage = journal.lineage, lineage.hostResponsibleUnique != nil else {
                retain(id, "Its install journal has no usable record of the installer's process lineage (it was written by an older build, or that evidence was lost), so processes it may have started cannot be ruled out. The lane stays held.")
                continue
            }
            // Journal and record must name the same installer process by kernel unique ID
            // (the PIDs must agree too, but never decide alone).
            guard let ownerUnique = record.ownerUnique else {
                retain(id, "The held exclusive record has no kernel identity for its owner (it was written by an older build), so it can't be matched to its install journal. The lane stays held.")
                continue
            }
            guard ownerUnique == lineage.hostUnique, record.ownerPID == journal.host.pid else {
                retain(id, "The install journal does not match the held exclusive record (\(Self.ownerText(record))). The lane stays held.")
                continue
            }
            let hostAlive: Bool
            switch liveness {
            case .unknown: retain(id, "Its installer process (\(Self.installerText(journal))) cannot be inspected."); continue
            case .alive:
                // Only once that host has itself finished the lane as unproved, never mid-finish.
                guard lineage.returnedWatermark != nil, record.phase == .uncertain else { retain(id, "Its installer process (\(Self.installerText(journal))) is still running."); continue }
                hostAlive = true
            case .gone: hostAlive = false
            }
            let scope = StagingInstallWorkload.Scope(host: journal.host, lineage: lineage, tag: id.uuidString, hostAlive: hostAlive)
            let workload = workload
            let verdict = await Task.detached(priority: .userInitiated) { await workload.verify(scope) }.value
            guard case .ended(let scan) = verdict else { retain(id, Self.heldText(verdict)); continue }
            let evidence = hostAlive
                ? "Staging \(journal.action.rawValue) \(id): its installer call had returned; every process that kept the lane held has exited. " + scan
                : "Staging \(journal.action.rawValue) \(id) was interrupted: kernel shows its exact installer process (\(Self.installerText(journal))) has exited. " + scan + " The next install or rollback repairs its files first."
            do {
                // Exact-snapshot reconcile: refused if the record changed since it was inspected.
                try await coordinator.reconcileAfterPhysicalExit(record, evidence: evidence)
                Self.remove(id, in: directory)
                heldReasons[id] = nil
                results.append(.released(id, evidence: evidence))
            } catch { retain(id, "Release failed: " + Self.describe(error)) }
        }
        return results
    }

    /// How the installer process is named to people: by its stable kernel identity.
    nonisolated static func installerText(_ journal: Journal) -> String {
        let unique = journal.lineage.map { "kernel unique ID \($0.hostUnique), " } ?? ""
        return "\(unique)PID \(journal.host.pid) at audit generation \(journal.host.words[7])"
    }
    nonisolated static func ownerText(_ record: PhysicalWorkOwnership.Record) -> String {
        record.ownerUnique.map { "its owner was kernel unique ID \($0), PID \(record.ownerPID)" } ?? "its owner's kernel identity was not recorded; PID \(record.ownerPID) at the time"
    }

    // MARK: Durable journal (0600 files in the 0700 registry directory)

    private var directory: URL { coordinator.storage.directory }
    nonisolated private static let prefix = "staging-install-"
    nonisolated private static func name(_ id: UUID) -> String { prefix + id.uuidString + ".json" }
    nonisolated static func save(_ journal: Journal, in directory: URL, replacing: Bool = false) throws {
        let data = try JSONEncoder().encode(journal)
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw Failure.refused("The ownership registry is unavailable. Nothing was installed.") }
        defer { close(dir) }
        let temporary = "." + prefix + UUID().uuidString
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.refused("Cannot record the install journal. Nothing was installed.") }
        defer { close(fd); unlinkat(dir, temporary, 0) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0 else { throw Failure.refused("Cannot record the install journal. Nothing was installed.") }
        if !replacing {
            var existing = stat()
            guard fstatat(dir, name(journal.operationID), &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw Failure.refused("An install journal for this operation already exists. Nothing was installed.")
            }
        }
        guard renameat(dir, temporary, dir, name(journal.operationID)) == 0, fsync(dir) == 0 else {
            throw Failure.refused("Cannot commit the install journal. Nothing was installed.")
        }
    }
    nonisolated static func remove(_ id: UUID, in directory: URL) {
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return }
        unlinkat(dir, name(id), 0); fsync(dir); close(dir)
    }
    nonisolated static func journals(in directory: URL) -> [Journal] {
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return [] }
        defer { close(dir) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted()
        return names.compactMap { file in
            let fd = openat(dir, file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
                  info.st_nlink == 1, (1...65536).contains(info.st_size) else { return nil }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
            guard read(fd, &bytes, bytes.count) == bytes.count, let journal = try? JSONDecoder().decode(Journal.self, from: Data(bytes)),
                  [1, 2, 3].contains(journal.version), file == name(journal.operationID), journal.host.words.count == 8 else { return nil }
            return journal
        }
    }

    // MARK: Exact-process liveness (audit token PID + generation, never a bare PID)

    enum Liveness: Equatable { case alive, gone, unknown }
    nonisolated static func liveness(_ token: HostProcessToken) -> Liveness {
        guard token.words.count == 8, token.pid > 0 else { return .unknown }
        if kill(token.pid, 0) != 0, errno == ESRCH { return .gone }
        guard let now = try? HostProcessToken.read(token.pid) else {
            return kill(token.pid, 0) != 0 && errno == ESRCH ? .gone : .unknown
        }
        // Same PID with a different generation is a different, later process.
        return now.words[5] == token.words[5] && now.words[7] == token.words[7] ? .alive : .gone
    }
    nonisolated static func describe(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    nonisolated static func describe<T>(_ outcome: Result<T, Error>) -> String {
        if case .failure(let error) = outcome { return describe(error) }; return "succeeded"
    }
}

/// Kernel NOTE_FORK watch on this process, for hosts whose only work is the install.
final class SelfForkWatch: @unchecked Sendable {
    private let queue: Int32
    init() throws {
        queue = kqueue()
        guard queue >= 0 else { throw StagingInstallLane.Failure.refused("Cannot watch the installer process for forks. Nothing was installed.") }
        var change = kevent64_s()
        change.ident = UInt64(getpid()); change.filter = Int16(EVFILT_PROC)
        change.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR); change.fflags = UInt32(NOTE_FORK)
        guard kevent64(queue, &change, 1, nil, 0, 0, nil) == 0 else {
            close(queue); throw StagingInstallLane.Failure.refused("The kernel refused to watch the installer process for forks. Nothing was installed.")
        }
    }
    /// A note if a fork (or a failed observation) happened since init; nil otherwise. The
    /// lineage scan, not this watch, decides whether the lane may be released.
    func forkObserved() -> String? {
        while true {
            var event = kevent64_s(), timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let count = kevent64(queue, nil, 0, &event, 1, 0, &timeout)
            if count < 0 && errno == EINTR { continue }
            if count < 0 || (count > 0 && event.flags & UInt16(EV_ERROR) != 0) { return "The installer's kernel fork watch failed." }
            if count == 0 { return nil }
            if event.fflags & UInt32(NOTE_FORK) != 0 { return "Kernel observed the installer process fork during the exclusive lane." }
        }
    }
    deinit { close(queue) }
}
