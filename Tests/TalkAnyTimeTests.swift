import Foundation
import AppKit

// Turn-free step 2, "talk any time": per-teammate state instead of one room-wide busy flag.
// A message sent mid-round reaches free teammates at once and busy ones as soon as they
// finish; Stop works per teammate. Pretend teammates only; nothing leaves the machine.
@MainActor final class TalkTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String
    let library: URL?
    /// While true, a reply waits until the test calls reply().
    var hold = false
    var prompts: [(request: String, text: String)] = []
    /// Whether Jason's message was already on disk at the instant it was dispatched.
    var storedAtDispatch: [Bool] = []
    var stops = 0
    init(_ agent: String, library: URL? = nil) { self.agent = agent; self.library = library }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: "fixture-" + agent, started: false); self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append((requestID.lowercased(), text))
        if let library {
            let saved = (try? Data(contentsOf: library.appendingPathComponent("workspace.json"))).flatMap { try? JSONDecoder().decode(ConversationWorkspace.self, from: $0) }
            let mine = saved?.conversations.flatMap(\.messages).first { $0.requestId?.lowercased() == requestID.lowercased() && ($0.author == "Jason" || $0.author == "Silkwire") }
            storedAtDispatch.append(mine.map { text.contains($0.text) } ?? false)
        }
        guard !hold else { return }
        let request = requestID
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(15))
            guard let self else { return }
            self.eventHandler?(.delta("\(self.agent) answered \(request.prefix(8))"))
            self.eventHandler?(.finished(status: "completed", message: nil))
        }
    }
    func reply(_ text: String) { eventHandler?(.delta(text)); eventHandler?(.finished(status: "completed", message: nil)) }
    func stop() async throws { stops += 1; eventHandler?(.finished(status: "interrupted", message: "Stopped by Jason")) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture") }
}

/// Holds library writes until released, so a message can be kept "still saving".
final class TalkWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var holding = false, waiting: [DispatchSemaphore] = []
    func hold() { lock.lock(); holding = true; lock.unlock() }
    func release() { lock.lock(); holding = false; let held = waiting; waiting = []; lock.unlock(); held.forEach { $0.signal() } }
    var held: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
    func write(_ data: Data, _ url: URL) throws {
        lock.lock(); let gate: DispatchSemaphore? = holding ? DispatchSemaphore(value: 0) : nil; if let gate { waiting.append(gate) }; lock.unlock()
        gate?.wait()
        try data.write(to: url, options: .atomic)
    }
}

@main struct TalkAnyTimeTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL: " + label) }
            checks += 1; print("PASS " + label)
        }
        func wait(_ label: String, seconds: Double = 15, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() { guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }; try await Task.sleep(for: .milliseconds(5)) }
        }

        // Display: answers to two live messages never trade places across Jason's message.
        do {
            let j1 = UUID(), e1 = UUID(), c1 = UUID(), j2 = UUID(), e2 = UUID(), c2 = UUID()
            let request = [e1: "r1", c1: "r1", e2: "r2", c2: "r2"]
            // Eve answered both before Codex said a word on the first.
            let seq = [e1: 1, e2: 2, c1: 3, c2: 4]
            let order = TranscriptFlow.speakingOrder([j1, c1, e1, j2, c2, e2], id: { $0 }, seq: seq, group: { request[$0] })
            try check(order == [j1, e1, c1, j2, e2, c2], "replies keep speaking order within their own message, never above Jason's next one")
            try check(TranscriptFlow.speakingOrder([j1, c1, e1], id: { $0 }, seq: [e1: 1, c1: 2]) == [j1, e1, c1], "without groups the speaking order is unchanged")
        }

        // MARK: Room
        var events: [[String: Any]] = [], transports: [String: TalkTransport] = [:]
        let room = NativeRoom(emit: { events.append($0) }, factory: { agent, _ in let t = TalkTransport(agent); transports[agent] = t; return t })
        defer { room.close() }
        await room.dispatch(["action": "connect", "conversationID": UUID().uuidString.lowercased(), "participants": ["eve", "claude", "codex"], "projectFolders": [[String: String]]()])
        try await wait("room connected") { events.filter { $0["type"] as? String == "connection" && $0["state"] as? String == "connected" }.count >= 3 }
        let eve = transports["eve"]!, codex = transports["codex"]!, claude = transports["claude"]!
        func of(_ id: String, _ type: String, _ agent: String? = nil) -> [[String: Any]] {
            events.filter { $0["requestId"] as? String == id && $0["type"] as? String == type && (agent == nil || $0["agent"] as? String == agent) }
        }
        func send(_ targets: [String], text: String = "Synthetic request", openFloor: Bool = false, wait: Bool = true) async -> String {
            let id = UUID().uuidString.lowercased()
            var value: [String: Any] = ["action": "send", "requestId": id, "text": text, "targets": targets, "history": [[String: String]](), "historyTotal": 0, "openFloor": openFloor]
            if wait { value["waitForBusy"] = true }
            await room.dispatch(value)
            return id
        }
        func prompts(_ t: TalkTransport, _ id: String) -> [String] { t.prompts.filter { $0.request == id }.map(\.text) }

        // 1. Free teammates get a mid-round message at once; a busy one gets it when done.
        eve.hold = true
        let r1 = await send(["eve"], text: "First task for Eve")
        try await wait("eve has r1") { !prompts(eve, r1).isEmpty }
        let refused = await send(["eve", "codex"], wait: false)
        try check(of(refused, "rejected").first.map { ($0["message"] as? String ?? "").contains("still working") } == true, "without waitForBusy a busy teammate still refuses the message (old rule kept)")
        let r2 = await send(["eve", "codex"], text: "MID-ROUND-312", openFloor: true)
        try await wait("codex answers r2") { of(r2, "finished", "codex").count == 1 }
        try check(of(r2, "waiting", "eve").count == 1 && prompts(eve, r2).isEmpty, "Eve, still busy, is marked waiting and has not been sent the new message")
        try check(of(r1, "settled").isEmpty && of(r2, "settled").isEmpty, "neither message settles while Eve still owes replies")
        eve.hold = false
        eve.reply("EVE-R1-ANSWER-731")
        try await wait("both settle") { of(r1, "settled").count == 1 && of(r2, "settled").count == 1 }
        try check(prompts(eve, r2).count == 1 && prompts(eve, r2)[0].contains("MID-ROUND-312"), "Eve gets the mid-round message once, right after finishing")
        try check(prompts(eve, r2)[0].contains("EVE-R1-ANSWER-731"), "the late start includes the reply Eve finished meanwhile, so her context isn't stale")
        try check(of(r2, "finished").filter { $0["status"] as? String == "completed" }.count == 2 && of(r2, "finished").count == 2, "each teammate finishes the new message exactly once")
        let eveStarts = events.enumerated().filter { $0.element["type"] as? String == "started" && $0.element["agent"] as? String == "eve" }.map(\.offset)
        let eveR1End = events.firstIndex { $0["requestId"] as? String == r1 && $0["type"] as? String == "finished" && $0["agent"] as? String == "eve" }!
        try check(eveStarts.count == 2 && eveStarts[1] > eveR1End, "Eve works one message at a time: the new one starts only after the first ends")

        // 2. Sequential: the free teammate goes now; the busy one when free; the turn settles once.
        eve.hold = true
        let r3 = await send(["eve"])
        try await wait("eve has r3") { !prompts(eve, r3).isEmpty }
        let r4 = await send(["codex", "eve"], text: "Sequential while busy")
        try await wait("codex answers r4") { of(r4, "finished", "codex").count == 1 }
        try check(of(r4, "waiting", "eve").count == 1 && prompts(eve, r4).isEmpty, "in turn-taking mode the busy teammate's turn waits")
        eve.hold = false; eve.reply("eve r3 done")
        try await wait("r4 settles") { of(r4, "settled").count == 1 }
        try check(prompts(eve, r4).count == 1 && prompts(eve, r4)[0].contains("codex answered"), "Eve's turn still sees Codex's earlier reply to the same message")

        // 3. Several messages for one busy teammate are taken oldest first, each once.
        eve.hold = true
        let r5 = await send(["eve"])
        try await wait("eve has r5") { !prompts(eve, r5).isEmpty }
        let r6 = await send(["eve"]), r7 = await send(["eve"])
        try check(of(r6, "waiting", "eve").count == 1 && of(r7, "waiting", "eve").count == 1, "both later messages wait")
        eve.hold = false; eve.reply("eve r5 done")
        try await wait("r6 and r7 settle") { of(r6, "settled").count == 1 && of(r7, "settled").count == 1 }
        let order = eve.prompts.map(\.request).filter { [r5, r6, r7].contains($0) }
        try check(order == [r5, r6, r7], "Eve takes waiting messages in the order Jason sent them, each exactly once")

        // 4. One teammate's Stop: ends their reply and what's waiting for them; others go on.
        eve.hold = true; codex.hold = true
        let r8 = await send(["eve", "codex"], openFloor: true)
        try await wait("both have r8") { !prompts(eve, r8).isEmpty && !prompts(codex, r8).isEmpty }
        let r9 = await send(["eve", "codex"], text: "Waiting behind Stop", openFloor: true)
        try await wait("both wait on r9") { of(r9, "waiting").count == 2 }
        let eveStops = eve.stops
        await room.dispatch(["action": "stop", "agent": "eve"])
        try await wait("eve stops") { of(r8, "finished", "eve").count == 1 && of(r9, "finished", "eve").count == 1 }
        try check(of(r8, "finished", "eve").first?["status"] as? String == "interrupted" && eve.stops == eveStops + 1, "Eve's running reply is interrupted")
        try check(of(r9, "finished", "eve").first?["status"] as? String == "cancelled" && prompts(eve, r9).isEmpty, "the message waiting for Eve is cancelled and never sent to her")
        try check(of(r8, "finished", "codex").isEmpty && of(r8, "settled").isEmpty && codex.stops == 0, "Codex is untouched and still working")
        codex.hold = false; codex.reply("codex r8 done")
        try await wait("r8 and r9 settle") { of(r8, "settled").count == 1 && of(r9, "settled").count == 1 }
        try check(of(r9, "finished", "codex").first?["status"] as? String == "completed" && of(r9, "finished").count == 2, "Codex still answers the message Eve's Stop cancelled for her")
        eve.hold = false
        let r10 = await send(["eve"])
        try await wait("eve answers after Stop") { of(r10, "settled").count == 1 }
        try check(of(r10, "finished", "eve").first?["status"] as? String == "completed", "a message sent after Eve's Stop reaches her")

        // 5. Stopping a teammate whose sequential turn hasn't come skips them; the rest go on.
        eve.hold = true
        let r11 = await send(["eve", "codex", "claude"], wait: false)
        try await wait("eve has r11") { !prompts(eve, r11).isEmpty }
        await room.dispatch(["action": "stop", "agent": "codex"])
        try check(of(r11, "finished", "codex").first?["status"] as? String == "cancelled" && of(r11, "finished", "eve").isEmpty, "Codex's pending turn is cancelled at once; Eve keeps going")
        eve.hold = false; eve.reply("eve r11 done")
        try await wait("r11 settles") { of(r11, "settled").count == 1 }
        try check(prompts(codex, r11).isEmpty && of(r11, "finished", "claude").first?["status"] as? String == "completed" && of(r11, "finished").count == 3, "the turn skips Codex and Claude still answers; everyone ends once")
        _ = claude

        // 6. The whole-team Stop also ends messages that were waiting.
        eve.hold = true
        let r12 = await send(["eve"])
        try await wait("eve has r12") { !prompts(eve, r12).isEmpty }
        let r13 = await send(["eve", "codex"], openFloor: true)
        try await wait("codex answers r13") { of(r13, "finished", "codex").count == 1 && of(r13, "waiting", "eve").count == 1 }
        await room.dispatch(["action": "stop"])
        try await wait("all settle") { of(r12, "settled").count == 1 && of(r13, "settled").count == 1 }
        try check(of(r12, "finished", "eve").first?["status"] as? String == "interrupted" && of(r13, "finished", "eve").first?["status"] as? String == "cancelled", "team Stop interrupts the running reply and cancels the waiting one")
        try await Task.sleep(for: .milliseconds(100))
        try check(of(r12, "finished").count == 1 && of(r13, "finished").count == 2 && prompts(eve, r13).isEmpty, "nothing ends twice or starts late after Stop")

        // 7. A teammate dropping out cancels what was waiting for them, and nothing is resent.
        eve.hold = true
        let r14 = await send(["eve"])
        try await wait("eve has r14") { !prompts(eve, r14).isEmpty }
        let r15 = await send(["eve"])
        eve.eventHandler?(.disconnected(message: "Synthetic connection lost", uncertain: true))
        try await wait("disconnect settles") { of(r14, "settled").count == 1 && of(r15, "settled").count == 1 }
        try check(of(r14, "finished", "eve").first?["status"] as? String == "unconfirmed" && of(r15, "finished", "eve").first?["status"] as? String == "cancelled" && prompts(eve, r15).isEmpty, "the waiting message is cancelled before dispatch, never sent")

        // MARK: Store
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-talk-any-time-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var project = Project(); project.name = "Talk any time fixture"; project.participants = ["eve", "codex"]
        var conversation = Conversation(); conversation.projectID = project.id; conversation.recipient = "eve"
        try JSONEncoder().encode(ConversationWorkspace(activeID: conversation.id, conversations: [conversation], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))
        var made: [String: TalkTransport] = [:]
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in let t = TalkTransport(agent, library: library); made[agent] = t; return t }, workspaceSandbox: stage)
        let gate = TalkWriteGate()
        store.persistenceWriter = { data, url in try gate.write(data, url) }
        defer { store.disconnect() }
        // Runs first: a failed check while a write is held must report, not hang teardown.
        defer { gate.release() }
        await store.start()
        try await wait("store connected") { !store.connecting && store.seats["eve"]?.state == "connected" && store.seats["codex"]?.state == "connected" }
        let sEve = made["eve"]!, sCodex = made["codex"]!
        func jason(_ text: String) -> Message? { store.conversation.messages.last { $0.author == "Jason" && $0.text == text } }
        func reply(_ request: String?, _ author: String) -> Message? { store.conversation.messages.first { $0.requestId == request && $0.author == author } }

        // 8. Send while Eve works: saved, then sent at once; Codex answers now, Eve when done.
        store.conversation.recipient = "eve"
        sEve.hold = true
        store.conversation.draft = "Eve, start the long job."
        store.send()
        try await wait("eve working") { sEve.prompts.count == 1 }
        try check(store.busy && store.isWorking("eve") && !store.isWorking("codex"), "per-teammate state: Eve is working, Codex is free")
        store.toggleRecipient("codex")
        try check(store.targets == ["eve", "codex"], "recipients can change while a teammate works")
        store.conversation.draft = "MID-ROUND-ADDITION-447"
        try check(store.canSend, "Send is available while the team works")
        store.send()
        try check(store.conversation.draft.isEmpty && !store.hasQueued && jason("MID-ROUND-ADDITION-447") != nil, "the message goes into the transcript at once; nothing is queued")
        let second = jason("MID-ROUND-ADDITION-447")?.requestId
        try await wait("codex answers mid-round") { reply(second, "Codex")?.state == "completed" }
        try check(sEve.prompts.count == 1 && store.busy && reply(second, "Eve")?.state == "queued" && (reply(second, "Eve")?.detail ?? "").contains("Waiting"), "Codex answered while Eve is still busy; Eve's copy is shown waiting")
        try check(sCodex.storedAtDispatch.allSatisfy { $0 } && !sCodex.storedAtDispatch.isEmpty, "the mid-round message was on disk before it was dispatched")
        try check(jason("MID-ROUND-ADDITION-447")?.state == "sent", "the mid-round message is marked sent")
        let ordered = store.conversation.messages.filter { $0.author == "Codex" || $0.author == "Eve" }.map(\.requestId)
        try check(ordered.firstIndex(of: second) != nil, "replies stay attached to their own message")
        sEve.hold = false; sEve.reply("EVE-LONG-JOB-DONE")
        try await wait("store quiet") { !store.busy }
        try check(sEve.prompts.count == 2 && sEve.prompts[1].text.contains("MID-ROUND-ADDITION-447") && sEve.prompts[1].text.contains("EVE-LONG-JOB-DONE"), "Eve gets the addition once, after her reply, with that reply in context")
        try check(sEve.storedAtDispatch.allSatisfy { $0 }, "every dispatch to Eve was saved first")
        try check(Set(sEve.prompts.map(\.request)).count == sEve.prompts.count && Set(sCodex.prompts.map(\.request)).count == sCodex.prompts.count, "no message is ever sent twice to the same teammate")
        try check(store.conversation.messages.filter { $0.author != "Jason" }.allSatisfy { $0.state == "completed" }, "every reply completed")

        // 9. One teammate's Stop from the store: Eve stops; Codex keeps going; Send waits for Stop.
        store.setOpenFloor(true)
        sEve.hold = true; sCodex.hold = true
        store.conversation.draft = "Both of you, go."
        store.send()
        try await wait("both working") { sEve.prompts.count == 3 && sCodex.prompts.count == 2 }
        try check(store.canStopTeammate("eve") && store.canStopTeammate("codex"), "each working teammate can be stopped alone")
        store.stopTeammate("eve")
        try check(store.stoppingAgents == ["eve"], "Eve is marked stopping")
        store.conversation.draft = "While Eve stops"
        try check(!store.canSend, "a message to a teammate still stopping waits for that Stop")
        try await wait("eve stopped") { store.conversation.messages.last { $0.author == "Eve" }?.state == "interrupted" }
        try check(store.stoppingAgents.isEmpty && store.busy && store.isWorking("codex") && !store.isWorking("eve"), "Eve stopped; Codex is still working")
        store.conversation.recipient = "eve"
        try check(store.canSend, "Eve can be messaged again right away")
        store.conversation.draft = ""
        sCodex.hold = false; sCodex.reply("codex finished anyway")
        try await wait("quiet after one stop") { !store.busy }
        try check(store.conversation.messages.last { $0.author == "Codex" }?.state == "completed", "Codex's reply completes after Eve's Stop")
        sEve.hold = false

        // 9b. Stop during save: pause saving, stop one teammate, then let the save land. That
        // teammate never gets the earlier message; the others do; a new message still works.
        store.conversation.recipient = "eve,codex"
        let eveBefore = sEve.prompts.count, codexBefore = sCodex.prompts.count
        gate.hold()
        store.conversation.draft = "SAVE-RACE-603"
        store.send()
        try await wait("save-race write held") { gate.held > 0 }
        let raced = jason("SAVE-RACE-603")?.requestId
        try check(store.canStopTeammate("eve") && sEve.prompts.count == eveBefore, "while the message is saving Eve has it queued and can be stopped")
        store.stopTeammate("eve")
        try check(reply(raced, "Eve")?.state == "cancelled" && reply(raced, "Codex")?.state == "queued", "Eve's copy is cancelled at once; Codex's is untouched")
        try check(!store.isWorking("eve") && store.stoppingAgents.isEmpty, "with nothing else in flight, Eve's Stop finishes immediately")
        gate.release()
        try await wait("save-race settles") { !store.busy }
        try check(!sEve.prompts.contains { $0.request == raced?.lowercased() || $0.text.contains("SAVE-RACE-603") } && sEve.prompts.count == eveBefore, "Eve never receives the message she was stopped from, even though its save finished afterwards")
        try check(sCodex.prompts.filter { $0.request == raced?.lowercased() }.count == 1 && sCodex.prompts.count == codexBefore + 1, "Codex receives it exactly once")
        try check(reply(raced, "Codex")?.state == "completed" && jason("SAVE-RACE-603")?.state == "sent", "Codex answers and the message is marked sent")
        try check(sCodex.storedAtDispatch.last == true, "it was still saved before dispatch")
        store.conversation.draft = "AFTER-STOP-777"
        store.send()
        try await wait("message after stop") { !store.busy && reply(jason("AFTER-STOP-777")?.requestId, "Eve")?.state == "completed" }
        // Counted by request: with open floor on, the chime-in round that follows quotes this
        // message in its history, which is context, not a second delivery.
        let after = jason("AFTER-STOP-777")?.requestId?.lowercased()
        try check(sEve.prompts.filter { $0.request == after }.count == 1 && sCodex.prompts.filter { $0.request == after }.count == 1, "a message sent after the Stop reaches Eve (and Codex) once")
        // Stopping the only recipient while saving: nothing is sent and the draft comes back.
        store.conversation.recipient = "eve"
        let eveSolo = sEve.prompts.count
        gate.hold()
        store.conversation.draft = "SOLO-SAVE-RACE-604"
        store.send()
        try await wait("solo write held") { gate.held > 0 }
        store.stopTeammate("eve")
        gate.release()
        try await wait("solo settles") { !store.busy }
        try check(sEve.prompts.count == eveSolo && jason("SOLO-SAVE-RACE-604")?.state == "failed" && store.conversation.draft.contains("SOLO-SAVE-RACE-604"), "stopping the only recipient while saving sends nothing, marks it Not sent and returns the draft")
        store.conversation.draft = ""

        // 10. A composer still showing an unsaved message is that message: never sent twice.
        store.conversation.recipient = "eve"
        sEve.hold = true
        store.conversation.draft = "Long job two"
        let eveBeforeLong = sEve.prompts.count
        store.send()
        try await wait("eve working again") { sEve.prompts.count == eveBeforeLong + 1 }
        gate.hold()
        store.conversation.draft = "ECHO-CHECK-118"
        store.send()
        try await wait("save held") { gate.held > 0 }
        store.conversation.draft = "ECHO-CHECK-118" // the composer re-publishes the text it just sent
        store.send()
        try check(store.conversation.messages.filter { $0.author == "Jason" && $0.text == "ECHO-CHECK-118" }.count == 1, "re-pressing Send on the same unsaved text doesn't create a second message")
        // 11. That message can't be delivered (Eve drops out); new typing is kept with it.
        store.conversation.draft = "TYPING-THE-NEXT-ONE-905"
        sEve.eventHandler?(.disconnected(message: "Synthetic connection lost", uncertain: false))
        gate.release()
        try await wait("rejected settles") { !store.busy }
        try check(store.conversation.draft.contains("ECHO-CHECK-118") && store.conversation.draft.contains("TYPING-THE-NEXT-ONE-905"), "the unsent message returns to the composer without losing what Jason typed since")
        try check(jason("ECHO-CHECK-118")?.state == "failed" && !sEve.prompts.contains { $0.text.contains("ECHO-CHECK-118") }, "it is labelled Not sent and was never dispatched")

        print("PASS \(checks) talk-any-time checks; pretend teammates only")
    }
}
