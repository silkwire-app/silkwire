import Foundation

// Stop while teammates are mid-operation on the open floor (Eve's review of 7D642AF5).
// Eve asks for a web inspection; Codex keeps typing; Claude never answers. Stop must end
// everyone, and the room must take the next message.
@MainActor final class StopFloorTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    let agent: String
    var mode: String
    var stopped = 0
    init(_ agent: String, mode: String) { self.agent = agent; self.mode = mode }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = ProviderIdentity(id: "fixture-" + agent, started: false)
        self.identity = value
        return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        let current = mode, followUp = text.contains("WEB INSPECTION RESULT")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard let self else { return }
            switch current {
            case "web" where !followUp:
                self.eventHandler?(.delta("<<INSPECT_WEB {\"url\":\"https://staging.silkwire.app/\",\"steps\":[{\"wait\":5000}]}>>"))
                self.eventHandler?(.finished(status: "completed", message: nil))
            case "stream":
                self.eventHandler?(.delta("Still thinking"))
            case "silent":
                break
            default:
                self.eventHandler?(.delta(self.agent + " reply"))
                self.eventHandler?(.finished(status: "completed", message: nil))
            }
        }
    }
    func stop() async throws {
        stopped += 1
        eventHandler?(.finished(status: "interrupted", message: "Stopped by Jason"))
    }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture") }
}

@main struct OpenFloorStopTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL: " + label) }
            checks += 1; print("PASS " + label)
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Fixture timed out") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        var events: [[String: Any]] = [], transports: [String: StopFloorTransport] = [:]
        let modes = ["eve": "web", "codex": "stream", "claude": "silent"]
        let room = NativeRoom(emit: { events.append($0) }, factory: { agent, _ in
            let transport = StopFloorTransport(agent, mode: modes[agent] ?? "reply"); transports[agent] = transport; return transport
        })
        defer { room.close() }
        await room.dispatch(["action": "connect", "conversationID": UUID().uuidString.lowercased(), "participants": ["eve", "claude", "codex"], "projectFolders": [[String: String]]()])
        try await wait { transports.count == 3 && events.filter { $0["type"] as? String == "connection" && $0["state"] as? String == "connected" }.count >= 3 }
        func of(_ id: String, _ type: String) -> [[String: Any]] { events.filter { $0["requestId"] as? String == id && $0["type"] as? String == type } }
        func send(_ openFloor: Bool) async -> String {
            let id = UUID().uuidString
            await room.dispatch(["action": "send", "requestId": id, "text": "Synthetic stop task", "targets": ["eve", "claude", "codex"], "history": [[String: String]](), "historyTotal": 0, "openFloor": openFloor])
            return id
        }

        let first = await send(true)
        try await wait { events.contains { $0["requestId"] as? String == first && $0["type"] as? String == "activity" && $0["agent"] as? String == "eve" } }
        try await wait { !(transports["codex"]?.prompts.isEmpty ?? true) && !(transports["claude"]?.prompts.isEmpty ?? true) }
        try await Task.sleep(for: .milliseconds(60))
        try check(of(first, "settled").isEmpty, "the room is still busy while a web inspection runs")
        await room.dispatch(["action": "stop"])
        try await wait { !of(first, "settled").isEmpty }
        let finished = of(first, "finished")
        try check(Set(finished.compactMap { $0["agent"] as? String }) == ["eve", "claude", "codex"], "Stop ends every teammate, including one in a web inspection")
        try check(finished.count == 3, "each teammate ends exactly once")
        print("statuses: " + finished.map { ($0["agent"] as? String ?? "") + "=" + ($0["status"] as? String ?? "") }.joined(separator: ", "))
        // In this sandbox the page check can fail fast and Eve may finish before Stop arrives.
        try check(finished.filter { ["claude", "codex"].contains($0["agent"] as? String ?? "") }.allSatisfy { $0["status"] as? String == "interrupted" }, "teammates still working are labelled interrupted")
        try check(finished.allSatisfy { ["interrupted", "completed"].contains($0["status"] as? String ?? "") }, "no reply ends as failed or unconfirmed")
        try check(of(first, "settled").count == 1, "the room settles once")
        try await Task.sleep(for: .milliseconds(200))
        try check(of(first, "finished").count == 3 && of(first, "settled").count == 1, "nothing finishes late after Stop")

        for (agent, item) in transports { item.mode = agent == "eve" ? "reply" : "reply" }
        let next = await send(true)
        try await wait { !of(next, "settled").isEmpty || !of(next, "rejected").isEmpty }
        try check(of(next, "rejected").isEmpty, "the room accepts the next message after Stop")
        try check(of(next, "finished").filter { $0["status"] as? String == "completed" }.count == 3, "all three teammates answer the next message")

        for item in transports.values { item.mode = "silent" }
        transports["eve"]?.mode = "web"
        let turns = await send(false)
        try await wait { events.contains { $0["requestId"] as? String == turns && $0["type"] as? String == "activity" && $0["agent"] as? String == "eve" } }
        try await Task.sleep(for: .milliseconds(60))
        await room.dispatch(["action": "stop"])
        try await wait { !of(turns, "settled").isEmpty }
        try check(of(turns, "finished").count == 3, "turn-taking Stop during a web inspection still ends everyone once")
        for item in transports.values { item.mode = "reply" }
        let after = await send(false)
        try await wait { !of(after, "settled").isEmpty || !of(after, "rejected").isEmpty }
        try check(of(after, "rejected").isEmpty && of(after, "finished").count == 3, "turn-taking also accepts the next message")
        print("PASS " + String(checks) + " open floor Stop checks; pretend teammates only")
    }
}
