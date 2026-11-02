import Foundation

/// Host dispatch boundary for the parallel room adapter. Origin is supplied by
/// NativeRoom, never accepted from agent JSON. Host scope/service resolvers retain
/// existing Project permissions and choose storage; no path is an agent argument.
@MainActor final class HostJobCommandRouter {
    typealias Scope = (_ conversationID: UUID, _ workspaceID: UUID, _ agentID: String) async throws -> BackgroundWorkScope
    typealias Service = (_ conversationID: UUID) async throws -> any BackgroundJobHost
    private let scope: Scope
    private let service: Service
    init(scope: @escaping Scope, service: @escaping Service) { self.scope = scope; self.service = service }
    func handle(_ args: [String: Any], originatingConversationID: UUID) async throws -> [String: Any] {
        guard let action = args["action"] as? String else { throw BackgroundWorkError.invalidInput }
        switch action {
        case "backgroundSubmit":
            guard Set(args.keys).isSubset(of: ["action", "requestId", "operationID", "workspaceID", "agentID", "workDescription", "totalSteps", "stepsPerSlice"]),
                  let rawID = args["operationID"] as? String, let operationID = UUID(uuidString: rawID),
                  let rawWorkspace = args["workspaceID"] as? String, let workspace = UUID(uuidString: rawWorkspace),
                  let agent = args["agentID"] as? String, agents.contains(agent),
                  let description = args["workDescription"] as? String,
                  let total = args["totalSteps"] as? Int, let slice = args["stepsPerSlice"] as? Int,
                  (1...10_000).contains(total), (1...total).contains(slice),
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.utf8.count <= 240 else { throw BackgroundWorkError.invalidInput }
            let authorized = try await scope(originatingConversationID, workspace, agent)
            guard authorized.conversationID == originatingConversationID, authorized.workspaceID == workspace, authorized.agentID == agent else { throw HostExecutionCoordinator.Failure.permissionChanged }
            let host = try await service(originatingConversationID)
            let id = try await host.submit(.init(operationID: operationID, scope: authorized, workDescription: description, limits: .init(totalSteps: total, stepsPerSlice: slice)))
            return ["version": 1, "jobID": id.uuidString.lowercased(), "accepted": true]
        case "backgroundStatus", "backgroundStop":
            guard Set(args.keys).isSubset(of: ["action", "requestId", "jobID"]),
                  let raw = args["jobID"] as? String, let id = UUID(uuidString: raw) else { throw BackgroundWorkError.invalidInput }
            let host = try await service(originatingConversationID)
            guard let snapshot = host.snapshot(id), snapshot.originatingConversationID == originatingConversationID else { throw BackgroundWorkError.unavailable }
            if action == "backgroundStop" {
                let acknowledgement = try await host.stop(id)
                return ["version": 1, "jobID": id.uuidString.lowercased(), "stopRequested": acknowledgement.stopRequested]
            }
            var result: [String: Any] = ["version": 1, "jobID": id.uuidString.lowercased(), "revision": snapshot.revision, "state": snapshot.state.rawValue, "progress": snapshot.progress, "note": snapshot.note]
            result["completionID"] = snapshot.completionID?.uuidString.lowercased()
            result["resultID"] = snapshot.resultID?.uuidString.lowercased()
            return result
        default: throw BackgroundWorkError.invalidInput
        }
    }
}
