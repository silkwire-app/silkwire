import Foundation

final class SustainedDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var savedRequests = Set<String>()
    private var count = 0
    var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return savedRequests.contains(id.lowercased()) }
    func write(_ bytes: Data, _ file: URL) throws {
        precondition(!Thread.isMainThread, "Validation/encoding/write must stay off-main")
        // Every successive write is slow, including critical and lifecycle saves.
        Thread.sleep(forTimeInterval: 1.2)
        try bytes.write(to: file, options: .atomic)
        let saved = try JSONDecoder().decode(ConversationWorkspace.self, from: bytes)
        let ids = saved.conversations.flatMap(\.messages).filter { $0.author == "Jason" }.compactMap(\.requestId)
        lock.lock(); savedRequests = Set(ids.map { $0.lowercased() }); count += 1; lock.unlock()
    }
}
@MainActor final class SustainedTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let disk: SustainedDisk
    var sends = 0
    var savedAtDispatch = false
    init(disk: SustainedDisk) { self.disk = disk }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false); self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        sends += 1; savedAtDispatch = disk.contains(requestID)
        eventHandler?(.delta("Measured fixture reply\n<<REMEMBER {\"kind\":\"done\",\"text\":\"Synthetic responsiveness check completed\"}>>"))
        eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic fixture") }
}
@main struct SustainedPersistenceTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-sustained-" + UUID().uuidString)
        let disk = SustainedDisk()
        var transport: SustainedTransport!
        let store = ConversationStore(directory: root, transportFactory: { _, _ in
            let made = SustainedTransport(disk: disk); transport = made; return made
        }, workspaceSandbox: WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging")))
        store.connect()
        for _ in 0..<300 where store.connecting { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!store.connecting)
        store.conversation.recipient = "codex"
        let image = Data(repeating: 77, count: 1_536_000)
        store.conversation.messages = (0..<170).map { index in
            Message(author: "Codex", text: "Synthetic image-heavy history \(index)", state: "completed", attachments: [Attachment(name: "image-\(index).png", mimeType: "image/png", data: image)])
        }
        let initialSaved = await store.saveDurably(); precondition(initialSaved)
        let file = root.appendingPathComponent("workspace.json")
        let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).intValue
        precondition(bytes >= 330 * 1024 * 1024, "Fixture must match the reported 332 MiB library")
        store.persistenceWriter = { try disk.write($0, $1) }
        var gaps: [Double] = [], edits: [Double] = []
        let ticker = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                let now = ProcessInfo.processInfo.systemUptime; gaps.append((now - previous) * 1000); previous = now
            }
        }
        let began = ProcessInfo.processInfo.systemUptime
        for index in 0..<160 {
            let editStart = ProcessInfo.processInfo.systemUptime
            store.conversation.draft = "Sustained typing \(index)"; store.scheduleSave()
            edits.append((ProcessInfo.processInfo.systemUptime - editStart) * 1000)
            try await Task.sleep(for: .milliseconds(50))
        }
        let backgroundWrites = disk.writes
        store.conversation.draft = "A short submitted message under sustained persistence"
        let sendStart = ProcessInfo.processInfo.systemUptime
        store.send()
        let sendHandlerMs = (ProcessInfo.processInfo.systemUptime - sendStart) * 1000
        store.conversation.draft += " plus later typing"
        let deadline = Date().addingTimeInterval(90)
        while store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let sendLatency = ProcessInfo.processInfo.systemUptime - sendStart
        precondition(!store.busy && transport.sends == 1 && transport.savedAtDispatch, "Dispatch must follow its successfully completed atomic write")
        precondition(store.conversation.draft.hasSuffix("plus later typing"))
        let finalSaved = await store.saveDurably(); precondition(finalSaved)
        ticker.cancel(); await ticker.value
        let sorted = gaps.sorted(), maxGap = sorted.last ?? 0
        let result: [String: Any] = ["libraryBytes": bytes, "successiveWriteDelaySeconds": 1.2, "backgroundWritesDuringTyping": backgroundWrites, "totalWrites": disk.writes,
            "edits": edits.count, "maxEditHandlerMs": edits.max() ?? 0, "sendHandlerMs": sendHandlerMs, "sendPersistenceAndReplyLatencySeconds": sendLatency,
            "maxMainActorGapMs": maxGap, "p95MainActorGapMs": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)], "mainActorSamples": gaps.count,
            "durationSeconds": ProcessInfo.processInfo.systemUptime - began,
            "scope": "patched store and room, synthetic library and fake connected transport; no mounted-window or live-provider performance claim"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        precondition(backgroundWrites <= 6 && disk.writes <= 10, "Obsolete background snapshots must not accumulate")
        precondition(sendHandlerMs < 100 && maxGap < 250, "UI actor must stay responsive, including memory/lifecycle saves")
        print("PASS sustained slow persistence with a 332 MiB synthetic image-heavy library")
        store.disconnect(persist: false)
    }
}
