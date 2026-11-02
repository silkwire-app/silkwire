import Foundation

@MainActor final class RoomFixtureTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var capabilities: [String] = []
    var prompts: [String] = []
    var closed = false
    var terminal = true
    var response: (String, Int) -> String = { _, _ in "Fixture response" }
    var beforeAcknowledgment: (() -> Void)?
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        self.capabilities.append(capabilities)
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        self.capabilities.append(capabilities); prompts.append(text)
        eventHandler?(.delta(response(text, prompts.count)))
        if terminal { eventHandler?(.finished(status:"completed", message:nil)) }
        beforeAcknowledgment?()
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status:"interrupted", message:nil)) }
    func stopPrevious() async throws {}
    func close() { closed = true }
    func connectionDetail() async throws -> ConnectionDetail {
        ConnectionDetail(agent:"codex", installed:true, signedIn:true, account:"Synthetic", model:"fixture", effort:"low", speed:"included", permissions:"read", usage:[], models:[], note:nil)
    }
}
@main struct RoomTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        var checks = 0
        func verify(_ value: Bool, _ label: String) { guard value else { print("FAIL: "+label); exit(1) }; checks += 1; print("PASS "+label) }
        func wait(_ predicate: () -> Bool) async {
            for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for:.milliseconds(5)) }
            preconditionFailure("Timed out waiting for room fixture")
        }
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-room-\(UUID())")
        try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
        try "FILE-TOKEN-314".write(to:folder.appendingPathComponent("known.txt"), atomically:true, encoding:.utf8)
        var transports: [String:RoomFixtureTransport] = [:], events: [[String:Any]] = []
        let room = NativeRoom(emit:{ events.append($0) }, factory:{ agent, _ in let transport = RoomFixtureTransport(); transports[agent] = transport; return transport })
        await room.dispatch(["action":"connect", "conversationID":UUID().uuidString, "participants":["eve","claude","codex"], "projectFolders":[["id":"notes","name":"Project Notes","root":folder.path]], "projectBrief":"BRIEF-TOKEN-515"])
        verify(events.filter { $0["type"] as? String == "connection" && $0["state"] as? String == "connected" }.count == 3, "three independent connections")
        verify(transports.values.allSatisfy { $0.capabilities.first?.contains("READ_PROJECT") == true }, "one shared current reader capability across agents")
        transports["eve"]?.response = { _, count in count == 1 ? "<<READ_PROJECT {\"action\":\"read\",\"folderId\":\"notes\",\"path\":\"known.txt\"}>>" : "Eve FILE-TOKEN-314" }
        transports["claude"]?.response = { text, _ in text.contains("Eve FILE-TOKEN-314") ? "Claude saw Eve" : "Missing context" }
        transports["codex"]?.response = { _, _ in "Codex finished" }
        transports["eve"]?.beforeAcknowledgment = { verify(transports["claude"]?.prompts.isEmpty == true, "terminal event is not send acknowledgment") }
        let id = UUID().uuidString
        await room.dispatch(["action":"send", "requestId":id,"text":"Read known file then discuss", "targets":["eve","claude","codex"],"history":[], "attachments":[]])
        await wait { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == id } }
        verify(transports["eve"]?.prompts.count == 2 && transports["eve"]?.prompts.last?.contains("FILE-TOKEN-314") == true, "hidden native reader continuation supplies actual file bytes")
        verify(transports["eve"]?.prompts.first?.contains("BRIEF-TOKEN-515") == true, "brief supplied as quoted context")
        for (agent, position) in [("eve", 1), ("claude", 2), ("codex", 3)] {
            let prompt = transports[agent]?.prompts.first ?? ""
            verify(prompt.contains("\"position\":\(position)") && prompt.contains("\"isFinalSpeaker\":\(position == 3 ? "true" : "false")"), "runtime supplies exact queue position and final flag to " + agent)
        }
        verify(transports["claude"]?.prompts.first?.contains("Eve FILE-TOKEN-314") == true && transports["codex"]?.prompts.first?.contains("Claude saw Eve") == true, "ordered shared replies carry forward")
        verify(!events.contains { ($0["text"] as? String ?? "").contains("<<READ_PROJECT") }, "file protocol hidden from transcript")
        verify(events.contains { $0["type"] as? String == "projectAccess" && $0["state"] as? String == "verified" }, "actual broker evidence updates verified status")
        transports["eve"]?.beforeAcknowledgment = nil
        transports["eve"]?.response = { _, count in
            if count == 3 { return "<<READ_PROJECT {broken JSON}>>" }
            if count == 4 { return "<<READ_PROJECT {\"action\":\"read\",\"folderId\":\"notes\",\"path\":\"known.txt\"}>>" }
            return "Recovered FILE-TOKEN-314"
        }
        let corrected = UUID().uuidString
        await room.dispatch(["action":"send", "requestId":corrected, "text":"Correct malformed request without loosening access", "targets":["eve"]])
        await wait { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == corrected } }
        verify(transports["eve"]?.prompts.count == 5 && transports["eve"]?.prompts[3].contains("No file operation ran") == true, "malformed read gets bounded no-operation feedback before a strictly validated retry")
        verify(events.contains { $0["type"] as? String == "finished" && $0["requestId"] as? String == corrected && $0["status"] as? String == "completed" }, "protocol correction preserves healthy connection")
        let healthy = transports["claude"]
        await room.dispatch(["action":"disconnectAgent", "agent":"codex"])
        await room.dispatch(["action":"reconnectAgent", "agent":"codex"])
        verify(transports["claude"] === healthy && healthy?.closed == false, "targeted recovery preserves healthy transport")
        let previousCount = transports.values.reduce(0) { $0 + $1.prompts.count }
        verify(previousCount == 6, "reconnect does not replay a send") // 5 Eve + 1 Claude; Codex replaced.
        transports["codex"]?.terminal = false
        let stopped = UUID().uuidString
        await room.dispatch(["action":"send", "requestId":stopped, "text":"Stop test", "targets":["codex","claude"]])
        await wait { transports["codex"]?.prompts.count == 1 }
        await room.dispatch(["action":"stop"])
        await wait { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == stopped } }
        verify(events.contains { $0["type"] as? String == "finished" && $0["agent"] as? String == "claude" && $0["status"] as? String == "cancelled" }, "Stop cancels remaining queue before dispatch")
        verify(transports["claude"]?.prompts.count == 1, "cancelled agent never receives prompt")
        let immediate = UUID().uuidString, beforeImmediate = transports["codex"]?.prompts.count
        await room.dispatch(["action":"send", "requestId":immediate, "text":"Immediate stop race", "targets":["codex"]])
        await room.dispatch(["action":"stop"])
        await wait { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == immediate } }
        verify(transports["codex"]?.prompts.count == beforeImmediate, "Stop before scheduled send dispatch settles without sending")
        let callback = transports["codex"]?.eventHandler, count = events.count
        room.close(); callback?(.delta("LATE DATA")); callback?(.finished(status:"completed",message:nil))
        verify(events.count == count, "closed room ignores late callbacks")
        var countEvents: [[String:Any]] = []
        let countRoom = NativeRoom(emit:{countEvents.append($0)},factory:{agent,_ in let item = RoomFixtureTransport(); if agent == "eve" { item.response = {_,_ in ""} }; return item })
        await countRoom.dispatch(["action":"connect","conversationID":UUID().uuidString,"participants":["eve","claude"]])
        let countID = UUID().uuidString
        await countRoom.dispatch(["action":"send","requestId":countID,"text":"Count actual prior replies only","targets":["eve","claude"],"historyTotal":9])
        await wait { countEvents.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == countID } }
        verify(countEvents.first { $0["type"] as? String == "context" && $0["agent"] as? String == "claude" }?["total"] as? Int == 9,"failed prior teammate does not inflate history denominator")
        countRoom.close()
        print("PASS: \(checks) room lifecycle, ordered context, scoped read, recovery and Stop checks")
    }
}
