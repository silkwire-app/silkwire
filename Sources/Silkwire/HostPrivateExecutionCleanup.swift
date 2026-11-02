import Foundation
import Darwin

private func cleanupFailure(_ message: String) -> NSError {
    NSError(domain: "Silkwire.PrivateCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// procargs can disappear during exit, or change between its size/read calls at
/// exec, before proc_pidinfo reports a zombie. This invalidates the entire scan;
/// it is never an empty-process answer. Only fresh complete scans can release.
struct HostPrivateInspectionRace: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A kernel audit token includes the PID version. Never signal a polled PID: it
/// can be reused between inspection and kill. The kernel validates this token.
struct HostProcessToken: Codable, Equatable, Sendable {
    let words: [UInt32]
    var pid: pid_t { pid_t(bitPattern: words[5]) }
    static func read(_ pid: pid_t) throws -> Self {
        var port: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else {
            throw cleanupFailure("Cannot obtain exact process identity for PID \(pid).")
        }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t(), count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / 4)
        let status = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        guard status == KERN_SUCCESS else { throw cleanupFailure("Cannot read exact process identity for PID \(pid).") }
        return withUnsafeBytes(of: token) { Self(words: Array($0.bindMemory(to: UInt32.self))) }
    }
    func signal(_ value: Int32) throws {
        guard words.count == 8, pid > 1, pid != getpid(), words[1] == getuid() else {
            throw cleanupFailure("Unsafe or foreign cleanup process identity.")
        }
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { target in words.withUnsafeBytes { target.copyMemory(from: $0) } }
        guard proc_signal_with_audittoken(&token, value) == 0 || errno == ESRCH else {
            throw cleanupFailure("Exact-process cleanup signal failed for PID \(pid) (errno \(errno)).")
        }
    }
}

struct HostPrivateCleanupResult: Sendable, Equatable {
    let identity: HostExecutionIdentity
    let workspaceID: UUID
    let jobID: UUID?
    let evidence: String
}

struct HostPrivateCleanupBinding: Codable, Equatable, Sendable {
    let identity: HostExecutionIdentity
    let workspaceID: UUID
    let jobID: UUID?
    let tag: UUID
    let owner: HostProcessToken
    var lineage: StagingInstallWorkload.Lineage? = nil
}

struct HostPrivateCleanupManifest: Codable, Sendable {
    let identity: HostExecutionIdentity
    let workspaceID: UUID
    let jobID: UUID?
    let tag: UUID
    let owner: HostProcessToken
    // Optional only to decode old evidence; absence can never authorize release.
    var lineage: StagingInstallWorkload.Lineage? = nil
    var roots: [StagingInstallWorkload.Identity]? = nil
    // Positive descendant observations, saved while parent links still exist.
    // Their unique IDs remain authoritative after orphaning and exec.
    var observed: [StagingInstallWorkload.Identity]? = nil
    var tracked: [HostProcessToken] = []
    var sealed = false
    var disabledReason: String?
    var binding: HostPrivateCleanupBinding {
        .init(identity: identity, workspaceID: workspaceID, jobID: jobID, tag: tag, owner: owner, lineage: lineage)
    }
    var summary: String {
        "Approved sandboxed private-work practical cleanup for operation \(identity.operationID), attempt \(identity.attemptID), workspace \(workspaceID): tracked processes swept; two complete shared kernel-lineage scans found no job descendants, possible job-time orphans or execution-tagged survivors. This is practical cleanup, not whole-workload kernel exit proof."
    }
}

/// Host-only, outside every command sandbox. A manifest exists before any private
/// launch; tracked audit tokens are committed while each child is suspended.
struct HostPrivateCleanupStore: Sendable {
    let directory: URL
    private func directoryFD() throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw cleanupFailure("Private cleanup registry is unavailable.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(fd); throw cleanupFailure("Private cleanup registry metadata is unsafe.")
        }
        return fd
    }
    private func name(_ identity: HostExecutionIdentity) -> String { "private-cleanup-" + identity.attemptID.uuidString + ".json" }
    private func bindingName(_ identity: HostExecutionIdentity) -> String { "private-binding-" + identity.attemptID.uuidString + ".json" }
    private func readBinding(_ dir: Int32, _ identity: HostExecutionIdentity) throws -> HostPrivateCleanupBinding {
        let fd = openat(dir, bindingName(identity), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw cleanupFailure("Required private run/job binding is missing or unreadable.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, (1...16384).contains(info.st_size) else { throw cleanupFailure("Unsafe private run/job binding metadata.") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
        while offset < bytes.count {
            let total = bytes.count
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), total - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw cleanupFailure("Incomplete private run/job binding.") }; offset += n
        }
        return try JSONDecoder().decode(HostPrivateCleanupBinding.self, from: Data(bytes))
    }
    private func bind(_ dir: Int32, _ manifest: HostPrivateCleanupManifest) throws {
        let fd = openat(dir, bindingName(manifest.identity), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 && errno == EEXIST {
            guard try readBinding(dir, manifest.identity) == manifest.binding else { throw cleanupFailure("Private evidence does not match its original run/job binding.") }; return
        }
        guard fd >= 0 else { throw cleanupFailure("Cannot persist private run/job binding.") }
        defer { close(fd) }
        let bytes = try JSONEncoder().encode(manifest.binding)
        try bytes.withUnsafeBytes { data in
            var offset = 0
            while offset < data.count {
                let n = write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw cleanupFailure("Cannot write private run/job binding.") }; offset += n
            }
        }
        guard fsync(fd) == 0, fsync(dir) == 0 else { throw cleanupFailure("Cannot commit private run/job binding.") }
    }
    func save(_ manifest: HostPrivateCleanupManifest) throws {
        let dir = try directoryFD(); defer { close(dir) }
        try bind(dir, manifest)
        let bytes = try JSONEncoder().encode(manifest)
        guard bytes.count <= 1_048_576, manifest.tracked.count <= 4096, (manifest.observed?.count ?? 0) <= 4096 else { throw cleanupFailure("Private cleanup evidence exceeds its bound.") }
        let temporary = ".private-cleanup-" + UUID().uuidString
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw cleanupFailure("Cannot create private cleanup evidence.") }
        defer { close(fd); unlinkat(dir, temporary, 0) }
        try bytes.withUnsafeBytes { data in
            var offset = 0
            while offset < data.count {
                let n = write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw cleanupFailure("Cannot write private cleanup evidence.") }; offset += n
            }
        }
        guard fsync(fd) == 0, renameat(dir, temporary, dir, name(manifest.identity)) == 0, fsync(dir) == 0 else {
            throw cleanupFailure("Cannot commit private cleanup evidence.")
        }
    }
    func load(_ identity: HostExecutionIdentity) throws -> HostPrivateCleanupManifest? {
        let dir = try directoryFD(); defer { close(dir) }
        let fd = openat(dir, name(identity), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw cleanupFailure("Cannot open private cleanup evidence (errno \(errno)).") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, (1...1_048_576).contains(info.st_size) else { throw cleanupFailure("Unsafe private cleanup evidence metadata.") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
        while offset < bytes.count {
            let total = bytes.count
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), total - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw cleanupFailure("Incomplete private cleanup evidence.") }; offset += n
        }
        let manifest = try JSONDecoder().decode(HostPrivateCleanupManifest.self, from: Data(bytes))
        guard try readBinding(dir, identity) == manifest.binding else { throw cleanupFailure("Private cleanup evidence has the wrong workspace, job or original host binding.") }
        guard manifest.identity == identity, !identity.owner.kind.isExclusive, manifest.tracked.count <= 4096, (manifest.observed?.count ?? 0) <= 4096,
              ([manifest.owner] + manifest.tracked).allSatisfy({ $0.words.count == 8 && $0.words[1] == getuid() }) else {
            throw cleanupFailure("Stale or foreign private cleanup identity; ownership stays held.")
        }
        return manifest
    }
}

/// Bounded process inspection. Only environment entries matching our one tag are
/// retained; arguments and other environment values never enter logs or storage.
struct HostPrivateProcessInspector: Sendable {
    static let tagKey = "SILKWIRE_PRIVATE_EXECUTION"
    private func info(_ pid: pid_t) throws -> proc_bsdinfo? {
        var value = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout.size(ofValue: value))) == MemoryLayout.size(ofValue: value) { return value }
        if errno == ESRCH { return nil }
        throw cleanupFailure("Process inspection failed for PID \(pid) (errno \(errno)).")
    }
    func live(_ token: HostProcessToken) throws -> Bool {
        guard let state = try info(token.pid), state.pbi_status != UInt32(SZOMB) else { return false }
        return try HostProcessToken.read(token.pid) == token
    }
    /// A complete snapshot for every caller, including inspection outside sweep.
    /// Re-enumeration belongs here rather than requiring caller/test retries.
    /// After a transition, two fresh empty scans are required before returning
    /// empty. Cleanup supplies its ORIGINAL deadline, never a renewed budget.
    func survivors(_ manifest: HostPrivateCleanupManifest, deadline: ContinuousClock.Instant? = nil) throws -> [HostProcessToken] {
        try snapshot(manifest, deadline: deadline).survivors
    }
    struct Snapshot { var survivors: [HostProcessToken] = []; var signalable: [HostProcessToken] = []; var evidence = "" }
    func snapshot(_ manifest: HostPrivateCleanupManifest, deadline suppliedDeadline: ContinuousClock.Instant? = nil) throws -> Snapshot {
        let clock = ContinuousClock(), deadline = suppliedDeadline ?? ContinuousClock.now.advanced(by: .seconds(5))
        var lastRace: HostPrivateInspectionRace?
        var emptyPasses = 0
        while true {
            guard clock.now < deadline else {
                if let lastRace { throw lastRace }
                throw cleanupFailure("Private inspection deadline expired; ownership stays held.")
            }
            do {
                let result = try scan(manifest)
                guard clock.now < deadline else { throw cleanupFailure("Private inspection exceeded the cleanup deadline; ownership stays held.") }
                if lastRace == nil || !result.survivors.isEmpty { return result }
                emptyPasses += 1
                if emptyPasses == 2 { return result }
            } catch let race as HostPrivateInspectionRace {
                lastRace = race; emptyPasses = 0
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
    private func scan(_ manifest: HostPrivateCleanupManifest) throws -> Snapshot {
        guard let lineage = manifest.lineage, let roots = manifest.roots,
              roots.count == manifest.tracked.count,
              zip(roots, manifest.tracked).allSatisfy({ root, token in
                  root.pid == token.pid && root.unique > lineage.startWatermark
                      && UInt32(bitPattern: root.version) == token.words[7]
              }) else { throw cleanupFailure("Missing or inconsistent private process lineage; ownership stays held.") }
        let scope = StagingInstallWorkload.Scope(host: manifest.owner, lineage: lineage,
            tag: manifest.tag.uuidString, hostAlive: true, roots: roots + (manifest.observed ?? []), environmentKey: Self.tagKey)
        let pass: StagingInstallWorkload.Pass
        do { pass = try StagingInstallWorkload.pass(scope) }
        catch { throw HostPrivateInspectionRace(message: "Kernel lineage inspection incomplete: " + error.localizedDescription) }
        if let why = pass.incomplete { throw HostPrivateInspectionRace(message: why) }
        var result = Snapshot()
        result.evidence = pass.survivors.prefix(8).map { "\($0.text) [unique ID \($0.unique), signalable: \($0.signalSafe)]" }.joined(separator: "; ")
        for survivor in pass.survivors {
            // Bind the audit token used for signalling to the stable identity
            // found by the shared scanner. Exec/PID reuse invalidates the pass.
            guard survivor.pid != getpid() else { throw cleanupFailure("Private lineage includes the host; ownership stays held.") }
            do {
                let token = try HostProcessToken.read(survivor.pid)
                guard case .live(let current) = try StagingInstallWorkload.identity(survivor.pid),
                      current.unique == survivor.unique, UInt32(bitPattern: current.version) == token.words[7] else {
                    throw cleanupFailure("Process identity changed during lineage inspection.")
                }
                result.survivors.append(token)
                if survivor.signalSafe { result.signalable.append(token) }
            } catch {
                throw HostPrivateInspectionRace(message: "Cannot bind lineage survivor \(survivor.text) [unique ID \(survivor.unique), signalable: \(survivor.signalSafe)] to an exact signal identity: " + error.localizedDescription)
            }
        }
        for token in manifest.tracked where try live(token) && !result.survivors.contains(token) {
            result.survivors.append(token); result.signalable.append(token)
        }
        return result
    }
}

/// The approved policy, distinct from strict physical-exit certificates. Injection
/// is for failure tests; production always uses the native inspector and signals.
struct HostPrivateExecutionCleanup: Sendable {
    var inspect: (@Sendable (HostPrivateCleanupManifest) throws -> [HostProcessToken])? = nil
    var signal: @Sendable (HostProcessToken, Int32) throws -> Void = { try $0.signal($1) }
    var deadlineSeconds: Double = 5
    func sweep(_ manifest: HostPrivateCleanupManifest) async -> HostPhysicalExit {
        do {
            guard manifest.lineage != nil, manifest.roots != nil else {
                throw cleanupFailure("Missing private process lineage; ownership stays held.")
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(deadlineSeconds))
            var passes = 0
            var inspectionRace: String?
            var lastSurvivors = ""
            while true {
                guard clock.now < deadline else {
                    throw cleanupFailure("Private cleanup deadline expired; ownership stays held." + (inspectionRace.map { " Last incomplete scan: " + $0 } ?? "") + (lastSurvivors.isEmpty ? "" : " Last survivors: " + lastSurvivors))
                }
                let survivors: [HostProcessToken], signalable: [HostProcessToken]
                do {
                    if let inspect { survivors = try inspect(manifest); signalable = survivors }
                    else {
                        let snapshot = try HostPrivateProcessInspector().snapshot(manifest, deadline: deadline)
                        survivors = snapshot.survivors; signalable = snapshot.signalable; lastSurvivors = snapshot.evidence
                    }
                }
                catch let race as HostPrivateInspectionRace {
                    // Do not combine an empty scan from before a process changed
                    // with one from afterward. Re-enumerate within this sweep's
                    // original deadline, without caching a successful verdict.
                    passes = 0; inspectionRace = race.localizedDescription
                    try await Task.sleep(for: .milliseconds(25))
                    continue
                }
                guard clock.now < deadline else { throw cleanupFailure("Private inspection exceeded the cleanup deadline; ownership stays held.") }
                if survivors.isEmpty {
                    passes += 1
                    if passes == 2 { return .privateCleanup(.init(identity: manifest.identity, workspaceID: manifest.workspaceID, jobID: manifest.jobID, evidence: manifest.summary)) }
                } else {
                    passes = 0
                    for process in signalable { try signal(process, SIGKILL) }
                }
                guard clock.now < deadline else { throw cleanupFailure("Private cleanup deadline expired with process-lineage or tagged survivors; ownership stays held. " + lastSurvivors) }
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch { return .unconfirmed(reason: "Private cleanup failed; ownership stays held: " + error.localizedDescription) }
    }
    func recover(_ record: PhysicalWorkOwnership.Record, directory: URL) async -> HostPhysicalExit? {
        guard !record.owner.kind.isExclusive else { return nil }
        do {
            let store = HostPrivateCleanupStore(directory: directory)
            guard let manifest = try store.load(.init(record)) else { return nil }
            if let reason = manifest.disabledReason { return .unconfirmed(reason: reason) }
            let inspector = HostPrivateProcessInspector()
            // A new host must not sweep an execution whose original host is alive.
            if !manifest.sealed, try inspector.live(manifest.owner) {
                return .unconfirmed(reason: "The private execution's original host is still alive; cleanup cannot take over its ownership.")
            }
            return await sweep(manifest)
        } catch { return .unconfirmed(reason: "Private recovery evidence unavailable; ownership stays held: " + error.localizedDescription) }
    }
}
