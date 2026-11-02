import Foundation

// Pretend teammates for the open floor. Each answers after its own delay, so a
// truly simultaneous room shows every teammate started before anyone finishes.
@MainActor final class OpenFloorTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    let agent: String
    var delay: Int
    var reply: String
    var hang = false
    var stopped = 0
    init(_ agent: String, delay: Int, reply: String) { self.agent = agent; self.delay = delay; self.reply = reply }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = ProviderIdentity(id: "fixture-" + agent, started: false)
        self.identity = value
        return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        let wait = delay, words = reply, stuck = hang
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard let self, !stuck else { return }
            self.eventHandler?(.delta(words))
            self.eventHandler?(.finished(status: "completed", message: nil))
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

@main struct OpenFloorTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL: " + label) }
            checks += 1; print("PASS " + label)
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Fixture timed out") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        var events: [[String: Any]] = [], transports: [String: OpenFloorTransport] = [:]
        let plan: [String: (Int, String)] = ["eve": (300, "Eve view"), "claude": (100, "PASS"), "codex": (200, "Codex view")]
        let room = NativeRoom(emit: { events.append($0) }, factory: { agent, _ in
            let item = plan[agent] ?? (50, "Reply")
            let transport = OpenFloorTransport(agent, delay: item.0, reply: item.1); transports[agent] = transport; return transport
        })
        defer { room.close() }
        await room.dispatch(["action": "connect", "conversationID": UUID().uuidString.lowercased(), "participants": ["eve", "claude", "codex"], "projectFolders": [[String: String]]()])
        try await wait { transports.count == 3 && events.filter { $0["type"] as? String == "connection" && $0["state"] as? String == "connected" }.count >= 3 }

        func of(_ id: String) -> [[String: Any]] { events.filter { $0["requestId"] as? String == id } }
        func kinds(_ id: String, _ type: String) -> [[String: Any]] { of(id).filter { $0["type"] as? String == type } }
        func send(_ order: [String], openFloor: Bool) async -> String {
            let id = UUID().uuidString
            await room.dispatch(["action": "send", "requestId": id, "text": "Synthetic open floor task", "targets": order, "history": [[String: String]](), "historyTotal": 0, "openFloor": openFloor])
            return id
        }
        func settled(_ id: String) -> Bool { !kinds(id, "settled").isEmpty }

        // 1. Everyone starts at once.
        let open = await send(["eve", "claude", "codex"], openFloor: true)
        try await wait { settled(open) }
        let ordered = of(open).compactMap { item -> String? in
            guard let type = item["type"] as? String, ["started", "finished", "settled"].contains(type) else { return nil }
            return type + ":" + (item["agent"] as? String ?? "")
        }
        try check(kinds(open, "accepted").first?["openFloor"] as? Bool == true, "room confirms the open floor")
        try check(Array(ordered.prefix(3)).allSatisfy { $0.hasPrefix("started:") }, "all three teammates start before anyone finishes")
        try check(kinds(open, "finished").count == 3 && kinds(open, "settled").count == 1, "three replies, one settle")
        try check(ordered.last == "settled:", "the room settles only after the last teammate finishes")
        let finishOrder = kinds(open, "finished").compactMap { $0["agent"] as? String }
        try check(finishOrder == ["claude", "codex", "eve"], "replies land as each teammate is ready, not in queue order")

        // 2. Prompts describe the open floor instead of the reply queue.
        let prompts = ["eve", "claude", "codex"].compactMap { transports[$0]?.prompts.last }
        try check(prompts.count == 3 && prompts.allSatisfy { $0.contains("OPEN FLOOR (turn-free chat)") && !$0.contains("COLLAB ROOM RULES") }, "each teammate gets open-floor rules")
        try check(prompts.allSatisfy { $0.contains("replying at once") && !$0.contains("isFinalSpeaker") }, "no first or final speaker on the open floor")
        try check(prompts.allSatisfy { $0.contains("none is available to you yet") && !$0.contains("you are the first responding teammate") }, "nobody is told they spoke first")

        // 3. PASS is silence.
        let claudeDone = kinds(open, "finished").first { $0["agent"] as? String == "claude" }
        try check(claudeDone?["silent"] as? Bool == true && claudeDone?["status"] as? String == "completed", "a PASS is marked silent")
        try check(kinds(open, "finished").filter { $0["silent"] != nil }.count == 1, "real replies are not silent")
        try check(OpenFloor.isPass(" pass. ") && OpenFloor.isPass("PASS") && !OpenFloor.isPass("Pass on this, but here is why"), "only a bare PASS counts as silence")

        // 4. Without the setting, the room still takes turns.
        let turns = await send(["eve", "claude", "codex"], openFloor: false)
        try await wait { settled(turns) }
        let sequence = of(turns).compactMap { item -> String? in
            guard let type = item["type"] as? String, ["started", "finished"].contains(type) else { return nil }
            return type + ":" + (item["agent"] as? String ?? "")
        }
        try check(sequence == ["started:eve", "finished:eve", "started:claude", "finished:claude", "started:codex", "finished:codex"], "turn-taking order is unchanged when open floor is off")
        try check(kinds(turns, "accepted").first?["openFloor"] as? Bool == false, "room confirms turn-taking")
        try check(transports["codex"]!.prompts.last!.contains("COLLAB ROOM RULES"), "turn-taking keeps the collaboration rules")
        try check(kinds(turns, "finished").allSatisfy { $0["silent"] == nil }, "PASS stays visible when open floor is off")

        // 5. One teammate cannot hold an open floor alone.
        let solo = await send(["codex"], openFloor: true)
        try await wait { settled(solo) }
        try check(kinds(solo, "accepted").first?["openFloor"] as? Bool == false, "a single teammate takes a normal turn")

        // 6. Stop stops everyone still talking.
        for item in transports.values { item.hang = true }
        let stuck = await send(["eve", "claude", "codex"], openFloor: true)
        try await wait { kinds(stuck, "started").count == 3 && transports.values.allSatisfy { !$0.prompts.isEmpty } }
        try await Task.sleep(for: .milliseconds(50))
        await room.dispatch(["action": "stop"])
        try await wait { settled(stuck) }
        try check(transports.values.allSatisfy { $0.stopped == 1 }, "Stop reaches every teammate")
        try check(kinds(stuck, "finished").count == 3 && kinds(stuck, "finished").allSatisfy { $0["status"] as? String == "interrupted" }, "every reply ends as interrupted")

        // 7. The room is free for the next message.
        for item in transports.values { item.hang = false }
        let after = await send(["eve", "codex"], openFloor: true)
        try await wait { settled(after) }
        try check(kinds(after, "rejected").isEmpty && kinds(after, "finished").count == 2, "a new open-floor message runs after Stop")
        print("PASS " + String(checks) + " open floor checks; pretend teammates only")
    }
}
