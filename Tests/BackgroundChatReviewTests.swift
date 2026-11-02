import Foundation
import Darwin

// Desired background/chat boundary, exercised through the real NativeRoom API.
// These transports simulate a long-running engineering reply and a held send
// acknowledgement. They execute NO broker command, provider call or network work.
// This does not test UI card order, a durable scheduler or real build cancellation.
@MainActor private final class BackgroundChatTransport: NativeAgentTransport {
    final class Submission {
        let requestID: String
        var finished = false
        var acknowledged = false
        var gate: CheckedContinuation<Void, Never>?
        init(_ requestID: String) { self.requestID = requestID }
    }
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String
    var submissions: [Submission] = []
    var holdAcknowledgement = false
    var stopped = 0
    init(_ agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = ProviderIdentity(id: "background-chat-fixture-" + agent, started: false)
        self.identity = value
        return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        let item = Submission(requestID)
        submissions.append(item)
        if holdAcknowledgement { await withCheckedContinuation { item.gate = $0 } }
        item.acknowledged = true
    }
    func words(_ text: String) { eventHandler?(.delta(text)) }
    func finishLatest() {
        guard let item = submissions.last, !item.finished else { return }
        item.finished = true
        eventHandler?(.delta(agent + " synthetic reply"))
        eventHandler?(.finished(status: "completed", message: nil))
    }
    func releaseAcknowledgements() {
        for item in submissions {
            let continuation = item.gate
            item.gate = nil
            continuation?.resume()
        }
    }
    func stop() async throws {
        stopped += 1
        releaseAcknowledgements()
        guard let item = submissions.last, !item.finished else { return }
        item.finished = true
        eventHandler?(.finished(status: "interrupted", message: "Synthetic Stop"))
    }
    func stopPrevious() async throws {}
    func close() { releaseAcknowledgements() }
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport only") }
}

@MainActor private final class BackgroundChatFixture {
    var events: [[String: Any]] = []
    var transports: [String: BackgroundChatTransport] = [:]
    lazy var room = NativeRoom(emit: { [weak self] in self?.events.append($0) }, factory: { [weak self] agent, _ in
        let item = BackgroundChatTransport(agent)
        self?.transports[agent] = item
        return item
    })
    func connect(_ participants: [String] = ["eve", "claude", "codex"]) async throws {
        await room.dispatch(["action": "connect", "conversationID": UUID().uuidString.lowercased(), "participants": participants, "projectFolders": [[String: String]]()])
        try await wait {
            participants.allSatisfy { agent in
                self.transports[agent] != nil && self.events.contains {
                    $0["type"] as? String == "connection" && $0["agent"] as? String == agent && $0["state"] as? String == "connected"
                }
            }
        }
    }
    func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw nativeFailure("Synthetic background/chat checkpoint timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func of(_ request: String, _ type: String) -> [[String: Any]] {
        events.filter { $0["requestId"] as? String == request && $0["type"] as? String == type }
    }
    func send(_ targets: [String], text: String) async -> String {
        let id = UUID().uuidString
        await room.dispatch(["action": "send", "requestId": id, "text": text, "targets": targets, "history": [[String: String]](), "historyTotal": 0, "openFloor": true])
        return id
    }
}

@main struct BackgroundChatReviewTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        func rejection(_ fixture: BackgroundChatFixture, _ id: String) {
            for item in fixture.of(id, "rejected") { print("Observed rejection: " + (item["message"] as? String ?? "unspecified")) }
        }

        // 1. A normal team message finishes for Eve and Claude; Codex keeps working.
        // A subsequent message targets ONLY the available crew. No concurrent use
        // of Codex's provider session is requested by this acceptance test.
        do {
            let f = BackgroundChatFixture(); defer { f.room.close() }
            try await f.connect()
            let work = await f.send(["eve", "claude", "codex"], text: "Synthetic engineering work; keep the Codex reply pending")
            try await f.wait { f.transports.values.allSatisfy { $0.submissions.count == 1 && $0.submissions[0].acknowledged } }
            check(f.of(work, "accepted").first?["openFloor"] as? Bool == true, "control: the real room admits an open-floor message")
            f.transports["eve"]!.finishLatest(); f.transports["claude"]!.finishLatest()
            f.transports["codex"]!.words("Synthetic engineering progress")
            try await f.wait { f.of(work, "finished").count == 2 }
            check(f.of(work, "settled").isEmpty, "control: the Codex work reply remains pending")
            let chat = await f.send(["eve", "claude"], text: "Continue chatting with the available crew without cancelling Codex")
            rejection(f, chat)
            let accepted = f.of(chat, "accepted").count == 1 && f.of(chat, "rejected").isEmpty
            check(accepted, "available teammates must accept room chat while another teammate is working")
            check(f.transports["codex"]!.stopped == 0 && f.of(work, "finished").count == 2, "attempting chat must not cancel the working teammate")
            if accepted {
                try await f.wait { f.transports["eve"]!.submissions.count == 2 && f.transports["claude"]!.submissions.count == 2 }
                f.transports["eve"]!.finishLatest(); f.transports["claude"]!.finishLatest()
                try await f.wait { f.of(chat, "settled").count == 1 }
                check(f.of(chat, "finished").count == 2 && f.of(work, "settled").isEmpty, "foreground chat can finish before the original work reply")
            }

            // Control: another room can run, so a failure above is not a blocked
            // main actor or a network/provider delay in this fixture.
            let other = BackgroundChatFixture(); defer { other.room.close() }
            try await other.connect(["eve"])
            let separate = await other.send(["eve"], text: "Independent-room control")
            try await other.wait { other.transports["eve"]!.submissions.count == 1 }
            other.transports["eve"]!.finishLatest()
            try await other.wait { other.of(separate, "settled").count == 1 }
            check(other.of(separate, "rejected").isEmpty && f.of(work, "settled").isEmpty, "control: an independent room chats while the original room has pending work")

            await f.room.dispatch(["action": "stop"])
            try await f.wait { f.of(work, "settled").count == 1 }
            check(f.of(work, "finished").count == 3 && f.of(work, "finished").contains { $0["agent"] as? String == "codex" && $0["status"] as? String == "interrupted" }, "control: explicit Stop still ends the pending work exactly once")
            let after = await f.send(["eve"], text: "Chat after explicit Stop")
            try await f.wait { f.transports["eve"]!.submissions.count >= (accepted ? 3 : 2) }
            f.transports["eve"]!.finishLatest()
            try await f.wait { f.of(after, "settled").count == 1 }
            check(f.of(after, "rejected").isEmpty, "control: the same room accepts chat after explicit Stop")
        }

        // 2. A targeted work reply must not monopolize unrelated idle seats.
        do {
            let f = BackgroundChatFixture(); defer { f.room.close() }
            try await f.connect()
            let work = await f.send(["codex"], text: "Targeted synthetic work reply")
            try await f.wait { f.transports["codex"]!.submissions.count == 1 && f.transports["codex"]!.submissions[0].acknowledged }
            let chat = await f.send(["eve"], text: "A question for an idle teammate")
            rejection(f, chat)
            check(f.of(chat, "accepted").count == 1 && f.of(chat, "rejected").isEmpty, "an idle teammate must accept chat during a targeted work reply")
            check(f.transports["codex"]!.stopped == 0, "a targeted work reply must not be stopped merely to attempt chat")
            // Complete any admitted chat before testing natural work completion.
            if !f.of(chat, "accepted").isEmpty {
                try await f.wait { f.transports["eve"]!.submissions.count == 1 }
                f.transports["eve"]!.finishLatest()
                try await f.wait { f.of(chat, "settled").count == 1 }
            }
            f.transports["codex"]!.finishLatest()
            try await f.wait { f.of(work, "settled").count == 1 }
            let after = await f.send(["eve"], text: "Chat after natural completion")
            try await f.wait { f.transports["eve"]!.submissions.count == (f.of(chat, "accepted").isEmpty ? 1 : 2) }
            f.transports["eve"]!.finishLatest()
            try await f.wait { f.of(after, "settled").count == 1 }
            check(f.of(after, "rejected").isEmpty && f.transports["codex"]!.stopped == 0, "control: natural work completion releases the existing room gate")
        }

        // 3. Isolate the transport-acknowledgement boundary without time-based
        // simulated build durations. Cleanup explicitly releases every continuation.
        do {
            let f = BackgroundChatFixture(); defer { f.room.close() }
            try await f.connect()
            f.transports["codex"]!.holdAcknowledgement = true
            let work = await f.send(["codex"], text: "Synthetic work with acknowledgement held")
            try await f.wait { f.transports["codex"]!.submissions.last?.gate != nil }
            check(f.transports["codex"]!.submissions.last?.acknowledged == false, "control: the work transport acknowledgement is deterministically held")
            let chat = await f.send(["eve"], text: "Keep chatting while another transport is pending")
            rejection(f, chat)
            check(f.of(chat, "accepted").count == 1 && f.of(chat, "rejected").isEmpty, "a pending transport acknowledgement must not block another teammate's chat")
            f.transports["codex"]!.releaseAcknowledgements()
            try await f.wait { f.transports["codex"]!.submissions[0].acknowledged }
            await f.room.dispatch(["action": "stop"])
            try await f.wait { f.of(work, "settled").count == 1 }
            check(f.transports["codex"]!.submissions[0].gate == nil && f.of(work, "finished").count == 1, "control: acknowledgement and Stop cleanup leave no suspended fixture or duplicate finish")
        }
        print("Background/chat review: \(passed) passed, \(failed) failed; synthetic transports only")
        if failed > 0 { exit(1) }
    }
}
