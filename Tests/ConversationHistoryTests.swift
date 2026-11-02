import Foundation
import AppKit

// End-to-end regression for the screen -> native room -> synthetic transport path.
// Forty short messages fit comfortably within the existing prompt allowance;
// their age alone must not make an earlier decision disappear.
@MainActor final class HistoryProbeTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false)
        self.identity = value
        return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        eventHandler?(.delta("Synthetic history check complete."))
        eventHandler?(.finished(status: "completed", message: nil))
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport: no account inspection") }
}

@main struct ConversationHistoryTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) }
            else { failures += 1; print("FAIL: " + label) }
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(30)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-history-" + UUID().uuidString)
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var project = Project()
        project.name = "Synthetic history regression"
        var conversation = Conversation()
        conversation.projectID = project.id
        conversation.recipient = "eve"
        conversation.messages = (0..<40).map { index in
            Message(author: index % 2 == 0 ? "Jason" : "Eve", text: "HISTORY-ITEM-\(index)-END", state: index % 2 == 0 ? "sent" : "completed", requestId: UUID().uuidString)
        }
        conversation.messages.append(Message(author: "Eve", text: "FAILED-REPLY-MUST-NOT-BECOME-MEMORY", state: "failed", requestId: UUID().uuidString))
        conversation.messages.append(Message(author: "Eve", text: "UNCONFIRMED-REPLY-MUST-NOT-BECOME-MEMORY", state: "unconfirmed", requestId: UUID().uuidString))
        let originalMessages = conversation.messages
        try JSONEncoder().encode(ConversationWorkspace(activeID: conversation.id, conversations: [conversation], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))
        var transports: [String: HistoryProbeTransport] = [:]
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in
            let transport = HistoryProbeTransport()
            transports[agent] = transport
            return transport
        }, workspaceSandbox: stage)
        defer { store.disconnect() }
        check(store.storageError == nil, "synthetic library opens without changing the owner's library")
        guard store.storageError == nil else { exit(1) }
        await store.start()
        try await wait("synthetic connection") { !store.connecting && store.seats["eve"]?.state == "connected" }
        store.conversation.recipient = "eve"
        store.conversation.draft = "CURRENT-HISTORY-REQUEST-TOKEN"
        check(store.canSend, "synthetic request can be sent")
        store.send()
        try await wait("synthetic reply") { transports["eve"]?.prompts.isEmpty == false && !store.busy }
        let prompts = transports["eve"]?.prompts ?? []
        let prompt = prompts.first ?? ""
        check(prompts.count == 1, "one send produces exactly one synthetic prompt")
        check(prompt.contains("HISTORY-ITEM-0-END"), "decision older than 30 messages survives the complete send path")
        check(prompt.contains("HISTORY-ITEM-8-END"), "history is not discarded solely because of message count")
        check(prompt.contains("HISTORY-ITEM-39-END"), "most recent eligible history remains available")
        check(prompt.contains("CURRENT-HISTORY-REQUEST-TOKEN"), "current request remains available")
        check(!prompt.contains("FAILED-REPLY-MUST-NOT-BECOME-MEMORY") && !prompt.contains("UNCONFIRMED-REPLY-MUST-NOT-BECOME-MEMORY"), "failed and unconfirmed replies are not promoted into working history")
        let preserved = store.conversation.messages.prefix(originalMessages.count)
        check(preserved.map(\.id) == originalMessages.map(\.id) && preserved.map(\.text) == originalMessages.map(\.text), "preparing agent context does not delete or rewrite original transcript messages")
        print("ConversationHistoryTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
