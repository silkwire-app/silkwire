import Foundation

@MainActor final class CollabRulesTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    let agent: String
    var fails = false
    init(_ agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = ProviderIdentity(id: "fixture-" + agent, started: false)
        self.identity = value
        return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        eventHandler?(.delta(agent == "claude" ? "PASS" : "Unique " + agent + " finding"))
        eventHandler?(.finished(status: fails ? "failed" : "completed", message: fails ? "Synthetic failure" : nil))
    }
    func stop() async throws {}
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture") }
}

@main struct CollabRoomRulesTests {
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
        var events: [[String: Any]] = [], transports: [String: CollabRulesTransport] = [:]
        let room = NativeRoom(emit: { events.append($0) }, factory: { agent, _ in
            let transport = CollabRulesTransport(agent); transports[agent] = transport; return transport
        })
        defer { room.close() }
        await room.dispatch(["action": "connect", "conversationID": UUID().uuidString.lowercased(), "participants": ["eve", "claude", "codex"], "projectFolders": [[String: String]]()])
        try await wait { transports.count == 3 && events.filter { $0["type"] as? String == "connection" && $0["state"] as? String == "connected" }.count >= 3 }
        func send(_ order: [String], history: [[String: String]] = []) async throws {
            let id = UUID().uuidString
            await room.dispatch(["action": "send", "requestId": id, "text": "Synthetic collaboration task", "targets": order, "history": history, "historyTotal": history.count])
            try await wait { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == id } }
        }
        func block(_ prompt: String) -> String {
            prompt.components(separatedBy: "EARLIER TEAMMATE REPLIES TO THIS REQUEST").last?.components(separatedBy: "CURRENT REQUEST FROM JASON").first ?? ""
        }
        try await send(["eve", "claude", "codex"], history: (0..<100).map { ["author": "Jason", "state": "sent", "text": "Old history \($0) " + String(repeating: "x", count: 500)] })
        let first = transports["eve"]!.prompts.last!, second = transports["claude"]!.prompts.last!, third = transports["codex"]!.prompts.last!
        try check(block(first).contains("None yet"), "first speaker is not given invented predecessors")
        try check(block(second).contains("Unique eve finding"), "second speaker receives the first completed reply explicitly")
        try check(block(third).contains("Unique eve finding") && block(third).contains("PASS"), "third speaker receives both completed replies including a pass")
        try check(!block(third).contains("Old history"), "current-turn block excludes old conversation history")
        try check([first, second, third].allSatisfy { $0.contains("COLLAB ROOM RULES") && $0.contains("reply exactly PASS") && $0.utf16.count <= 32000 }, "rules survive long-history compaction within transport limit")
        try await send(["codex", "eve"])
        try check(block(transports["codex"]!.prompts.last!).contains("None yet"), "new turn clears previous turn replies")
        try check(block(transports["eve"]!.prompts.last!).contains("Unique codex finding"), "shuffled order uses actual predecessors")
        transports["eve"]!.fails = true
        try await send(["eve", "codex"])
        try check(block(transports["codex"]!.prompts.last!).contains("None yet"), "failed output is not presented as a completed teammate reply")
        let huge = NativeRoom.currentReplyContext([["author": "Eve", "text": String(repeating: "🙂\\\"\n", count: 10000)], ["author": "Claude", "text": String(repeating: "z", count: 10000)]], budget: 2000)
        try check(huge.utf16.count <= 2000 && huge.contains("shortened"), "large Unicode and escaped replies are explicitly shortened to budget")
        let tiny = NativeRoom.currentReplyContext([["author": "Eve", "text": "Work" ]], budget: 100)
        try check(tiny.contains("could not fit"), "insufficient room reports unavailable reply context honestly")
        print("PASS \(checks) collaboration room checks; synthetic transports only")
    }
}
