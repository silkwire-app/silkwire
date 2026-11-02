import Foundation
import Darwin

/// Cooperative, host-owned admission for physical work. No implicit storage path,
/// provider, timer, PID-based recovery, or deinit release. Call from a disk executor.
/// Every participant MUST use the same durable registry directory and capacity.
///
/// Two kinds of admitted work (see docs/safe-parallel-ownership.md):
/// - Private workspace work (`foregroundBuild`, `backgroundJob`) runs side by side up to
///   `capacity`, never two on the same or overlapping workspace (`workspaceBusy`).
/// - Exclusive work (`exclusiveOperation`) touches shared, machine-wide resources. It is
///   admitted only when nothing else holds resources, and while it is held or queued no
///   new private work is admitted (`exclusiveHeld` / `exclusivePending`). Its queue entry
///   (`ExclusiveWaiter`) never holds physical work, so it only orders admission: safety
///   always comes from the held records.
struct PhysicalWorkOwnership: Sendable {
    enum Failure: Error, Equatable {
        case invalidInput, unsafeRegistry, unavailable, registryBusy
        case configurationMismatch, workspaceBusy, limitReached, operationAlreadyKnown, invalidLease
        case invalidTransition
        /// Private work refused while an exclusive operation holds the registry.
        case exclusiveHeld
        /// Private work refused while an exclusive operation is queued (it waits for the
        /// running work and is not starved by new arrivals).
        case exclusivePending
        case io(Int32)
    }
    enum Kind: String, Codable, Sendable {
        case foregroundBuild, backgroundJob
        /// Shared, machine-wide resources: waits for, and blocks, all other work.
        case exclusiveOperation
        var isExclusive: Bool { self == .exclusiveOperation }
    }
    enum Phase: String, Codable, Sendable { case reserved, executing, uncertain, finished, abandoned }
    struct Owner: Codable, Equatable, Sendable {
        let conversationID: UUID
        let kind: Kind
    }
    struct Workspace: Codable, Equatable, Sendable {
        let path: String
        let device: UInt64
        let inode: UInt64

        /// Existing directories only. Symlinks, dot components and case aliases
        /// converge by physical directory identity; lexical path also stays fenced.
        static func canonical(_ url: URL) throws -> Workspace {
            guard url.isFileURL, let resolved = realpath(url.path, nil) else { throw Failure.invalidInput }
            defer { free(resolved) }
            let path = String(cString: resolved)
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.invalidInput }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw Failure.io(errno) }
            return Workspace(path: path, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
        }
        fileprivate func conflicts(_ other: Workspace) -> Bool {
            path == other.path || (device == other.device && inode == other.inode)
        }
    }
    struct Record: Codable, Equatable, Sendable {
        let operationID: UUID
        let owner: Owner
        let ownerPID: Int32 // Diagnostic only: never used to reclaim ownership.
        /// The owning process's kernel unique ID (never reused, unlike a PID). Nil in
        /// records written by older builds.
        var ownerUnique: UInt64? = nil
        let workspace: Workspace
        let createdAt: Date
        fileprivate let secret: UUID
        var phase: Phase
        var stopRequested: Bool
        var evidence: String?
        var executionAttemptID: UUID { secret }
        var holdsResources: Bool { phase != .finished && phase != .abandoned }
        var exclusive: Bool { owner.kind.isExclusive }
    }
    /// A queued exclusive request. Holds no physical work: it only fences NEW private
    /// admissions so the exclusive operation is not starved. The waiter refreshes it on
    /// every attempt; an entry not refreshed within `waiterLifetime` (its process died or
    /// gave up) is pruned. Pruning can only change ordering, never exclusion.
    struct ExclusiveWaiter: Codable, Equatable, Sendable {
        let operationID: UUID
        let owner: Owner
        let queuedAt: Date
        var refreshedAt: Date
    }
    enum ExclusiveReservation: Sendable {
        case admitted(Lease)
        /// Still queued: `holders` records hold resources, `ahead` exclusive requests are earlier.
        case waiting(holders: Int, ahead: Int)
    }
    struct AdmissionState: Sendable {
        let capacity: Int
        let records: [Record]
        let exclusiveWaiters: [ExclusiveWaiter]
        var held: [Record] { records.filter(\.holdsResources) }
        var exclusiveHeld: Record? { held.first(where: \.exclusive) }
    }
    /// Opaque authority for the admitting process, deliberately not Codable.
    struct Lease: Sendable {
        let operationID: UUID
        fileprivate let secret: UUID
    }
    private struct Alias: Codable { let workspace: Workspace; let conflictRoot: Workspace }
    private struct Ledger: Codable {
        var version: Int
        var capacity: Int
        var records: [Record]
        var hostAliases: [Alias]? = nil
        var hostJobIdentities: [String: String]? = nil
        /// Version 3 only. FIFO: only the first live waiter may be admitted.
        var exclusiveWaiters: [ExclusiveWaiter]? = nil
    }
    private let root: Workspace
    let capacity: Int
    private static let byteLimit = 4 * 1024 * 1024
    private static let recordLimit = 10_000
    private static let waiterLimit = 64
    static let waiterLifetime: TimeInterval = 15
    /// Version 3 adds exclusive operations and capacity migration. Every older binary
    /// accepts only versions 1 and 2, so it refuses a v3 ledger instead of reading an
    /// exclusive record as ordinary workspace work.
    private static let currentVersion = 3

    /// Caller provisions a stable, private, mode-0700 directory on a local disk.
    /// Missing state behind an existing lock fails closed (including interrupted
    /// bootstrap). Never delete, rotate or replace either file while in service.
    init(directory: URL, capacity: Int) throws {
        guard (1...256).contains(capacity) else { throw Failure.invalidInput }
        root = try Workspace.canonical(directory); self.capacity = capacity
        try transaction(bootstrap: true) { _ in }
    }

    /// Reserves workspace AND one global worker slot in one durable transaction.
    /// An operation UUID is an idempotency fence, including after completion.
    /// No cancellation check after commit: a committed lease must reach its caller.
    /// Private workspace work only; exclusive work uses `reserveExclusive`.
    func reserve(workspace: URL, owner: Owner, operationID: UUID) throws -> Lease {
        try Task.checkCancellation()
        guard !owner.kind.isExclusive else { throw Failure.invalidInput }
        let requested = try Workspace.canonical(workspace)
        return try transaction { ledger in
            let canonical = Self.conflictRoot(requested, in: ledger)
            try Task.checkCancellation()
            guard !ledger.records.contains(where: { $0.operationID == operationID }) else { throw Failure.operationAlreadyKnown }
            guard !ledger.records.contains(where: { $0.holdsResources && $0.exclusive }) else { throw Failure.exclusiveHeld }
            guard (ledger.exclusiveWaiters ?? []).isEmpty else { throw Failure.exclusivePending }
            guard !ledger.records.contains(where: { $0.holdsResources && $0.workspace.conflicts(canonical) }) else { throw Failure.workspaceBusy }
            guard ledger.records.filter(\.holdsResources).count < capacity else { throw Failure.limitReached }
            guard ledger.records.count < Self.recordLimit else { throw Failure.unavailable }
            let secret = UUID()
            ledger.records.append(Record(operationID: operationID, owner: owner, ownerPID: getpid(), ownerUnique: Self.ownUnique, workspace: canonical,
                createdAt: Date(), secret: secret, phase: .reserved, stopRequested: false))
            return Lease(operationID: operationID, secret: secret)
        }
    }

    /// Queues (or refreshes) an exclusive request and admits it once NOTHING else holds
    /// resources and no earlier exclusive request is queued. `resource` names what it
    /// touches (diagnostic; any existing directory). Call again until `.admitted`, or
    /// `withdrawExclusive` when giving up. The queue entry is committed even while
    /// waiting, so new private work is refused from the first call.
    func reserveExclusive(resource: URL, owner: Owner, operationID: UUID) throws -> ExclusiveReservation {
        try Task.checkCancellation()
        guard owner.kind.isExclusive else { throw Failure.invalidInput }
        let workspace = try Workspace.canonical(resource)
        return try transaction { ledger in
            try Task.checkCancellation()
            guard !ledger.records.contains(where: { $0.operationID == operationID }) else { throw Failure.operationAlreadyKnown }
            let now = Date()
            var waiters = ledger.exclusiveWaiters ?? []
            if let index = waiters.firstIndex(where: { $0.operationID == operationID }) {
                guard waiters[index].owner == owner else { throw Failure.operationAlreadyKnown }
                waiters[index].refreshedAt = now
            } else {
                guard waiters.count < Self.waiterLimit else { throw Failure.limitReached }
                waiters.append(ExclusiveWaiter(operationID: operationID, owner: owner, queuedAt: now, refreshedAt: now))
            }
            ledger.version = Self.currentVersion
            let holders = ledger.records.filter(\.holdsResources).count
            let ahead = waiters.prefix(while: { $0.operationID != operationID }).count
            guard holders == 0, ahead == 0, ledger.records.count < Self.recordLimit else {
                ledger.exclusiveWaiters = waiters
                return .waiting(holders: holders, ahead: ahead)
            }
            waiters.removeFirst()
            ledger.exclusiveWaiters = waiters.isEmpty ? nil : waiters
            let secret = UUID()
            ledger.records.append(Record(operationID: operationID, owner: owner, ownerPID: getpid(), ownerUnique: Self.ownUnique, workspace: workspace,
                createdAt: now, secret: secret, phase: .reserved, stopRequested: false))
            return .admitted(Lease(operationID: operationID, secret: secret))
        }
    }
    /// Removes a queued exclusive request (no-op once admitted or unknown).
    func withdrawExclusive(operationID: UUID) throws {
        try transaction { ledger in
            guard let waiters = ledger.exclusiveWaiters else { return }
            let remaining = waiters.filter { $0.operationID != operationID }
            ledger.exclusiveWaiters = remaining.isEmpty ? nil : remaining
        }
    }
    func admissionState() throws -> AdmissionState {
        try transaction { AdmissionState(capacity: capacity, records: $0.records, exclusiveWaiters: $0.exclusiveWaiters ?? []) }
    }

    /// Durable submit identity tombstones, independent of bounded result archives.
    /// A crash between this claim and the runner enqueue requires review, never replay.
    func claimHostJob(operationID: UUID, fingerprint: String) throws -> Bool {
        guard fingerprint.count == 64, fingerprint.allSatisfy({ $0.isHexDigit }) else { throw Failure.invalidInput }
        return try transaction { ledger in
            let key = operationID.uuidString
            if let existing = ledger.hostJobIdentities?[key] {
                guard existing == fingerprint else { throw Failure.operationAlreadyKnown }
                return false
            }
            guard (ledger.hostJobIdentities?.count ?? 0) < Self.recordLimit else { throw Failure.unavailable }
            ledger.version = max(ledger.version, 2) // Older D2 binaries must refuse, never erase host metadata.
            var identities = ledger.hostJobIdentities ?? [:]; identities[key] = fingerprint; ledger.hostJobIdentities = identities
            return true
        }
    }
    /// Trusted host mapping, persisted in the SAME locked ledger for helpers/reopens.
    /// Agent paths/receipt fields cannot call this API. Mappings cannot be retargeted.
    func registerHostAlias(_ alias: URL, conflictRoot: URL) throws {
        let workspace = try Workspace.canonical(alias), source = try Workspace.canonical(conflictRoot)
        try transaction { ledger in
            let root = Self.conflictRoot(source, in: ledger)
            let existing = Self.conflictRoot(workspace, in: ledger)
            if (ledger.hostAliases ?? []).contains(where: { $0.workspace.conflicts(workspace) }) || !existing.conflicts(workspace) {
                guard existing.conflicts(root) else { throw Failure.configurationMismatch }
                return
            }
            // Do not rewrite the conflict key of already-admitted physical work.
            guard !ledger.records.contains(where: { $0.holdsResources && $0.workspace.conflicts(workspace) }) else { throw Failure.workspaceBusy }
            guard (ledger.hostAliases?.count ?? 0) < Self.recordLimit else { throw Failure.unavailable }
            ledger.version = max(ledger.version, 2)
            ledger.hostAliases = (ledger.hostAliases ?? []) + [Alias(workspace: workspace, conflictRoot: root)]
        }
    }
    func hostConflictRoot(_ url: URL) throws -> Workspace {
        let workspace = try Workspace.canonical(url)
        return try transaction { Self.conflictRoot(workspace, in: $0) }
    }
    private static func conflictRoot(_ workspace: Workspace, in ledger: Ledger) -> Workspace {
        // Hosts register exact execution roots; unknown descendants are conservatively
        // mapped when they lie beneath a registered private root.
        let match = (ledger.hostAliases ?? []).filter {
            $0.workspace.conflicts(workspace) || workspace.path.hasPrefix($0.workspace.path + "/")
        }.max { $0.workspace.path.count < $1.workspace.path.count }
        return match?.conflictRoot ?? workspace
    }

    /// Must commit BEFORE dispatch. After this succeeds, any error is potentially
    /// physical execution and cannot use abandonBeforeExecution.
    func beginExecution(_ lease: Lease) throws {
        try Task.checkCancellation()
        try update(lease) { record in
            try Task.checkCancellation()
            guard record.phase == .reserved, !record.stopRequested else { throw Failure.invalidTransition }
            record.phase = .executing
        }
    }
    /// Stop is a durable intent, never physical completion or resource release.
    /// The caller must also fence new operations and cancel its physical executor.
    func requestStop(_ lease: Lease) throws {
        try update(lease) { record in
            guard record.holdsResources else { throw Failure.invalidTransition }
            record.stopRequested = true
        }
    }
    func abandonBeforeExecution(_ lease: Lease) throws {
        try update(lease) { record in
            guard record.phase == .reserved else { throw Failure.invalidTransition }
            record.phase = .abandoned
        }
    }
    /// Trusted executor attestation: the entire physical operation, including
    /// descendants, broker callbacks and remote requests, has ended. A Stop ACK,
    /// logical Task completion, timeout or thrown cancellation is NOT evidence.
    /// Preserve a separate pending-step/outcome reconciliation fence if needed.
    func finishAfterPhysicalExit(_ lease: Lease, evidence: String) throws {
        try Self.validateEvidence(evidence)
        try update(lease) { record in
            guard record.phase == .executing else { throw Failure.invalidTransition }
            record.phase = .finished; record.evidence = evidence
        }
    }
    /// A failed/unknown physical join remains counted and workspace-exclusive.
    func markUncertain(_ lease: Lease, evidence: String) throws {
        try Self.validateEvidence(evidence)
        try update(lease) { record in
            guard record.holdsResources else { throw Failure.invalidTransition }
            record.phase = .uncertain; record.evidence = evidence
        }
    }
    /// Explicit HOST recovery only, after independent physical-exit verification.
    /// Exact snapshot comparison fences concurrent Stop/phase changes. This does
    /// not authorize replay; the operation UUID tombstone is retained forever.
    func reconcileAfterPhysicalExit(_ expected: Record, evidence: String) throws {
        try Self.validateEvidence(evidence)
        try transaction { ledger in
            guard let index = ledger.records.firstIndex(where: { $0.operationID == expected.operationID }),
                  ledger.records[index] == expected, expected.holdsResources else { throw Failure.invalidTransition }
            ledger.records[index].phase = .finished
            ledger.records[index].evidence = evidence
        }
    }
    func snapshot() throws -> [Record] { try transaction { $0.records } }

    /// This process's kernel unique ID (PROC_PIDUNIQIDENTIFIERINFO), or nil if unreadable.
    static let ownUnique: UInt64? = {
        var info = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), Int32(0), Int32(0), UInt64(0), UInt64(0))
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard size == 56, proc_pidinfo(getpid(), 17, 0, &info, size) == size, info.2 > 0 else { return nil }
        return info.2
    }()

    private static func validateEvidence(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 4096 else { throw Failure.invalidInput }
    }
    private func update(_ lease: Lease, _ change: (inout Record) throws -> Void) throws {
        try transaction { ledger in
            guard let index = ledger.records.firstIndex(where: { $0.operationID == lease.operationID }),
                  ledger.records[index].secret == lease.secret,
                  ledger.records[index].ownerPID == getpid(),
                  ledger.records[index].ownerUnique.map({ $0 == Self.ownUnique }) ?? true else { throw Failure.invalidLease }
            try change(&ledger.records[index])
        }
    }
    private func checkedFile(_ fd: Int32, directory: Bool = false) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.io(errno) }
        guard info.st_uid == geteuid(), info.st_mode & 0o777 == (directory ? 0o700 : 0o600),
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { throw Failure.unsafeRegistry }
    }
    private func transaction<T>(bootstrap: Bool = false, _ body: (inout Ledger) throws -> T) throws -> T {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unavailable }
        defer { close(directory) }
        try checkedFile(directory, directory: true)
        var info = stat()
        guard fstat(directory, &info) == 0,
              UInt64(UInt32(bitPattern: info.st_dev)) == root.device, UInt64(info.st_ino) == root.inode else { throw Failure.unsafeRegistry }
        var created = false
        var lock = openat(directory, "ownership.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if lock >= 0 { created = true }
        else if errno == EEXIST { lock = openat(directory, "ownership.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC) }
        guard lock >= 0 else { throw Failure.unavailable }
        defer { close(lock) }
        try checkedFile(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw Failure.registryBusy }; throw Failure.io(errno)
        }
        defer { flock(lock, LOCK_UN) }
        let fd = openat(directory, "ownership.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var ledger: Ledger
        let original: Data?
        if fd < 0 {
            guard errno == ENOENT, created, bootstrap else { throw Failure.unavailable }
            original = nil; ledger = Ledger(version: 1, capacity: capacity, records: [])
        } else {
            defer { close(fd) }
            try checkedFile(fd)
            var fileInfo = stat()
            guard fstat(fd, &fileInfo) == 0, fileInfo.st_size <= Self.byteLimit else { throw Failure.unavailable }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw Failure.io(errno) }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= Self.byteLimit else { throw Failure.unavailable }
            }
            original = bytes
            do { ledger = try JSONDecoder().decode(Ledger.self, from: bytes) }
            catch { throw Failure.unavailable }
        }
        guard (1...Self.currentVersion).contains(ledger.version) else { throw Failure.configurationMismatch }
        if ledger.capacity != capacity {
            // A capacity change (e.g. an old single-slot registry) is adopted only while
            // nothing holds resources, so no held slot is ever reinterpreted; a busy
            // registry is refused as before. The ledger becomes v3 so the older binary
            // that wrote it refuses it rather than misreading the new limit.
            guard (1...256).contains(ledger.capacity), !ledger.records.contains(where: \.holdsResources),
                  (ledger.exclusiveWaiters ?? []).isEmpty else { throw Failure.configurationMismatch }
            ledger.capacity = capacity; ledger.version = Self.currentVersion
        }
        guard ledger.version >= 2 || (ledger.hostAliases == nil && ledger.hostJobIdentities == nil) else { throw Failure.unavailable }
        let held = ledger.records.filter(\.holdsResources)
        guard ledger.version == Self.currentVersion || (ledger.exclusiveWaiters == nil && !ledger.records.contains(where: \.exclusive)) else { throw Failure.unavailable }
        // An exclusive record never coexists with other held work.
        guard !held.contains(where: \.exclusive) || held.count == 1 else { throw Failure.unavailable }
        if let waiters = ledger.exclusiveWaiters {
            guard waiters.count <= Self.waiterLimit, Set(waiters.map(\.operationID)).count == waiters.count,
                  waiters.allSatisfy({ $0.owner.kind.isExclusive }) else { throw Failure.unavailable }
            // Prune queue entries whose waiter stopped refreshing (or whose clock is
            // implausible). They never held physical work.
            let now = Date()
            let live = waiters.filter { abs(now.timeIntervalSince($0.refreshedAt)) <= Self.waiterLifetime }
            ledger.exclusiveWaiters = live.isEmpty ? nil : live
        }
        guard ledger.records.count <= Self.recordLimit,
              Set(ledger.records.map(\.operationID)).count == ledger.records.count,
              ledger.records.filter(\.holdsResources).count <= capacity,
              (ledger.hostAliases?.count ?? 0) <= Self.recordLimit,
              (ledger.hostJobIdentities?.count ?? 0) <= Self.recordLimit,
              (ledger.hostAliases ?? []).allSatisfy({ $0.workspace.path.hasPrefix("/") && $0.conflictRoot.path.hasPrefix("/") && !$0.workspace.path.contains("\0") && !$0.conflictRoot.path.contains("\0") }),
              (ledger.hostJobIdentities ?? [:]).allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.count == 64 && $0.value.allSatisfy({ $0.isHexDigit }) }) else { throw Failure.unavailable }
        let result = try body(&ledger)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(ledger)
        guard bytes.count <= Self.byteLimit else { throw Failure.unavailable }
        if original != bytes { try persist(bytes, directory: directory) }
        return result
    }
    private func persist(_ bytes: Data, directory: Int32) throws {
        let name = ".ownership-" + UUID().uuidString
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io(errno) }
        defer { close(fd); unlinkat(directory, name, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Failure.io(errno) }
                guard count > 0 else { throw Failure.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw Failure.io(errno) }
        guard renameat(directory, name, directory, "ownership.json") == 0 else { throw Failure.io(errno) }
        guard fsync(directory) == 0 else { throw Failure.io(errno) }
    }
}
