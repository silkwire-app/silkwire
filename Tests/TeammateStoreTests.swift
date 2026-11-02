import Foundation
import AppKit

@MainActor final class HeldReplyTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String
    var prompts: [String] = []
    var hold = true
    init(_ agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false); self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        eventHandler?(.delta("Working on it — "))
        if !hold { eventHandler?(.finished(status: "completed", message: nil)) }
    }
    func release() { eventHandler?(.delta("done.")); eventHandler?(.finished(status: "completed", message: nil)) }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture") }
}

@main struct TeammateStoreTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL: " + label) }
            checks += 1; print("PASS " + label)
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(30)
            while !predicate() { guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }; try await Task.sleep(for: .milliseconds(10)) }
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-teammate-store-" + UUID().uuidString)
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var project = Project(); project.name = "Fixture"
        var first = Conversation(); first.projectID = project.id; first.title = "First"
        var second = Conversation(); second.projectID = project.id; second.title = "Second"
        let runningID = UUID().uuidString, otherID = UUID().uuidString, diskID = UUID().uuidString
        first.messages = [Message(author: "Builder", text: "## Staging work · Codex · active\n\nTask: draft", state: "streaming", requestId: runningID),
                          Message(author: "Builder", text: "## Staging work · Eve · review\n\nTask: finished earlier", state: "completed", requestId: UUID().uuidString)]
        second.messages = [Message(author: "Builder", text: "## Staging work · Eve · active\n\nTask: other", state: "streaming", requestId: otherID),
                           Message(author: "Builder", text: "## Staging work · Claude · active\n\nTask: crashed", state: "unconfirmed", requestId: diskID)]
        try JSONEncoder().encode(ConversationWorkspace(activeID: first.id, conversations: [first, second], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))

        // A final receipt saved on disk before a quit settles the entry on reopen.
        let diskReceipt: [String: Any] = ["id": diskID, "owner": "claude", "status": "review", "task": "crashed", "finishedAt": "2026-10-23T00:00:00Z", "diff": "+recovered line\n", "steps": [[String: Any]]()]
        let diskFolder = root.appendingPathComponent("Staging/Team Workspaces/working/\(second.id.uuidString.lowercased())/claude/\(diskID)")
        try FileManager.default.createDirectory(at: diskFolder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: diskReceipt).write(to: diskFolder.appendingPathComponent("receipt.json"))

        var made: [String: HeldReplyTransport] = [:]
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in let value = HeldReplyTransport(agent); made[agent] = value; return value }, workspaceSandbox: stage)
        try check(store.storageError == nil && store.workspaceStorage.path.hasPrefix(root.path), "workspace storage is the injected synthetic sandbox, never the owner's")
        let reconciled = store.conversations.first { $0.id == second.id }?.messages.first { $0.requestId == diskID }
        try check(reconciled?.state == "completed" && reconciled?.text.contains("recovered line") == true, "launch settles an unconfirmed entry from its saved final receipt")
        try check(store.conversation.messages.first?.state == "unconfirmed", "entries without a saved final receipt stay unconfirmed")

        // A retired room's final receipt updates the existing entry by ID, in whichever conversation holds it.
        func deliver(_ receipt: [String: Any]) throws {
            let event: [String: Any] = ["type": "workspaceReceipt", "agent": receipt["owner"] ?? "codex", "receipt": receipt, "retired": true]
            store.receive(try JSONSerialization.data(withJSONObject: event), generation: UUID())
        }
        let count = store.conversation.messages.count
        try deliver(["id": runningID, "owner": "codex", "status": "active", "task": "draft"])
        try check(store.conversation.messages.first?.state == "unconfirmed", "a non-final receipt from a retired room is ignored")
        try deliver(["id": runningID, "owner": "codex", "status": "stopped", "task": "draft", "finishedAt": "2026-10-23T01:00:00Z", "diff": "+codex draft\n", "steps": [[String: Any]]()])
        try check(store.conversation.messages.first?.state == "interrupted" && store.conversation.messages.first?.text.contains("+codex draft") == true && store.conversation.messages.count == count, "final Stop receipt with diff replaces the stale entry; nothing appended")
        try deliver(["id": otherID, "owner": "eve", "status": "review", "task": "other", "finishedAt": "2026-10-23T01:00:00Z", "diff": "+eve\n", "steps": [[String: Any]]()])
        try check(store.conversations.first { $0.id == second.id }?.messages.first?.state == "completed", "a receipt for another conversation settles there")
        try deliver(["id": UUID().uuidString, "owner": "eve", "status": "review", "finishedAt": "2026-10-23T01:00:00Z"])
        try check(store.conversation.messages.count == count && store.conversations.first { $0.id == second.id }?.messages.count == 2, "an unknown receipt ID is never appended")

        // Shared artifacts: every Builder receipt state is offered to teammates.
        await store.start()
        try await wait("connected") { !store.connecting && store.seats["eve"]?.state == "connected" }
        store.conversation.messages.append(Message(author: "Builder", text: "## Staging work · Codex · active\n\nTask: still running", state: "streaming", requestId: UUID().uuidString))
        store.conversation.recipient = "eve"; store.conversation.draft = "What is everyone working on?"
        try check(store.activeReplyMessageID == nil, "no active reply before sending")
        var completionCalls = 0
        store.completionHandler = { title in if title == store.conversation.title { completionCalls += 1 } }
        store.send()
        try await wait("reply streaming") { store.activeReplyMessageID != nil }
        let active = store.conversation.messages.first { $0.id == store.activeReplyMessageID }
        try check(active?.author == "Eve" && active?.state == "streaming", "active reply identifies the teammate reply being written")
        let prompt = made["eve"]?.prompts.first ?? ""
        try check(prompt.contains("\"transcriptState\":\"streaming\"") && prompt.contains("\"transcriptState\":\"interrupted\"") && prompt.contains("\"transcriptState\":\"completed\""), "running, stopped and finished receipts are all shared with their states")
        try check(completionCalls == 0, "notification/chime completion hook waits for the whole turn")
        let preference = store.preferences.autoScrollReplies
        made["eve"]?.release()
        try await wait("reply finished") { !store.busy }
        try check(store.activeReplyMessageID == nil && store.preferences.autoScrollReplies == preference, "active reply clears when the turn settles; auto-scroll preference untouched")
        try check(completionCalls == 1, "completed turn triggers exactly one notification/chime hook without sending an OS alert")
        store.disconnect()
        print("\(checks) teammate store checks passed. Synthetic fixture: \(root.path)")
    }
}
