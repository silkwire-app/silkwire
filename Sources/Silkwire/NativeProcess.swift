import Foundation
import Darwin

/// A process has its own POSIX process group from spawn, not a racy post-launch setpgid.
/// stdout/stderr callbacks and onExit run on the main actor; both streams drain first.
@MainActor final class NativeProcess {
    private static var owned: [pid_t: NativeProcess] = [:]
    private(set) var pid: pid_t = 0
    private(set) var isRunning = false
    private var input: Int32 = -1
    private var killTask: Task<Void, Never>?
    private let writes = DispatchQueue(label: "app.silkwire.process-input." + UUID().uuidString)

    /// `standardSignals`: Builder commands get ordinary Unix pipe semantics (SIGPIPE
    /// unblocked and default), so `producer | head` reports the producer's SIGPIPE
    /// instead of an EPIPE error exit that would read as a failed check.
    init(executable: String, arguments: [String], directory: URL, environment: [String: String], standardSignals: Bool = false, physicalEvidence: HostLocalExecutionEvidence? = nil, sandboxedPrivate: Bool = false, stdout: @escaping (Data) -> Void, stderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable), directory.isFileURL,
              !arguments.contains(where: { $0.contains("\0") }), !environment.contains(where: { $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") }) else { throw nativeFailure("The external runtime or process configuration is unavailable.") }
        guard !sandboxedPrivate || (executable == "/usr/bin/sandbox-exec" && arguments.first == "-p" && arguments.count >= 3) else {
            throw nativeFailure("Private cleanup requires the host sandbox launcher.")
        }
        var inheritedEnvironment = environment
        if NativeSandboxState.isSandboxed, inheritedEnvironment[HostPrivateProcessInspector.tagKey] == nil {
            inheritedEnvironment[HostPrivateProcessInspector.tagKey] = ProcessInfo.processInfo.environment[HostPrivateProcessInspector.tagKey]
        }
        let launchEnvironment = try physicalEvidence?.launchEnvironment(inheritedEnvironment, sandboxedPrivate: sandboxedPrivate) ?? inheritedEnvironment
        var inPipe = [Int32](repeating: 0, count: 2), outPipe = inPipe, errPipe = inPipe
        guard pipe(&inPipe) == 0 else { throw nativeFailure("Could not open a runtime pipe.") }
        guard pipe(&outPipe) == 0 else { for fd in inPipe { Darwin.close(fd) }; throw nativeFailure("Could not open a runtime pipe.") }
        guard pipe(&errPipe) == 0 else { for fd in inPipe + outPipe { Darwin.close(fd) }; throw nativeFailure("Could not open a runtime pipe.") }
        let allFDs = inPipe + outPipe + errPipe
        for fd in allFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        for fd in allFDs { posix_spawn_file_actions_addclose(&actions, fd) }
        if #available(macOS 26.0, *) { posix_spawn_file_actions_addchdir(&actions, directory.path) }
        else { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        if standardSignals {
            var none = sigset_t(); sigemptyset(&none); posix_spawnattr_setsigmask(&attributes, &none)
            var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGPIPE); posix_spawnattr_setsigdefault(&attributes, &defaults)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        } else {
            // A closed stdin must report EPIPE, never terminate the host app with SIGPIPE.
            var ignored = sigset_t(); sigemptyset(&ignored); sigaddset(&ignored, SIGPIPE)
            posix_spawnattr_setsigmask(&attributes, &ignored)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK))
        }
        if physicalEvidence != nil {
            var flags: Int16 = 0
            posix_spawnattr_getflags(&attributes, &flags)
            posix_spawnattr_setflags(&attributes, flags | Int16(POSIX_SPAWN_START_SUSPENDED))
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = launchEnvironment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for item in argv + envp { if let item { free(item) } } }
        var child: pid_t = 0
        let code = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in posix_spawn(&child, executable, &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!)) } }
        guard code == 0 else { for fd in allFDs { Darwin.close(fd) }; throw nativeFailure("The external runtime could not launch (\(code)).") }
        if let physicalEvidence {
            do { try physicalEvidence.observeSuspended(pid: child) }
            catch {
                // No user code ran. Reap this exact child; never signal a recycled PID.
                _ = Darwin.kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                for fd in allFDs { Darwin.close(fd) }
                throw error
            }
            guard Darwin.kill(child, SIGCONT) == 0 else {
                physicalEvidence.invalidate("Managed worker could not resume after exit-observer registration.")
                _ = Darwin.kill(child, SIGKILL)
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                for fd in allFDs { Darwin.close(fd) }
                throw nativeFailure("Managed worker could not resume safely.")
            }
        }
        Darwin.close(inPipe[0]); Darwin.close(outPipe[1]); Darwin.close(errPipe[1])
        input = inPipe[1]; pid = child; isRunning = true
        Self.owned[child] = self
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
        // Nonblocking stdin prevents a stalled runtime from blocking the app's UI.
        _ = fcntl(input, F_SETFL, O_NONBLOCK)
        let drains = DispatchGroup(), drainControl = NativeProcessDrainControl()
        for (fd, callback) in [(outPipe[0], stdout), (errPipe[0], stderr)] {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            drains.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var bytes = [UInt8](repeating: 0, count: 16384)
                while !drainControl.cancelled {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                    let ready = poll(&descriptor, 1, 100)
                    if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                    if ready < 0 { break }
                    let size = Darwin.read(fd, &bytes, bytes.count)
                    if size > 0 { let data = Data(bytes.prefix(size)); DispatchQueue.main.async { callback(data) } }
                    else if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    else { break }
                }
                Darwin.close(fd); drains.leave()
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            // Keep the exited leader unreaped while signalling its group. Its PID
            // cannot be recycled underneath a late Stop or the drain callback.
            var info = siginfo_t()
            var waited: Int32
            repeat { waited = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) } while waited < 0 && errno == EINTR
            if waited == 0 { _ = Darwin.kill(-child, SIGKILL) }
            var drained = drains.wait(timeout: .now() + .milliseconds(100)) == .success
            if !drained {
                if let physicalEvidence {
                    let swept = DispatchSemaphore(value: 0)
                    Task { @MainActor in await physicalEvidence.sweepAfterLeaderExit(); swept.signal() }
                    swept.wait()
                }
                drained = drains.wait(timeout: .now() + 5) == .success
            }
            if !drained { drainControl.cancel(); drains.wait() }
            let observed = waited == 0
            DispatchQueue.main.async {
                if !drained { physicalEvidence?.invalidate("Managed output streams did not join before the drain deadline; ownership stays held.") }
                self.isRunning = false
                if Self.owned[child] === self { Self.owned.removeValue(forKey:child) }
                self.closeInput()
                self.killTask?.cancel(); self.killTask = nil
                var status: Int32 = 0
                if observed {
                    while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                } else { physicalEvidence?.invalidate("Managed child wait identity was lost; group signals and exit proof were refused.") }
                let result: Int32 = !observed || !drained ? -1 : (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                onExit(result)
            }
        }
    }
    func write(_ data: Data) throws {
        guard isRunning, input >= 0 else { throw nativeFailure("The external runtime is disconnected; nothing was resent.") }
        // Files are small bounded protocol frames; use a dedicated serial writer for pipe backpressure.
        // Duplicating protects against a simultaneous close without writing to a recycled descriptor.
        let fd = fcntl(input, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw nativeFailure("The external runtime pipe is unavailable.") }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let processGroup = pid
        writes.async { [weak self] in
            defer { Darwin.close(fd) }
            let complete = data.withUnsafeBytes { buffer -> Bool in
                guard let base = buffer.baseAddress else { return true }
                var offset = 0
                while offset < data.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                    if count > 0 { offset += count }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN || errno == EWOULDBLOCK {
                        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        var ready: Int32
                        repeat { ready = poll(&descriptor, 1, 1000) } while ready < 0 && errno == EINTR
                        guard ready > 0, descriptor.revents & Int16(POLLOUT) != 0 else { return false }
                    } else { return false }
                }
                return true
            }
            // A partial protocol frame is NEVER treated as a successful send. Closing
            // the owned runtime produces an explicit unconfirmed outcome at the boundary.
            if !complete { DispatchQueue.main.async { guard self?.pid == processGroup else { return }; self?.terminate() } }
        }
    }
    func closeInput() {
        guard input >= 0 else { return }
        let fd = input; input = -1
        writes.async { Darwin.close(fd) }
    }
    func terminate() {
        guard isRunning, pid > 0 else { return }
        _ = Darwin.kill(-pid, SIGTERM)
        guard killTask == nil else { return }
        let group = pid
        killTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, self?.isRunning == true, self?.pid == group else { return }
            _ = Darwin.kill(-group, SIGKILL)
        }
    }
    static func shutdownOwnedGroups() {
        // Application termination cannot rely on a two-second Task executing
        // after its event loop has gone away. Never leave an owned command/CLI
        // descendant behind when the host exits. This does not touch Gateway.
        for process in owned.values where process.isRunning {
            process.killTask?.cancel()
            _ = Darwin.kill(-process.pid, SIGKILL)
            process.closeInput()
        }
    }
    static func run(executable: String, arguments: [String], directory: URL, environment: [String: String], timeoutSeconds: Double = 120, outputLimit: Int = 1_048_576, standardSignals: Bool = false, returnInterruptedResult: Bool = false, physicalEvidence: HostLocalExecutionEvidence? = nil, sandboxedPrivate: Bool = false) async throws -> NativeProcessResult {
        let run = NativeCapturedProcess()
        run.returnInterruptedResult = returnInterruptedResult
        return try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { continuation in
            run.continuation = continuation
            if Task.isCancelled { run.continuation = nil; continuation.resume(throwing: CancellationError()); return }
            do {
                run.process = try NativeProcess(executable: executable, arguments: arguments, directory: directory, environment: environment, standardSignals: standardSignals, physicalEvidence: physicalEvidence, sandboxedPrivate: sandboxedPrivate, stdout: { run.append($0, error: false, limit: outputLimit) }, stderr: { run.append($0, error: true, limit: outputLimit) }, onExit: { run.finish($0) })
                run.process?.closeInput()
                run.deadline = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.01, timeoutSeconds) * 1_000_000_000))
                    guard !Task.isCancelled, run.continuation != nil else { return }
                    run.timedOut = true; run.process?.terminate()
                }
            } catch { run.continuation = nil; continuation.resume(throwing: error) }
          }
        }, onCancel: { Task { @MainActor in run.cancel() } })
    }
}
@MainActor private final class NativeCapturedProcess {
    var process: NativeProcess?
    var returnInterruptedResult = false
    var continuation: CheckedContinuation<NativeProcessResult, Error>?
    var output = Data(), errors = Data(), truncated = false, timedOut = false, cancelled = false
    var deadline: Task<Void, Never>?
    func cancel() { cancelled = true; process?.terminate() }
    func append(_ data: Data, error: Bool, limit: Int) {
        let available = max(0, limit - output.count - errors.count)
        if error { errors.append(data.prefix(available)) } else { output.append(data.prefix(available)) }
        if data.count > available { truncated = true; process?.terminate() }
    }
    func finish(_ code: Int32) {
        deadline?.cancel(); deadline = nil
        guard let continuation else { return }
        self.continuation = nil; process = nil
        if cancelled && !returnInterruptedResult { continuation.resume(throwing: CancellationError()) }
        else if timedOut { continuation.resume(throwing: nativeFailure("The external runtime timed out; its process group was stopped. Nothing was resent.")) }
        else { continuation.resume(returning: NativeProcessResult(exitCode: code, stdout: String(decoding: output, as: UTF8.self), stderr: String(decoding: errors, as: UTF8.self), truncated: truncated)) }
    }
}
func nativeProviderEnvironment() -> [String: String] {
    let original = ProcessInfo.processInfo.environment
    var result = Dictionary(uniqueKeysWithValues: ["USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SECURITYSESSIONID", "__CF_USER_TEXT_ENCODING"].compactMap { key in original[key].map { (key, $0) } })
    result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
    result["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    return result
}
func nativeProviderDirectory(_ name: String) throws -> URL {
    let base = WorkspaceEnvironment.current.staging ? WorkspaceEnvironment.current.library.appendingPathComponent("Runtime") : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Silkwire Runtime")
    let root = base.appendingPathComponent("Provider Processes/" + name, isDirectory: true)
    guard WorkspaceEnvironment.current.permitsManagedPath(root) else { throw nativeFailure("Staging provider storage points outside its private library.") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

/// Readers close their own descriptors after cancellation, avoiding a close/read
/// race against a reused FD. Polling bounds cancellation even for detached pipes.
private final class NativeProcessDrainControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}
