import Foundation
import Darwin

// Follow-up review of F973EBB8. These transports run no real provider, broker,
// account or network operation. The composer and durable executor are not tested.
@MainActor private final class IdentityReviewTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String
    var sent: [String] = []
    var finished = true
    var holdAcknowledgement = false
    var acknowledgement: CheckedContinuation<Void, Never>?
    var holdStop = false
    var stopGate: CheckedContinuation<Void, Never>?
    var stopCalls = 0
    init(_ agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let result = ProviderIdentity(id: "identity-review-fixture-" + agent, started: false)
        self.identity = result
        return result
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        sent.append(requestID); finished = false
        if holdAcknowledgement { await withCheckedContinuation { acknowledgement = $0 } }
    }
    func releaseAcknowledgement() {
        let gate = acknowledgement; acknowledgement = nil; gate?.resume()
    }
    func releaseStop() { let gate = stopGate; stopGate = nil; gate?.resume() }
    func words(_ text: String) { eventHandler?(.delta(text)) }
    func finish(_ status: String = "completed") {
        guard !finished else { return }
        finished = true
        if status == "completed" { words(agent + " synthetic reply") }
        eventHandler?(.finished(status: status, message: nil))
    }
    func stop() async throws {
        stopCalls += 1
        if holdStop { await withCheckedContinuation { stopGate = $0 } }
        releaseAcknowledgement(); finish("interrupted")
    }
    func stopPrevious() async throws {}
    func close() { releaseAcknowledgement(); releaseStop() }
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic fixture only") }
}

@MainActor private final class IdentityReviewFixture {
    var events: [[String: Any]] = []
    var transports: [String: IdentityReviewTransport] = [:]
    lazy var room = NativeRoom(emit: { [weak self] in self?.events.append($0) }, factory: { [weak self] agent, _ in
        let transport = IdentityReviewTransport(agent)
        self?.transports[agent] = transport
        return transport
    })
    func connect() async throws {
        let participants = ["codex", "eve", "claude"]
        await room.dispatch(["action": "connect", "conversationID": UUID().uuidString.lowercased(), "participants": participants, "projectFolders": [[String: String]]()])
        try await wait {
            participants.allSatisfy { agent in
                self.events.contains { $0["type"] as? String == "connection" && $0["agent"] as? String == agent && $0["state"] as? String == "connected" }
            }
        }
    }
    func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw nativeFailure("Synthetic identity-review checkpoint timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func of(_ id: String, _ type: String) -> [[String: Any]] {
        events.filter { $0["requestId"] as? String == id && $0["type"] as? String == type }
    }
    @discardableResult func send(_ targets: [String], id: String = UUID().uuidString, openFloor: Bool = true) async -> String {
        await room.dispatch(["action": "send", "requestId": id, "text": "Synthetic request identity review", "targets": targets, "history": [[String: String]](), "historyTotal": 0, "openFloor": openFloor])
        return id
    }
}

@main struct BackgroundRoomIdentityReviewTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        // Admission, not transport acknowledgement, reserves the request ID.
        do {
            let f = IdentityReviewFixture(); defer { f.room.close() }
            try await f.connect()
            let codex = f.transports["codex"]!, eve = f.transports["eve"]!
            codex.holdAcknowledgement = true
            let id = await f.send(["codex"])
            try await f.wait { codex.acknowledgement != nil }
            await f.send(["eve"], id: id)
            check(f.of(id, "accepted").count == 1 && f.of(id, "rejected").count == 1, "a live ID is reserved even before transport acknowledgement")
            check(eve.sent.isEmpty && codex.sent.count == 1 && codex.stopCalls == 0, "duplicate admission neither dispatches another seat nor cancels the original")
            codex.releaseAcknowledgement(); codex.finish()
            try await f.wait { f.of(id, "settled").count == 1 }
            check(f.of(id, "finished").count == 1 && f.of(id, "settled").count == 1, "the original request still finishes and settles once after duplicate rejection")
        }
        // An unadmitted busy-target request must not poison its identity.
        do {
            let f = IdentityReviewFixture(); defer { f.room.close() }
            try await f.connect()
            let codex = f.transports["codex"]!
            let work = await f.send(["codex"])
            try await f.wait { codex.sent.count == 1 }
            let retry = await f.send(["codex"])
            check(f.of(retry, "accepted").isEmpty && f.of(retry, "rejected").count == 1 && codex.sent.count == 1, "busy-target rejection creates no live request or provider submission")
            codex.finish()
            try await f.wait { f.of(work, "settled").count == 1 }
            await f.send(["codex"], id: retry)
            try await f.wait { codex.sent.count == 2 }
            check(f.of(retry, "accepted").count == 1 && f.of(retry, "rejected").count == 1 && codex.sent.last == retry, "a previously rejected ID can be admitted once the seat is idle")
            codex.words("retry routing marker")
            // NativeRoom publishes the first visible words as replace, then deltas.
            let routed = f.of(retry, "replace") + f.of(retry, "delta")
            check(routed.filter { $0["text"] as? String == "retry routing marker" && $0["agent"] as? String == "codex" }.count == 1, "retry words preserve the exact admitted request string")
            codex.finish()
            try await f.wait { f.of(retry, "settled").count == 1 }
            check(f.of(retry, "finished").count == 1, "the admitted retry has exactly one terminal reply")
        }
        // Fence queued sequential work before awaiting either concurrent Stop.
        do {
            let f = IdentityReviewFixture(); defer { f.room.close() }
            try await f.connect()
            let codex = f.transports["codex"]!, eve = f.transports["eve"]!, claude = f.transports["claude"]!
            codex.holdStop = true; eve.holdStop = true
            let sequence = await f.send(["codex", "claude"], openFloor: false)
            try await f.wait { codex.sent.count == 1 }
            let parallel = await f.send(["eve"])
            try await f.wait { eve.sent.count == 1 }
            let stopping = Task { @MainActor in await f.room.dispatch(["action": "stop"]) }
            try await f.wait { codex.stopGate != nil && eve.stopGate != nil }
            check(claude.sent.isEmpty && f.of(sequence, "finished").contains { $0["agent"] as? String == "claude" && $0["status"] as? String == "cancelled" }, "queued work is cancelled before either Stop acknowledgement is released")
            let busy = await f.send(["codex", "eve"])
            check(f.of(busy, "rejected").count == 1 && codex.sent.count == 1 && eve.sent.count == 1, "physically stopping seats cannot receive a new turn")
            codex.releaseStop()
            try await f.wait { f.of(sequence, "settled").count == 1 }
            check(eve.stopGate != nil && f.of(parallel, "settled").isEmpty, "one stopped turn can settle while the other acknowledgement remains held")
            check(claude.sent.isEmpty && codex.stopCalls == 1 && eve.stopCalls == 1, "late completion during Stop never dispatches the cancelled sequential target")
            eve.releaseStop(); await stopping.value
            try await f.wait { f.of(parallel, "settled").count == 1 }
            check(f.of(sequence, "finished").count == 2 && f.of(parallel, "finished").count == 1, "concurrent Stop yields one terminal event per dispatched or queued target")
            let after = await f.send(["claude"])
            try await f.wait { claude.sent.count == 1 }
            claude.finish()
            try await f.wait { f.of(after, "settled").count == 1 }
            check(f.of(after, "accepted").count == 1 && f.of(after, "rejected").isEmpty, "the cancelled queued seat remains usable for a fresh request")
        }
        print("Background room identity review: \(passed) passed, \(failed) failed; synthetic transports only")
        if failed > 0 { exit(1) }
    }
}
