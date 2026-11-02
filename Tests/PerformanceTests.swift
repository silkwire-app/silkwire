import Foundation

@main struct PerformanceTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-performance-\(UUID())")
        let store = ConversationStore(directory: root)
        let prose = String(repeating: "A measured native workspace keeps typing and scrolling responsive. ", count: 8)
        let imageBytes = Data(repeating: 77, count: 300000)
        store.conversation.messages = (0..<160).map { index in
            Message(author: index % 4 == 0 ? "Jason" : "Codex", text: "## Synthetic message \(index)\n\n" + prose, state: "completed", attachments: index < 20 ? [Attachment(name: "Synthetic image \(index).png", mimeType: "image/png", data: imageBytes)] : nil)
        }
        precondition(store.save())
        var times: [Double] = []
        for index in 0..<80 {
            let start = Date.timeIntervalSinceReferenceDate
            store.conversation.draft = String(repeating: "x", count: index + 1)
            store.scheduleSave()
            times.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
        }
        precondition(store.save())
        let saved = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
        precondition(saved.conversations.first { $0.id == store.conversation.id }?.draft == String(repeating: "x", count: 80))
        let sorted = times.sorted(), bytes = try Data(contentsOf: root.appendingPathComponent("workspace.json")).count
        let result: [String: Any] = ["messages": 160, "libraryBytes": bytes, "edits": times.count, "medianMainThreadEditMs": sorted[sorted.count/2], "p95MainThreadEditMs": sorted[Int(Double(sorted.count)*0.95)], "maxMainThreadEditMs": sorted.last!]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
        store.shutdown()
        // An older queued checkpoint must never overwrite a newer critical save.
        let ordering = ConversationStore(directory: root.appendingPathComponent("ordering"))
        ordering.conversation.draft = "older checkpoint"; ordering.scheduleSave()
        try await Task.sleep(for: .milliseconds(550))
        ordering.conversation.draft = "newest critical draft"; precondition(ordering.save())
        try await Task.sleep(for: .milliseconds(600))
        let ordered = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: ordering.directory.appendingPathComponent("workspace.json")))
        precondition(ordered.conversations.first?.draft == "newest critical draft")
        ordering.shutdown()
        // A background write error still fences sending and retains the previous bytes.
        let failed = ConversationStore(directory: root.appendingPathComponent("failed"))
        let original = failed.directory.appendingPathComponent("workspace.json"), retained = failed.directory.appendingPathComponent("retained.json")
        let before = try Data(contentsOf: original)
        try FileManager.default.moveItem(at: original, to: retained)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        failed.conversation.draft = "unsaved but retained in memory"; failed.scheduleSave()
        try await Task.sleep(for: .milliseconds(900))
        precondition(failed.storageError != nil && !failed.canSend)
        let untouched = try Data(contentsOf: retained); precondition(untouched == before)
        // Regression for the Oct 28 Send freeze: when one save is slower than the checkpoint
        // interval, typing must not pile up full-library saves that Send then waits behind.
        let slow = ConversationStore(directory: root.appendingPathComponent("backlog"))
        let writesBefore = slow.persistenceWriteCount
        slow.persistenceQueue.async { Thread.sleep(forTimeInterval: 3) }  // a 3 s disk stall
        for index in 0..<12 {
            slow.conversation.draft = "typing during a slow save \(index)"; slow.scheduleSave()
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .milliseconds(2000))
        let backgroundWrites = slow.persistenceWriteCount - writesBefore
        precondition(backgroundWrites >= 1 && backgroundWrites <= 3, "background saves piled up behind a slow write: \(backgroundWrites)")
        let sendStarted = Date()
        slow.conversation.draft = "final draft"; precondition(slow.save())
        let sendWait = Date().timeIntervalSince(sendStarted)
        precondition(sendWait < 1, "Send waited \(sendWait) s behind queued saves")
        let latest = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: slow.directory.appendingPathComponent("workspace.json")))
        precondition(latest.conversations.first?.draft == "final draft")
        print("PASS: slow-disk backlog coalesced to \(backgroundWrites) background writes; Send waited \(String(format: "%.3f", sendWait)) s")
        slow.shutdown()
        // Regression: pressing Send while every save is slow must not freeze the window, must put
        // the message on disk before any dispatch attempt, and must not allow a second Send.
        let sender = ConversationStore(directory: root.appendingPathComponent("send-under-load"))
        for agent in sender.participants { sender.seats[agent]?.state = "connected" }
        sender.conversation.draft = "A few hundred words typed while saves are slow."
        precondition(sender.canSend, "fixture should allow Send")
        sender.persistenceQueue.async { Thread.sleep(forTimeInterval: 3) }  // slow disk
        let clicked = Date(); sender.send(); let blocked = Date().timeIntervalSince(clicked)
        precondition(blocked < 0.25, "Send blocked the main thread for \(blocked) s")
        precondition(sender.busy && !sender.canSend, "Send must reserve the turn so it cannot be pressed twice")
        var ticks = 0; let tickStart = Date()
        while Date().timeIntervalSince(tickStart) < 1 { try await Task.sleep(for: .milliseconds(50)); ticks += 1 }
        precondition(ticks >= 10, "main actor starved during a slow save: \(ticks) ticks")
        try await Task.sleep(for: .milliseconds(3000))
        let stored = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: sender.directory.appendingPathComponent("workspace.json")))
        precondition(stored.conversations.first { $0.id == sender.conversation.id }?.messages.contains { $0.author == "Jason" && $0.text.hasPrefix("A few hundred words") } == true, "message must be on disk before dispatch")
        precondition(!sender.busy, "turn must settle (this fixture has no room)")
        precondition(sender.conversation.draft.hasPrefix("A few hundred words"), "draft kept until a room accepts it")
        sender.shutdown()
        // Stop while the message is still saving: nothing dispatches and the draft is kept.
        let stopper = ConversationStore(directory: root.appendingPathComponent("stop-while-saving"))
        for agent in stopper.participants { stopper.seats[agent]?.state = "connected" }
        stopper.conversation.draft = "Stop me before I go"
        stopper.persistenceQueue.async { Thread.sleep(forTimeInterval: 1.5) }
        stopper.send(); stopper.stop()
        try await Task.sleep(for: .milliseconds(2500))
        precondition(!stopper.busy && stopper.conversation.draft == "Stop me before I go", "Stop while saving must settle and keep the draft")
        precondition(!stopper.conversation.messages.contains { ["sent", "sending", "queued"].contains($0.state) }, "nothing may remain sent or pending after Stop")
        stopper.shutdown()
        print("PASS: Send under a 3 s slow save blocked the main thread \(String(format: "%.3f", blocked)) s (\(ticks) main-actor ticks in 1 s); message stored before dispatch; Stop while saving kept the draft")
        print("PASS: bounded draft checkpoints; newer critical snapshot wins; async write failures fence sending and retain previous bytes")
    }
}
