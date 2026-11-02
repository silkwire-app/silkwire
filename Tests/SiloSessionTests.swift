import Foundation
import AppKit

@MainActor final class IdleSiloProbe: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var closes = 0
    var sends = 0
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: "synthetic-idle-" + UUID().uuidString, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        sends += 1
        eventHandler?(.delta("synthetic result"))
        eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws {}
    func stopPrevious() async throws {}
    func close() { closes += 1 }
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic only") }
}

@main struct SiloSessionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; setbuf(stdout, nil)
        // Disable the unrelated automatic usage inspection in this synthetic
        // session-lifetime fixture; it otherwise creates extra probe transports.
        setenv("SILKWIRE_ACCEPTANCE", "design-idle-test", 1)
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("output/tests/idle-silos-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        var project = Project(); project.participants = ["eve"]
        var rooms: [Conversation] = []
        for index in 0..<6 {
            var room = Conversation(); room.projectID = project.id; room.focusedAgent = "eve"; room.recipient = "eve"
            room.title = "Silo \(index)"; room.draft = "draft \(index)"
            room.messages = [Message(author: "Jason", text: "history \(index)", state: "sent")]
            rooms.append(room)
        }
        var workspace = ConversationWorkspace(activeID: rooms[0].id, conversations: rooms, projects: [project])
        workspace.environment = "staging"
        try JSONEncoder().encode(workspace).write(to: root.appendingPathComponent("workspace.json"))
        let environment = WorkspaceEnvironment(staging: true, library: root)
        var probes: [IdleSiloProbe] = []
        let store = ConversationStore(directory: root, transportFactory: { _, _ in
            let probe = IdleSiloProbe(); probes.append(probe); return probe
        }, environment: environment, workspaceSandbox: environment)
        defer { store.disconnect() }
        func ready() async throws {
            let deadline = Date().addingTimeInterval(15)
            while store.connecting { guard Date() < deadline else { throw nativeFailure("Synthetic connection timeout") }; try await Task.sleep(for: .milliseconds(10)) }
            precondition(store.seats["eve"]?.state == "connected")
            // Let terminal readiness/identity callbacks settle before parking.
            try await Task.sleep(for: .milliseconds(50))
        }
        await store.start(); try await ready()
        let a = probes[0]
        store.conversation.draft = "A edited"
        precondition(store.selectConversation(rooms[1].id)); try await ready()
        precondition(a.closes == 0 && probes.count == 2, "switch parks the connected outgoing room")
        let b = probes[1]
        precondition(store.selectConversation(rooms[0].id))
        precondition(!store.connecting && probes.count == 2 && a.closes == 0 && b.closes == 0, "return reuses A without starting a provider")
        precondition(store.conversation.draft == "A edited" && store.conversation.messages.map(\.text) == ["history 0"])
        precondition(store.selectConversation(rooms[1].id))
        precondition(!store.connecting && probes.count == 2 && store.conversation.draft == "draft 1")
        store.busy = true
        precondition(!store.selectConversation(rooms[0].id), "in-flight replies still cannot change owners")
        store.busy = false
        // An inactive connection/data event must never mutate B. The old room
        // is invalidated, then reconnects instead of restoring stale readiness.
        a.eventHandler?(.delta("FOREIGN LATE TEXT"))
        a.eventHandler?(.disconnected(message: "Synthetic idle connection ended", uncertain: false))
        try await Task.sleep(for: .milliseconds(50))
        precondition(store.conversation.id == rooms[1].id && store.conversation.messages.map(\.text) == ["history 1"])
        precondition(store.selectConversation(rooms[0].id)); try await ready()
        precondition(probes.count == 3 && a.closes > 0, "late inactive event invalidates cache")
        let beforeEdit = probes.count
        var edited = store.activeProject!; edited.brief = "Changed grant context"
        precondition(store.updateProject(edited)); try await ready()
        precondition(b.closes > 0, "Project changes revoke hidden rooms too")
        precondition(store.selectConversation(rooms[1].id)); try await ready()
        precondition(probes.count >= beforeEdit + 2, "revoked room requires fresh initialization")
        precondition(store.archiveConversation(rooms[0].id))
        for index in 2..<6 { precondition(store.selectConversation(rooms[index].id)); try await ready() }
        precondition(probes.filter { $0.closes == 0 }.count <= 4, "cache bounds retained idle rooms to three plus active")
        store.disconnect()
        precondition(probes.allSatisfy { $0.closes > 0 }, "explicit disconnect closes all cached providers")
        precondition(probes.allSatisfy { $0.sends == 0 }, "navigation never sends or replays messages")
        print("PASS warm return avoids reconnect; drafts/history stay isolated; busy navigation is refused; late events, Project edits, archive, bounded eviction and explicit disconnect safely invalidate idle rooms")
    }
}
