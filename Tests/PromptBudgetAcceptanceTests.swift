import Foundation

@MainActor final class BudgetTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false); self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text); eventHandler?(.delta("Fixture answer")); eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture") }
}
@main struct PromptBudgetAcceptanceTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-prompt-budget-" + UUID().uuidString)
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let source = stage.sources.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let storage = stage.library.appendingPathComponent("Team Workspaces"), roomID = UUID().uuidString.lowercased()
        let board = WorkspaceTaskBoard(root: storage.appendingPathComponent(roomID))
        for index in 0..<40 {
            _ = try board.begin(owner: agents[index % agents.count], folderID: "source", title: "Historical task \(index) " + String(repeating: "detail ", count: 140), paths: (0..<8).map { "file-\(index)-\($0)-" + String(repeating: "source-scope-", count: 7) + ".swift" }, taskID: nil)
        }
        let boardCharacters = try nativeJSON(board.json()).utf16.count
        precondition(boardCharacters > 25_000, "Fixture must create real optional-context pressure after the board's own 24-task/200-character limits")
        print("Historical task-board payload would add \(boardCharacters) UTF-16 characters before optional-context compaction")
        var events: [[String: Any]] = [], transports: [String: BudgetTransport] = [:]
        let room = NativeRoom(emit: { events.append($0) }, factory: { agent, _ in let value = BudgetTransport(); transports[agent] = value; return value }, trustedStorage: storage, trustedSandbox: stage)
        await room.dispatch(["action": "connect", "conversationID": roomID, "participants": ["codex"], "projectBrief": "ESSENTIAL-REQUIRED-CONSTRAINT: protect regular Silkwire and accounts.", "projectFolders": [["id": "source", "name": "Staging source", "root": source.path]], "trustedFolderIDs": ["source"]])
        precondition(events.contains { $0["type"] as? String == "ready" })
        let request = UUID().uuidString
        let history = (0..<200).map { ["author": "Codex", "text": "History \($0) " + String(repeating: "quoted \\\"data\\\" ", count: 300), "state": "completed"] }
        await room.dispatch(["action": "send", "requestId": request, "text": "Please continue the authorized work", "targets": ["codex"], "projectMemory": String(repeating: "saved historical note ", count: 300), "history": history, "historyTotal": history.count])
        for _ in 0..<500 {
            if events.contains(where: { $0["type"] as? String == "settled" && $0["requestId"] as? String == request }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!events.contains { $0["type"] as? String == "rejected" })
        let prompt = transports["codex"]!.prompts[0]
        precondition(prompt.utf16.count <= 32000 && prompt.contains("Please continue the authorized work") && prompt.contains("ESSENTIAL-REQUIRED-CONSTRAINT"))
        precondition(prompt.contains("CURRENT TRUSTED STAGING CAPABILITIES") && prompt.contains("Use WORK_PROJECT action board"))
        let measured = events.first { $0["type"] as? String == "context" }!
        let components = measured["components"] as! [String: Int]
        precondition(components.values.reduce(0, +) == prompt.utf16.count)
        print("PASS five-word request fits despite 40 long saved tasks and 200 quoted history messages; current permissions and task constraints preserved")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["promptCharacters": prompt.utf16.count, "components": components], options: [.sortedKeys]), as: UTF8.self))
        // Required user attachments can still exceed the cap. That rejection must
        // accurately identify the required input after optional material is removed.
        let before = transports["codex"]!.prompts.count
        let attached = ["name": "required.txt", "mimeType": "text/plain", "data": Data(String(repeating: "required ", count: 1300).utf8).base64EncodedString()]
        let tooLarge = UUID().uuidString
        await room.dispatch(["action": "send", "requestId": tooLarge, "text": String(repeating: "x", count: 23000), "targets": ["codex"], "attachments": [attached]])
        let rejection = events.last { $0["type"] as? String == "rejected" && $0["requestId"] as? String == tooLarge }?["message"] as? String ?? ""
        precondition(rejection.contains("after optional Silkwire history was removed") && rejection.contains("Your message uses 23000") && transports["codex"]!.prompts.count == before)
        print("PASS unavoidable required-input overflow is accurately explained and never dispatched")
        room.close()
    }
}
