import Foundation
import Darwin

// maintenanceRequired: the private directory holds more entries than open-time
// maintenance may scan; nothing was removed or read. unresolvedEvidence: an archive
// holds a stopped job's uncertain step that does not fit back in the ledger;
// nothing was changed. Both need a host decision, never silent deletion.
enum BackgroundWorkStoreError: Error {
    case unsafePath, alreadyOpen, alreadyAttached, invalidDocument, scopeMismatch, changed, unavailable, io, maintenanceRequired, unresolvedEvidence
}
enum BackgroundWorkStorageBoundary: Equatable, Sendable { case beforeFileSync, beforeReplace, afterReplace, archiveBeforeReplace }
/// One settled item in the bounded archive. Sequence orders retention (oldest first).
struct BackgroundWorkArchiveEntry: Codable, Equatable, Sendable {
    let sequence: UInt64
    let item: BackgroundWorkItem
}
/// What open-time maintenance did under the exclusive writer lock.
struct BackgroundWorkStorageMaintenance: Equatable, Sendable {
    /// Abandoned temporary writes from an interrupted process, removed.
    var removedTemporaries = 0
    /// Entries with a temporary-file name that were not provably this store's own
    /// private leftover (links, directories, shared or foreign files): untouched.
    var retainedEntries = 0
}

/// Legacy synchronous adapter for the original engine contract and its regression
/// fixtures. Do NOT attach it to live UI: that engine's Save contract is synchronous.
/// New integration must await BackgroundWorkStorageSession rather than block the
/// main actor, dispatch-and-forget, or wait on a semaphore for a durable write.
@MainActor final class BackgroundWorkStore {
    static let ledgerName = BackgroundWorkDisk.ledgerName
    static let backupName = BackgroundWorkDisk.backupName
    static let lockName = BackgroundWorkDisk.lockName
    static let maximumBytes = BackgroundWorkDisk.maximumBytes
    typealias Boundary = BackgroundWorkStorageBoundary
    private let disk: BackgroundWorkDisk
    /// Filled in by makeEngine, which runs open-time maintenance before reading.
    var maintenance: BackgroundWorkStorageMaintenance { disk.maintenance }
    init(directory: URL, projectID: UUID, conversationID: UUID,
         fault: @escaping (Boundary) throws -> Void = { _ in }) throws {
        disk = try BackgroundWorkDisk(directory: directory, projectID: projectID, conversationID: conversationID, fault: fault)
    }
    func makeEngine(maxConcurrent: Int = 3, authorize: @escaping BackgroundWorkEngine.Authorize,
                    execute: @escaping BackgroundWorkEngine.Execute) throws -> BackgroundWorkEngine {
        let saved = try disk.claimSnapshot()
        return try BackgroundWorkEngine(restoring: saved, maxConcurrent: maxConcurrent,
            save: { [disk] in try disk.persist($0) }, authorize: authorize, execute: execute)
    }
}

/// Off-main, single-owner checkpoint I/O for the NEXT asynchronous engine contract.
/// This actor does not run providers, select a live path, or start an engine.
/// Its methods perform no await during a physical write. Actor mailboxes are NOT
/// FIFO: generation checks reject stale concurrent saves instead of assuming order.
/// The writer lock survives cancellation until physical I/O really ends.
actor BackgroundWorkStorageSession {
    struct State: Sendable {
        let snapshot: BackgroundWorkSnapshot?
        let generation: UInt64
        let storageFailed: Bool
        /// Settled history, oldest first. Never runnable and never a pending result.
        let archived: [BackgroundWorkItem]
    }
    /// Bounded retention: the oldest settled entries are dropped first.
    static let maximumArchivedItems = BackgroundWorkDisk.maximumArchivedItems
    static let maximumBytes = BackgroundWorkDisk.maximumBytes
    private let disk: BackgroundWorkDisk
    private var snapshot: BackgroundWorkSnapshot?
    private var archive: [BackgroundWorkArchiveEntry]
    private var nextSequence: UInt64
    private var generation: UInt64 = 0
    private var storageFailed = false
    private var runnerOwner: UUID?
    /// Open-time maintenance, performed under the writer lock before any read.
    nonisolated let maintenance: BackgroundWorkStorageMaintenance
    private init(disk: BackgroundWorkDisk, snapshot: BackgroundWorkSnapshot?, archive: [BackgroundWorkArchiveEntry]) {
        self.disk = disk; self.snapshot = snapshot; self.archive = archive
        maintenance = disk.maintenance
        nextSequence = (archive.map(\.sequence).max() ?? 0) + 1
    }
    func state() -> State { State(snapshot: snapshot, generation: generation, storageFailed: storageFailed, archived: archive.map(\.item)) }
    // Runtime-only ownership, never decoded from a task or an agent response.
    // A claimed session cannot attach another runner or accept unowned saves.
    func claimRunner() throws -> (id: UUID, state: State) {
        guard !storageFailed else { throw BackgroundWorkStoreError.unavailable }
        guard runnerOwner == nil else { throw BackgroundWorkStoreError.alreadyAttached }
        let owner = UUID(); runnerOwner = owner
        return (owner, state())
    }
    /// Opens descriptors, validates primary/recovery data and saves restart pauses
    /// on a detached utility task, never synchronously on the caller's main actor.
    /// The host must supply an EXISTING private directory; agent text supplies none.
    nonisolated static func open(directory: URL, projectID: UUID, conversationID: UUID,
        fault: @escaping @Sendable (BackgroundWorkStorageBoundary) throws -> Void = { _ in }) async throws -> BackgroundWorkStorageSession {
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            let disk = try BackgroundWorkDisk(directory: directory, projectID: projectID, conversationID: conversationID, fault: fault)
            let saved = try disk.claimSnapshot()
            var items = (saved?.items ?? []).map { original -> BackgroundWorkItem in
                var item = original
                if item.state == .running || item.state == .queued {
                    item.state = .paused
                    item.pause = item.pendingStepID == nil ? .restart : .reconciliation
                }
                return item
            }
            // An archive written before unresolved steps were kept in the ledger may
            // hold a stopped job's uncertain step. Move it back, ledger first, so
            // retention can never drop it and the host can reconcile it. A crash
            // between the two writes leaves it in both files; the ledger copy is
            // authoritative and the next open finishes the move.
            var archive = disk.claimedArchive
            let stranded = archive.map(\.item).filter { !BackgroundWorkEngine.isArchivable($0) }
            let known = Set(items.map(\.id))
            items += stranded.filter { !known.contains($0.id) }
            guard saved != nil || !stranded.isEmpty else {
                return BackgroundWorkStorageSession(disk: disk, snapshot: nil, archive: archive)
            }
            let restored = BackgroundWorkSnapshot(version: 1, items: items)
            if stranded.isEmpty { try BackgroundWorkEngine.validateSnapshot(restored) }
            else {
                // Refuse, changing nothing, rather than drop evidence to make it fit.
                do {
                    try BackgroundWorkEngine.validateSnapshot(restored)
                    guard try disk.encodedLedgerSize(restored) <= BackgroundWorkDisk.maximumBytes else { throw BackgroundWorkStoreError.unresolvedEvidence }
                } catch { throw BackgroundWorkStoreError.unresolvedEvidence }
            }
            try disk.persist(restored)
            if !stranded.isEmpty {
                archive.removeAll { !BackgroundWorkEngine.isArchivable($0.item) }
                try disk.persistArchive(archive)
            }
            return BackgroundWorkStorageSession(disk: disk, snapshot: restored, archive: archive)
        }.value
    }
    /// Callers MUST await this result before execution/publication. Cancellation
    /// before I/O prevents a save; cancellation during a physical save cannot undo
    /// it. Return its real result, not a misleading post-commit CancellationError.
    /// Engine cancellation fences must be set BEFORE awaiting this actor.
    @discardableResult func save(_ next: BackgroundWorkSnapshot, basedOn expected: UInt64) throws -> UInt64 {
        guard runnerOwner == nil else { throw BackgroundWorkStoreError.alreadyAttached }
        return try commit(next, basedOn: expected)
    }
    @discardableResult func saveForRunner(_ next: BackgroundWorkSnapshot, basedOn expected: UInt64, owner: UUID) throws -> UInt64 {
        guard runnerOwner == owner else { throw BackgroundWorkStoreError.unavailable }
        return try commit(next, basedOn: expected)
    }
    /// Moves exactly these settled, resolved items from the ledger into the bounded
    /// archive. An item with an uncertain pending step is refused: it is evidence,
    /// not history, and retention may drop history. The archive is written first:
    /// a crash between the two writes leaves an item in both files, and the ledger
    /// copy stays authoritative (it is settled, so it can never run or publish).
    /// The ledger change is exactly the removal.
    func compactForRunner(archiving ids: Set<UUID>, basedOn expected: UInt64, owner: UUID) throws -> (generation: UInt64, archived: [BackgroundWorkItem]) {
        guard runnerOwner == owner else { throw BackgroundWorkStoreError.unavailable }
        try Task.checkCancellation()
        guard !ids.isEmpty, let current = snapshot else { throw BackgroundWorkStoreError.unavailable }
        let moving = current.items.filter { ids.contains($0.id) }
        guard moving.count == ids.count else { throw BackgroundWorkStoreError.unavailable }
        try BackgroundWorkEngine.validateArchived(moving, limit: BackgroundWorkDisk.maximumArchivedItems)
        let next = BackgroundWorkSnapshot(version: 1, items: current.items.filter { !ids.contains($0.id) })
        try admit(next, basedOn: expected)
        var entries = archive.filter { !ids.contains($0.item.id) }
        var sequence = nextSequence
        for item in moving.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            entries.append(BackgroundWorkArchiveEntry(sequence: sequence, item: item)); sequence += 1
        }
        do {
            entries = try disk.retainedArchive(entries)
            try disk.persistArchive(entries)
        } catch { storageFailed = true; throw error }
        archive = entries; nextSequence = sequence
        return (try write(next), entries.map(\.item))
    }
    private func commit(_ next: BackgroundWorkSnapshot, basedOn expected: UInt64) throws -> UInt64 {
        try Task.checkCancellation()
        try admit(next, basedOn: expected)
        return try write(next)
    }
    /// Pure checks, before any I/O. An over-capacity snapshot changes nothing on
    /// disk, so it throws BackgroundWorkError.capacity without latching a failure.
    private func admit(_ next: BackgroundWorkSnapshot, basedOn expected: UInt64) throws {
        guard !storageFailed, generation < UInt64.max else { throw BackgroundWorkStoreError.unavailable }
        guard expected == generation else { throw BackgroundWorkStoreError.changed }
        try BackgroundWorkEngine.validateSnapshot(next)
        guard try disk.encodedLedgerSize(next) <= BackgroundWorkDisk.maximumBytes else { throw BackgroundWorkError.capacity }
    }
    private func write(_ next: BackgroundWorkSnapshot) throws -> UInt64 {
        do { try disk.persist(next) }
        catch { storageFailed = true; throw error }
        snapshot = next; generation += 1
        return generation
    }
}

/// Thread-confined implementation. Every instance has exactly ONE owner: either
/// the legacy main-actor facade or one storage-session actor, never both. No disk
/// handle escapes that owner. The same atomic I/O/path checks serve both adapters.
private final class BackgroundWorkDisk {
    static let ledgerName = "background-work.json"
    static let backupName = "background-work.previous.json"
    static let lockName = "background-work.lock"
    static let archiveName = "background-work.archive.json"
    static let maximumBytes = 2_097_152
    static let maximumArchivedItems = 256
    /// Open-time maintenance scans at most this many directory entries; a larger
    /// directory is refused (maintenanceRequired) rather than partly maintained.
    static let maximumMaintenanceEntries = 1_024
    static let temporaryPrefix = "background-work-"
    static let temporarySuffix = ".tmp"
    private struct Document: Codable {
        let version: Int
        let projectID: UUID
        let conversationID: UUID
        let snapshot: BackgroundWorkSnapshot
    }
    private struct ArchiveDocument: Codable {
        let version: Int
        let projectID: UUID
        let conversationID: UUID
        let entries: [BackgroundWorkArchiveEntry]
    }
    private let directory: URL
    private let directoryFD: Int32
    private let lockFD: Int32
    private let projectID: UUID
    private let conversationID: UUID
    private let fault: (BackgroundWorkStorageBoundary) throws -> Void
    private var attached = false
    private var failed = false
    private var writing = false
    private var previousBytes: Data?
    private var previousArchiveBytes: Data?
    private(set) var claimedArchive: [BackgroundWorkArchiveEntry] = []
    private(set) var maintenance = BackgroundWorkStorageMaintenance()
    init(directory: URL, projectID: UUID, conversationID: UUID,
         fault: @escaping (BackgroundWorkStorageBoundary) throws -> Void) throws {
        let root = try Self.openDirectory(directory)
        var lock: Int32 = -1
        do {
            lock = openat(root, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
            guard lock >= 0 else { throw BackgroundWorkStoreError.unsafePath }
            _ = try Self.regularFile(lock, limit: 0)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw BackgroundWorkStoreError.alreadyOpen }
            let named = try Self.metadata(root, Self.lockName)
            let opened = try Self.regularFile(lock, limit: 0)
            guard let named, Self.sameFile(named, opened) else { throw BackgroundWorkStoreError.changed }
        } catch {
            if lock >= 0 { Darwin.close(lock) }
            Darwin.close(root)
            throw error
        }
        self.directory = directory
        directoryFD = root; lockFD = lock
        self.projectID = projectID; self.conversationID = conversationID; self.fault = fault
    }
    /// Never unlink the lock or close it merely because a caller cancelled a Task.
    deinit { Darwin.close(lockFD); Darwin.close(directoryFD) }
    func claimSnapshot() throws -> BackgroundWorkSnapshot? {
        guard !attached, !failed else { throw BackgroundWorkStoreError.alreadyAttached }
        attached = true
        do {
            try checkIdentity()
            try removeAbandonedTemporaries()
            let current = try read(Self.ledgerName), backup = try read(Self.backupName)
            if let backup { _ = try decode(backup) }
            guard current != nil || backup == nil else { throw BackgroundWorkStoreError.invalidDocument }
            let saved = try current.map { try decode($0) }
            // A corrupt or foreign archive is refused, never treated as empty history.
            let archived = try read(Self.archiveName)
            let entries = try archived.map { try decodeArchive($0) } ?? []
            previousBytes = current; previousArchiveBytes = archived; claimedArchive = entries
            return saved
        } catch { failed = true; throw error }
    }
    private func decodeArchive(_ bytes: Data) throws -> [BackgroundWorkArchiveEntry] {
        let document: ArchiveDocument
        do { document = try JSONDecoder().decode(ArchiveDocument.self, from: bytes) }
        catch { throw BackgroundWorkStoreError.invalidDocument }
        guard document.version == 1 else { throw BackgroundWorkStoreError.invalidDocument }
        try validateArchive(document.entries, allowingUnresolved: true)
        guard document.projectID == projectID, document.conversationID == conversationID else { throw BackgroundWorkStoreError.scopeMismatch }
        return document.entries
    }
    private func validateArchive(_ entries: [BackgroundWorkArchiveEntry], allowingUnresolved: Bool = false) throws {
        guard entries.allSatisfy({ $0.item.scope.projectID == projectID && $0.item.scope.conversationID == conversationID }) else {
            throw BackgroundWorkStoreError.scopeMismatch
        }
        guard zip(entries, entries.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }) else { throw BackgroundWorkStoreError.invalidDocument }
        do { try BackgroundWorkEngine.validateArchived(entries.map(\.item), limit: Self.maximumArchivedItems, allowingUnresolved: allowingUnresolved) }
        catch { throw BackgroundWorkStoreError.invalidDocument }
    }
    private func encodeArchive(_ entries: [BackgroundWorkArchiveEntry]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ArchiveDocument(version: 1, projectID: projectID, conversationID: conversationID, entries: entries))
    }
    private func encodeLedger(_ snapshot: BackgroundWorkSnapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(version: 1, projectID: projectID, conversationID: conversationID, snapshot: snapshot))
    }
    /// Pure: the exact on-disk size of this ledger document. No I/O, no failure latch.
    func encodedLedgerSize(_ snapshot: BackgroundWorkSnapshot) throws -> Int { try encodeLedger(snapshot).count }
    /// Pure bounded retention: drops the oldest entries until the archive has at
    /// most maximumArchivedItems entries and its document fits maximumBytes.
    func retainedArchive(_ entries: [BackgroundWorkArchiveEntry]) throws -> [BackgroundWorkArchiveEntry] {
        var kept = Array(entries.sorted { $0.sequence < $1.sequence }.suffix(Self.maximumArchivedItems))
        let encoder = JSONEncoder()
        let overhead = try encodeArchive([]).count
        var sizes = try kept.map { try encoder.encode($0).count }
        var total = overhead + sizes.reduce(0, +) + max(0, kept.count - 1)
        while !kept.isEmpty && total > Self.maximumBytes {
            total -= sizes.removeFirst() + (kept.count > 1 ? 1 : 0); kept.removeFirst()
        }
        // The estimate is exact for JSONEncoder; confirm once rather than trust it.
        while !kept.isEmpty, try encodeArchive(kept).count > Self.maximumBytes { kept.removeFirst() }
        return kept
    }
    /// Atomic, synchronized archive replacement with the ledger's path, identity,
    /// permission and external-change checks. No recovery copy: this is bounded
    /// history, and the ledger remains authoritative for anything also listed here.
    func persistArchive(_ entries: [BackgroundWorkArchiveEntry]) throws {
        guard attached, !failed, !writing else { failed = true; throw BackgroundWorkStoreError.unavailable }
        writing = true
        defer { writing = false }
        do {
            try validateArchive(entries)
            let bytes = try encodeArchive(entries)
            guard bytes.count <= Self.maximumBytes else { throw BackgroundWorkStoreError.invalidDocument }
            try checkIdentity()
            guard try read(Self.archiveName) == previousArchiveBytes else { throw BackgroundWorkStoreError.changed }
            let temporary = try prepare(bytes, inject: false)
            defer { unlinkat(directoryFD, temporary, 0) }
            try fault(.archiveBeforeReplace)
            guard !failed else { throw BackgroundWorkStoreError.unavailable }
            try checkIdentity()
            guard try read(Self.archiveName) == previousArchiveBytes else { throw BackgroundWorkStoreError.changed }
            guard renameat(directoryFD, temporary, directoryFD, Self.archiveName) == 0 else { throw BackgroundWorkStoreError.io }
            guard !failed, fsync(directoryFD) == 0 else { throw BackgroundWorkStoreError.io }
            previousArchiveBytes = bytes
        } catch { failed = true; throw error }
    }
    private func decode(_ bytes: Data) throws -> BackgroundWorkSnapshot {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: bytes) }
        catch { throw BackgroundWorkStoreError.invalidDocument }
        guard document.version == 1 else { throw BackgroundWorkStoreError.invalidDocument }
        guard document.projectID == projectID, document.conversationID == conversationID,
              document.snapshot.items.allSatisfy({ $0.scope.projectID == projectID && $0.scope.conversationID == conversationID }) else {
            throw BackgroundWorkStoreError.scopeMismatch
        }
        try BackgroundWorkEngine.validateSnapshot(document.snapshot)
        return document.snapshot
    }
    func persist(_ snapshot: BackgroundWorkSnapshot) throws {
        guard attached, !failed, !writing else { failed = true; throw BackgroundWorkStoreError.unavailable }
        writing = true
        defer { writing = false }
        do {
            try BackgroundWorkEngine.validateSnapshot(snapshot)
            guard snapshot.items.allSatisfy({ $0.scope.projectID == projectID && $0.scope.conversationID == conversationID }) else {
                throw BackgroundWorkStoreError.scopeMismatch
            }
            let bytes = try encodeLedger(snapshot)
            guard bytes.count <= Self.maximumBytes else { throw BackgroundWorkStoreError.invalidDocument }
            try checkIdentity()
            guard try read(Self.ledgerName) == previousBytes else { throw BackgroundWorkStoreError.changed }
            if let backup = try read(Self.backupName) { _ = try decode(backup) }
            let temporary = try prepare(bytes, inject: true)
            defer { unlinkat(directoryFD, temporary, 0) }
            if let previousBytes {
                let backup = try prepare(previousBytes, inject: false)
                defer { unlinkat(directoryFD, backup, 0) }
                guard renameat(directoryFD, backup, directoryFD, Self.backupName) == 0,
                      fsync(directoryFD) == 0 else { throw BackgroundWorkStoreError.io }
            }
            try fault(.beforeReplace)
            guard !failed else { throw BackgroundWorkStoreError.unavailable }
            try checkIdentity()
            guard try read(Self.ledgerName) == previousBytes else { throw BackgroundWorkStoreError.changed }
            guard renameat(directoryFD, temporary, directoryFD, Self.ledgerName) == 0 else { throw BackgroundWorkStoreError.io }
            try fault(.afterReplace)
            guard !failed, fsync(directoryFD) == 0 else { throw BackgroundWorkStoreError.io }
            previousBytes = bytes
        } catch { failed = true; throw error }
    }
    /// Exactly the names prepare() creates. No committed file has this shape.
    static func isTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryPrefix), name.hasSuffix(temporarySuffix) else { return false }
        let middle = String(name.dropFirst(temporaryPrefix.count).dropLast(temporarySuffix.count))
        return middle.utf8.count == 36 && UUID(uuidString: middle)?.uuidString.lowercased() == middle
    }
    /// Bounded crash-leftover maintenance, under the exclusive writer lock and
    /// before anything is read. Every commit renames its temporary file away, so a
    /// leftover is an uncommitted write, and save-before-execute means no step ran
    /// on its contents. Only an exact prepare() name that is a private, single-link
    /// regular file owned by this user, within the document bound, and not the
    /// inode of the primary, recovery copy, archive or permanent lock, is removed.
    /// Anything else with such a name is left untouched and counted. A directory
    /// too large to scan within the bound is refused before anything is removed.
    private func removeAbandonedTemporaries() throws {
        let listing = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listing >= 0 else { throw BackgroundWorkStoreError.io }
        var opened = stat(), named = stat()
        guard fstat(listing, &opened) == 0, fstat(directoryFD, &named) == 0, Self.sameFile(opened, named),
              let stream = fdopendir(listing) else { Darwin.close(listing); throw BackgroundWorkStoreError.changed }
        var candidates: [String] = [], entries = 0
        do {
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw BackgroundWorkStoreError.io }
                    break
                }
                let length = Int(entry.pointee.d_namlen)
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
                if name == "." || name == ".." { continue }
                entries += 1
                guard entries <= Self.maximumMaintenanceEntries else { throw BackgroundWorkStoreError.maintenanceRequired }
                if Self.isTemporaryName(name) { candidates.append(name) }
            }
        }
        guard !candidates.isEmpty else { return }
        let protected = try [Self.ledgerName, Self.backupName, Self.archiveName, Self.lockName].compactMap { try Self.metadata(directoryFD, $0) }
        for name in candidates {
            let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { if errno != ENOENT { maintenance.retainedEntries += 1 }; continue }
            defer { Darwin.close(fd) }
            guard let info = try? Self.regularFile(fd, limit: Self.maximumBytes),
                  !protected.contains(where: { Self.sameFile($0, info) }),
                  let current = try Self.metadata(directoryFD, name), Self.sameFile(current, info) else {
                maintenance.retainedEntries += 1; continue
            }
            guard unlinkat(directoryFD, name, 0) == 0 else { throw BackgroundWorkStoreError.io }
            maintenance.removedTemporaries += 1
        }
        if maintenance.removedTemporaries > 0 { guard fsync(directoryFD) == 0 else { throw BackgroundWorkStoreError.io } }
    }
    private func prepare(_ bytes: Data, inject: Bool) throws -> String {
        let name = Self.temporaryPrefix + UUID().uuidString.lowercased() + Self.temporarySuffix
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw BackgroundWorkStoreError.io }
        var ready = false
        defer { Darwin.close(fd); if !ready { unlinkat(directoryFD, name, 0) } }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw BackgroundWorkStoreError.io }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BackgroundWorkStoreError.io }
                offset += count
            }
        }
        if inject { try fault(.beforeFileSync) }
        guard !failed, fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw BackgroundWorkStoreError.io }
        _ = try Self.regularFile(fd, limit: Self.maximumBytes)
        ready = true
        return name
    }
    private func read(_ name: String) throws -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw BackgroundWorkStoreError.unsafePath
        }
        defer { Darwin.close(fd) }
        _ = try Self.regularFile(fd, limit: Self.maximumBytes)
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw BackgroundWorkStoreError.io }
            if count == 0 { break }
            guard result.count <= Self.maximumBytes - count else { throw BackgroundWorkStoreError.invalidDocument }
            result.append(contentsOf: buffer.prefix(count))
        }
        let info = try Self.regularFile(fd, limit: Self.maximumBytes)
        guard info.st_size == result.count else { throw BackgroundWorkStoreError.changed }
        return result
    }
    private func checkIdentity() throws {
        let current = try Self.openDirectory(directory)
        defer { Darwin.close(current) }
        var original = stat(), now = stat()
        guard fstat(directoryFD, &original) == 0, fstat(current, &now) == 0,
              Self.sameFile(original, now), let named = try Self.metadata(directoryFD, Self.lockName),
              Self.sameFile(named, try Self.regularFile(lockFD, limit: 0)) else { throw BackgroundWorkStoreError.changed }
    }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    private static func metadata(_ root: Int32, _ name: String) throws -> stat? {
        var info = stat()
        if fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw BackgroundWorkStoreError.io
        }
        return info
    }
    private static func regularFile(_ fd: Int32, limit: Int) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0,
              info.st_size >= 0, info.st_size <= limit else { throw BackgroundWorkStoreError.unsafePath }
        return info
    }
    private static func openDirectory(_ url: URL) throws -> Int32 {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else { throw BackgroundWorkStoreError.unsafePath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw BackgroundWorkStoreError.unsafePath }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw BackgroundWorkStoreError.unsafePath }
        for part in parts {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw BackgroundWorkStoreError.unsafePath }
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else {
            Darwin.close(fd); throw BackgroundWorkStoreError.unsafePath
        }
        return fd
    }
}
