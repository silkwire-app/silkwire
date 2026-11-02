import Foundation
import AppKit
import SwiftUI
import Combine

// Component-level baseline, not a full ConversationView keyboard/frame benchmark.
// The production test runner excludes SilkwireApp.swift, so these measurements
// deliberately cover the native editor binding, store, streaming and persistence.
// Timing is diagnostic rather than a machine-dependent pass/fail threshold.
@MainActor final class TypingStreamProbe: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    var startedSending = false
    var emitted = 0
    static let chunkCount = 400
    static func chunk(_ index: Int) -> String { "chunk-\(index) 🧵 " }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: "synthetic-typing-" + UUID().uuidString, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text); startedSending = true
        for index in 0..<Self.chunkCount {
            try await Task.sleep(for: .milliseconds(3))
            eventHandler?(.delta(Self.chunk(index))); emitted += 1
        }
        eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic typing probe: no account inspection") }
}

@main struct TypingResponsivenessReviewTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + 30
            while !predicate() {
                guard ProcessInfo.processInfo.systemUptime < end else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("output/tests/typing-review-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let prose = String(repeating: "Synthetic Markdown **history** with a decision, a list and a source reference.\n", count: 12)
        let attachment = Attachment(name: "Synthetic payload.bin", mimeType: "application/octet-stream", data: Data(repeating: 77, count: 131072))
        for messageCount in [50, 500, 2000] {
            let library = root.appendingPathComponent("history-\(messageCount)")
            try files.createDirectory(at: library, withIntermediateDirectories: true)
            let sandbox = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging-\(messageCount)"))
            var project = Project(); project.name = "Synthetic typing review"
            var chat = Conversation(); chat.projectID = project.id; chat.focusedAgent = "codex"; chat.recipient = "codex"
            chat.messages = (0..<messageCount).map { index in
                Message(author: index % 2 == 0 ? "Jason" : "Codex", text: "HISTORY-\(index)-ONLY\n" + prose, state: index % 2 == 0 ? "sent" : "completed", attachments: index < 8 ? [Attachment(name: "Payload \(index)", mimeType: attachment.mimeType, data: attachment.data)] : nil)
            }
            let originalHistory = try encoder.encode(chat.messages)
            let file = library.appendingPathComponent("workspace.json")
            try encoder.encode(ConversationWorkspace(activeID: chat.id, conversations: [chat], projects: [project])).write(to: file)
            var probes: [TypingStreamProbe] = []
            let store = ConversationStore(directory: library, transportFactory: { _, _ in
                let probe = TypingStreamProbe(); probes.append(probe); return probe
            }, workspaceSandbox: sandbox)
            check(store.storageError == nil, "\(messageCount): synthetic history opens")
            await store.start()
            try await wait("connected") { !store.connecting && store.seats["codex"]?.state == "connected" }
            store.conversation.draft = "Please produce a synthetic streaming reply."
            check(store.canSend, "\(messageCount): long-history fixture can send")
            store.send()
            try await wait("synthetic stream started") { probes.contains { $0.startedSending } }
            guard let probe = probes.first(where: { $0.startedSending }) else { throw nativeFailure("No synthetic sender") }
            let revisionBefore = store.transcriptRevision, writesBefore = store.persistenceWriteCount
            var publications = 0
            let observation = store.objectWillChange.sink { publications += 1 }
            let composer = NativeComposer(text: Binding(get: { store.conversation.draft }, set: { store.conversation.draft = $0; store.scheduleSave() }), enabled: true, addURLs: { _ in }, addImage: { _ in }, send: {})
            let coordinator = composer.makeCoordinator()
            let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 82))
            coordinator.synchronizeText(in: field)
            var intended = "", editMs: [Double] = [], wakeExcessMs: [Double] = []
            var editsWhileBusy = 0
            for index in 0..<80 {
                let start = now()
                intended += index % 7 == 0 ? "🧵" : "x"
                field.string = intended
                field.setSelectedRange(NSRange(location: (intended as NSString).length, length: 0))
                coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
                coordinator.synchronizeText(in: field)
                editMs.append((now() - start) * 1000)
                if store.busy { editsWhileBusy += 1 }
                let sleepStart = now()
                try await Task.sleep(for: .milliseconds(8))
                wakeExcessMs.append(max(0, (now() - sleepStart) * 1000 - 8))
            }
            check(editsWhileBusy > 0, "\(messageCount): native editor callbacks overlap an active reply")
            check(field.string == intended && store.conversation.draft == intended, "\(messageCount): Unicode draft survives stream-triggered editor synchronization")
            check(field.selectedRange().location == (intended as NSString).length, "\(messageCount): editor caret remains at its intended position")
            try await wait("stream complete") { !store.busy }
            observation.cancel()
            let expectedReply = (0..<TypingStreamProbe.chunkCount).map(TypingStreamProbe.chunk).joined()
            let replies = store.conversation.messages.filter { $0.author == "Codex" && $0.requestId != nil }
            check(replies.count == 1 && replies.first?.text == expectedReply && replies.first?.state == "completed", "\(messageCount): coalesced streaming preserves every chunk exactly once")
            check(probe.prompts.count == 1 && probes.reduce(0, { $0 + $1.prompts.count }) == 1, "\(messageCount): typing does not submit another request")
            check(store.transcriptRevision - revisionBefore < UInt64(TypingStreamProbe.chunkCount / 2), "\(messageCount): stream publication is batched instead of one revision per chunk")
            check(store.persistenceWriteCount - writesBefore < 80, "\(messageCount): typing and streaming do not save once per edit")
            check(try encoder.encode(Array(store.conversation.messages.prefix(messageCount))) == originalHistory, "\(messageCount): all upstream messages and attachment bytes remain unchanged")
            let saveStart = now()
            check(store.save(), "\(messageCount): latest draft and completed reply reach a critical save")
            let criticalSaveMs = (now() - saveStart) * 1000
            try await Task.sleep(for: .milliseconds(600))
            let savedBytes = try Data(contentsOf: file)
            let saved = try JSONDecoder().decode(ConversationWorkspace.self, from: savedBytes)
            guard let persisted = saved.conversations.first(where: { $0.id == chat.id }) else { throw nativeFailure("Saved chat missing") }
            check(persisted.draft == intended, "\(messageCount): an older background snapshot cannot overwrite the newest draft")
            check(try encoder.encode(Array(persisted.messages.prefix(messageCount))) == originalHistory && persisted.messages.count == messageCount + 2, "\(messageCount): persisted history is complete, not trimmed to a display window")
            check(persisted.messages.last(where: { $0.author == "Codex" })?.text == expectedReply, "\(messageCount): completed stream is durable")
            let metrics: [String: Any] = ["scope": "native editor binding + store; excludes full SwiftUI transcript rendering", "historyMessages": messageCount, "fixtureBytes": savedBytes.count, "editCallbacks": editMs.count, "editsWhileReplyActive": editsWhileBusy, "editorCallbackP95Ms": percentile(editMs, 0.95), "editorCallbackMaxMs": editMs.max() ?? 0, "mainActorWakeExcessP95Ms": percentile(wakeExcessMs, 0.95), "mainActorWakeExcessMaxMs": wakeExcessMs.max() ?? 0, "criticalSaveMs": criticalSaveMs, "storePublicationsDuringStream": publications, "streamChunks": probe.emitted]
            print("METRICS " + String(data: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), encoding: .utf8)!)
            store.disconnect()
        }
        print("TypingResponsivenessReviewTests: \(checks) checks, \(failures) failures. Diagnostic timings are not full-app typing latency or a memory measurement.")
        if failures > 0 { exit(1) }
    }
}
