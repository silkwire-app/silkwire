import Foundation
import AppKit

/// Holds or fails library writes on demand, so tests control exactly when a save lands.
final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var holding = false, failNext = false, waiting: [DispatchSemaphore] = []
    private var completed = 0
    func hold() { lock.lock(); holding = true; lock.unlock() }
    func failNextWrite() { lock.lock(); failNext = true; lock.unlock() }
    func releaseAll() { lock.lock(); holding = false; let held = waiting; waiting = []; lock.unlock(); held.forEach { $0.signal() } }
    var held: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
    var completedWrites: Int { lock.lock(); defer { lock.unlock() }; return completed }
    func write(_ data: Data, _ url: URL) throws {
        lock.lock()
        let gate: DispatchSemaphore? = holding ? DispatchSemaphore(value: 0) : nil
        if let gate { waiting.append(gate) }
        lock.unlock()
        gate?.wait()
        lock.lock(); let fail = failNext; failNext = false; lock.unlock()
        if fail { throw NSError(domain: "SendSafetyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated disk failure"]) }
        try data.write(to: url, options: .atomic)
        lock.lock(); completed += 1; lock.unlock()
    }
}

/// A stand-in teammate that records, at the instant of dispatch, whether the message was already on disk.
@MainActor final class DispatchRecordingTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String, library: URL
    var dispatched: [(text: String, storedAtDispatch: Bool)] = []
    init(_ agent: String, library: URL) { self.agent = agent; self.library = library }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false); self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        let saved = (try? Data(contentsOf: library.appendingPathComponent("workspace.json"))).flatMap { try? JSONDecoder().decode(ConversationWorkspace.self, from: $0) }
        let submitted = saved?.conversations.flatMap(\.messages).first { $0.author == "Jason" && $0.requestId?.lowercased() == requestID.lowercased() }
        let stored = submitted.map { !$0.text.isEmpty && text.contains($0.text) } ?? false
        dispatched.append((text, stored))
        eventHandler?(.delta("ok"))
        eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture") }
}

@main struct SendSafetyTests {
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
        /// Counts how often the main actor gets to run during an interval; a frozen window scores ~0.
        func mainActorTicks(_ seconds: Double) async throws -> Int {
            var ticks = 0; let start = Date()
            while Date().timeIntervalSince(start) < seconds { try await Task.sleep(for: .milliseconds(50)); ticks += 1 }
            return ticks
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-send-safety-" + UUID().uuidString)
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var project = Project(); project.name = "Fixture"; project.trustedStaging = true
        var room = Conversation(); room.projectID = project.id; room.title = "Send safety"
        try JSONEncoder().encode(ConversationWorkspace(activeID: room.id, conversations: [room], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))

        var made: [String: DispatchRecordingTransport] = [:]
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in let value = DispatchRecordingTransport(agent, library: library); made[agent] = value; return value }, workspaceSandbox: stage)
        let gate = WriteGate()
        store.persistenceWriter = { data, url in try gate.write(data, url) }
        await store.start()
        try await wait("connected") { !store.connecting && store.seats["eve"]?.state == "connected" }
        store.conversation.recipient = "eve"
        let eve = { made["eve"]!.dispatched }

        // 1. Every write held until released: Send stays responsive and nothing dispatches early.
        gate.hold()
        store.conversation.draft = "First message held on disk"
        let clicked = Date(); store.send(); let sendBlocked = Date().timeIntervalSince(clicked)
        try check(sendBlocked < 0.1, "Send returns immediately while every write is held (\(String(format: "%.3f", sendBlocked)) s)")
        try check(store.busy && !store.canSend, "the turn is reserved: Send cannot be pressed twice")
        store.send()
        try check(!store.hasQueued, "a duplicate Send while saving cannot queue the same message")
        let ticks = try await mainActorTicks(1)
        try check(ticks >= 10, "window keeps running while the save is held (\(ticks) main-actor ticks in 1 s)")
        try check(eve().isEmpty && gate.held >= 1, "nothing is dispatched while the message's write is held")
        store.conversation.draft = "First message held on disk, then more typing"
        let laterAttachment = Attachment(name: "added-later.txt", mimeType: "text/plain", data: Data("added after Send".utf8))
        store.conversation.draftAttachments.append(laterAttachment)
        gate.releaseAll()
        try await wait("first turn settles") { !store.busy }
        try check(eve().count == 1 && eve()[0].storedAtDispatch, "at the instant of dispatch the message was already on disk")
        try check(store.conversation.draft == "First message held on disk, then more typing", "text typed while saving is kept when the earlier message is accepted")

        try check(store.conversation.draftAttachments.map(\.id) == [laterAttachment.id], "acceptance preserves attachments added after Send")
        store.conversation.draftAttachments = []

        // 2. Stop while the message's write is held: responsive, never dispatched, draft kept.
        gate.hold()
        store.conversation.draft = "Stop me before I go"
        store.send()
        let stopped = Date(); store.stop(); let stopBlocked = Date().timeIntervalSince(stopped)
        try check(stopBlocked < 0.1, "Stop returns immediately while the write is held")
        gate.releaseAll()
        try await wait("stop settles") { !store.busy }
        try check(eve().count == 1, "a message stopped while saving is never dispatched")
        try check(store.conversation.draft == "Stop me before I go", "the stopped message's draft is kept")
        let stoppedMessage = store.conversation.messages.last { $0.author == "Jason" }
        try check(stoppedMessage?.text == "Stop me before I go" && stoppedMessage?.state == "failed", "the stopped message is labelled Not sent")

        // 3. Room closes while the write is held: responsive, never dispatched, draft kept.
        gate.hold()
        store.conversation.draft = "Closed room message"
        store.send()
        let closing = Date(); store.disconnect(); let closeBlocked = Date().timeIntervalSince(closing)
        try check(closeBlocked < 0.1, "closing the room does not wait for held writes (\(String(format: "%.3f", closeBlocked)) s)")
        gate.releaseAll()
        try await wait("held writes drain") { gate.held == 0 }
        try await Task.sleep(for: .milliseconds(300))
        try check(eve().count == 1 && !store.busy, "a message whose room closed while saving is never dispatched")
        try check(store.conversation.draft == "Closed room message", "the closed room's draft is kept")

        // A blank/whitespace draft with an attachment receives a useful fallback.
        store.connect()
        try await wait("fallback connection") { !store.connecting && store.seats["eve"]?.state == "connected" }
        store.conversation.recipient = "eve"
        store.conversation.draft = "  \n "
        store.conversation.draftAttachments = [laterAttachment]
        store.send()
        try await wait("fallback settles") { !store.busy }
        try check(store.conversation.messages.last { $0.author == "Jason" }?.text == "Please review the attached files.", "blank draft plus attachment uses fallback text")
        try check(store.conversation.draftAttachments.isEmpty, "acceptance removes only the submitted attachment")

        gate.hold()
        store.conversation.draft = "Disconnect while saving"
        store.send()
        try await wait("disconnect write held") { gate.held > 0 }
        let beforeDisconnect = made["eve"]!.dispatched.count
        made["eve"]!.eventHandler?(.disconnected(message: "Synthetic connection lost", uncertain: false))
        gate.releaseAll()
        try await wait("disconnected save settles") { !store.busy }
        try check(made["eve"]!.dispatched.count == beforeDisconnect && store.conversation.draft == "Disconnect while saving", "provider loss during saving prevents dispatch and preserves text")
        try check(store.status.contains("disconnected"), "disconnected send rejection reports the real cause")
        store.disconnect()

        store.connect()
        try await wait("revocation connection") { !store.connecting && store.seats["eve"]?.state == "connected" }
        store.conversation.recipient = "eve"; store.conversation.draft = "Revoked while saving"
        gate.hold(); store.send()
        try await wait("revocation write held") { gate.held > 0 }
        let beforeRevoke = made["eve"]!.dispatched.count
        let revocation = Task { @MainActor in await store.revokeStagingAccess(project.id) }
        await Task.yield()
        try check(!store.busy && !store.trustsStaging(store.activeProject!), "revocation blocks pending work before awaiting persistence")
        gate.releaseAll(); await revocation.value
        try await Task.sleep(for: .milliseconds(100))
        try check(made["eve"]!.dispatched.count == beforeRevoke && store.conversation.draft == "Revoked while saving", "revoking access during save prevents a late dispatch")

        // 4. The message's write fails: never dispatched, draft kept, sending paused with a reason.
        store.connect()
        try await wait("reconnected") { !store.connecting && store.seats["eve"]?.state == "connected" }
        store.conversation.recipient = "eve"
        let before = made["eve"]!.dispatched.count
        gate.failNextWrite()
        store.conversation.draft = "This save will fail"
        store.send()
        try await wait("failed save settles") { !store.busy }
        try check(made["eve"]!.dispatched.count == before, "a message that could not be saved is never dispatched")
        try check(store.conversation.draft == "This save will fail" && store.storageError != nil, "failed save keeps the draft and pauses sending with a reason")
        store.disconnect()
        let queueLibrary = root.appendingPathComponent("failed-addition")
        var queueTransports: [String: DispatchRecordingTransport] = [:]
        let queueStore = ConversationStore(directory: queueLibrary, transportFactory: { agent, _ in
            let value = DispatchRecordingTransport(agent, library: queueLibrary); queueTransports[agent] = value; return value
        }, workspaceSandbox: stage)
        queueStore.connect()
        try await wait("failed queue connection") { !queueStore.connecting && queueStore.seats["eve"]?.state == "connected" }
        let drained = await queueStore.saveDurably(); try check(drained, "queue failure fixture starts with a durable snapshot")
        queueStore.persistenceWriter = { _, _ in throw nativeFailure("Synthetic persistent disk failure") }
        queueStore.conversation.recipient = "eve"; queueStore.conversation.draft = "Initial failed message"
        queueStore.send(); queueStore.conversation.draft = "Later addition must remain visible"; queueStore.send()
        try await wait("failed queued addition settles") { !queueStore.busy && queueStore.storageError != nil }
        try check(!queueStore.hasQueued && queueStore.conversation.draft.contains("Later addition must remain visible") && queueTransports["eve"]!.dispatched.isEmpty, "failed persistence restores queued text to the composer and dispatches neither message")
        queueStore.disconnect()
        print("\(checks) send safety checks passed. Synthetic fixture: \(root.path)")
    }
}
