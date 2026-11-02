import Foundation
import Darwin

// Staging install/rollback in the coordinator's exclusive lane (docs/staging-install-exclusive.md).
// Synthetic, ad-hoc-signed bundles in a private Applications folder and a private
// ownership registry under the fixture root; the real /Applications, every library and
// the app-global registry are never touched. The restart case SIGKILLs a real child
// process (this same executable) in the middle of its install.
private let files = FileManager.default
private typealias Ownership = PhysicalWorkOwnership

final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
struct Receipt: @unchecked Sendable { let value: [String: Any] }
final class Spawned: @unchecked Sendable { var process: Process? }


/// Stall diagnostics: a plain thread (not the cooperative pool, not Foundation's Process)
/// that, when one stage runs longer than `limit`, prints the stage, `ps` of this process
/// and the processes it names, and a `sample` of this process. It never fails or ends
/// the test itself; the bounded waits do that.
final class StallWatchdog: @unchecked Sendable {
    static let shared = StallWatchdog()
    private let lock = NSLock(); private var label = "start"; private var since = Date(); private var dumped = false
    private var extra: [pid_t] = []
    func stage(_ text: String, watching pids: [pid_t] = []) { lock.lock(); label = text; since = Date(); dumped = false; extra = pids; lock.unlock() }
    func start(limit: Double) {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                lock.lock(); let current = label, began = since, done = dumped, pids = extra; lock.unlock()
                guard !done, Date().timeIntervalSince(began) > limit else { continue }
                lock.lock(); dumped = true; lock.unlock()
                print("STALL: stage \"\(current)\" has run \(Int(Date().timeIntervalSince(began))) s")
                Self.diagnose(pids)
                Self.run("/usr/bin/sample", [String(getpid()), "2", "-mayDie"])
                print("STALL: end of diagnostics for \"\(current)\"")
            }
        }
        thread.start()
    }
    /// `ps` for this process, its children and `pids` (blocked/pending signals, state).
    static func diagnose(_ pids: [pid_t]) {
        let me = String(getpid())
        run("/bin/ps", ["-o", "pid,ppid,stat,blocked,pending,sigmask,wchan,etime,command", "-p", ([me] + pids.map(String.init)).joined(separator: ",")])
        run("/usr/bin/pgrep", ["-l", "-P", me])
    }
    static func run(_ path: String, _ arguments: [String]) {
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, nil, nil, argv, environ) == 0 else { print("STALL: cannot run \(path)"); return }
        var status: Int32 = 0
        for _ in 0..<600 { if waitpid(pid, &status, WNOHANG) != 0 { return }; usleep(50_000) }
        kill(pid, SIGKILL); waitpid(pid, &status, 0)
    }
}

@main struct StagingInstallExclusiveTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if let child = ProcessInfo.processInfo.environment["SILKWIRE_INSTALL_LANE_CHILD"] { try await runChild(child); return }
        if ProcessInfo.processInfo.environment["SILKWIRE_INSTALL_LANE_DISCLAIMED"] == nil, !responsibleForItself() {
            exit(try runDisclaimed())
        }
        var checks = 0, failures = 0
        StallWatchdog.shared.start(limit: 40)
        func check(_ value: Bool, _ label: String) {
            StallWatchdog.shared.stage("after check: " + String(label.prefix(100)))
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        let fixture = try NativeTemporaryDirectory.canonical(files.temporaryDirectory).appendingPathComponent("silkwire-install-lane-" + UUID().uuidString)
        try files.createDirectory(at: fixture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: fixture) }
        func directory(_ name: String) throws -> URL {
            let url = fixture.appendingPathComponent(name)
            try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return url
        }
        @discardableResult func shell(_ path: String, _ args: [String]) throws -> Int32 {
            let job = Process(); job.executableURL = URL(fileURLWithPath: path); job.arguments = args
            job.standardOutput = FileHandle.nullDevice; job.standardError = FileHandle.nullDevice
            try job.run()
            // Bounded, and decided by kernel identity: never an unbounded waitUntilExit.
            let deadline = Date().addingTimeInterval(120), unique = uniqueOf(job)
            while !childExited(job, unique: unique) {
                guard Date() < deadline else { job.terminate(); throw nativeFailure("\(path) did not finish within 120 s") }
                usleep(20_000)
            }
            for _ in 0..<250 where job.isRunning { usleep(20_000) }
            guard !job.isRunning else { throw nativeFailure("\(path) exited, but Foundation never reported its status") }
            return job.terminationStatus
        }
        func bundle(_ name: String, revision: String, sign: Bool = true) throws -> URL {
            let app = fixture.appendingPathComponent("candidates/\(name)/Silkwire Staging.app")
            try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try files.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try files.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Silkwire").path)
            try Data("resource \(name)\n".utf8).write(to: app.appendingPathComponent("Contents/Resources/marker.txt"))
            let info: [String: Any] = ["CFBundleExecutable": "Silkwire", "CFBundleIdentifier": "app.silkwire.staging", "CFBundlePackageType": "APPL", "SilkwireEnvironment": "staging", "SilkwireGitRevision": revision, "SilkwireSourceDigest": "", "SilkwireSourceStatus": "clean"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            if sign { guard try shell("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path]) == 0 else { throw nativeFailure("Cannot ad-hoc sign fixture") } }
            return app
        }
        func waitFor(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
            return false
        }
        /// Bounded reap of a Process: never an unbounded waitUntilExit. On timeout prints
        /// the kernel's view of the process (state, blocked and pending signals).
        func reaped(_ process: Process, _ label: String, _ seconds: Double = 15, unique: UInt64? = nil) async -> Bool {
            let pid = process.processIdentifier
            let known = unique ?? uniqueOf(process)
            if await waitFor(seconds, { childExited(process, unique: known) }) {
                if process.isRunning { print("DIAG: \(label): the kernel shows PID \(pid) (unique ID \(known.map(String.init) ?? "none")) has exited, but Foundation has not reported it; not waiting on Foundation.") }
                return true
            }
            let gone = kill(pid, 0) != 0 && errno == ESRCH
            print("DIAG: \(label): PID \(pid) not seen to exit within \(Int(seconds)) s (kernel: \(gone ? "no such process" : "still present"))")
            StallWatchdog.diagnose([pid])
            return false
        }
        func refusal(_ body: () async throws -> HostExecutionAdmission) async -> Error? {
            do { _ = try await body(); return nil } catch { return error }
        }
        func journals(_ registry: URL) -> [String] {
            ((try? files.contentsOfDirectory(atPath: registry.path)) ?? []).filter { $0.hasPrefix("staging-install-") }
        }

        // MARK: 0. The lane's installer launches no child: in-process signature check matches codesign.
        let valid = try bundle("sig-valid", revision: String(repeating: "1", count: 40))
        let tamperedResource = try bundle("sig-resource", revision: String(repeating: "2", count: 40))
        try Data("changed after signing\n".utf8).write(to: tamperedResource.appendingPathComponent("Contents/Resources/marker.txt"))
        let tamperedExecutable = try bundle("sig-executable", revision: String(repeating: "3", count: 40))
        let handle = try FileHandle(forWritingTo: tamperedExecutable.appendingPathComponent("Contents/MacOS/Silkwire")); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        let addedFile = try bundle("sig-added", revision: String(repeating: "4", count: 40))
        try Data("unsealed\n".utf8).write(to: addedFile.appendingPathComponent("Contents/Resources/extra.txt"))
        let unsigned = try bundle("sig-unsigned", revision: String(repeating: "5", count: 40), sign: false)
        for (label, app) in [("valid", valid), ("tampered resource", tamperedResource), ("tampered executable", tamperedExecutable), ("added resource", addedFile), ("unsigned", unsigned)] {
            let cli = try shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0
            check(StagingInstaller.signatureValid(app) == cli, "in-process signature check agrees with codesign --verify --deep --strict (\(label): \(cli ? "valid" : "invalid"))")
        }
        check(StagingInstaller.signatureValid(valid) && !StagingInstaller.signatureValid(tamperedResource) && !StagingInstaller.signatureValid(unsigned), "a valid bundle passes; tampered and unsigned bundles fail")
        check(StagingInstaller.runningExecutablePaths()?.contains(where: { $0 == Bundle.main.executablePath || $0 == CommandLine.arguments[0] || ($0 as NSString).lastPathComponent == "StagingInstallExclusiveTests" }) == true,
              "in-process process listing (libproc) sees this test process")

        let registry = fixture.appendingPathComponent("registry")
        let coordinator = HostExecutionCoordinator(directory: registry)
        let lane = StagingInstallLane(coordinator: coordinator)
        let applications = try directory("Applications")
        let installer = StagingInstaller(applications: applications, processPaths: { [] })
        func record(_ id: UUID) async -> Ownership.Record? { try? await coordinator.storage.snapshot().first { $0.operationID == id } }
        func admitPrivate(_ workspace: URL, kind: Ownership.Kind = .backgroundJob, wait: Bool = false) async throws -> HostExecutionAdmission {
            try await coordinator.admit(operationID: UUID(), conversationID: UUID(), kind: kind,
                authorize: { .init(executionRoot: workspace, conflictRoot: workspace) }, mayOperate: { true }, wait: wait)
        }
        let a = try bundle("a", revision: String(repeating: "a", count: 40)), identityA = try StagingInstaller.identify(a)
        let b = try bundle("b", revision: String(repeating: "b", count: 40)), identityB = try StagingInstaller.identify(b)
        let c = try bundle("c", revision: String(repeating: "c", count: 40)), identityC = try StagingInstaller.identify(c)

        // MARK: 1. Install blocked while private work holds ownership, then proceeds after it releases.
        let jobWorkspace = try directory("job-workspace"), previewWorkspace = try directory("preview-workspace")
        let job = try await admitPrivate(jobWorkspace, kind: .backgroundJob)
        let preview = try await admitPrivate(previewWorkspace, kind: .foregroundBuild)
        var statuses: [String] = []
        let started1 = Flag()
        let install1ID = UUID()
        let install1 = Task { @MainActor in
            try await lane.run(.install, operationID: install1ID, requester: UUID(), resource: applications, status: { statuses.append($0) }) {
                started1.set(); return Receipt(value: try installer.install(candidate: a, reviewed: identityA))
            }
        }
        check(await waitFor { (try? await coordinator.admissionState().exclusiveWaiters.map(\.operationID)) == [install1ID] }, "the install queues in the exclusive lane behind a running background job and a running preview/build")
        check(!journals(registry).isEmpty, "its durable journal (exact installer process) is written before admission")
        try await Task.sleep(for: .milliseconds(600))
        var state = try await coordinator.admissionState()
        check(!started1.isSet && !files.fileExists(atPath: installer.target.path), "while they hold ownership the installer has not started and the target is untouched")
        check(state.held.count == 2 && state.held.allSatisfy { $0.phase == .executing && !$0.stopRequested } && state.exclusiveHeld == nil,
              "running work is neither stopped nor released by the waiting install")
        check(statuses.contains { $0.contains("Waiting for 2 running Silkwire jobs") }, "the wait is reported in plain words: \(statuses.last ?? "")")
        check((await refusal { try await admitPrivate(try directory("late-1")) } as? Ownership.Failure) == .exclusivePending, "new work is held back while the install waits")
        try await coordinator.finish(job, exit: .verified(evidence: "fixture: background job's executor exited"))
        try await Task.sleep(for: .milliseconds(300))
        check(!started1.isSet, "one finished job is not enough: the preview still holds ownership")
        // An unproved exit stays held (uncertain) and keeps blocking the install.
        _ = try? await coordinator.finish(preview, exit: .unconfirmed(reason: "fixture: preview worker exit not proved"))
        try await Task.sleep(for: .milliseconds(300))
        state = try await coordinator.admissionState()
        check(!started1.isSet && state.held.count == 1 && state.held.first?.phase == .uncertain, "an uncertain (unproved) record still blocks the install")
        check(statuses.last?.contains("aren't proved to have exited") == true && statuses.last?.contains("Release") == true, "and the wait names it as unproved, pointing to Release: \(statuses.last ?? "")")
        let handoffText = StagingInstallLane.waitingText(state, for: install1ID, action: "update") ?? ""
        check(handoffText.contains("1 finished job whose processes aren't proved") && !handoffText.contains("running Silkwire job"), "the self-update handoff uses the same wording: \(handoffText)")
        try await coordinator.reconcileAfterPhysicalExit(state.held[0], evidence: "fixture: host verified the preview's workers exited")
        let receipt1 = try await install1.value.value
        check(started1.isSet && installer.installed()?.manifestSHA256 == identityA.manifestSHA256 && receipt1["action"] as? String == "install", "after the last holder releases, the install proceeds and installs the reviewed build")
        let lane1 = await record(install1ID)
        check(lane1?.owner.kind == .exclusiveOperation && lane1?.phase == .finished && (lane1?.evidence ?? "").contains("launches no child process") && (lane1?.evidence ?? "").contains("succeeded"),
              "the install's exclusive record is finished with strict exit evidence: \(lane1?.evidence ?? "none")")
        check(journals(registry).isEmpty && !installer.hasInterruptedOperation, "the journal and in-progress marker are cleared after a finished install")
        let after1 = try await admitPrivate(try directory("after-1"))
        check(after1.kind == .backgroundJob, "new work is admitted again after the install")
        try await coordinator.finish(after1, exit: .verified(evidence: "fixture: never dispatched"))

        // Cancelling while waiting withdraws the request and changes nothing.
        let holder = try await admitPrivate(try directory("holder"))
        var cancelled = false
        let cancelID = UUID()
        let cancelTask = Task { @MainActor in
            try await lane.run(.install, operationID: cancelID, requester: UUID(), resource: applications, mayOperate: { !cancelled }) {
                Receipt(value: try installer.install(candidate: b, reviewed: identityB))
            }
        }
        check(await waitFor { (try? await coordinator.admissionState().exclusiveWaiters.count) == 1 }, "a second install queues behind new running work")
        cancelled = true
        var cancelError: Error?
        do { _ = try await cancelTask.value } catch { cancelError = error }
        state = try await coordinator.admissionState()
        let cancelRecord = await record(cancelID)
        check(StagingInstallLane.describe(cancelError ?? CancellationError()).contains("cancelled") && state.exclusiveWaiters.isEmpty && cancelRecord == nil
              && installer.installed()?.manifestSHA256 == identityA.manifestSHA256 && journals(registry).isEmpty,
              "Cancel while waiting withdraws the queued install; nothing is installed and no journal remains")
        check(state.held.map(\.operationID) == [holder.operationID] && state.held[0].phase == .executing, "and the running work it waited for is untouched")
        try await coordinator.finish(holder, exit: .verified(evidence: "fixture: holder exited"))

        // MARK: 2. New work waits during the install.
        let reachedCopy = Flag(), releaseCopy = DispatchSemaphore(value: 0)
        let pausing = StagingInstaller(applications: applications, processPaths: { [] }, progress: { text in
            if text.hasPrefix("Installing the verified candidate") { reachedCopy.set(); releaseCopy.wait() }
        })
        let install2ID = UUID()
        let install2 = Task { @MainActor in
            try await lane.run(.install, operationID: install2ID, requester: UUID(), resource: applications) {
                Receipt(value: try pausing.install(candidate: b, reviewed: identityB))
            }
        }
        check(await waitFor { reachedCopy.isSet }, "the install is admitted and reaches its copy step")
        state = try await coordinator.admissionState()
        check(state.exclusiveHeld?.operationID == install2ID && state.exclusiveHeld?.phase == .executing && state.held.count == 1, "it holds the registry alone while it runs")
        check((await refusal { try await admitPrivate(try directory("late-2")) } as? Ownership.Failure) == .exclusiveHeld, "an immediate begin is refused (exclusiveHeld) during the install")
        check(HostExecutionCoordinator.privateAdmissionRefusal(state)?.contains("Staging install") == true, "with the plain refusal text the rooms show")
        let waitingWorkspace = try directory("waiting-2")
        let admittedLate = Flag()
        let waiter = Task { @MainActor in let value = try await admitPrivate(waitingWorkspace, wait: true); admittedLate.set(); return value }
        try await Task.sleep(for: .milliseconds(600))
        check(!admittedLate.isSet, "a waiting begin does not start while the install holds the lane")
        let lateRecordDuringInstall = try await coordinator.admissionState().records.contains { $0.workspace.path.hasSuffix("waiting-2") }
        check(!lateRecordDuringInstall, "and reserves nothing in the registry meanwhile")
        releaseCopy.signal()
        let receipt2 = try await install2.value.value
        let late = try await waiter.value
        state = try await coordinator.admissionState()
        check(receipt2["action"] as? String == "install" && installer.installed()?.manifestSHA256 == identityB.manifestSHA256, "the install completes")
        let lane2 = await record(install2ID)
        check(admittedLate.isSet && lane2?.phase == .finished && state.held.map(\.operationID) == [late.operationID],
              "the waiting work is admitted only after the install's lane is finished")
        try await coordinator.finish(late, exit: .verified(evidence: "fixture: never dispatched"))

        // MARK: 3. Install failure releases the exclusive lane.
        let failing = StagingInstaller(applications: applications, processPaths: { [] }, progress: { text in
            // Corrupt the copied bytes after the copy, so post-install verification fails.
            if text.hasPrefix("Verifying the installed app bytes") {
                try? Data("corrupted mid-install\n".utf8).write(to: applications.appendingPathComponent("Silkwire Staging.app/Contents/Resources/marker.txt"))
            }
        })
        let install3ID = UUID()
        var failure3: Error?
        do {
            _ = try await lane.run(.install, operationID: install3ID, requester: UUID(), resource: applications) {
                Receipt(value: try failing.install(candidate: c, reviewed: identityC))
            }
        } catch { failure3 = error }
        let lane3 = await record(install3ID)
        check(StagingInstallLane.describe(failure3 ?? CancellationError()).contains("Installation failed"), "a failed install reports its failure: \(failure3.map(StagingInstallLane.describe) ?? "none")")
        check(installer.installed()?.manifestSHA256 == identityB.manifestSHA256 && !installer.hasInterruptedOperation, "the previous app is put back and no in-progress marker remains")
        check(lane3?.phase == .finished && (lane3?.evidence ?? "").contains("failed") && journals(registry).isEmpty, "the failed install still releases its exclusive lane with exit evidence: \(lane3?.evidence ?? "none")")
        let after3 = try await admitPrivate(try directory("after-3"))
        check(after3.kind == .backgroundJob, "new work is admitted at once after the failed install")
        try await coordinator.finish(after3, exit: .verified(evidence: "fixture: never dispatched"))
        // A refused install (candidate changed after review) also releases the lane.
        let install3bID = UUID()
        do { _ = try await lane.run(.install, operationID: install3bID, requester: UUID(), resource: applications) { Receipt(value: try installer.install(candidate: c, reviewed: identityA)) } } catch {}
        let lane3b = await record(install3bID), held3b = try await coordinator.admissionState().held
        check(lane3b?.phase == .finished && held3b.isEmpty, "a refused install (candidate changed after review) releases the lane too")

        // Strictness: inside the lane the installer may not launch a child process, and a
        // host that watches itself keeps the lane held if a fork happens anyway.
        do {
            _ = try await lane.run(.install, requester: UUID(), resource: applications) { () throws -> Receipt in
                _ = try StagingInstaller.sourceDigest(fixture); return Receipt(value: [:])
            }
            check(false, "a child launch inside the lane is refused")
        } catch { check(StagingInstallLane.describe(error).contains("would launch a child process"), "a child launch inside the lane is refused: \(StagingInstallLane.describe(error))") }
        // A fork alone no longer decides: the kernel lineage scan does. A reaped child is
        // proved gone and the lane is released, with the fork named in the evidence.
        let watching = StagingInstallLane(coordinator: coordinator, observeSelfForks: true)
        let forkID = UUID()
        var forkError: Error?
        do {
            _ = try await watching.run(.install, operationID: forkID, requester: UUID(), resource: applications) { () throws -> Receipt in
                let job = Process(); job.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try job.run()
                let unique = StagingInstallExclusiveTests.uniqueOf(job)
                for _ in 0..<1500 where !StagingInstallExclusiveTests.childExited(job, unique: unique) { usleep(20_000) }
                return Receipt(value: [:])
            }
        } catch { forkError = error }
        let forked = await record(forkID)
        check(forkError == nil && forked?.phase == .finished && (forked?.evidence ?? "").contains("Kernel observed the installer process fork") && (forked?.evidence ?? "").contains("Kernel lineage proof") && journals(registry).isEmpty,
              "an observed fork whose child has exited is released only with the kernel lineage proof: \(forked?.evidence ?? forkError.map(StagingInstallLane.describe) ?? "none")")
        // Without a crash: a child that outlives the installer call keeps the lane held, by
        // name, until it exits; then the lane frees itself.
        let strayID = UUID()
        var strayError: Error?
        let spawned = Spawned()
        do {
            _ = try await lane.run(.install, operationID: strayID, requester: UUID(), resource: applications) { () throws -> Receipt in
                let job = Process(); job.executableURL = URL(fileURLWithPath: "/bin/sleep"); job.arguments = ["600"]; try job.run(); spawned.process = job; return Receipt(value: [:])
            }
        } catch { strayError = error }
        let strayChild = spawned.process ?? Process()
        let strayText = StagingInstallLane.describe(strayError ?? CancellationError())
        let stray = await record(strayID)
        check(stray?.phase == .uncertain && strayText.contains("still held") && strayText.contains("sleep (PID \(strayChild.processIdentifier), kernel unique ID ") && strayText.contains("was started by the installer"),
              "a child still running when the installer returns keeps the lane held and is named: \(strayText)")
        lane.stopRecovering()
        let strayRecovery = await lane.recoverInterrupted()
        let strayHeld = await record(strayID)?.holdsResources == true
        check(strayRecovery.contains { if case .retained(let id, let reason) = $0 { return id == strayID && reason.contains("sleep") }; return false } && strayHeld,
              "recovery keeps it held while that child lives: \(strayRecovery)")
        check((await refusal { try await admitPrivate(try directory("stray-blocked")) } as? Ownership.Failure) == .exclusiveHeld, "new work still waits behind it")
        // Exact process, bounded: SIGTERM by audit token, then a bounded reap.
        let strayToken = try HostProcessToken.read(strayChild.processIdentifier), strayUnique = uniqueOf(strayChild)
        StallWatchdog.shared.stage("stray child: SIGTERM and reap", watching: [strayChild.processIdentifier])
        try strayToken.signal(SIGTERM)
        var strayGone = await reaped(strayChild, "stray child after SIGTERM", 10, unique: strayUnique)
        if !strayGone { try? strayToken.signal(SIGKILL); strayGone = await reaped(strayChild, "stray child after SIGKILL", 10, unique: strayUnique) }
        check(strayGone, "the stray child exits on SIGTERM (bounded wait)")
        StallWatchdog.shared.stage("stray child: lane frees itself")
        lane.keepRecovering()
        check(await waitFor(15) { await record(strayID)?.phase == .finished }, "once the child exits, the lane frees itself (re-check): \(await record(strayID)?.evidence ?? "none")")
        lane.stopRecovering()
        check((await record(strayID)?.evidence ?? "").contains("Kernel lineage proof") && journals(registry).isEmpty, "the release carries the lineage proof and drops the journal")

        // MARK: 4. Restart mid-install leaves state recoverable, not stuck.
        let reached = fixture.appendingPathComponent("child-reached-copy")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        var environment = ProcessInfo.processInfo.environment
        environment["SILKWIRE_INSTALL_LANE_CHILD"] = try String(decoding: JSONSerialization.data(withJSONObject: [
            "registry": registry.path, "applications": applications.path, "candidate": c.path, "reached": reached.path]), as: UTF8.self)
        child.environment = environment
        let childLog = fixture.appendingPathComponent("child.log"); files.createFile(atPath: childLog.path, contents: nil)
        let childOutput = try FileHandle(forWritingTo: childLog); child.standardOutput = childOutput; child.standardError = childOutput
        try child.run()
        check(await waitFor(30) { files.fileExists(atPath: reached.path) }, "a separate installer process is admitted and starts replacing the app")
        state = try await coordinator.admissionState()
        let crashed = state.exclusiveHeld
        check(crashed?.ownerPID == child.processIdentifier && crashed?.phase == .executing && !files.fileExists(atPath: installer.target.path) && installer.hasInterruptedOperation,
              "mid-install: the child holds the lane, the previous app has been moved aside, progress is recorded")
        let whileAlive = await lane.recoverInterrupted()
        let heldWhileAlive = try await coordinator.admissionState().exclusiveHeld
        check(whileAlive.contains { if case .retained(_, let reason) = $0 { return reason.contains("still running") }; return false } && heldWhileAlive != nil,
              "recovery never releases the lane while that exact installer process is alive")
        let restartUnique = uniqueOf(child)
        kill(child.processIdentifier, SIGKILL)
        check(await reaped(child, "restart installer after SIGKILL", unique: restartUnique), "the killed installer process has exited (kernel identity, bounded wait)")
        try? childOutput.close()
        check(killedBySIGKILL(child), "the installer process is killed mid-install (SIGKILL)")
        // Simulate the half-written copy an interrupted copyItem leaves behind.
        try files.createDirectory(at: installer.target.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: installer.target.appendingPathComponent("Contents/MacOS/Silkwire"))
        check((await refusal { try await admitPrivate(try directory("stuck-4")) } as? Ownership.Failure) == .exclusiveHeld, "before recovery, the dead installer's lane still blocks new work")
        let recovered = await lane.recoverInterrupted()
        let released = recovered.contains { if case .released(let id, let evidence) = $0 { return id == crashed?.operationID && evidence.contains("exact installer process") }; return false }
        let lane4 = await record(crashed?.operationID ?? UUID())
        check(released && lane4?.phase == .finished && journals(registry).isEmpty,
              "recovery releases it once the kernel shows that exact process gone: \(recovered)")
        let after4 = try await admitPrivate(try directory("after-4"))
        check(after4.kind == .backgroundJob, "new work is admitted again after recovery, without any install having to run")
        try await coordinator.finish(after4, exit: .verified(evidence: "fixture: never dispatched"))
        check(installer.hasInterruptedOperation, "the interrupted install's file state is still recorded for repair")
        let receipt4 = try await lane.run(.install, requester: UUID(), resource: applications) { Receipt(value: try installer.install(candidate: c, reviewed: identityC)) }.value
        let backups = installer.listBackups()
        let incomplete = (try? files.contentsOfDirectory(atPath: installer.backups.path))?.filter { $0.contains("incomplete") } ?? []
        let partialKept = incomplete.contains { (try? Data(contentsOf: installer.backups.appendingPathComponent($0).appendingPathComponent("Silkwire Staging.app/Contents/MacOS/Silkwire"))) == Data("partial".utf8) }
        check((receipt4["repairedInterrupted"] as? String ?? "").contains("put back") && installer.installed()?.manifestSHA256 == identityC.manifestSHA256 && !installer.hasInterruptedOperation,
              "the next install first repairs the interrupted one (previous app put back), then installs: \(receipt4["repairedInterrupted"] as? String ?? "none")")
        check(partialKept && backups.contains { $0.identity?.manifestSHA256 == identityB.manifestSHA256 }, "the partial copy is retained, not deleted, and the pre-crash app is kept as a backup")

        // MARK: 5. Crash before the installer could record a child it started.
        // A separate installer process (this executable) takes the lane, starts a child (a)
        // or a child that starts a grandchild and exits (b), then is SIGKILLed before the
        // lane can finish or record anything about them. Recovery must keep the lane held
        // while anything of that workload lives, and release it only with proof (c).
        func crashedInstaller(_ mode: String, _ label: String) async throws -> (operation: UUID, survivors: [HostProcessToken], report: [String: Any]) {
            let reached = fixture.appendingPathComponent("reached-" + label)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            var environment = ProcessInfo.processInfo.environment
            environment["SILKWIRE_INSTALL_LANE_CHILD"] = try String(decoding: JSONSerialization.data(withJSONObject: [
                "mode": mode, "registry": registry.path, "applications": applications.path, "reached": reached.path, "scratch": fixture.path]), as: UTF8.self)
            child.environment = environment
            let log = fixture.appendingPathComponent("child-\(label).log"); files.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log); child.standardOutput = output; child.standardError = output
            try child.run()
            guard await waitFor(30, { files.fileExists(atPath: reached.path) }),
                  let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reached)) as? [String: Any],
                  let pids = report["survivors"] as? [Int], !pids.isEmpty else {
                kill(child.processIdentifier, SIGKILL); _ = await reaped(child, "installer child (\(label)) that never started")
                throw nativeFailure("installer child (\(label)) never started its workload: " + ((try? String(contentsOf: log, encoding: .utf8)) ?? ""))
            }
            let tokens = try pids.map { try HostProcessToken.read(pid_t($0)) }
            let held = try await coordinator.admissionState().exclusiveHeld
            let childUnique = uniqueOf(child)
            kill(child.processIdentifier, SIGKILL)
            guard await reaped(child, "installer child (\(label)) after SIGKILL", unique: childUnique) else { throw nativeFailure("installer child (\(label)) did not exit within 15 s of SIGKILL") }
            try? output.close()
            guard let held, held.ownerPID == child.processIdentifier, killedBySIGKILL(child) else {
                throw nativeFailure("installer child (\(label)) did not hold the lane when it was SIGKILLed")
            }
            return (held.operationID, tokens, report)
        }
        func alive(_ token: HostProcessToken) -> Bool { StagingInstallLane.liveness(token) == .alive }
        func end(_ token: HostProcessToken) async -> Bool { try? token.signal(SIGKILL); return await waitFor(10) { StagingInstallLane.liveness(token) == .gone } }
        func retainedReason(_ results: [StagingInstallLane.Recovery], _ id: UUID) -> String? {
            for case .retained(let found, let reason) in results where found == id { return reason }; return nil
        }
        func releasedEvidence(_ results: [StagingInstallLane.Recovery], _ id: UUID) -> String? {
            for case .released(let found, let evidence) in results where found == id { return evidence }; return nil
        }
        func stillHeld(_ id: UUID) async -> Bool {
            let held = try? await coordinator.admissionState().exclusiveHeld
            let blocked = (await refusal { try await admitPrivate(try directory("blocked-" + UUID().uuidString)) } as? Ownership.Failure) == .exclusiveHeld
            return held?.operationID == id && blocked
        }
        /// Releases are retried briefly: a busy machine can leave a pass incomplete.
        func recoverUntilReleased(_ lane: StagingInstallLane, _ id: UUID) async -> (String?, [StagingInstallLane.Recovery]) {
            var last: [StagingInstallLane.Recovery] = []
            for _ in 0..<40 {
                last = await lane.recoverInterrupted()
                if let evidence = releasedEvidence(last, id) { return (evidence, last) }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return (nil, last)
        }

        // a) The installer starts a child, then is SIGKILLed before recording it.
        let crashA = try await crashedInstaller("child", "a")
        let aChild = crashA.survivors[0]
        check(alive(aChild) && StagingInstallWorkload.tag(aChild.pid, expecting: crashA.operation.uuidString) == .match,
              "a) the installer started a child (PID \(aChild.pid), carrying the install tag) and was SIGKILLed before recording it; the child lives on")
        let a1 = await lane.recoverInterrupted()
        let aReason = retainedReason(a1, crashA.operation) ?? "none"
        check(aReason.contains("(PID \(aChild.pid), kernel unique ID ") && aReason.contains("was started by the installer") && releasedEvidence(a1, crashA.operation) == nil,
              "a) recovery keeps the lane held while the child lives and names it: \(aReason)")
        check(await stillHeld(crashA.operation), "a) the lane is still held and new work waits")
        try? await Task.sleep(for: .seconds(1))
        let a2 = await lane.recoverInterrupted()
        let probe1 = await stillHeld(crashA.operation)
        check(retainedReason(a2, crashA.operation) != nil && releasedEvidence(a2, crashA.operation) == nil && alive(aChild) && probe1,
              "a) a later check still keeps it held while the child lives")
        check(StagingInstallLane.waitingText(try await coordinator.admissionState(), for: UUID(), action: "install", heldReason: lane.heldReasons[crashA.operation])?.contains("(PID \(aChild.pid), kernel unique ID ") == true,
              "a) a waiting install is shown why the earlier lane is held")

        // c) After everything exits: released only with proof; without proof, held.
        check(await end(aChild), "c) the child exits (the installer is already gone)")
        let blind = StagingInstallLane(coordinator: coordinator, workload: .init(inspect: { _ in .unprovable("fixture: process inspection unavailable.") }))
        let c1 = await blind.recoverInterrupted()
        let probe2 = await stillHeld(crashA.operation)
        check((retainedReason(c1, crashA.operation) ?? "").contains("cannot be proved") && probe2,
              "c) if process inspection can't prove the workload ended, the lane stays held: \(retainedReason(c1, crashA.operation) ?? "none")")
        let tagged = Process(); tagged.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        tagged.environment = ["PATH": "/usr/bin:/bin", "SILKWIRE_INSTALL_LANE_CHILD": "{\"mode\":\"sleep\"}", StagingInstallWorkload.tagKey: crashA.operation.uuidString]
        try tagged.run()
        let c2 = await lane.recoverInterrupted()
        let probe3 = await stillHeld(crashA.operation)
        check((retainedReason(c2, crashA.operation) ?? "").contains("(PID \(tagged.processIdentifier), kernel unique ID ") && (retainedReason(c2, crashA.operation) ?? "").contains(") carries this install's tag") && probe3,
              "c) a live process carrying the install's tag (outside its lineage) keeps the lane held: \(retainedReason(c2, crashA.operation) ?? "none")")
        let taggedUnique = uniqueOf(tagged)
        kill(tagged.processIdentifier, SIGKILL)
        check(await reaped(tagged, "tagged process", unique: taggedUnique), "c) the tagged process exits (bounded wait)")
        guard let journalA = StagingInstallLane.journals(in: registry).first(where: { $0.operationID == crashA.operation }) else { throw nativeFailure("the crashed install's journal is missing") }
        var stripped = journalA; stripped.lineage = nil
        try StagingInstallLane.save(stripped, in: registry, replacing: true)
        let c3 = await lane.recoverInterrupted()
        let probe4 = await stillHeld(crashA.operation)
        check((retainedReason(c3, crashA.operation) ?? "").contains("no usable record of the installer's process lineage") && probe4,
              "c) if the lineage evidence was lost, the lane stays held: \(retainedReason(c3, crashA.operation) ?? "none")")
        StagingInstallLane.remove(crashA.operation, in: registry)
        let c4 = await lane.recoverInterrupted()
        let probe5 = await stillHeld(crashA.operation)
        check((retainedReason(c4, crashA.operation) ?? "").contains("No readable install journal") && probe5,
              "c) if the journal itself was lost, the lane stays held: \(retainedReason(c4, crashA.operation) ?? "none")")
        try StagingInstallLane.save(journalA, in: registry)
        let (aEvidence, c5) = await recoverUntilReleased(lane, crashA.operation)
        let probe6 = await record(crashA.operation)
        check((aEvidence ?? "").contains("exact installer process") && (aEvidence ?? "").contains("Kernel lineage proof") && probe6?.phase == .finished && journals(registry).isEmpty,
              "c) with the evidence intact and everything exited, recovery proves it and releases: \(aEvidence ?? "\(c5)")")
        let afterA = try await admitPrivate(try directory("after-a"))
        check(afterA.kind == .backgroundJob, "c) new work is admitted again")
        try await coordinator.finish(afterA, exit: .verified(evidence: "fixture: never dispatched"))

        // b) The child starts a grandchild and exits; the installer is SIGKILLed.
        let crashB = try await crashedInstaller("grandchild", "b")
        let grandchild = crashB.survivors[0]
        check(alive(grandchild) && (crashB.report["intermediateExited"] as? Bool) == true && StagingInstallWorkload.tag(grandchild.pid, expecting: crashB.operation.uuidString) != .match,
              "b) the installer's child started a grandchild (PID \(grandchild.pid), /bin/sleep with the tag removed; macOS hides its environment anyway) and exited; the installer was SIGKILLed; the grandchild lives on")
        // It execs twice (env, then sleep): wait until it runs /bin/sleep, its last image.
        func runsSleep(_ pid: pid_t) -> Bool {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path) == "/bin/sleep"
        }
        let reset = await waitFor(10) {
            guard runsSleep(grandchild.pid), case .live(let id)? = try? StagingInstallWorkload.identity(grandchild.pid) else { return false }
            return id.parent == 1
        }
        check(reset, "b) after its parent exited it exec'd, so the kernel now names launchd as its parent")
        // Exec gives it a new audit-token version: re-read it (same kernel unique ID) to signal it later.
        let grandchildBefore = try? StagingInstallWorkload.identity(grandchild.pid)
        let grandchildNow = try HostProcessToken.read(grandchild.pid)
        let grandchildAfter = try? StagingInstallWorkload.identity(grandchild.pid)
        guard case .live(let before)? = grandchildBefore, case .live(let after)? = grandchildAfter, before.unique == after.unique else { throw nativeFailure("the grandchild changed while it was being identified") }
        let b1 = await lane.recoverInterrupted()
        let bReason = retainedReason(b1, crashB.operation) ?? "none"
        let probe7 = await stillHeld(crashB.operation)
        check(bReason.contains("(PID \(grandchild.pid), kernel unique ID ") && bReason.contains("by a process that has exited (PID version") && releasedEvidence(b1, crashB.operation) == nil && probe7,
              "b) recovery keeps the lane held while the grandchild lives (lineage alone, no tag): \(bReason)")
        try? await Task.sleep(for: .seconds(1))
        let b2 = await lane.recoverInterrupted()
        let probe8 = await stillHeld(crashB.operation)
        check(retainedReason(b2, crashB.operation) != nil && releasedEvidence(b2, crashB.operation) == nil && alive(grandchildNow) && probe8,
              "b) a later check still keeps it held while the grandchild lives")
        check(await end(grandchildNow), "c) the grandchild exits")
        let (bEvidence, b3) = await recoverUntilReleased(lane, crashB.operation)
        let probe9 = await record(crashB.operation)
        check((bEvidence ?? "").contains("Kernel lineage proof") && probe9?.phase == .finished && journals(registry).isEmpty,
              "c) once the grandchild has exited too, recovery proves it and releases: \(bEvidence ?? "\(b3)")")

        // b2) Same, but the grandchild execs while its parent still lives: the kernel keeps
        // the exited parent's unique ID.
        let crashB2 = try await crashedInstaller("grandchild-early", "b2")
        _ = await waitFor(10) { runsSleep(crashB2.survivors[0].pid) }
        let early = try HostProcessToken.read(crashB2.survivors[0].pid)
        let kept: Bool
        if case .live(let id)? = try? StagingInstallWorkload.identity(early.pid) { kept = id.parent != 1 } else { kept = false }
        check(kept, "b2) its exec happened before its parent exited, so the kernel still names that exited parent")
        let b2Reason = retainedReason(await lane.recoverInterrupted(), crashB2.operation) ?? "none"
        let b2Held = await stillHeld(crashB2.operation)
        check(alive(early) && b2Reason.contains("(PID \(early.pid), kernel unique ID ") && b2Reason.contains("by a process that has exited (kernel unique ID") && b2Held,
              "b2) a grandchild that exec'd before its parent exited also keeps the lane held: \(b2Reason)")
        check(await end(early), "c) that grandchild exits")
        let (b2Evidence, b2Last) = await recoverUntilReleased(lane, crashB2.operation)
        let b2Record = await record(crashB2.operation)
        check((b2Evidence ?? "").contains("Kernel lineage proof") && b2Record?.phase == .finished && journals(registry).isEmpty,
              "c) and the lane is released once that is proved: \(b2Evidence ?? "\(b2Last)")")

        // d) The installer replaces its own program image mid-lane (exec): the kernel's PID
        // version changes, so the audit token no longer matches, but it is still running.
        let reachedD = fixture.appendingPathComponent("reached-d")
        let execChild = Process()
        execChild.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        var execEnvironment = ProcessInfo.processInfo.environment
        execEnvironment["SILKWIRE_INSTALL_LANE_CHILD"] = try String(decoding: JSONSerialization.data(withJSONObject: [
            "mode": "exec", "registry": registry.path, "applications": applications.path, "reached": reachedD.path, "scratch": fixture.path]), as: UTF8.self)
        execChild.environment = execEnvironment
        execChild.standardOutput = FileHandle.nullDevice; execChild.standardError = FileHandle.nullDevice
        try execChild.run()
        check(await waitFor(30) { files.fileExists(atPath: reachedD.path) }, "d) a separate installer process takes the lane")
        let heldD = try await coordinator.admissionState().exclusiveHeld
        let journalD = StagingInstallLane.journals(in: registry).first { $0.operationID == heldD?.operationID }
        let replaced = await waitFor(10) { journalD.map { StagingInstallLane.liveness($0.host) == .gone } ?? false }
        check(replaced && execChild.isRunning, "d) after its exec the installer's original audit token no longer matches, though the process still runs")
        let dReason = retainedReason(await lane.recoverInterrupted(), heldD?.operationID ?? UUID()) ?? "none"
        let dHeld = await stillHeld(heldD?.operationID ?? UUID())
        check(dReason.contains("(PID \(execChild.processIdentifier), kernel unique ID \(journalD?.lineage?.hostUnique ?? 0)) is the installer process itself") && dHeld,
              "d) recovery recognises the installer itself by its kernel unique ID and keeps the lane held: \(dReason)")
        // SIGKILL: exec kept the worker thread's blocked signal mask, so SIGTERM would wait.
        let execUnique = uniqueOf(execChild)
        kill(execChild.processIdentifier, SIGKILL)
        check(await reaped(execChild, "exec'd installer", unique: execUnique), "d) the exec'd installer exits (bounded wait)")
        let (dEvidence, dLast) = await recoverUntilReleased(lane, heldD?.operationID ?? UUID())
        check((dEvidence ?? "").contains("Kernel lineage proof") && journals(registry).isEmpty, "c) once it has exited, the lane is released with proof: \(dEvidence ?? "\(dLast)")")

        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { throw nativeFailure("FAIL: \(failures) of \(checks) staging install lane checks failed") }
        print("PASS: staging install exclusive lane (\(checks) checks)")
    }

    /// Child role for the restart case: run one install in the lane on the shared registry
    /// and stop dead (until SIGKILL) right after the previous app is moved aside.
    @MainActor static func runChild(_ json: String) async throws {
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] else { exit(64) }
        if value["mode"] == "sleep" { while true { sleep(1) } }
        if value["mode"] != nil { try await runWorkloadChild(value); return }
        guard let registry = value["registry"], let applications = value["applications"], let candidate = value["candidate"], let reached = value["reached"] else { exit(64) }
        let lane = StagingInstallLane(coordinator: HostExecutionCoordinator(directory: URL(fileURLWithPath: registry)), observeSelfForks: true)
        let installer = StagingInstaller(applications: URL(fileURLWithPath: applications), processPaths: { [] }, progress: { text in
            if text.hasPrefix("Installing the verified candidate") {
                FileManager.default.createFile(atPath: reached, contents: Data())
                while true { Thread.sleep(forTimeInterval: 1) }
            }
        })
        let app = URL(fileURLWithPath: candidate), identity = try StagingInstaller.identify(app)
        _ = try await lane.run(.install, requester: UUID(), resource: URL(fileURLWithPath: applications)) { Receipt(value: try installer.install(candidate: app, reviewed: identity)) }
        exit(65) // Never reached: the parent kills this process mid-install.
    }

    /// Child role for section 5: inside the lane, start a child ("child") or a child that
    /// starts a grandchild without the tag and exits ("grandchild"), report the survivors,
    /// then hang until SIGKILL. The lane never gets to finish or record any of it.
    @MainActor static func runWorkloadChild(_ value: [String: String]) async throws {
        guard let mode = value["mode"], let registry = value["registry"], let applications = value["applications"],
              let reached = value["reached"], let scratch = value["scratch"] else { exit(64) }
        let lane = StagingInstallLane(coordinator: HostExecutionCoordinator(directory: URL(fileURLWithPath: registry)), observeSelfForks: true)
        let sleeper = Bundle.main.executablePath ?? CommandLine.arguments[0], sleepRole = "SILKWIRE_INSTALL_LANE_CHILD={\"mode\":\"sleep\"}"
        _ = try await lane.run(.install, requester: UUID(), resource: URL(fileURLWithPath: applications)) { () throws -> Receipt in
            var report: [String: Any] = [:]
            if mode == "exec" {
                // Replace the installer's own program image: same kernel unique ID, new
                // audit-token version. Report itself first.
                let temporary = reached + ".partial"
                try JSONSerialization.data(withJSONObject: ["survivors": [Int(getpid())]]).write(to: URL(fileURLWithPath: temporary))
                guard rename(temporary, reached) == 0 else { exit(67) }
                var inherited: [String] = []
                var cursor = environ
                while let entry = cursor.pointee { let text = String(cString: entry); if !text.hasPrefix("SILKWIRE_INSTALL_LANE_CHILD=") { inherited.append(text) }; cursor += 1 }
                let argv = [strdup(sleeper), nil], envp = (inherited + [sleepRole]).map { strdup($0) } + [nil]
                execve(sleeper, argv, envp)
                exit(68)
            }
            if mode == "child" {
                // This executable in its sleep role: not a platform binary, so macOS shows
                // its environment and the inherited tag can be observed too.
                report["survivors"] = [Int(try spawn(sleeper, [], extra: [sleepRole]))]
            } else {
                // "grandchild": the intermediate exits first and the grandchild execs only
                // afterwards, so the kernel resets its parent unique ID to launchd's.
                // "grandchild-early": it execs while the intermediate still lives.
                let file = scratch + "/grandchild-\(getpid())", strip = "env -u \(StagingInstallWorkload.tagKey) /bin/sleep 600"
                let script = mode == "grandchild" ? "( /bin/sleep 1.5; exec \(strip) ) >/dev/null 2>&1 & echo $! > \"$0\""
                                                  : "\(strip) >/dev/null 2>&1 & echo $! > \"$0\"; /bin/sleep 2"
                let shell = try spawn("/bin/sh", ["-c", script, file])
                var status: Int32 = 0
                while waitpid(shell, &status, 0) < 0 && errno == EINTR {}
                guard let text = try? String(contentsOfFile: file, encoding: .utf8), let grandchild = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { exit(66) }
                report["survivors"] = [grandchild]; report["intermediate"] = Int(shell)
                report["intermediateExited"] = kill(shell, 0) != 0 && errno == ESRCH
            }
            let temporary = reached + ".partial"
            try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: temporary))
            guard rename(temporary, reached) == 0 else { exit(67) }
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        exit(65) // Never reached: the parent kills this process while its workload runs.
    }
    /// Whether a child this test started has exited, by kernel identity. Foundation's
    /// own report can be missed: the 74e7e98 hang was the main thread in
    /// -[NSConcreteTask waitUntilExit] after the kernel showed the child gone (outside
    /// Codex's sample, practical-release-3 raw-logs/superseded-e08010f). So the kernel
    /// decides; Foundation is only consulted when it agrees.
    static func childExited(_ process: Process, unique: UInt64?) -> Bool {
        if !process.isRunning { return true }
        guard let unique else { return true }
        switch try? StagingInstallWorkload.identity(process.processIdentifier) {
        case .gone?: return true
        case .live(let now)?: return now.unique != unique
        case nil: return false
        }
    }
    static func uniqueOf(_ process: Process) -> UInt64? {
        if case .live(let id)? = try? StagingInstallWorkload.identity(process.processIdentifier) { return id.unique }; return nil
    }
    /// Killed by SIGKILL, when Foundation has reported the exit; otherwise the kernel's
    /// word that it is gone (after this test's own SIGKILL) is what there is.
    static func killedBySIGKILL(_ process: Process) -> Bool {
        process.isRunning || (process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
    }
    static func responsibleForItself() -> Bool {
        guard case .live(let me)? = try? StagingInstallWorkload.identity(getpid()) else { return false }
        return StagingInstallWorkload.responsibleUnique(getpid()) == me.unique
    }
    /// posix_spawn with this process's environment, which carries the lane's tag.
    static func spawn(_ path: String, _ arguments: [String], extra: [String] = []) throws -> pid_t {
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        var inherited: [String] = []
        var cursor = environ
        while let entry = cursor.pointee { let text = String(cString: entry); if !text.hasPrefix("SILKWIRE_INSTALL_LANE_CHILD=") { inherited.append(text) }; cursor += 1 }
        let envp = (inherited + extra).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, nil, nil, argv, envp) == 0 else { throw nativeFailure("Cannot start \(path)") }
        return pid
    }

    /// Re-runs this test as its own responsible process, as the working app is. Orphans
    /// that concurrently running suites leave behind are attributed to the terminal or
    /// agent app that launched them, so the lineage scan can tell them apart from this
    /// test's own installers' work. SIGTERM/SIGINT (the harness deadline) are forwarded.
    static func runDisclaimed() throws -> Int32 {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Bool) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { throw nativeFailure("Cannot disclaim responsibility for the test process.") }
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
        guard unsafeBitCast(symbol, to: Disclaim.self)(&attributes, true) == 0 else { throw nativeFailure("Cannot disclaim responsibility for the test process.") }
        setenv("SILKWIRE_INSTALL_LANE_DISCLAIMED", "1", 1)
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let argv = ([path] + CommandLine.arguments.dropFirst()).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, nil, &attributes, argv, environ) == 0 else { throw nativeFailure("Cannot re-run the test as its own responsible process.") }
        disclaimedChild = pid
        for value in [SIGTERM, SIGINT] { signal(value) { received in if disclaimedChild > 0 { kill(disclaimedChild, received) } } }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}
nonisolated(unsafe) private var disclaimedChild: pid_t = 0
