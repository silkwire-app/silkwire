import Foundation
import Darwin

/// Real scans with one injected procargs exit/exec race between empty scans.
private final class InterruptedPrivateInspection: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func inspect(_ manifest: HostPrivateCleanupManifest) throws -> [HostProcessToken] {
        lock.lock(); calls += 1; let call = calls; lock.unlock()
        let survivors = try HostPrivateProcessInspector().survivors(manifest)
        if call == 2 { throw HostPrivateInspectionRace(message: "injected procargs exit/exec race") }
        return survivors
    }
}

@main struct PracticalReleaseTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count > 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let coordinator = HostExecutionCoordinator(directory: root.appendingPathComponent("registry"))
            let owner = try await coordinator.admit(operationID: UUID(), conversationID: UUID(), kind: .foregroundBuild,
                authorize: { .init(executionRoot: source, conflictRoot: source) }, mayOperate: { true })
            owner.physicalEvidence.enableLocalTracking()
            try owner.physicalEvidence.bind(workspaceID: UUID(), jobID: UUID())
            let profile = "(version 1)(allow default)(deny network*)(deny file-write* (require-not (subpath \"\(root.path)\")))"
            _ = try await NativeProcess.run(executable: "/usr/bin/sandbox-exec", arguments: ["-p", profile, root.appendingPathComponent("worker").path, root.appendingPathComponent("child.pid").path], directory: root, environment: ["PATH": "/usr/bin:/bin"], physicalEvidence: owner.physicalEvidence, sandboxedPrivate: true)
            try Data("ready".utf8).write(to: root.appendingPathComponent("ready"))
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        let root = try NativeTemporaryDirectory.createWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        func directory(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return url
        }
        var checks = 0
        func check(_ okay: Bool, _ label: String) throws {
            print((okay ? "PASS: " : "FAIL: ") + label)
            guard okay else { throw nativeFailure(label) }; checks += 1
        }
        func held(_ answer: HostPhysicalExit) -> Bool {
            if case .unconfirmed(let reason) = answer { print("HELD: " + reason); return !reason.isEmpty }; return false
        }
        func practical(_ answer: HostPhysicalExit) -> Bool {
            if case .privateCleanup(let result) = answer { print("CLEANED: " + result.evidence); return true }; return false
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let env = ["HOME": root.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let source = try directory("source")
        try Data("synthetic\n".utf8).write(to: source.appendingPathComponent("README.md"))
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@local.invalid", "commit", "-qm", "Fixture"]] {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null"] + args, directory: source, environment: env)
            try check(result.exitCode == 0, "synthetic Git fixture: \(args[0])")
        }
        // Real production Builder launches and adapter; no fabricated exit answers.
        let sequential = HostExecutionCoordinator(directory: root.appendingPathComponent("sequential-registry"))
        for index in 0..<6 {
            var receipt: [String: Any] = [:]
            let builder = NativeBuilder(onReceipt: { receipt = $0 }, storageRoot: root.appendingPathComponent("sequential-runs"), ownership: sequential)
            await builder.start(source: source, task: "Sequential fixture \(index)", build: index == 5 ? "false" : "printf fixture", test: "", edit: false)
            let sequentialHeld = try await sequential.storage.snapshot().filter(\.holdsResources)
            if !sequentialHeld.isEmpty { print("RECEIPT: \(try nativeJSON(receipt))"); print("HELD RECORDS: \(sequentialHeld)") }
            try check(receipt["physicalExitUnconfirmed"] as? Bool != true && sequentialHeld.isEmpty
                      && (receipt["physicalCleanup"] as? [String: Any])?["kernelWholeWorkloadProof"] as? Bool == false,
                      "sequential private execution \(index + 1) cleans and reuses admission")
            try check(receipt["status"] as? String == (index == 5 ? "failed" : "review"), "cleanup preserves command \(index == 5 ? "failure" : "success")")
        }
        let lateAdapter = BackgroundJobExitVerification(coordinator: sequential)
        var lateBuilder: NativeBuilder?, lateReceipt: [String: Any] = [:]
        lateBuilder = NativeBuilder(onReceipt: { lateReceipt = $0 }, storageRoot: root.appendingPathComponent("late-stop"), ownership: sequential,
            verifyPhysicalExit: { request in lateBuilder?.stop(); return await lateAdapter.verifyForegroundExit(request) })
        await lateBuilder!.start(source: source, task: "Stop during cleanup", build: "true", test: "", edit: false)
        let afterLateStop = try await sequential.storage.snapshot()
        try check(lateReceipt["status"] as? String == "stopped" && lateReceipt["executionStatus"] as? String == "stopped"
                  && lateReceipt["stopRequested"] as? Bool == true && afterLateStop.filter(\.holdsResources).isEmpty,
                  "Stop accepted during cleanup releases ownership and still publishes stopped execution")
        lateBuilder = nil
        for stopped in [false, true] {
            let heldCoordinator = HostExecutionCoordinator(directory: root.appendingPathComponent(stopped ? "stopped-held-registry" : "failed-held-registry"))
            var heldBuilder: NativeBuilder?, heldReceipt: [String: Any] = [:]
            heldBuilder = NativeBuilder(onReceipt: { heldReceipt = $0 }, storageRoot: root.appendingPathComponent(stopped ? "stopped-held-runs" : "failed-held-runs"), ownership: heldCoordinator,
                verifyPhysicalExit: { _ in
                    if stopped { heldBuilder?.stop() }
                    return .unconfirmed(reason: "injected unavailable cleanup evidence")
                })
            await heldBuilder!.start(source: source, task: "Separate execution and ownership outcome", build: stopped ? "true" : "false", test: "", edit: false)
            let heldRecords = try await heldCoordinator.storage.snapshot()
            try check(heldReceipt["status"] as? String == (stopped ? "stopped" : "failed")
                      && heldReceipt["executionStatus"] as? String == (stopped ? "stopped" : "failed")
                      && heldReceipt["physicalExitUnconfirmed"] as? Bool == true && heldReceipt["ownershipState"] as? String == "needs-review"
                      && heldRecords.first?.holdsResources == true && heldRecords.first?.evidence?.contains("injected unavailable") == true,
                      "injected missing cleanup evidence retains ownership while preserving \(stopped ? "stopped" : "failed") command outcome")
            heldBuilder = nil
        }
        let team = HostExecutionCoordinator(directory: root.appendingPathComponent("team-registry"))
        var builders: [NativeBuilder] = [], sources: [URL] = []
        for index in 0..<3 {
            let copy = root.appendingPathComponent("source-\(index)")
            let cloned = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["clone", "-q", source.path, copy.path], directory: root, environment: env)
            try check(cloned.exitCode == 0, "independent source \(index) prepared")
            sources.append(copy)
            builders.append(NativeBuilder(onReceipt: { _ in }, storageRoot: root.appendingPathComponent("team-\(index)"), ownership: team))
        }
        let concurrentBuilders = builders, concurrentSources = sources
        async let a = concurrentBuilders[0].beginTrusted(source: concurrentSources[0], task: "A", owner: "a")
        async let b = concurrentBuilders[1].beginTrusted(source: concurrentSources[1], task: "B", owner: "b")
        async let c = concurrentBuilders[2].beginTrusted(source: concurrentSources[2], task: "C", owner: "c")
        _ = try await (a, b, c)
        try check(try await team.storage.snapshot().filter(\.holdsResources).count == 3, "three real private workspaces coexist with native verification")
        for builder in builders { let result = try await builder.finishTrusted(summary: "Done"); try check(result["physicalExitUnconfirmed"] as? Bool != true, "real private workspace cleans on finish") }

        let registry = try directory("process-registry"), processCoordinator = HostExecutionCoordinator(directory: registry)
        let adapter = BackgroundJobExitVerification(coordinator: processCoordinator)
        func admit(_ label: String) async throws -> (HostExecutionAdmission, HostExitRequest) {
            let workspace = try directory(label)
            let admission = try await processCoordinator.admit(operationID: UUID(), conversationID: UUID(), kind: .backgroundJob,
                authorize: { .init(executionRoot: workspace, conflictRoot: workspace) }, mayOperate: { true }, wait: false)
            admission.physicalEvidence.enableLocalTracking()
            let id = UUID(), job = UUID()
            try admission.physicalEvidence.bind(workspaceID: id, jobID: job)
            return (admission, .init(workspaceID: id, jobID: job, evidence: admission.physicalEvidence))
        }
        let profile = "(version 1)(allow default)(deny network*)(deny appleevent-send)(deny mach-lookup)(deny file-write* (require-not (subpath \"\(root.path)\")))"
        func launch(_ admission: HostExecutionAdmission, command: String, exit: @escaping (Int32) -> Void) throws -> NativeProcess {
            try NativeProcess(executable: "/usr/bin/sandbox-exec", arguments: ["-p", profile, "/bin/sh", "-c", command], directory: root, environment: env,
                physicalEvidence: admission.physicalEvidence, sandboxedPrivate: true, stdout: { _ in }, stderr: { _ in }, onExit: exit)
        }
        let (ownerA, requestA) = try await admit("A"), (ownerB, requestB) = try await admit("B")
        var aExit: Int32?, bExit: Int32?
        let ap = try launch(ownerA, command: "exec /bin/sleep 60", exit: { aExit = $0 })
        let bp = try launch(ownerB, command: "exec /bin/sleep 60", exit: { bExit = $0 })
        defer { ap.terminate(); bp.terminate() }
        let currentB = try HostProcessToken.read(bp.pid)
        var staleWords = currentB.words; staleWords[7] ^= 0x40000000
        try HostProcessToken(words: staleWords).signal(SIGKILL)
        try await Task.sleep(for: .milliseconds(50))
        try check(bp.isRunning && bExit == nil && kill(bp.pid, 0) == 0,
                  "kernel refuses a stale audit generation even when its PID names a live B")
        try await processCoordinator.stop(ownerA); ap.terminate(); try await wait("A joined") { aExit != nil }
        let answerA = await adapter.verifyExit(requestA)
        try check(practical(answerA) && aExit != 0, "Stop A cleans while preserving nonzero command exit")
        try await processCoordinator.finish(ownerA, exit: answerA)
        let afterA = try await processCoordinator.storage.snapshot()
        try check(bp.isRunning && bExit == nil && afterA.first { $0.operationID == ownerB.operationID }!.holdsResources, "Stop/release A leaves B alive and admitted")
        let (reused, reusedRequest) = try await admit("A")
        try check(reused.physicalEvidence.identity.attemptID != requestA.identity.attemptID, "A's slot is reusable with a fresh attempt")
        try check(held(await adapter.verifyExit(.init(workspaceID: requestB.workspaceID, jobID: requestA.jobID, evidence: ownerA.physicalEvidence))), "wrong workspace cannot authorize cleanup")
        try check(held(await adapter.verifyExit(.init(workspaceID: requestA.workspaceID, jobID: requestB.jobID, evidence: ownerA.physicalEvidence))), "wrong job cannot authorize cleanup")
        do { try await processCoordinator.finish(reused, exit: answerA); try check(false, "stale answer rejected") }
        catch { try check(try await processCoordinator.storage.snapshot().first { $0.operationID == reused.operationID }!.holdsResources, "stale attempt answer cannot release reused slot") }
        // A real detached, tagged helper escapes the original process group.
        let worker = root.appendingPathComponent("worker")
        let compilation = try await NativeProcess.run(executable: "/usr/bin/cc", arguments: ["Tests/Fixtures/PhysicalExitWorker.c", "-o", worker.path], directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), environment: env)
        try check(compilation.exitCode == 0, "real detached helper fixture compiles")
        // Apple platform binaries hide their environment. Lineage must hold
        // ownership even when a real tagged shell cannot be found by its tag.
        for mode in ["child", "grandchild"] {
            let (owner, request) = try await admit("lineage-" + mode)
            let pidFile = root.appendingPathComponent("lineage-\(mode).pid")
            let exitFile = root.appendingPathComponent("lineage-\(mode).exit")
            var exit: Int32?
            let job = try launch(owner, command: "exec '\(worker.path)' lineage \(mode) '\(pidFile.path)' '\(exitFile.path)'", exit: { exit = $0 })
            defer { job.terminate() }
            try await wait("lineage job returned") { exit != nil }
            try check(exit == 0, "\(mode) fixture job returns with its platform shell alive")
            let shell = try HostProcessToken.read(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!)
            defer { try? shell.signal(SIGKILL) }
            let record = try await processCoordinator.storage.snapshot().first { $0.operationID == owner.operationID }!
            let manifest = try HostPrivateCleanupStore(directory: registry).load(.init(record))!
            try check(StagingInstallWorkload.tag(shell.pid, expecting: manifest.tag.uuidString, key: HostPrivateProcessInspector.tagKey) == .hidden,
                      "macOS hides the \(mode) /bin/sh environment from the tag scan")
            if mode == "grandchild" {
                var info = proc_bsdinfo()
                try check(proc_pidinfo(shell.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) && info.pbi_ppid == 1,
                          "untagged grandchild execs /bin/sh after reparenting to launchd")
            }
            try check(try HostPrivateProcessInspector().survivors(manifest).contains(shell),
                      "shared kernel lineage finds the surviving \(mode) shell without its environment")
            // Inert signalling explicitly tests the held-until-exit rule even
            // if live sampling already proved this platform survivor belongs
            // to the job. Successful production signalling is exercised below.
            let cleanup = HostPrivateExecutionCleanup(signal: { _, _ in }, deadlineSeconds: 0.1)
            let answer = await cleanup.sweep(manifest)
            try check(held(answer) && (try HostPrivateProcessInspector().live(shell)), "live \(mode) shell prevents practical release")
            do { try await processCoordinator.finish(owner, exit: answer) } catch HostExecutionCoordinator.Failure.physicalExitUnconfirmed { }
            try check(try await processCoordinator.storage.snapshot().first { $0.operationID == owner.operationID }!.holdsResources,
                      "ownership stays durably held while \(mode) shell survives")
            try Data().write(to: exitFile)
            try await wait("platform shell exits naturally") { (try? HostPrivateProcessInspector().live(shell)) == false }
            let recovery = BackgroundJobHostRecovery(coordinator: processCoordinator, verify: adapter.verifyRecovery)
            try check(practical(await adapter.verifyExit(request)), "production verifier seals the ended \(mode) scope with fresh lineage scans")
            let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(20))
            let initial = try await recovery.check(operationID: owner.operationID)
            var release = try await recovery.reconcile(initial)
            // Concurrent load can create another possible orphan between fresh
            // scans. A correct conservative hold is not release failure: wait
            // for a NEW proof, as automatic recovery does, without caching one.
            while case .retained(_, let reason) = release, ContinuousClock.now < recoveryDeadline {
                print("RECOVERY HELD (\(mode)): " + reason)
                guard try await processCoordinator.storage.snapshot().first(where: { $0.operationID == owner.operationID })?.holdsResources == true else {
                    throw nativeFailure("Retained recovery lost ownership without proof")
                }
                try await Task.sleep(for: .milliseconds(50))
                let fresh = try await recovery.check(operationID: owner.operationID)
                release = try await recovery.reconcile(fresh)
            }
            if case .released = release { try check(true, "\(mode) ownership releases only after its last process exits") }
            else { try check(false, "\(mode) lineage recovery after natural exit: \(release)") }
        }
        // A durable positive observation must survive both orphaning and exec.
        // This is the case for compiler helpers whose Apple-platform environment
        // is hidden after their parent exits. No signal seam is injected here.
        let (observedOwner, observedRequest) = try await admit("observed-grandchild")
        let prePID = root.appendingPathComponent("observed-before.pid"), parentGo = root.appendingPathComponent("observed-parent.go")
        let postPID = root.appendingPathComponent("observed-after.pid"), observedExit = root.appendingPathComponent("observed.exit")
        var observedStatus: Int32?
        let observedJob = try launch(observedOwner, command: "exec '\(worker.path)' observed '\(prePID.path)' '\(parentGo.path)' '\(postPID.path)' '\(observedExit.path)'", exit: { observedStatus = $0 })
        defer { observedJob.terminate(); try? Data().write(to: parentGo); try? Data().write(to: observedExit) }
        try await wait("grandchild publishes identity before orphaning") {
            (try? String(contentsOf: prePID, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } != nil
        }
        let beforePID = Int32(try String(contentsOf: prePID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        guard case .live(let beforeExec) = try StagingInstallWorkload.identity(beforePID) else { throw nativeFailure("Observed grandchild disappeared") }
        let observedRecord = try await processCoordinator.storage.snapshot().first { $0.operationID == observedOwner.operationID }!
        let observedStore = HostPrivateCleanupStore(directory: registry)
        try await wait("stable grandchild identity is durably observed") {
            (try? observedStore.load(.init(observedRecord)))?.observed?.contains(where: { $0.unique == beforeExec.unique }) == true
        }
        try check(true, "shared live lineage sampler persists a real grandchild before its parent exits")
        try Data().write(to: parentGo)
        try await wait("observed grandchild execs after adoption") { observedStatus != nil }
        let observedToken = try HostProcessToken.read(Int32(try String(contentsOf: postPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!)
        defer { try? observedToken.signal(SIGKILL) }
        guard case .live(let afterExec) = try StagingInstallWorkload.identity(observedToken.pid) else { throw nativeFailure("Exec'd grandchild disappeared") }
        try check(observedStatus == 0 && afterExec.unique == beforeExec.unique && afterExec.version != beforeExec.version && afterExec.parent == 1,
                  "observed grandchild keeps its unique ID through launchd reparenting and exec, with a new PID version")
        let observedManifest = try observedStore.load(.init(observedRecord))!
        try check(StagingInstallWorkload.tag(observedToken.pid, expecting: observedManifest.tag.uuidString, key: HostPrivateProcessInspector.tagKey) == .hidden,
                  "observed exec'd grandchild has no visible private tag")
        try check(try HostPrivateProcessInspector().snapshot(observedManifest).signalable.contains(observedToken),
                  "durable stable lineage authorizes exact signalling after the original parent link is lost")
        let observedAnswer = await adapter.verifyExit(observedRequest)
        try check(practical(observedAnswer) && !(try HostPrivateProcessInspector().live(observedToken)),
                  "production cleanup kills the durably observed untagged platform orphan and proves it gone")
        try await processCoordinator.finish(observedOwner, exit: observedAnswer)
        try check(try await processCoordinator.storage.snapshot().first { $0.operationID == observedOwner.operationID }!.holdsResources == false,
                  "observed orphan cleanup releases only its own job")
        let (helperOwner, helperRequest) = try await admit("helper")
        let pidFile = root.appendingPathComponent("helper.pid")
        var wrapperExit: Int32?
        let wrapper = try launch(helperOwner, command: "exec '\(worker.path)' '\(pidFile.path)'", exit: { wrapperExit = $0 })
        defer { wrapper.terminate() }
        try await wait("wrapper exited leaving helper") { wrapperExit != nil }
        let helperPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        let helperToken = try HostProcessToken.read(helperPID)
        defer { try? helperToken.signal(SIGKILL) }
        let helperRecord = try await processCoordinator.storage.snapshot().first { $0.operationID == helperOwner.operationID }!
        let store = HostPrivateCleanupStore(directory: registry)
        let manifest = try store.load(.init(helperRecord))!
        try check(try HostPrivateProcessInspector().survivors(manifest).contains(helperToken), "tag scan finds real surviving helper outside the wrapper's group")
        // Failure seams deliberately use the REAL inspector and helper. Only the
        // failed syscall is injected. These are separate from real cleanup tests.
        let manifestPath = registry.appendingPathComponent("private-cleanup-" + helperRecord.executionAttemptID.uuidString + ".json")
        let originalManifest = try Data(contentsOf: manifestPath)
        for field in ["jobID", "workspaceID"] {
            var forged = try JSONSerialization.jsonObject(with: originalManifest) as! [String: Any]
            forged[field] = UUID().uuidString
            try JSONSerialization.data(withJSONObject: forged).write(to: manifestPath)
            try check(held(await adapter.verifyRecovery(helperRecord)) && (try HostPrivateProcessInspector().live(helperToken)), "wrong \(field) in recovery evidence cannot clean or release current execution")
            try originalManifest.write(to: manifestPath)
        }
        for field in ["lineage", "roots"] {
            var missing = try JSONSerialization.jsonObject(with: originalManifest) as! [String: Any]
            missing.removeValue(forKey: field)
            try JSONSerialization.data(withJSONObject: missing).write(to: manifestPath)
            try check(held(await adapter.verifyRecovery(helperRecord)) && (try HostPrivateProcessInspector().live(helperToken)),
                      "missing \(field) cannot authorize private cleanup")
            try originalManifest.write(to: manifestPath)
        }
        let bindingPath = registry.appendingPathComponent("private-binding-" + helperRecord.executionAttemptID.uuidString + ".json")
        let originalBinding = try Data(contentsOf: bindingPath)
        try FileManager.default.removeItem(at: bindingPath)
        try check(held(await adapter.verifyRecovery(helperRecord)) && (try HostPrivateProcessInspector().live(helperToken)), "missing required run/job binding cannot authorize cleanup")
        try originalBinding.write(to: bindingPath); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bindingPath.path)
        let signalFailure = HostPrivateExecutionCleanup(signal: { _, _ in throw nativeFailure("injected signal failure") })
        let failedSignal = await signalFailure.sweep(manifest)
        try check(held(failedSignal) && (try HostPrivateProcessInspector().live(helperToken)), "injected cleanup failure retains a real live helper")
        do { try await processCoordinator.finish(helperOwner, exit: failedSignal) } catch HostExecutionCoordinator.Failure.physicalExitUnconfirmed { }
        let failedRecord = try await processCoordinator.storage.snapshot().first { $0.operationID == helperOwner.operationID }!
        try check(failedRecord.holdsResources && failedRecord.phase == .uncertain && failedRecord.evidence?.contains("injected signal failure") == true, "cleanup failure persists held ownership with its actual reason")
        let inspectionFailure = HostPrivateExecutionCleanup(inspect: { _ in throw nativeFailure("injected inspection failure") })
        try check(held(await inspectionFailure.sweep(manifest)), "injected inspection error cannot become cleanup success")
        let persistentRace = HostPrivateExecutionCleanup(inspect: { _ in throw HostPrivateInspectionRace(message: "injected persistent procargs EINVAL") }, deadlineSeconds: 0.05)
        try check(held(await persistentRace.sweep(manifest)) && (try HostPrivateProcessInspector().live(helperToken)),
                  "persistent procargs unreadability reaches the original deadline and retains the live helper")
        let deadlineFailure = HostPrivateExecutionCleanup(signal: { _, _ in }, deadlineSeconds: 0.05)
        try check(held(await deadlineFailure.sweep(manifest)) && (try HostPrivateProcessInspector().live(helperToken)), "cleanup deadline with surviving helper fails closed")
        let helperAnswer = await adapter.verifyExit(helperRequest)
        try check(practical(helperAnswer) && !(try HostPrivateProcessInspector().live(helperToken)), "native cleanup kills tagged helper and confirms no survivors")
        let interruptedInspection = InterruptedPrivateInspection()
        let interruptedSweep = HostPrivateExecutionCleanup(inspect: { try interruptedInspection.inspect($0) })
        try check(practical(await interruptedSweep.sweep(manifest)) && interruptedInspection.count >= 4,
                  "one sweep restarts complete scanning after a procargs race; interrupted scans never count as empty")
        let helperRecovery = BackgroundJobHostRecovery(coordinator: processCoordinator, verify: adapter.verifyRecovery)
        let helperTicket = try await helperRecovery.check(operationID: helperOwner.operationID)
        if case .released = try await helperRecovery.reconcile(helperTicket) { try check(true, "previous cleanup failure releases only after fresh successful cleanup") }
        else { try check(false, "helper recovery after cleanup failure") }
        // A detached helper that keeps stdout/stderr open must be swept before
        // NativeProcess can finish draining and the execution can finalize.
        let (pipeOwner, pipeRequest) = try await admit("pipe-holder")
        let pipePID = root.appendingPathComponent("pipe.pid"), pipeGo = root.appendingPathComponent("pipe.go")
        var pipeExit: Int32?
        let pipeWrapper = try launch(pipeOwner, command: "exec '\(worker.path)' '\(pipePID.path)' '\(pipeGo.path)'", exit: { pipeExit = $0 })
        defer { pipeWrapper.terminate() }
        try await wait("pipe helper ready") { FileManager.default.fileExists(atPath: pipePID.path) }
        let pipeChild = try HostProcessExitObservation(pid: Int32(try String(contentsOf: pipePID, encoding: .utf8))!)
        try Data("go".utf8).write(to: pipeGo)
        try await wait("tagged pipe helper swept and streams joined") { pipeExit != nil }
        if case .verified = pipeChild.verdict() { try check(true, "kernel observes detached pipe-holding helper exit before wrapper join") }
        else { try check(false, "detached pipe helper survived join") }
        try check(pipeExit == 0, "pre-drain cleanup preserves wrapper's actual successful exit")
        let pipeAnswer = await adapter.verifyExit(pipeRequest)
        try check(practical(pipeAnswer), "private execution releases after tagged pipe holder is cleaned")
        try await processCoordinator.finish(pipeOwner, exit: pipeAnswer)
        // Recovery rereads the exact manifest, not a cached success certificate.
        let bRecord = try await processCoordinator.storage.snapshot().first { $0.operationID == ownerB.operationID }!
        try check(held(await BackgroundJobExitVerification(coordinator: HostExecutionCoordinator(directory: registry)).verifyRecovery(bRecord)) && bp.isRunning,
                  "recovery refuses takeover while original unsealed host is alive")
        bp.terminate(); try await wait("B joined") { bExit != nil }
        let bAnswer = await adapter.verifyExit(requestB)
        try check(practical(bAnswer), "B cleans using only B's own evidence")
        do { try await processCoordinator.finish(ownerB, exit: .unconfirmed(reason: "fixture: publication interrupted")) } catch { }
        let reopened = HostExecutionCoordinator(directory: registry)
        let recovery = BackgroundJobHostRecovery(coordinator: reopened, verify: BackgroundJobExitVerification(coordinator: reopened).verifyRecovery)
        let ticket = try await recovery.check(operationID: ownerB.operationID)
        if case .released = try await recovery.reconcile(ticket) { try check(true, "restart recovery releases exact sealed practical execution") }
        else { try check(false, "practical recovery release") }
        try check(try await reopened.storage.snapshot().first { $0.operationID == reused.operationID }!.holdsResources, "recovery leaves another uncertain attempt held")
        // Missing/foreign durable evidence cannot authorize another attempt.
        let stalePath = registry.appendingPathComponent("private-cleanup-" + reused.physicalEvidence.identity.attemptID.uuidString + ".json")
        let aPath = registry.appendingPathComponent("private-cleanup-" + requestA.identity.attemptID.uuidString + ".json")
        try FileManager.default.copyItem(at: aPath, to: stalePath)
        let reusedRecord = try await reopened.storage.snapshot().first { $0.operationID == reused.operationID }!
        try check(held(await BackgroundJobExitVerification(coordinator: reopened).verifyRecovery(reusedRecord)), "copied old manifest cannot authorize a current attempt on the same workspace")
        try FileManager.default.removeItem(at: stalePath)
        try check(held(await BackgroundJobExitVerification(coordinator: reopened).verifyRecovery(reusedRecord)), "missing required evidence leaves ownership held")
        // A real host crash BEFORE sealing leaves a durable tagged-worker scope.
        let crashRoot = try directory("crash-owner")
        try FileManager.default.copyItem(at: worker, to: crashRoot.appendingPathComponent("worker"))
        let host = Process(); host.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); host.arguments = [crashRoot.path]; host.environment = env
        try host.run()
        defer { if host.isRunning { host.terminate() } }
        try await wait("crash owner ready") { FileManager.default.fileExists(atPath: crashRoot.appendingPathComponent("ready").path) || !host.isRunning }
        try check(host.isRunning, "real private owner reaches pre-seal crash barrier")
        let crashChild = try HostProcessToken.read(Int32(try String(contentsOf: crashRoot.appendingPathComponent("child.pid"), encoding: .utf8))!)
        defer { try? crashChild.signal(SIGKILL) }
        kill(host.processIdentifier, SIGKILL); host.waitUntilExit()
        try check(host.terminationReason == .uncaughtSignal && host.terminationStatus == SIGKILL, "real private owner crashes with tagged detached helper alive")
        let crashCoordinator = HostExecutionCoordinator(directory: crashRoot.appendingPathComponent("registry"))
        let crashRecovery = BackgroundJobHostRecovery(coordinator: crashCoordinator, verify: BackgroundJobExitVerification(coordinator: crashCoordinator).verifyRecovery)
        let crashRecord = try await crashCoordinator.storage.snapshot().first!
        let crashTicket = try await crashRecovery.check(operationID: crashRecord.operationID)
        try check(practical(crashTicket.verdict) && !(try HostPrivateProcessInspector().live(crashChild)), "restart discovers and cleans crashed owner's exact tagged helper")
        let crashRelease = try await crashRecovery.reconcile(crashTicket)
        if case .released = crashRelease { try check(true, "restart rechecks cleanup and releases exact crashed attempt") }
        else { try check(false, "crashed private recovery: \(crashRelease)") }
        try check(try await reopened.storage.snapshot().first { $0.operationID == reused.operationID }!.holdsResources, "crash recovery does not release another registry owner")
        // Strict exclusive work cannot consume practical cleanup evidence.
        let exclusiveCoordinator = HostExecutionCoordinator(directory: root.appendingPathComponent("exclusive-registry"))
        let exclusive = try await exclusiveCoordinator.admitExclusive(operationID: UUID(), requester: UUID(), resource: source, mayOperate: { true })
        exclusive.physicalEvidence.enableLocalTracking()
        let exclusiveID = UUID(); try exclusive.physicalEvidence.bind(workspaceID: exclusiveID, jobID: nil)
        try exclusive.physicalEvidence.recordOfflinePreview()
        var exclusiveExit: Int32?
        let exclusiveProcess = try launch(exclusive, command: "exec /bin/sleep 60", exit: { exclusiveExit = $0 })
        defer { exclusiveProcess.terminate() }
        let exclusiveAnswer = await BackgroundJobExitVerification(coordinator: exclusiveCoordinator).verifyForegroundExit(.init(workspaceID: exclusiveID, jobID: nil, evidence: exclusive.physicalEvidence))
        try check(held(exclusiveAnswer) && exclusiveProcess.isRunning, "exclusive work retains strict physical-exit requirements")
        do { try await exclusiveCoordinator.finish(exclusive, exit: helperAnswer); try check(false, "exclusive accepted private exception") }
        catch { try check(try await exclusiveCoordinator.storage.snapshot().first!.holdsResources, "private answer cannot release exclusive work") }
        exclusiveProcess.terminate(); try await wait("exclusive fixture shutdown") { exclusiveExit != nil }
        try check(held(await BackgroundJobExitVerification(coordinator: exclusiveCoordinator).verifyForegroundExit(.init(workspaceID: exclusiveID, jobID: nil, evidence: exclusive.physicalEvidence))),
                  "offline preview cannot supply strict whole-worker proof even after exclusive tracked launches join")
        let (unsandboxedOwner, unsandboxedRequest) = try await admit("unsandboxed-preview")
        let unsandboxedResult = try await NativeProcess.run(executable: "/usr/bin/true", arguments: [], directory: root, environment: env,
            physicalEvidence: unsandboxedOwner.physicalEvidence, sandboxedPrivate: false)
        try unsandboxedOwner.physicalEvidence.recordOfflinePreview()
        let unsandboxedAnswer = await adapter.verifyExit(unsandboxedRequest)
        try check(unsandboxedResult.exitCode == 0 && held(unsandboxedAnswer),
                  "offline preview cannot grant practical eligibility to joined unsandboxed work")
        _ = reusedRequest
        print("PASS: PracticalReleaseTests \(checks) checks; real processes except explicitly injected failure syscalls")
    }
}
