import Foundation
import AppKit

@MainActor final class FocusReviewTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String
    var prompts: [String] = []
    init(_ agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: "synthetic-focus-" + agent + "-" + UUID().uuidString, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        try await Task.sleep(for: .milliseconds(40))
        eventHandler?(.delta("Synthetic focused reply from " + agent))
        eventHandler?(.finished(status: "completed", message: nil))
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport only") }
}

// Exercises the actual menu action -> store -> room -> transport path after
// combining Claude C73EFF9F and Eve FE920FD1. No provider accounts or live chats.
@main struct FocusedConversationReviewTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = Date().addingTimeInterval(30)
            while !predicate() {
                guard Date() < end else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("output/tests/focused-review-" + UUID().uuidString)
        let library = root.appendingPathComponent("library")
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let sandbox = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        var project = Project(); project.name = "Synthetic focused review"
        var team = Conversation(); team.projectID = project.id; team.recipient = "eve,claude,codex"
        team.draft = "TEAM-DRAFT-KEEP-281"
        team.messages = [Message(author: "Jason", text: "TEAM-HISTORY-ONLY-672", state: "sent"), Message(author: "Claude", text: "TEAM-REPLY-KEEP-289", state: "completed")]
        for agent in agents { team.identities[agent] = ProviderIdentity(id: "synthetic-team-" + agent, started: true) }
        let teamIDs = team.identities.mapValues(\.id)
        let workspaceURL = library.appendingPathComponent("workspace.json")
        try JSONEncoder().encode(ConversationWorkspace(activeID: team.id, conversations: [team], projects: [project])).write(to: workspaceURL)
        var transports: [FocusReviewTransport] = []
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in
            let t = FocusReviewTransport(agent); transports.append(t); return t
        }, workspaceSandbox: sandbox)
        defer { store.disconnect() }
        guard store.storageError == nil else { throw nativeFailure("Synthetic library did not open") }
        await store.start()
        try await wait("team connection") { !store.connecting && agents.allSatisfy { store.seats[$0]?.state == "connected" } }
        let initialCount = store.conversations.count
        check(!store.newFocusedChat(with: "unknown-provider") && store.conversations.count == initialCount, "invalid focused-chat target creates nothing")
        var focusIDs: [String: UUID] = [:], sessionIDs: [String: String] = [:]
        for agent in ["claude", "eve", "codex"] {
            let beforeTransports = transports.count
            check(store.newFocusedChat(with: agent), "\(agent): focused-chat menu action creates a conversation")
            let id = store.conversation.id; focusIDs[agent] = id
            check(id != team.id && store.conversation.projectID == project.id && store.conversation.recipient == agent, "\(agent): new identity stays in this Project and targets only the chosen agent")
            check(store.conversation.messages.isEmpty && store.conversation.draft.isEmpty, "\(agent): team transcript and unsent draft are not copied")
            try await wait("focused connection") { !store.connecting && store.seats[agent]?.state == "connected" }
            let session = store.conversation.identities[agent]?.id ?? ""
            sessionIDs[agent] = session
            check(!session.isEmpty && session != teamIDs[agent], "\(agent): provider session is separate from the team session")
            let marker = "FOCUS-ONLY-" + agent + "-397"
            store.conversation.draft = marker
            store.send()
            check(store.busy && !store.newFocusedChat(with: "claude") && store.conversation.id == id, "\(agent): opening another chat cannot abandon an active reply")
            try await wait("focused reply") { !store.busy }
            let newTransports = Array(transports.dropFirst(beforeTransports))
            let sent = newTransports.filter { !$0.prompts.isEmpty }
            check(sent.count == 1 && sent.first?.agent == agent && sent.first?.prompts.count == 1, "\(agent): exactly one send reaches only the selected teammate")
            let prompt = sent.first?.prompts.first ?? ""
            check(prompt.contains("FOCUSED CHAT:") && !prompt.contains("COLLAB ROOM RULES:"), "\(agent): real focused-chat action activates focused instructions, not team deduplication")
            check(!prompt.contains("TEAM-HISTORY-ONLY-672") && !prompt.contains("TEAM-DRAFT-KEEP-281"), "\(agent): focused prompt excludes team transcript and draft")
            check(!["claude", "eve", "codex"].filter { $0 != agent }.contains { prompt.contains("FOCUS-ONLY-" + $0 + "-397") }, "\(agent): focused prompt excludes other focused chats")
            store.conversation.draft = "DRAFT-ONLY-" + agent
        }
        check(Set(focusIDs.values).count == 3 && Set(sessionIDs.values).count == 3, "each focused conversation and selected provider session has its own identity")
        check(store.selectConversation(team.id), "team conversation can be reopened")
        try await wait("team reconnect") { !store.connecting }
        check(store.conversation.messages.map(\.id) == team.messages.map(\.id) && store.conversation.messages.map(\.text) == team.messages.map(\.text), "focused work preserves the original team transcript byte-for-byte")
        check(store.conversation.draft == team.draft && store.conversation.identities.mapValues(\.id) == teamIDs, "team draft and all original provider identities survive focused work")
        // Addressing one teammate in a team conversation is not a focused room.
        store.conversation.recipient = "claude"
        store.conversation.draft = "TEAM-SINGLE-RECIPIENT-442"
        let beforeTeamSend = transports.flatMap(\.prompts).count
        store.send(); try await wait("single-target team reply") { !store.busy }
        let teamPrompt = transports.flatMap(\.prompts).dropFirst(beforeTeamSend).last ?? ""
        check(teamPrompt.contains("COLLAB ROOM RULES:") && !teamPrompt.contains("FOCUSED CHAT:"), "single-target message in a team conversation retains team-room rules")
        check(teamPrompt.contains("TEAM-HISTORY-ONLY-672") && !teamPrompt.contains("FOCUS-ONLY-"), "team prompt retains its own history without importing focused transcripts")
        for agent in ["claude", "eve", "codex"] {
            check(store.selectConversation(focusIDs[agent]!), "\(agent): focused conversation reopens")
            try await wait("focused reconnect") { !store.connecting }
            check(store.conversation.recipient == agent && store.conversation.identities[agent]?.id == sessionIDs[agent] && store.conversation.draft == "DRAFT-ONLY-" + agent, "\(agent): recipient, session and independent draft survive switching")
        }
        check(store.save(), "focused conversations are saved before reopening fixture data")
        let saved = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: workspaceURL))
        check(saved.conversations.count == initialCount + 3, "saved workspace contains one team chat plus three focused chats")
        check(focusIDs.allSatisfy { agent, id in saved.conversations.contains { $0.id == id && $0.recipient == agent && $0.identities[agent]?.id == sessionIDs[agent] && $0.draft == "DRAFT-ONLY-" + agent } }, "persisted focused transcripts, recipients, drafts and provider sessions remain associated with the correct chat")
        print("FocusedConversationReviewTests: \(checks) checks, \(failures) failures; synthetic transports only")
        if failures > 0 { exit(1) }
    }
}
