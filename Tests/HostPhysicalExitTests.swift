import Foundation
import Darwin

@main struct HostPhysicalExitTests {
    @MainActor static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() {
            guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func environment(_ root: URL) -> [String: String] {
        ["HOME": root.path, "TMPDIR": root.path + "/", "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "SILKWIRE_DEV_DATA": root.appendingPathComponent("library").path, "SILKWIRE_FIXTURE_WORKER": ProcessInfo.processInfo.environment["SILKWIRE_FIXTURE_WORKER"] ?? ""]
    }
    @MainActor static func admit(_ coordinator: HostExecutionCoordinator, _ source: URL) async throws -> HostExecutionAdmission {
        let a = try await coordinator.admit(operationID: UUID(), conversationID: UUID(), kind: .foregroundBuild,
            authorize: { .init(executionRoot: source, conflictRoot: source) }, mayOperate: { true })
        a.physicalEvidence.enableLocalTracking(); return a
    }
    @MainActor static func request(workspaceID: UUID = UUID(), jobID: UUID? = nil, evidence: HostLocalExecutionEvidence) throws -> HostExitRequest {
        try evidence.bind(workspaceID: workspaceID, jobID: jobID)
        return HostExitRequest(workspaceID: workspaceID, jobID: jobID, evidence: evidence)
    }
    @MainActor static func helper() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[2])
        let coordinator = HostExecutionCoordinator(directory: root.appendingPathComponent("registry"))
        let a = try await admit(coordinator, root.appendingPathComponent("source"))
        if args[1] == "--sealed-owner" {
            let result = try await NativeProcess.run(executable: "/usr/bin/true", arguments: [], directory: root,
                environment: environment(root), physicalEvidence: a.physicalEvidence)
            guard result.exitCode == 0 else { _exit(91) }
            let verdict = await a.physicalEvidence.verify(try request(jobID: UUID(), evidence: a.physicalEvidence))
            guard case .verified = verdict else { print("seal failed: \(verdict)"); _exit(92) }
            print("READY: sealed proof persisted before ownership/result publication")
            try Data("ready".utf8).write(to: root.appendingPathComponent("ready"))
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        // No seal: a host crash loses the kernel subscription while its detached
        // worker survives. A fresh host must retain ownership even after PID exit.
        let pidFile = root.appendingPathComponent("child.pid")
        _ = try await NativeProcess.run(executable: ProcessInfo.processInfo.environment["SILKWIRE_FIXTURE_WORKER"]!, arguments: [pidFile.path], directory: root,
            environment: environment(root), physicalEvidence: a.physicalEvidence)
        try Data("ready".utf8).write(to: root.appendingPathComponent("ready"))
        while true { try await Task.sleep(for: .seconds(1)) }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count > 1 { try await helper(); return }
        let base = try NativeTemporaryDirectory.createWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let worker = base.appendingPathComponent("exit-worker")
        let compiled = try await NativeProcess.run(executable: "/usr/bin/cc", arguments: ["Tests/Fixtures/PhysicalExitWorker.c", "-o", worker.path], directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), environment: environment(base))
        print("FIXTURE: cc Tests/Fixtures/PhysicalExitWorker.c exit \(compiled.exitCode)")
        guard compiled.exitCode == 0 else { throw nativeFailure(compiled.stderr) }
        setenv("SILKWIRE_FIXTURE_WORKER", worker.path, 1)
        var checks = 0
        func check(_ okay: Bool, _ label: String) throws {
            print((okay ? "PASS: " : "FAIL: ") + label)
            guard okay else { throw nativeFailure(label) }; checks += 1
        }
        func unknown(_ verdict: HostPhysicalExit, contains: String = "") -> Bool {
            if case .unconfirmed(let reason) = verdict { print("RETAINED: " + reason); return !reason.isEmpty && (contains.isEmpty || reason.contains(contains)) }; return false
        }
        func verified(_ verdict: HostPhysicalExit) -> Bool { if case .verified(let evidence) = verdict { print("VERIFIED: " + evidence); return true }; return false }
        func fixture(_ name: String) throws -> URL {
            let root = base.appendingPathComponent(name)
            for url in [root, root.appendingPathComponent("source"), root.appendingPathComponent("other"), root.appendingPathComponent("registry")] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            return root
        }
        // Two simultaneous physical owners, real children and a responsive Stop.
        do {
            let root = try fixture("concurrent"), registry = root.appendingPathComponent("registry")
            let coordinator = HostExecutionCoordinator(directory: registry), adapter = BackgroundJobExitVerification(coordinator: coordinator)
            let a = try await admit(coordinator, root.appendingPathComponent("source"))
            let b = try await admit(coordinator, root.appendingPathComponent("other"))
            var aExit: Int32?, bExit: Int32?
            let ap = try NativeProcess(executable: "/bin/sleep", arguments: ["60"], directory: root, environment: environment(root), physicalEvidence: a.physicalEvidence, stdout: { _ in }, stderr: { _ in }, onExit: { aExit = $0 })
            let bp = try NativeProcess(executable: "/bin/sleep", arguments: ["60"], directory: root, environment: environment(root), physicalEvidence: b.physicalEvidence, stdout: { _ in }, stderr: { _ in }, onExit: { bExit = $0 })
            defer { ap.terminate(); bp.terminate() }
            let ar = try request(workspaceID: UUID(), jobID: UUID(), evidence: a.physicalEvidence)
            let br = try request(workspaceID: UUID(), jobID: UUID(), evidence: b.physicalEvidence)
            try check(try await coordinator.storage.snapshot().filter(\.holdsResources).count == 2, "two distinct workspace owners execute concurrently")
            try check(unknown(await adapter.verifyExit(ar), contains: "not been observed exited"), "live worker is retained despite caller asking to finish")
            try await coordinator.stop(a)
            try check(a.fenced && aExit == nil && bp.isRunning, "Stop fences A synchronously while physical A and B are still owned")
            var chat = false; await Task { @MainActor in chat = true }.value
            try check(chat, "independent control callback remains responsive during physical Stop")
            ap.terminate(); try await wait("A real exit") { aExit != nil }
            print("PROCESS: A exit \(aExit!)")
            let exit = await adapter.verifyExit(ar)
            try check(verified(exit), "kernel exit of A without forks supplies exact-attempt evidence")
            try await coordinator.finish(a, exit: exit)
            let records = try await coordinator.storage.snapshot()
            try check(records.first { $0.operationID == a.operationID }?.holdsResources == false && records.first { $0.operationID == b.operationID }?.holdsResources == true && bExit == nil && kill(bp.pid, 0) == 0, "finishing A preserves B's live process and protection")
            try check(unknown(await adapter.verifyForegroundExit(.init(workspaceID: br.workspaceID, jobID: br.jobID, evidence: a.physicalEvidence)), contains: "mismatched host job/workspace"), "A's witness cannot certify B's workspace")
            let bRecord = records.first { $0.operationID == b.operationID }!
            let aFile = registry.appendingPathComponent("physical-exit-" + a.physicalEvidence.identity.attemptID.uuidString + ".json")
            let bFile = registry.appendingPathComponent("physical-exit-" + b.physicalEvidence.identity.attemptID.uuidString + ".json")
            try FileManager.default.copyItem(at: aFile, to: bFile)
            try check(unknown(await adapter.verifyRecovery(bRecord), contains: "stale or belongs"), "copied stale proof cannot release another execution attempt")
            try FileManager.default.removeItem(at: bFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: aFile.path)
            try check(unknown(await adapter.verifyRecovery(records.first { $0.operationID == a.operationID }!), contains: "unsafe metadata"), "unsafe proof permissions fail closed")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: aFile.path)
            try check(unknown(await adapter.verifyRecovery(records.first { $0.operationID == a.operationID }!), contains: "cannot be opened"), "permission-denied exit proof retains ownership with its actual read failure")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aFile.path)
            try await coordinator.stop(b); bp.terminate(); try await wait("B real exit") { bExit != nil }
            print("PROCESS: B exit \(bExit!)")
            let bVerdict = await adapter.verifyExit(br); try check(verified(bVerdict), "B has its own independent proof")
            try await coordinator.finish(b, exit: bVerdict)
        }
        // A wrapper exits successfully while its detached child remains alive.
        do {
            let root = try fixture("wrapper"), coordinator = HostExecutionCoordinator(directory: root.appendingPathComponent("registry"))
            let a = try await admit(coordinator, root.appendingPathComponent("source"))
            let pidFile = root.appendingPathComponent("child.pid")
            let result = try await NativeProcess.run(executable: worker.path, arguments: [pidFile.path], directory: root, environment: environment(root), physicalEvidence: a.physicalEvidence)
            let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
            let child = try HostProcessExitObservation(pid: pid)
            defer { if unknown(child.verdict(), contains: "not been observed exited") { kill(pid, SIGKILL) } }
            print("PROCESS: wrapper exit \(result.exitCode); child \(pid) remains alive")
            try check(result.exitCode == 0 && kill(pid, 0) == 0, "wrapper and pipes finish while its detached child survives")
            let request = try Self.request(workspaceID: UUID(), jobID: nil, evidence: a.physicalEvidence)
            let verdict = await a.physicalEvidence.verify(request)
            try check(unknown(verdict, contains: "forked"), "kernel fork observation refuses wrapper completion as child-exit proof")
            do { try await coordinator.finish(a, exit: verdict); try check(false, "unconfirmed wrapper must fail finish") }
            catch HostExecutionCoordinator.Failure.physicalExitUnconfirmed { }
            let reopened = HostExecutionCoordinator(directory: root.appendingPathComponent("registry"))
            let adapter = BackgroundJobExitVerification(coordinator: reopened)
            let recovery = BackgroundJobHostRecovery(coordinator: reopened, verify: adapter.verifyRecovery)
            let ticket = try await recovery.check(operationID: a.operationID)
            if case .retained = try await recovery.reconcile(ticket) { try check(true, "recovery retains the exact owner while detached child lives") }
            else { try check(false, "surviving child released") }
            kill(pid, SIGKILL)
            try await wait("detached child kernel exit") { verified(child.verdict()) }
            try check(unknown(await adapter.verifyRecovery(try await reopened.storage.snapshot().first!)), "worker PID disappearance after lost whole-tree evidence still retains ownership")
        }
        // Actual owner-process crashes on both sides of durable proof persistence.
        for sealed in [false, true] {
            let root = try fixture(sealed ? "sealed-crash" : "unsealed-crash")
            let owner = Process(); owner.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            owner.arguments = [sealed ? "--sealed-owner" : "--unsealed-owner", root.path]; owner.environment = environment(root)
            try owner.run()
            defer { if owner.isRunning { owner.terminate() } }
            try await wait("owner ready") { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) || !owner.isRunning }
            try check(owner.isRunning, "owner reached controlled \(sealed ? "sealed" : "unsealed") crash barrier")
            let pidFile = root.appendingPathComponent("child.pid")
            let childPID = sealed ? nil : Int32(try String(contentsOf: pidFile, encoding: .utf8))
            let child = try childPID.map { try HostProcessExitObservation(pid: $0) }
            defer { if let childPID, let child, unknown(child.verdict(), contains: "not been observed exited") { kill(childPID, SIGKILL) } }
            kill(owner.processIdentifier, SIGKILL); owner.waitUntilExit()
            print("PROCESS: owner terminationReason=\(owner.terminationReason.rawValue), status=\(owner.terminationStatus) (expected SIGKILL=9)")
            try check(owner.terminationReason == .uncaughtSignal && owner.terminationStatus == SIGKILL, "real owner was killed and reaped before restart")
            let coordinator = HostExecutionCoordinator(directory: root.appendingPathComponent("registry"))
            let adapter = BackgroundJobExitVerification(coordinator: coordinator)
            let recovery = BackgroundJobHostRecovery(coordinator: coordinator, verify: adapter.verifyRecovery)
            let record = try await coordinator.storage.snapshot().first!
            let ticket = try await recovery.check(operationID: record.operationID)
            if sealed {
                try check(verified(ticket.verdict), "restart revalidates exact sealed kernel-exit certificate")
                // A concurrent Stop mutates the exact record after check.
                let other = try PhysicalWorkOwnership(directory: root.appendingPathComponent("registry"), capacity: HostOwnershipStorage.capacity)
                try other.reconcileAfterPhysicalExit(record, evidence: "fixture: independent host reconciled exact sealed proof")
                if case .retained = try await recovery.reconcile(ticket) { try check(true, "stale recovery ticket cannot alter a changed record") }
                else { try check(false, "stale ticket released") }
            } else {
                try check(childPID.map { kill($0, 0) == 0 } == true && unknown(ticket.verdict, contains: "No sealed"), "fresh host retains missing proof with a real surviving worker")
                if case .retained = try await recovery.reconcile(ticket) { try check(true, "Release with missing proof preserves ownership after crash") }
                else { try check(false, "missing proof released") }
                kill(childPID!, SIGKILL)
                try await wait("crashed owner's child exit") { verified(child!.verdict()) }
            }
        }
        // Positive Release, fresh evidence on both phases, repeated release and new work.
        do {
            let root = try fixture("release"), registry = root.appendingPathComponent("registry")
            let coordinator = HostExecutionCoordinator(directory: registry)
            let a = try await admit(coordinator, root.appendingPathComponent("source"))
            let b = try await admit(coordinator, root.appendingPathComponent("other"))
            let request = try Self.request(workspaceID: UUID(), jobID: nil, evidence: a.physicalEvidence)
            _ = try await NativeProcess.run(executable: "/usr/bin/true", arguments: [], directory: root, environment: environment(root), physicalEvidence: a.physicalEvidence)
            try check(verified(await a.physicalEvidence.verify(request)), "complete sealed local proof persists independently of ownership publication")
            // Simulate a publication/storage failure after proof: conservatively uncertain.
            do { try await coordinator.finish(a, exit: .unconfirmed(reason: "fixture: publication interrupted after sealing")) } catch HostExecutionCoordinator.Failure.physicalExitUnconfirmed { }
            do { try await coordinator.finish(b, exit: .unconfirmed(reason: "fixture: B remains uncertain")) } catch HostExecutionCoordinator.Failure.physicalExitUnconfirmed { }
            let reopened = HostExecutionCoordinator(directory: registry), adapter = BackgroundJobExitVerification(coordinator: coordinator)
            let recovery = BackgroundJobHostRecovery(coordinator: reopened, verify: adapter.verifyRecovery)
            let first = try await recovery.check(operationID: a.operationID)
            try check(verified(first.verdict), "Release check sees exact sealed proof")
            let file = registry.appendingPathComponent("physical-exit-" + a.physicalEvidence.identity.attemptID.uuidString + ".json")
            let saved = try Data(contentsOf: file); try FileManager.default.removeItem(at: file)
            if case .retained = try await recovery.reconcile(first) { try check(true, "Release rereads proof and refuses evidence removed after check") }
            else { try check(false, "stale cached proof released") }
            try saved.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let fresh = try await recovery.check(operationID: a.operationID)
            if case .released = try await recovery.reconcile(fresh) { try check(true, "fresh exact-attempt recovery releases A") }
            else { try check(false, "valid recovery failed") }
            try check(try await reopened.storage.snapshot().first { $0.operationID == b.operationID }!.holdsResources, "releasing A leaves B's uncertain ownership intact")
            do { _ = try await recovery.reconcile(fresh); try check(false, "repeated ticket accepted") } catch BackgroundWorkError.unavailable { try check(true, "repeated Release ticket cannot release anything else") }
            let newer = try await admit(reopened, root.appendingPathComponent("source"))
            try check(newer.operationID != a.operationID && newer.physicalEvidence.identity.attemptID != a.physicalEvidence.identity.attemptID, "verified release admits a new distinct execution after restart")
            try check(unknown(await adapter.verifyRecovery(try await reopened.storage.snapshot().first { $0.operationID == newer.operationID }!), contains: "No sealed"), "older certificate cannot release newer work on the same source")
            do { try await reopened.finish(newer, exit: .unconfirmed(reason: "fixture: new work has no witness")) } catch HostExecutionCoordinator.Failure.physicalExitUnconfirmed { }
        }
        print("PASS: \(checks) physical-exit/restart checks using real local children; no provider or app-global registry")
    }
}
