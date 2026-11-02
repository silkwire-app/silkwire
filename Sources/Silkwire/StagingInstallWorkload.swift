import Foundation
import Darwin

/// Kernel evidence that a Staging install's ENTIRE workload has ended: the installer
/// process, every process it started (directly or through intermediates that have since
/// exited) and every process carrying the install's tag (docs/staging-install-exclusive.md).
///
/// Every identity here is a stable kernel identity, never a bare PID. PIDs are reused;
/// these are not:
/// - a process's kernel unique ID: 64-bit, allocated in increasing order at fork, kept
///   across exec, never reused;
/// - its PID version: one global counter that advances at every fork and exec;
/// - an audit token (PID plus PID version) for the exact program image.
///
/// The lane records `Lineage` durably BEFORE any installer code runs:
/// - `hostUnique` / `hostVersion`: the installer process's unique ID and PID version.
/// - `hostResponsibleUnique`: the unique ID of the process macOS holds responsible for
///   the installer.
/// - `startWatermark` / `startVersion`: the kernel's unique-ID and PID-version counters at
///   that moment, read from a probe process (`CounterProbe`). Every process created
///   afterwards has a higher unique ID.
///
/// The kernel keeps each process's parent unique ID from the moment it was created, even
/// after the parent exits and the child is reparented to launchd, until the child next
/// execs: then the parent unique ID becomes launchd's, while the original parent's PID
/// version is still kept. A live process created after the install began is counted as
/// the install's workload when:
/// 1. its chain of parents reaches the installer (a descendant), or
/// 2. the chain hits a parent that was created after the install began and has exited.
///    It may be the installer's, and no surviving evidence says otherwise. The only
///    exception is a process the kernel attributes, by unique ID, to another live app
///    that is itself unrelated to the installer (such as a browser's crash handler), or
/// 3. it is this user's process and carries `SILKWIRE_STAGING_INSTALL=<operation>`.
///    macOS hides the environment of Apple platform binaries (such as /bin/sleep or
///    /bin/sh) from other processes, so the tag is checked where the kernel shows it;
///    the lineage rules above apply to every process either way.
///
/// "Ended" is proved on a consistent cut of the whole process table, not on snapshots
/// that something could slip between (`cut`):
/// - `proc_listallpids` copies the kernel's process list in ONE walk under the kernel's
///   process-list lock (xnu proc_listpids), so it is the exact set of processes at one
///   instant. The walk must reach the kernel task (PID 0) at the end of that list, or it
///   was cut short and proves nothing.
/// - A process still being forked at that instant is not on the list yet, but its parent
///   is, and is alive (it is inside fork).
/// - Every listed process must then be read back alive and be the very process listed:
///   its unique ID must be below a counter probe started just before the listing (a
///   process that took over a recycled PID afterwards has a higher one). If any listed
///   process exited before it was read, or can't be read, the cut proves nothing.
/// So a complete cut sees every process that existed at its instant, with its lineage. If
/// none is install work, no install work existed then, and none can appear afterwards
/// except through a process that already existed (which the cut classified). Two
/// consecutive complete cuts are required. Nothing here depends on watching the time
/// between scans.
struct StagingInstallWorkload: Sendable {
    static let tagKey = "SILKWIRE_STAGING_INSTALL"

    struct Lineage: Codable, Equatable, Sendable {
        let hostUnique: UInt64
        /// Unique ID of the process macOS holds responsible for the installer. Nil in a
        /// journal from an older build, which recorded only a PID: such a journal can't
        /// prove anything, and recovery keeps its lane held.
        let hostResponsibleUnique: UInt64?
        var startWatermark: UInt64
        let hostVersion: Int32
        var startVersion: Int32
        /// Set once the installer call has returned while its host process lives on (the
        /// working app). A live host's direct children created after this are not install
        /// work. Without it, a live host means the installer may still be running.
        var returnedWatermark: UInt64?
    }
    struct Scope: Sendable {
        let host: HostProcessToken
        let lineage: Lineage
        let tag: String
        let hostAlive: Bool
        /// nil keeps the installer-host scope. Private jobs supply their suspended launch
        /// identities (and observed descendants) instead, so concurrent jobs in one app are
        /// never all counted as descendants of the shared app process.
        var roots: [Identity]? = nil
        /// The environment entry that tags this scope's processes.
        var environmentKey: String = StagingInstallWorkload.tagKey
    }
    struct Survivor: Equatable, Sendable {
        let pid: pid_t
        let unique: UInt64
        let version: Int32
        let name: String
        let why: String
        /// Ambiguous orphans keep ownership held but can't authorize killing what may be
        /// an unrelated workload. A visible matching tag can establish that link.
        var signalSafe = true
        /// The PID is shown because people look processes up by it; the unique ID is what
        /// identifies the process.
        var text: String { "\(name) (PID \(pid), kernel unique ID \(unique)) \(why)" }
    }
    enum Verdict: Equatable, Sendable {
        case ended(evidence: String)
        case survivors([Survivor])
        case unprovable(String)
    }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Failure-test injection only; production always runs the kernel scan.
    var inspect: (@Sendable (Scope) -> Verdict)? = nil
    var deadlineSeconds: Double = 3

    /// Proves the workload ended, finds what still runs, or says why it can't tell.
    /// Bounded: the scan runs on its own thread and a scan that doesn't return in time
    /// (for example a kernel read that blocks) leaves the verdict unprovable, never hangs
    /// the caller. A late scan thread finishes on its own and its result is dropped.
    func verify(_ scope: Scope) async -> Verdict {
        if let inspect { return inspect(scope) }
        let seconds = deadlineSeconds
        let box = VerdictBox()
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            let thread = Thread { box.resolve(Self.scan(scope, seconds: seconds)) }
            thread.name = "Silkwire install workload scan"
            thread.start()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds + 5) {
                box.resolve(.unprovable("The kernel process scan did not return within \(Int(seconds) + 5) s."))
            }
        }
    }
    private final class VerdictBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Verdict, Never>?
        private var pending: Verdict?
        func install(_ value: CheckedContinuation<Verdict, Never>) {
            lock.lock(); defer { lock.unlock() }
            if let pending { value.resume(returning: pending); self.pending = nil; return }
            continuation = value
        }
        func resolve(_ verdict: Verdict) {
            lock.lock(); defer { lock.unlock() }
            if let continuation { continuation.resume(returning: verdict); self.continuation = nil }
            else if pending == nil { pending = verdict }
        }
    }
    private static func scan(_ scope: Scope, seconds: Double) -> Verdict {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        var clean = 0, last = "no cut ran", cuts = 0
        while clock.now < deadline {
            do {
                let cut = try Self.cut(scope)
                cuts += 1
                if !cut.survivors.isEmpty { return .survivors(cut.survivors) }
                if let note = cut.incomplete { clean = 0; last = note }
                else {
                    clean += 1
                    if clean == 2 {
                        return .ended(evidence: "Kernel lineage proof, 2 consecutive complete cuts of the whole process table (each one atomic kernel listing of all \(cut.count) processes, every one read back as the same process by kernel unique ID): none descends from the installer (unique ID \(scope.lineage.hostUnique)), none started after the install began (unique ID above \(scope.lineage.startWatermark), PID version above \(scope.lineage.startVersion)) has an exited parent unless the kernel attributes it by unique ID to an unrelated live app, and none of this user's processes carries the install tag (\(cut.hidden) had their environment hidden by macOS; lineage covers them).")
                    }
                }
            } catch { clean = 0; last = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return .unprovable("No 2 consecutive complete cuts of the process table within \(Int(seconds)) s (\(cuts) tried; last: \(last)).")
    }

    /// Recorded before admission (and refined once admitted).
    static func lineage() throws -> Lineage {
        guard case .live(let me) = try identity(getpid()) else { throw Failure(message: "Cannot read the installer's own kernel identity.") }
        guard let responsible = responsibleUnique(getpid()), case .live(let check) = try identity(getpid()), check.unique == me.unique else {
            throw Failure(message: "Cannot read which process macOS holds responsible for the installer.")
        }
        let now = try watermark()
        return Lineage(hostUnique: me.unique, hostResponsibleUnique: responsible, startWatermark: max(now.unique, me.unique),
                       hostVersion: me.version, startVersion: max(now.version, me.version))
    }
    /// The kernel's unique-ID and PID-version counters right now: every process created
    /// afterwards has higher values. Read from a probe process created for the purpose.
    static func watermark() throws -> (unique: UInt64, version: Int32) {
        let probe = try CounterProbe()
        defer { probe.end() }
        return try probe.counters()
    }

    // MARK: One consistent cut

    struct Cut { var survivors: [Survivor] = []; var incomplete: String?; var count = 0; var hidden = 0 }
    struct Identity: Codable, Equatable, Sendable { let pid: pid_t; let unique: UInt64; let parent: UInt64; let version: Int32; let originalParentVersion: Int32 }
    /// The shared scanner's name for one cut, used by private-job cleanup and its
    /// lineage sampling (HostPrivateExecutionCleanup, HostLocalExecutionEvidence).
    typealias Pass = Cut
    static func pass(_ scope: Scope) throws -> Pass { try cut(scope) }
    /// A read made through `process.pid` describes that process only if the PID still
    /// names exactly the snapshot identity afterwards (same unique ID, no exec since).
    static func stillSame(_ process: Identity) -> Bool {
        if case .live(let now)? = try? identity(process.pid), now == process { return true }
        return false
    }
    /// Owner and short name, read through the PID and bound to the snapshot identity.
    /// PROC_PIDT_SHORTBSDINFO is readable for every user's processes on this macOS; if
    /// it is ever refused, KERN_PROC_PID exposes the credentials without task access.
    struct Details { let uid: uid_t; let name: String }
    static func details(_ process: Identity) -> Details? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        if proc_pidinfo(process.pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size {
            guard stillSame(process) else { return nil }
            let name = withUnsafeBytes(of: info.pbsi_comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            return Details(uid: info.pbsi_uid, name: name)
        }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process.pid]
        var kernel = kinfo_proc(), bytes = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &kernel, &bytes, nil, 0) == 0, bytes == MemoryLayout<kinfo_proc>.size, stillSame(process) else { return nil }
        let name = withUnsafeBytes(of: kernel.kp_proc.p_comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return Details(uid: kernel.kp_eproc.e_ucred.cr_uid, name: name)
    }

    static func cut(_ scope: Scope) throws -> Cut {
        var result = Cut()
        // Counter probe first, then the atomic listing at once: a listed PID whose process
        // reads back with a unique ID at or above the probe's may be a recycled PID.
        let probe = try CounterProbe()
        defer { probe.end() }
        let listed = try allPIDs()
        let (bound, _) = try probe.counters()
        guard let kernelIndex = listed.firstIndex(of: 0), listed[..<kernelIndex].contains(1) else {
            throw Failure(message: "The kernel's process listing did not reach its end (PID 0 and launchd missing); it proves nothing.")
        }
        // Entries after the kernel task are zombies: already exited, can start nothing.
        let members = listed[..<kernelIndex]
        guard members.contains(probe.pid) else { throw Failure(message: "The process listing did not include this scan's own probe; it proves nothing.") }
        var live: [UInt64: Identity] = [:]
        for pid in members where pid != probe.pid {
            switch try identity(pid) {
            case .gone:
                result.incomplete = result.incomplete ?? "PID \(pid) exited before it could be read, so what it was is unknown."
            case .live(let id):
                guard id.unique < bound else {
                    result.incomplete = result.incomplete ?? "PID \(pid) now belongs to a process created during the cut (kernel unique ID \(id.unique)), so the listed process can't be confirmed."
                    continue
                }
                live[id.unique] = id
            }
        }
        result.count = live.count
        guard let launchd = live[1], launchd.pid == 1 else { throw Failure(message: "Cannot read launchd's kernel identity.") }
        let host = scope.lineage.hostUnique, start = scope.lineage.startWatermark
        let roots = scope.roots ?? []
        let rootIDs = Set(roots.map(\.unique)), rootVersions = Set(roots.map(\.version))
        let returned = scope.hostAlive ? scope.lineage.returnedWatermark : nil
        enum Link { case unrelated, descendant(direct: Bool), orphan(String) }
        func link(_ process: Identity) -> Link {
            var node = process
            for _ in 0..<65536 {
                // Reparented to launchd, then exec'd: only the original parent's PID version
                // remains. That parent has exited (that is why it was reparented).
                if node.parent == launchd.unique, node.originalParentVersion != launchd.version {
                    let fromRoot = scope.roots == nil ? node.originalParentVersion == scope.lineage.hostVersion : rootVersions.contains(node.originalParentVersion)
                    if fromRoot { return .descendant(direct: node.unique == process.unique) }
                    if node.originalParentVersion > scope.lineage.startVersion { return .orphan("PID version \(node.originalParentVersion)") }
                    return .unrelated
                }
                if scope.roots == nil ? node.parent == host : rootIDs.contains(node.parent) {
                    // A live host's children made after its installer call returned are not install work.
                    if let returned, node.unique > returned { return .unrelated }
                    return .descendant(direct: node.unique == process.unique)
                }
                if node.parent <= start { return .unrelated }
                guard let up = live[node.parent], up.unique < node.unique else { return .orphan("kernel unique ID \(node.parent)") }
                node = up
            }
            return .orphan("kernel unique ID \(node.parent)")
        }
        enum Tagged { case match, absent, hidden, unknown(String) }
        func tagged(_ process: Identity) -> Tagged {
            guard let details = details(process) else { return .unknown("PID \(process.pid) (kernel unique ID \(process.unique)) exited while it was read.") }
            guard details.uid == getuid() else { return .absent }
            for _ in 0..<3 {
                let read = tag(process.pid, expecting: scope.tag, key: scope.environmentKey)
                // The environment was read through the PID: count it only if the PID still
                // names the same process afterwards.
                guard stillSame(process) else { return .unknown("PID \(process.pid) (kernel unique ID \(process.unique)) exited while its environment was read.") }
                switch read {
                case .match: return .match
                case .absent: return .absent
                case .hidden: return .hidden
                case .gone, .unreadable: Thread.sleep(forTimeInterval: 0.005)
                }
            }
            return .unknown("Cannot read the environment of PID \(process.pid) (kernel unique ID \(process.unique)).")
        }
        /// Another live, unrelated app is responsible for it (it inherited that at spawn),
        /// and that app predates the install or job. By kernel unique ID only: when the
        /// responsible app exits, the kernel answers with the process itself, so a recycled
        /// PID can never stand in for it. Both ends are re-checked against the cut's
        /// identities afterwards, and the attribution must be unchanged.
        func attributedElsewhere(_ process: Identity) -> Bool {
            guard let owner = responsibleUnique(process.pid), stillSame(process),
                  owner != process.unique, owner != host, owner != scope.lineage.hostResponsibleUnique,
                  let app = live[owner], app.unique <= start, app.unique < process.unique, case .unrelated = link(app) else { return false }
            switch tagged(app) { case .absent, .hidden: break; case .match, .unknown: return false }
            return stillSame(app) && stillSame(process) && responsibleUnique(process.pid) == owner
        }
        func survivor(_ process: Identity, _ why: String) -> Survivor {
            Survivor(pid: process.pid, unique: process.unique, version: process.version, name: name(process), why: why)
        }
        // The installer's own unique ID survives exec; its audit token's version does not.
        if scope.roots == nil, !scope.hostAlive, let itself = live[host] {
            result.survivors.append(survivor(itself, "is the installer process itself, still running under a new program image"))
        }
        for process in live.values.sorted(by: { $0.unique < $1.unique }) where process.unique > start && process.unique != host {
            if rootIDs.contains(process.unique) {
                result.survivors.append(survivor(process, "is a job process, still running under its stable kernel identity"))
                continue
            }
            switch link(process) {
            case .descendant(let direct):
                result.survivors.append(survivor(process, direct ? "was started by the installer" : "descends from the installer"))
                continue
            case .orphan(let parent) where !attributedElsewhere(process):
                var found = survivor(process, "was started after the install began by a process that has exited (\(parent)), so it may be the installer's")
                if case .match = tagged(process) { found.signalSafe = true } else { found.signalSafe = false }
                result.survivors.append(found)
                continue
            case .orphan, .unrelated: break
            }
            switch tagged(process) {
            case .match: result.survivors.append(survivor(process, "carries this install's tag"))
            case .unknown(let why): result.incomplete = result.incomplete ?? why
            case .hidden: result.hidden += 1
            case .absent: break
            }
        }
        return result
    }
    /// For display. The path is read through the PID, so it is used only if the PID still
    /// names the same process afterwards; otherwise the name read with the unique ID.
    private static func name(_ process: Identity) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(process.pid, &buffer, UInt32(buffer.count)) > 0, stillSame(process) {
            return (String(cString: buffer) as NSString).lastPathComponent
        }
        return details(process).map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? "process"
    }

    // MARK: Kernel reads

    /// xnu `struct proc_uniqidentifierinfo` (56 bytes), flavor PROC_PIDUNIQIDENTIFIERINFO.
    private struct UniqueInfo {
        var uuid: (UInt64, UInt64) = (0, 0)
        var unique: UInt64 = 0
        var parentUnique: UInt64 = 0
        var idVersion: Int32 = 0
        var originalParentVersion: Int32 = 0
        var reserved: (UInt64, UInt64) = (0, 0)
    }
    /// Flavor PROC_PIDUNIQIDENTIFIERINFO: all of a process's kernel identifiers in one
    /// read. Readable for every user's processes; a zombie or exited process gives ESRCH.
    private static let uniqueFlavor: Int32 = 17
    enum Lookup { case live(Identity), gone }
    static func identity(_ pid: pid_t) throws -> Lookup {
        var info = UniqueInfo()
        let size = Int32(MemoryLayout<UniqueInfo>.size)
        let count = proc_pidinfo(pid, uniqueFlavor, 0, &info, size)
        let code = errno
        // A PID version of 0 is not a usable identity (never a real process image).
        if count == size, info.unique > 0, info.idVersion > 0 {
            return .live(Identity(pid: pid, unique: info.unique, parent: info.parentUnique, version: info.idVersion, originalParentVersion: info.originalParentVersion))
        }
        if count <= 0 && code == ESRCH { return .gone }
        throw Failure(message: "Cannot read the kernel identity of PID \(pid) (errno \(code)).")
    }
    /// One atomic kernel listing (see the type comment).
    static func allPIDs() throws -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0, estimate < 131072 else { throw Failure(message: "Process enumeration is unavailable.") }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 1024)
        let capacity = pids.count
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < capacity else { throw Failure(message: "Process enumeration was incomplete.") }
        return Array(pids.prefix(Int(count)))
    }
    /// libquarantine's responsibility lookup, by kernel unique ID (looked up at runtime;
    /// absent or failing means no attribution, which only ever keeps more processes counted).
    private typealias ResponsibleUniqueFunction = @convention(c) (pid_t) -> UInt64
    private static let responsibleUniqueFunction: ResponsibleUniqueFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_uniqueid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleUniqueFunction.self)
    }()
    /// The kernel unique ID of the process responsible for `pid`, or nil. Read through a
    /// PID: callers confirm afterwards that the PID still names the process they mean.
    static func responsibleUnique(_ pid: pid_t) -> UInt64? {
        guard let function = responsibleUniqueFunction else { return nil }
        let value = function(pid)
        return value > 0 && value != UInt64.max ? value : nil
    }

    enum TagRead: Equatable { case match, absent, hidden, gone, unreadable(String) }
    /// Reads only the one environment entry; nothing else leaves this function. Read
    /// through a PID: callers confirm the PID still names the same process afterwards.
    static func tag(_ pid: pid_t, expecting expected: String, key: String = tagKey) -> TagRead {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        func failed(_ code: Int32) -> TagRead {
            if case .gone? = try? identity(pid) { return .gone }
            return .unreadable("Cannot read the environment of PID \(pid) (errno \(code)).")
        }
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return failed(errno) }
        guard (4...4_194_304).contains(size) else { return failed(EINVAL) }
        var data = [UInt8](repeating: 0, count: size)
        guard data.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0, size >= 4 else { return failed(errno) }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard (0...65536).contains(argc) else { return failed(EINVAL) }
        var index = 4
        func skip() -> Bool {
            while index < size && data[index] != 0 { index += 1 }
            guard index < size else { return false }
            index += 1; return true
        }
        guard skip() else { return failed(EINVAL) }
        while index < size && data[index] == 0 { index += 1 }
        for _ in 0..<argc { guard skip() else { return failed(EINVAL) } }
        let wanted = Array((key + "=" + expected).utf8)
        var entries = 0
        while index < size && data[index] != 0 {
            let begin = index
            guard skip() else { return failed(EINVAL) }
            entries += 1
            if Array(data[begin..<(index - 1)]) == wanted { return .match }
        }
        // No entries at all: macOS withheld it (platform binaries), not an empty environment.
        return entries == 0 ? .hidden : .absent
    }
}

/// A process created only to read the kernel's process counters: it is spawned suspended
/// (it never runs a single instruction), with no environment and no inherited files, read
/// and then killed and reaped. Its unique ID and PID version are the counters' values at
/// its creation.
final class CounterProbe {
    let pid: pid_t
    private var ended = false
    init() throws {
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK))
        let path = "/usr/bin/true"
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        var child: pid_t = 0
        let status = posix_spawn(&child, path, nil, &attributes, argv, envp)
        guard status == 0, child > 0 else { throw StagingInstallWorkload.Failure(message: "Cannot start the process-counter probe (error \(status)).") }
        pid = child
    }
    func counters() throws -> (unique: UInt64, version: Int32) {
        guard case .live(let me) = try StagingInstallWorkload.identity(pid) else { throw StagingInstallWorkload.Failure(message: "The process-counter probe exited before it was read.") }
        return (me.unique, me.version)
    }
    /// SIGKILL and reap, bounded: if the kernel is slow to finish the probe's exit, a
    /// background thread reaps it, so the caller (possibly the main actor) never waits.
    func end() {
        guard !ended else { return }
        ended = true
        let child = pid
        kill(child, SIGKILL)
        var status: Int32 = 0
        for _ in 0..<200 {
            let result = waitpid(child, &status, WNOHANG)
            if result == child || (result < 0 && errno != EINTR) { return }
            usleep(1000)
        }
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        }
    }
    deinit { end() }
}
