import Foundation

@MainActor final class BudgetTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    var responses: [String] = []
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false); self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text); eventHandler?(.delta(responses.isEmpty ? "Fixture answer" : responses.removeFirst())); eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture") }
}
@main struct ProjectArtifactRoomTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-project-artifact-rooms-" + UUID().uuidString)
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let storage = stage.library.appendingPathComponent("Team Workspaces"), projectID = UUID()
        let artifacts = ProjectArtifactStore(storage: storage, projectID: projectID)
        let oldID = "00000000-0000-4000-8000-000000000001"
        for index in 0..<210 {
            let id = index == 0 ? oldID : UUID().uuidString
            let receipt: [String: Any] = ["id": id, "owner": "claude", "status": "review", "finishedAt": "2026-10-28T00:00:00Z", "diff": "SHARED-ARTIFACT-CODE", "diffTruncated": false, "task": "PRIVATE-OTHER-ROOM-PROMPT", "trustedFolderIDs": ["PRIVATE-GRANT"]]
            try artifacts.record(receipt, from: root.appendingPathComponent("archived-origin/" + id))
        }
        var events: [[String: Any]] = []
        let transport = BudgetTransport()
        transport.responses = ["<<READ_PROJECT {\"action\":\"artifacts\",\"startLine\":1,\"lineCount\":200}>>", "<<READ_PROJECT {\"action\":\"diff\",\"artifactId\":\"\(oldID)\"}>>", "<<READ_PROJECT {\"action\":\"artifact\",\"artifactId\":\"\(oldID)\"}>>", "Reviewed the Project output."]
        let room = NativeRoom(emit: { events.append($0) }, factory: { _, _ in transport }, trustedStorage: storage, trustedSandbox: stage)
        await room.dispatch(["action": "connect", "conversationID": UUID().uuidString, "projectID": projectID.uuidString, "participants": ["codex"]])
        let request = UUID().uuidString
        await room.dispatch(["action": "send", "requestId": request, "text": "Review the finished output from the archived room", "targets": ["codex"]])
        for _ in 0..<500 {
            if events.contains(where: { $0["type"] as? String == "settled" && $0["requestId"] as? String == request }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(transport.prompts.count == 4)
        precondition(transport.prompts[1].contains("\"total\":210") && transport.prompts[2].contains("SHARED-ARTIFACT-CODE") && transport.prompts[3].contains("SHARED-ARTIFACT-CODE"))
        precondition(!transport.prompts.joined().contains("PRIVATE-"))
        precondition(!transport.prompts.joined().contains("CURRENT TRUSTED STAGING CAPABILITIES"))
        print("PASS another room discovers all 210 finished Project artifacts and reads an older diff and receipt outside the recent inventory")
        print("PASS artifact reuse supplies no private room prompt, folder permissions or execution grant")
        room.close()
        let source = stage.sources.appendingPathComponent("other-project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let other = BudgetTransport()
        other.responses = ["<<READ_PROJECT {\"action\":\"diff\",\"artifactId\":\"\(oldID)\"}>>", "The other Project output was refused."]
        var foreignEvents: [[String: Any]] = []
        let foreign = NativeRoom(emit: { foreignEvents.append($0) }, factory: { _, _ in other }, trustedStorage: storage, trustedSandbox: stage)
        await foreign.dispatch(["action": "connect", "conversationID": UUID().uuidString, "projectID": UUID().uuidString, "participants": ["codex"], "projectFolders": [["id": "own", "name": "Own folder", "root": source.path]]])
        await foreign.dispatch(["action": "send", "requestId": UUID().uuidString, "text": "Test the Project boundary", "targets": ["codex"]])
        for _ in 0..<500 where other.prompts.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        precondition(other.prompts.count == 2 && other.prompts[1].contains("No saved private-workspace diff") && !other.prompts[1].contains("SHARED-ARTIFACT-CODE"))
        print("PASS another Project cannot read the saved artifact even with its own valid folder grant")
        foreign.close()
    }
}
