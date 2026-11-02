import Foundation
import Darwin

/// Production NativeBuilder/host path, harmless local commands, no providers.
@main struct HostPhysicalExitNativeTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = try NativeTemporaryDirectory.createWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), registry = root.appendingPathComponent("registry")
        for path in [source, registry, root.appendingPathComponent("ledger")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func check(_ okay: Bool, _ label: String) throws {
            print((okay ? "PASS: " : "FAIL: ") + label); if !okay { throw nativeFailure(label) }
        }
        let env = ["HOME": root.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        try Data("fixture\n".utf8).write(to: source.appendingPathComponent("README.md"))
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@local.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture"]] {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: source, environment: env)
            print("FIXTURE: git \(args) exit \(result.exitCode)")
            try check(result.exitCode == 0, "isolated source fixture command succeeded")
        }
        let revision = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["rev-parse", "HEAD"], directory: source, environment: env).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinator = HostExecutionCoordinator(directory: registry), adapter = BackgroundJobExitVerification(coordinator: coordinator)
        // Foreground callback binds the actual Run UUID and durable attempt.
        var requests: [HostExitRequest] = []
        let builder = NativeBuilder(onReceipt: { _ in }, storageRoot: root.appendingPathComponent("foreground"), ownership: coordinator,
            verifyPhysicalExit: { request in requests.append(request); return await adapter.verifyForegroundExit(request) })
        let begun = try await builder.beginTrusted(source: source, task: "Identity-bound local workspace", owner: "codex")
        let finished = try await builder.finishTrusted(summary: "Bounded local fixture")
        try check(requests.count == 1 && requests[0].workspaceID == (begun["id"] as? String).flatMap(UUID.init(uuidString:)) && requests[0].jobID == nil,
                  "foreground callback receives the exact Builder workspace UUID")
        let record = try await coordinator.storage.snapshot().first!
        try check(requests[0].identity == HostExecutionIdentity(record), "foreground callback carries the exact durable attempt and canonical workspace")
        // Sandboxed Git preparation uses the approved practical policy, not a kernel whole-tree claim.
        try check(finished["physicalExitUnconfirmed"] as? Bool != true && !record.holdsResources && record.evidence?.contains("practical cleanup") == true
                  && (finished["physicalCleanup"] as? [String: Any])?["kernelWholeWorkloadProof"] as? Bool == false,
                  "real sandboxed foreground Git work releases with explicitly practical evidence")
        // A separate source lets a real background execution progress concurrently.
        let second = root.appendingPathComponent("second")
        let copied = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["clone", "-q", source.path, second.path], directory: root, environment: env)
        try check(copied.exitCode == 0, "separate background source prepared without changing foreground source")
        let scope = BackgroundWorkScope(projectID: UUID(), conversationID: UUID(), workspaceID: UUID(), agentID: "claude", sourceRevision: revision)
        let runs = root.appendingPathComponent("runs")
        let native = HostNativeBuilderJobs(coordinator: coordinator, storageRoot: runs, plan: { _ in
            .init(source: second, build: "printf READY > \"$TMPDIR/physical-exit-barrier\"; /bin/sleep 60", test: "", edit: false)
        }, verifyExit: { request in requests.append(request); return await adapter.verifyExit(request) })
        let binding = HostBackgroundExecution(coordinator: coordinator, resolve: { _ in .init(executionRoot: second, conflictRoot: second) }, cancel: native.cancel, join: native.join)
        let service = try await HostBackgroundJobService.open(storage: BackgroundWorkStorageSession.open(directory: root.appendingPathComponent("ledger"), projectID: scope.projectID, conversationID: scope.conversationID), execution: binding,
            verifyRecovery: adapter.verifyRecovery, authorize: { $0 == scope }, execute: native.execute)
        let job = try await service.submit(.init(operationID: UUID(), scope: scope, workDescription: "Real native Stop barrier", limits: .init(totalSteps: 1, stepsPerSlice: 1)))
        let deadline = Date().addingTimeInterval(90)
        var barrier = false
        while !barrier {
            if let dirs = try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil) {
                barrier = dirs.contains { run in
                    guard let data = try? Data(contentsOf: run.appendingPathComponent("receipt.json")),
                          let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let temporary = receipt["temporaryPath"] as? String else { return false }
                    return FileManager.default.fileExists(atPath: URL(fileURLWithPath: temporary).appendingPathComponent("physical-exit-barrier").path)
                }
            }
            guard Date() < deadline else { throw nativeFailure("Native hold barrier not reached; state \(String(describing: service.snapshot(job)))") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pending = service.snapshot(job)!.pendingOperationID!
        try check(try await coordinator.storage.snapshot().filter(\.holdsResources).count == 1, "real background command holds its own admission after foreground cleanup")
        var chat = false; await Task { @MainActor in chat = true }.value
        try check(chat, "synthetic chat/control work progresses while actual NativeBuilder command is held")
        let stop = try await service.stop(job)
        try check(stop.stopRequested && service.snapshot(job)?.state != .completed, "Stop during real native execution acknowledges without claiming physical completion")
        while service.snapshot(job)?.state != .needsReview {
            guard Date() < deadline else { throw nativeFailure("Native Stop did not settle conservatively") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let backgroundRequests = requests.filter { $0.jobID == job }
        try check(!backgroundRequests.isEmpty && backgroundRequests.allSatisfy { $0.identity.operationID == pending && $0.workspaceID != scope.workspaceID },
                  "background proofs bind job, runner execution attempt and actual Builder run (not source receipt UUID)")
        let snapshot = try await coordinator.storage.snapshot()
        try check(snapshot.filter(\.holdsResources).isEmpty && snapshot.first { $0.operationID == record.operationID } == record && service.pendingResults.isEmpty,
                  "stopped sandboxed background work frees only its own admission and publishes no false result")
        let receiptURL = try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)[0].appendingPathComponent("receipt.json")
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
        print("REAL NATIVE RECEIPT: \(try nativeJSON(receipt))")
        let steps = receipt["steps"] as? [[String: Any]] ?? []
        try check(steps.count == 1 && steps[0]["status"] as? String == "stopped" && (steps[0]["exitCode"] as? Int).map { $0 != 0 } == true,
                  "real command Stop records its signal exit and preserves stopped evidence")
        try await service.shutdown()
        print("PASS: production foreground/background identity and real practical-cleanup Stop; no UI/provider demonstration")
    }
}
