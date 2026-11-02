import Foundation
import AppKit

@MainActor final class RemovalProbeTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String
    var prompts: [String] = []
    var didConnect = false
    init(_ agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        didConnect = true
        let value = identity ?? ProviderIdentity(id: "synthetic-removal-" + UUID().uuidString, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        eventHandler?(.delta("Synthetic response"))
        eventHandler?(.finished(status: "completed", message: nil))
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic only") }
}

@main struct FocusedParticipantRemovalTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ label: String) { checks += 1; if ok { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) } }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = Date().addingTimeInterval(30)
            while !predicate() { guard Date() < end else { throw nativeFailure("Timed out: " + label) }; try await Task.sleep(for: .milliseconds(10)) }
        }
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("output/tests/focused-removal-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let sandbox = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        for agent in agents {
            let library = root.appendingPathComponent(agent)
            try files.createDirectory(at: library, withIntermediateDirectories: true)
            var project = Project(); project.name = "Synthetic removal"
            var chat = Conversation(); chat.projectID = project.id; chat.focusedAgent = agent; chat.recipient = agent
            chat.draft = "FOCUSED-DRAFT-KEEP-291"
            chat.messages = [Message(author: "Jason", text: "FOCUSED-HISTORY-ONLY-582", state: "sent"), Message(author: names[agent]!, text: "Earlier synthetic reply", state: "completed")]
            chat.identities[agent] = ProviderIdentity(id: "synthetic-original-" + agent, started: true)
            let file = library.appendingPathComponent("workspace.json")
            try JSONEncoder().encode(ConversationWorkspace(activeID: chat.id, conversations: [chat], projects: [project])).write(to: file)
            var transports: [RemovalProbeTransport] = []
            let store = ConversationStore(directory: library, transportFactory: { who, _ in let t = RemovalProbeTransport(who); transports.append(t); return t }, workspaceSandbox: sandbox)
            await store.start()
            try await wait("initial focused connection") { !store.connecting }
            check(transports.filter(\.didConnect).map(\.agent) == [agent], "\(agent): valid focused chat initially connects only its teammate")
            for other in project.participants where other != agent { store.toggleRecipient(other) }
            check(store.conversation.recipient == agent && store.targets == [agent], "\(agent): available focused chat also refuses recipient broadening")
            store.conversation.recipient = "team"
            check(store.targets == [agent], "\(agent): stale team recipient cannot override the saved focused teammate")
            store.conversation.recipient = agent
            let beforeRemoval = transports.filter(\.didConnect).count
            var removed = store.activeProject!; removed.participants.removeAll { $0 == agent }
            check(store.updateProject(removed), "\(agent): participant removal saves through the real Project editor path")
            try await wait("removed participant reconnect") { !store.connecting }
            check(transports.filter(\.didConnect).count == beforeRemoval, "\(agent): removing its teammate creates no replacement team connections")
            check(agents.allSatisfy { store.seats[$0]?.state != "connected" }, "\(agent): removed focused chat leaves every provider disconnected")
            check(store.status.localizedCaseInsensitiveContains("unavailable"), "\(agent): unavailable focused chat has an explicit explanation")
            for other in removed.participants { store.toggleRecipient(other) }
            check(store.conversation.recipient == agent && store.targets.isEmpty && !store.canSend && !store.canPass, "\(agent): recipient toggles cannot turn the unavailable focused chat into a team chat")
            store.send(); try await wait("blocked send") { !store.busy }
            check(transports.allSatisfy { $0.prompts.isEmpty }, "\(agent): no focused history is dispatched to another teammate")
            check(store.conversation.draft == chat.draft && store.conversation.messages.map(\.id) == chat.messages.map(\.id), "\(agent): blocked send preserves unsent draft and original transcript")
            // Preserve the intended recipient even on the pre-fix reproduction path.
            store.conversation.recipient = agent; _ = store.save()
            let saved = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: file))
            check(saved.conversations.first?.focusedAgent == agent && saved.conversations.first?.identities[agent]?.id == chat.identities[agent]?.id, "\(agent): unavailable chat retains its focused marker and original provider identity")
            let copy = root.appendingPathComponent(agent + "-reopen")
            try files.createDirectory(at: copy, withIntermediateDirectories: true)
            try files.copyItem(at: file, to: copy.appendingPathComponent("workspace.json"))
            var reopenedConnections: [String] = []
            let reopened = ConversationStore(directory: copy, transportFactory: { who, _ in reopenedConnections.append(who); return RemovalProbeTransport(who) }, workspaceSandbox: sandbox)
            await reopened.start(); try await wait("unavailable reopen") { !reopened.connecting }
            check(reopenedConnections.isEmpty && reopened.targets.isEmpty && reopened.status.localizedCaseInsensitiveContains("unavailable"), "\(agent): restarting an unavailable focused chat also fails closed")
            reopened.disconnect()
            var restored = store.activeProject!; restored.participants = project.participants
            check(store.updateProject(restored), "\(agent): deliberately restoring Project membership succeeds")
            try await wait("restored focus") { !store.connecting }
            check(transports.filter(\.didConnect).dropFirst(beforeRemoval).map(\.agent) == [agent] && store.seats[agent]?.state == "connected" && store.targets == [agent], "\(agent): restoration reconnects only the intended teammate")
            check(store.conversation.identities[agent]?.id == chat.identities[agent]?.id, "\(agent): restoration resumes the same focused session")
            store.disconnect()
        }
        for marker in ["", "unknown-provider"] {
            let library = root.appendingPathComponent("invalid-" + UUID().uuidString)
            try files.createDirectory(at: library, withIntermediateDirectories: true)
            let project = Project()
            var chat = Conversation(); chat.projectID = project.id; chat.focusedAgent = marker; chat.recipient = "team"; chat.draft = "DO-NOT-BROADCAST"
            try JSONEncoder().encode(ConversationWorkspace(activeID: chat.id, conversations: [chat], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))
            var connected: [String] = []
            let store = ConversationStore(directory: library, transportFactory: { who, _ in connected.append(who); return RemovalProbeTransport(who) }, workspaceSandbox: sandbox)
            await store.start(); try await wait("invalid focus") { !store.connecting }
            check(connected.isEmpty && store.targets.isEmpty && !store.canSend, "invalid focused marker '\(marker)' never falls back to team routing")
            check(store.conversation.focusedAgent == marker && store.conversation.draft == chat.draft, "invalid focused marker and draft remain intact for explicit repair")
            store.disconnect()
        }
        print("FocusedParticipantRemovalTests: \(checks) checks, \(failures) failures; synthetic transports only")
        if failures > 0 { exit(1) }
    }
}
