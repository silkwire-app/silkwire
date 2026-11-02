import Foundation
import Darwin

/// Exercises the real non-UI Builder, actual Git preparation, Seatbelt command
/// execution and broker cleanup. No providers or installed app/library are used.
@main struct HostNativeBuilderIntegrationTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let base = try NativeTemporaryDirectory.createWorkspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source"), registry = base.appendingPathComponent("registry"), ledger = base.appendingPathComponent("ledger")
        for path in [source, registry, ledger] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try Data("synthetic source\n".utf8).write(to: source.appendingPathComponent("README.md"))
        for args in [["init", "-q"], ["add", "README.md"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@local.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "Synthetic source"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args; p.currentDirectoryURL = source
            p.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
            try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw nativeFailure("Fixture Git failed") }
        }
        let revision = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["rev-parse", "HEAD"], directory: source, environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinator = HostExecutionCoordinator(directory: registry)
        let scope = BackgroundWorkScope(projectID: UUID(), conversationID: UUID(), workspaceID: UUID(), agentID: "codex", sourceRevision: revision)
        let actual = HostNativeBuilderJobs(coordinator: coordinator, storageRoot: base.appendingPathComponent("runs"), plan: { _ in
            HostNativeBuildPlan(source: source, build: "/usr/bin/true", test: "/usr/bin/true", edit: false)
        }, verifyExit: { _ in
            // A process exit is not upgraded to descendant/remote evidence.
            .unconfirmed(reason: "fixture: real shell executor has no independent descendant verifier")
        })
        let binding = HostBackgroundExecution(coordinator: coordinator, resolve: { _ in .init(executionRoot: source, conflictRoot: source) }, cancel: actual.cancel, join: actual.join)
        let service = try await HostBackgroundJobService.open(storage: BackgroundWorkStorageSession.open(directory: ledger, projectID: scope.projectID, conversationID: scope.conversationID), execution: binding, authorize: { $0 == scope }, execute: actual.execute)
        let id = try await service.submit(.init(operationID: UUID(), scope: scope, workDescription: "Synthetic real native build path", limits: .init(totalSteps: 1, stepsPerSlice: 1)))
        let deadline = Date().addingTimeInterval(90)
        while service.snapshot(id)?.state != .needsReview {
            guard Date() < deadline else { throw nativeFailure("Native Builder integration timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let runs = try FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("runs"), includingPropertiesForKeys: nil)
        guard runs.count == 1 else { throw nativeFailure("Non-UI executor did not create exactly one isolated Builder run") }
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: runs[0].appendingPathComponent("receipt.json"))) as! [String: Any]
        print(try nativeJSON(receipt))
        guard receipt["status"] as? String == "needs-review", receipt["sourceUnchanged"] as? Bool == true,
              (receipt["steps"] as? [[String: Any]])?.count == 2,
              (receipt["steps"] as? [[String: Any]])?.allSatisfy({ $0["status"] as? String == "passed" }) == true,
              receipt["physicalExitUnconfirmed"] as? Bool == true,
              service.pendingResults.isEmpty,
              try await coordinator.storage.snapshot().filter(\.holdsResources).count == 1 else {
            throw nativeFailure("Actual non-UI native Builder ownership/evidence contract failed")
        }
        try await service.shutdown()
        print("PASS: actual NativeBuilder prepared Git, ran sequential build/test under inherited D2 admission, preserved source and retained the slot for unconfirmed descendant evidence; no UI or provider demonstration")
    }
}
