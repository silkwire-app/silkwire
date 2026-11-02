import Foundation
import Darwin

// Independent review of the concurrent NativeRoom candidate from receipt 5A76FC22.
// Synthetic transports only: no provider, real broker operation, account or network.
// These are room-level checks, not proof that the composer or durable work adapter is wired.
@MainActor private final class IsolationTransport: NativeAgentTransport {
    final class Submission {
        let id: String
        var acknowledged = false
        var finished = false
        var acknowledgement: CheckedContinuation<Void, Never>?
        init(_ id: String) { self.id = id }
    }
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String
    var submissions: [Submission] = []
    var holdAcknowledgement = false
    var holdStop = false
    var stopGate: CheckedContinuation<Void, Never>?
    var stopCalls = 0
    init(_ agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = ProviderIdentity(id: "room-isolation-fixture-" + agent, started: false)
        self.identity = value
        return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        let item = Submission(requestID)
        submissions.append(item)
        if holdAcknowledgement { await withCheckedContinuation { item.acknowledgement = $0 } }
        item.acknowledged = true
    }
    func words(_ text: String) { eventHandler?(.delta(text)) }
    func finish(_ status: String = "completed") {
        guard let item = submissions.last, !item.finished else { return }
        item.finished = true
        if status == "completed" { words(agent + " synthetic reply") }
        eventHandler?(.finished(status: status, message: nil))
    }
    func releaseAcknowledgements() {
        for item in submissions {
            let gate = item.acknowledgement
            item.acknowledgement = nil
            gate?.resume()
        }
    }
    func releaseStop() {
        let gate = stopGate
        stopGate = nil
        gate?.resume()
    }
    func stop() async throws {
        stopCalls += 1
        if holdStop { await withCheckedContinuation { stopGate = $0 } }
        releaseAcknowledgements()
        finish("interrupted")
    }
    func stopPrevious() async throws {}
    func close() { releaseStop(); releaseAcknowledgements() }
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport only") }
}

@MainActor private final class IsolationFixture {
    var events: [[String: Any]] = []
    var transports: [String: IsolationTransport] = [:]
    lazy var room = NativeRoom(emit: { [weak self] in self?.events.append($0) }, factory: { [weak self] agent, _ in
        let transport = IsolationTransport(agent)
        self?.transports[agent] = transport
        return transport
    })
    func connect() async throws {
        let participants = ["codex", "eve", "claude"]
        await room.dispatch(["action": "connect", "conversationID": UUID().uuidString.lowercased(), "participants": participants, "projectFolders": [[String: String]]()])
        try await wait {
            participants.allSatisfy { agent in
                self.transports[agent] != nil && self.events.contains {
                    $0["type"] as? String == "connection" && $0["agent"] as? String == agent && $0["state"] as? String == "connected"
                }
            }
        }
    }
    func eventually(seconds: TimeInterval = 10, _ predicate: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            if Date() >= deadline { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
    func wait(_ predicate: () -> Bool) async throws {
        guard try await eventually(predicate) else { throw nativeFailure("Synthetic room-isolation checkpoint timed out") }
    }
    func of(_ id: String, _ type: String) -> [[String: Any]] {
        events.filter { $0["requestId"] as? String == id && $0["type"] as? String == type }
    }
    func send(_ targets: [String], id: String = UUID().uuidString, openFloor: Bool = true) async -> String {
        await room.dispatch(["action": "send", "requestId": id, "text": "Synthetic room isolation request", "targets": targets, "history": [[String: String]](), "historyTotal": 0, "openFloor": openFloor])
        return id
    }
    func hasWords(_ words: String, request: String, agent: String) -> Bool {
        events.contains { ["delta", "replace"].contains($0["type"] as? String ?? "") && $0["text"] as? String == words && $0["requestId"] as? String == request && $0["agent"] as? String == agent }
    }
}

@main struct BackgroundRoomIsolationReviewTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }

        // Completing the older turn must not clear, consume or misroute the newer one.
        do {
            let f = IsolationFixture(); defer { f.room.close() }
            try await f.connect()
            let older = await f.send(["codex"])
            try await f.wait { f.transports["codex"]!.submissions.last?.acknowledged == true }
            let newer = await f.send(["eve"])
            try await f.wait { f.transports["eve"]!.submissions.last?.acknowledged == true }
            check(f.of(older, "accepted").count == 1 && f.of(newer, "accepted").count == 1, "disjoint teammates admit concurrent turns")
            f.transports["codex"]!.words("older words")
            f.transports["eve"]!.words("newer words")
            check(f.hasWords("older words", request: older, agent: "codex") && f.hasWords("newer words", request: newer, agent: "eve"), "concurrent words retain the correct request and teammate")
            let busy = await f.send(["codex"])
            check(f.of(busy, "rejected").count == 1 && f.transports["codex"]!.submissions.count == 1, "an occupied provider session cannot be dispatched twice")
            check(f.transports.values.allSatisfy { $0.stopCalls == 0 }, "a busy-target rejection does not cancel another turn")
            f.transports["codex"]!.finish()
            try await f.wait { f.of(older, "settled").count == 1 }
            check(f.of(newer, "settled").isEmpty && f.of(newer, "finished").isEmpty, "older completion leaves the newer turn pending")
            let third = await f.send(["codex"])
            try await f.wait { f.transports["codex"]!.submissions.count == 2 && f.transports["codex"]!.submissions.last?.acknowledged == true }
            f.transports["eve"]!.finish()
            try await f.wait { f.of(newer, "settled").count == 1 }
            check(f.of(third, "settled").isEmpty, "newer completion cannot clear a subsequently admitted turn")
            f.transports["codex"]!.words("third words")
            check(f.hasWords("third words", request: third, agent: "codex"), "a reused idle seat routes words to its new request")
            f.transports["codex"]!.finish()
            try await f.wait { f.of(third, "settled").count == 1 }
            check([older, newer, third].allSatisfy { f.of($0, "finished").count == 1 && f.of($0, "settled").count == 1 }, "three independent turns finish and settle exactly once")
        }

        // A sequential turn owns teammates it has not dispatched yet.
        do {
            let f = IsolationFixture(); defer { f.room.close() }
            try await f.connect()
            let sequence = await f.send(["codex", "eve"], openFloor: false)
            try await f.wait { f.transports["codex"]!.submissions.last?.acknowledged == true }
            let collision = await f.send(["eve"])
            check(f.of(collision, "rejected").count == 1 && f.transports["eve"]!.submissions.isEmpty, "queued sequential targets remain reserved")
            let separate = await f.send(["claude"])
            try await f.wait { f.transports["claude"]!.submissions.last?.acknowledged == true }
            f.transports["claude"]!.finish()
            try await f.wait { f.of(separate, "settled").count == 1 }
            check(f.of(sequence, "settled").isEmpty, "an unrelated teammate can chat while a sequential turn waits")
            f.transports["codex"]!.finish()
            try await f.wait { f.transports["eve"]!.submissions.last?.acknowledged == true }
            f.transports["eve"]!.finish()
            try await f.wait { f.of(sequence, "settled").count == 1 }
            check(f.of(sequence, "finished").count == 2 && f.transports["eve"]!.submissions.count == 1, "sequential continuation preserves its original request")
        }

        // Stop must clean both turns, including an unacknowledged transport send.
        do {
            let f = IsolationFixture(); defer { f.room.close() }
            try await f.connect()
            f.transports["codex"]!.holdAcknowledgement = true
            let older = await f.send(["codex"])
            try await f.wait { f.transports["codex"]!.submissions.last?.acknowledgement != nil }
            let newer = await f.send(["eve"])
            try await f.wait { f.transports["eve"]!.submissions.last?.acknowledged == true }
            await f.room.dispatch(["action": "stop"])
            try await f.wait { f.of(older, "settled").count == 1 && f.of(newer, "settled").count == 1 }
            check(f.transports["codex"]!.stopCalls == 1 && f.transports["eve"]!.stopCalls == 1, "ordinary Stop reaches both concurrent turns")
            check([older, newer].allSatisfy { f.of($0, "finished").count == 1 && f.of($0, "finished").first?["status"] as? String == "interrupted" }, "ordinary Stop produces one interrupted finish per turn")
            check(f.transports["codex"]!.submissions[0].acknowledgement == nil, "Stop releases the held send acknowledgement")
            f.room.close()
            let count = f.events.count
            f.transports["codex"]!.words("late words after close")
            f.transports["eve"]!.words("late words after close")
            check(f.events.count == count, "closed-room transport callbacks are fenced")
        }

        // A repeated live request ID must not create two distinguishable-by-agent
        // turns with the SAME request identity: downstream consumers key by requestId.
        do {
            let f = IsolationFixture(); defer { f.room.close() }
            try await f.connect()
            let id = UUID().uuidString
            _ = await f.send(["codex"], id: id)
            try await f.wait { f.transports["codex"]!.submissions.last?.acknowledged == true }
            _ = await f.send(["eve"], id: id)
            if f.of(id, "accepted").count > 1 {
                try await f.wait { f.transports["eve"]!.submissions.last?.acknowledged == true }
            }
            print("Observed duplicate ID: accepted=\(f.of(id, "accepted").count), rejected=\(f.of(id, "rejected").count), extra seat submissions=\(f.transports["eve"]!.submissions.count)")
            check(f.of(id, "accepted").count == 1 && f.of(id, "rejected").count == 1 && f.transports["eve"]!.submissions.isEmpty, "a duplicate live request ID cannot dispatch an additional turn")
            await f.room.dispatch(["action": "stop"])
        }

        // A provider's slow Stop acknowledgement must not delay stopping another
        // already-running turn. The first Stop is held by a continuation, not a
        // simulated build duration. A bounded wait prevents a hanging test suite.
        do {
            let f = IsolationFixture(); defer { f.room.close() }
            try await f.connect()
            f.transports["codex"]!.holdStop = true
            let older = await f.send(["codex"])
            try await f.wait { f.transports["codex"]!.submissions.last?.acknowledged == true }
            let newer = await f.send(["eve"])
            try await f.wait { f.transports["eve"]!.submissions.last?.acknowledged == true }
            let stopping = Task { @MainActor in await f.room.dispatch(["action": "stop"]) }
            try await f.wait { f.transports["codex"]!.stopGate != nil }
            let reachedOther = try await f.eventually(seconds: 1) { f.transports["eve"]!.stopCalls == 1 }
            print("Observed held Stop: first stop calls=\(f.transports["codex"]!.stopCalls), second stop calls=\(f.transports["eve"]!.stopCalls), first acknowledgement still held=\(f.transports["codex"]!.stopGate != nil)")
            check(reachedOther && f.transports["codex"]!.stopGate != nil, "a held Stop acknowledgement cannot prevent Stop reaching another turn")
            f.transports["codex"]!.releaseStop()
            await stopping.value
            try await f.wait { f.of(older, "settled").count == 1 && f.of(newer, "settled").count == 1 }
            check(f.transports["eve"]!.stopCalls == 1 && [older, newer].allSatisfy { f.of($0, "finished").count == 1 }, "releasing the held Stop cleans both turns without duplicate finishes")
        }
        print("Background room isolation review: \(passed) passed, \(failed) failed; synthetic transports only")
        if failed > 0 { exit(1) }
    }
}
