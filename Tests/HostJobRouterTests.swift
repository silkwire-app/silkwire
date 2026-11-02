import Foundation

@MainActor private final class RouterGate {
    var entered = false
    var permit: (() -> Bool)?
    var waiter: CheckedContinuation<Void, Never>?
    func run(_ context: BackgroundWorkContext) async throws -> BackgroundWorkStep {
        entered = true; permit = context.mayPerformOperation
        await withCheckedContinuation { waiter = $0 }
        return .completed(checkpoint: "synthetic", summary: "synthetic")
    }
    func release() { let old = waiter; waiter = nil; old?.resume() }
}
@main struct HostJobRouterTests {
    @MainActor static func main() async throws {
        let root = try NativeTemporaryDirectory.createWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), ledger = root.appendingPathComponent("ledger")
        for path in [source, ledger] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let scope = BackgroundWorkScope(projectID: UUID(), conversationID: UUID(), workspaceID: UUID(), agentID: "codex", sourceRevision: String(repeating: "a", count: 40))
        let coordinator = HostExecutionCoordinator(directory: root.appendingPathComponent("registry")), gate = RouterGate()
        let binding = HostBackgroundExecution(coordinator: coordinator, resolve: { value in
            guard value == scope else { throw BackgroundWorkError.invalidInput }; return .init(executionRoot: source, conflictRoot: source)
        }, cancel: { _ in }, join: { _ in .verified(evidence: "fixture: router's controlled executor explicitly joined") })
        let service = try await HostBackgroundJobService.open(storage: BackgroundWorkStorageSession.open(directory: ledger, projectID: scope.projectID, conversationID: scope.conversationID), execution: binding, authorize: { $0 == scope }, execute: gate.run)
        let router = HostJobCommandRouter(scope: { room, workspace, agent in
            guard room == scope.conversationID, workspace == scope.workspaceID, agent == scope.agentID else { throw HostExecutionCoordinator.Failure.permissionChanged }
            return scope
        }, service: { _ in service })
        let operation = UUID()
        let request: [String: Any] = ["action": "backgroundSubmit", "operationID": operation.uuidString, "workspaceID": scope.workspaceID.uuidString, "agentID": "codex", "workDescription": "Synthetic authorized native host request", "totalSteps": 1, "stepsPerSlice": 1]
        var checks = 0
        func refused(_ args: [String: Any], origin: UUID) async throws {
            do { _ = try await router.handle(args, originatingConversationID: origin); throw nativeFailure("Forged host request was accepted") }
            catch is HostExecutionCoordinator.Failure { checks += 1 }
            catch is BackgroundWorkError { checks += 1 }
        }
        var forged = request; forged["conversationID"] = UUID().uuidString
        try await refused(forged, origin: scope.conversationID)
        forged = request; forged["sourcePath"] = source.path
        try await refused(forged, origin: scope.conversationID)
        try await refused(request, origin: UUID())
        forged = request; forged["workDescription"] = String(repeating: "a", count: 241)
        try await refused(forged, origin: scope.conversationID)
        let accepted = try await router.handle(request, originatingConversationID: scope.conversationID)
        guard accepted["accepted"] as? Bool == true, accepted["jobID"] as? String == operation.uuidString.lowercased() else { throw nativeFailure("Router did not return stable durable acceptance") }
        checks += 1
        let deadline = Date().addingTimeInterval(10)
        while !gate.entered { guard Date() < deadline else { throw nativeFailure("Router fixture timed out") }; try await Task.sleep(for: .milliseconds(5)) }
        try await refused(["action": "backgroundStatus", "jobID": operation.uuidString], origin: UUID())
        try await refused(["action": "backgroundStop", "jobID": operation.uuidString], origin: UUID())
        guard gate.permit?() == true else { throw nativeFailure("Foreign Stop fenced another conversation") }; checks += 1
        let status = try await router.handle(["action": "backgroundStatus", "jobID": operation.uuidString], originatingConversationID: scope.conversationID)
        guard status["state"] as? String == "running", status["revision"] as? UInt64 != nil else { throw nativeFailure("Status omitted contract revision/state") }; checks += 1
        let stop = try await router.handle(["action": "backgroundStop", "jobID": operation.uuidString], originatingConversationID: scope.conversationID)
        guard stop["stopRequested"] as? Bool == true, gate.permit?() == false,
              try await coordinator.storage.snapshot().filter(\.holdsResources).count == 1 else { throw nativeFailure("Router Stop falsely released physical work") }; checks += 1
        gate.release(); await service.joinLocalExecutors(); try await service.shutdown()
        print("PASS: HostJobRouterTests, \(checks) origin/field/permission/acceptance/Stop checks; synthetic host dispatch only")
    }
}
