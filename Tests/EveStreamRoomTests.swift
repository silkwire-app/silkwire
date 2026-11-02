import Foundation
import AppKit

// Real room/store path with private on-disk fixtures and synthetic provider events.
@MainActor final class EveStreamProbeTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    func connect(_ previous: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = previous ?? ProviderIdentity(id: UUID().uuidString, started: false)
        identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws { prompts.append(text) }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic fixture") }
}

@MainActor @main struct EveStreamRoomTests {
    static var checks = 0, failures = 0
    static func check(_ value: Bool, _ label: String) {
        checks += 1
        if value { print("PASS: " + label) } else { failures += 1; print("FAIL: " + label) }
    }
    static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw nativeFailure("Fixture timeout: " + label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func probe(_ scenario: String, root: URL) async throws {
        let directory = root.appendingPathComponent(scenario)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var project = Project(); project.name = "Synthetic retention fixture"
        var conversation = Conversation(); conversation.projectID = project.id
        try JSONEncoder().encode(ConversationWorkspace(activeID: conversation.id, conversations: [conversation], projects: [project])).write(to: directory.appendingPathComponent("workspace.json"))
        let sandbox = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("isolated-staging"))
        var transports: [String: EveStreamProbeTransport] = [:]
        let store = ConversationStore(directory: directory, transportFactory: { agent, _ in
            let transport = EveStreamProbeTransport(); transports[agent] = transport; return transport
        }, workspaceSandbox: sandbox)
        defer { store.disconnect() }
        await store.start()
        try await wait("connected") { !store.connecting && store.seats["eve"]?.state == "connected" }
        store.conversation.recipient = "eve"
        store.conversation.draft = "Synthetic stream retention check"
        store.send()
        try await wait("dispatch") { transports["eve"]?.prompts.count == 1 }
        guard let transport = transports["eve"] else { throw nativeFailure("Missing transport") }
        let preview = "Already-visible reply text"
        transport.eventHandler?(.delta(preview))
        try await wait("published") { store.conversation.messages.last(where: { $0.author == "Eve" })?.text == preview }
        guard let original = store.conversation.messages.last(where: { $0.author == "Eve" }) else { throw nativeFailure("Missing reply") }
        transport.eventHandler?(.replace("")); transport.eventHandler?(.replace(""))
        try await Task.sleep(for: .milliseconds(50))
        let pending = store.conversation.messages.last(where: { $0.author == "Eve" })
        check(pending?.text == preview, scenario + ": empty updates cannot erase visible prose")
        check(pending?.id == original.id && pending?.state == "streaming" && store.busy, scenario + ": identity and streaming state remain stable")
        var expectedText = preview, expectedState = scenario
        switch scenario {
        case "completed":
            expectedText = preview + " — final"
            transport.eventHandler?(.replace(expectedText))
            transport.eventHandler?(.finished(status: "completed", message: nil))
        case "new-answer":
            expectedText = "New answer only"; expectedState = "completed"
            transport.eventHandler?(.delta(expectedText))
            transport.eventHandler?(.finished(status: "completed", message: nil))
        case "empty-completion":
            expectedState = "failed"
            transport.eventHandler?(.finished(status: "completed", message: nil))
        case "interrupted": store.stop()
        default: transport.eventHandler?(.finished(status: "failed", message: "Synthetic failure"))
        }
        try await wait("settlement") { !store.busy }
        let final = store.conversation.messages.last(where: { $0.author == "Eve" })
        check(final?.text == expectedText, scenario + ": correct retained or replacement text after settlement")
        check(final?.id == original.id && final?.state == expectedState, scenario + ": original message gets the honest terminal state")
        check(transport.prompts.count == 1, scenario + ": no duplicate dispatch")
        check(store.conversation.messages.filter { $0.author == "Eve" }.count == 1, scenario + ": no duplicate reply bubble")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-stream-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for scenario in ["completed", "interrupted", "failed", "new-answer", "empty-completion"] { try await probe(scenario, root: root) }
        print("EveStreamRoomTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
