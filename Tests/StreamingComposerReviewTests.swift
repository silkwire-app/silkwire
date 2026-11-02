import Foundation
import AppKit
import SwiftUI
import Combine

// Independent, synthetic editor/store regression. No live accounts or libraries,
// no SwiftUI window rendering, and no claim to measure physical key-to-paint time.
@MainActor final class ComposerReviewTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    static let chunks = 480
    static func chunk(_ n: Int) -> String { "piece-\(n) 🧵 " }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let result = identity ?? ProviderIdentity(id: "synthetic-composer-" + UUID().uuidString, started: false)
        self.identity = result; return result
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        for n in 0..<Self.chunks {
            try await Task.sleep(for: .milliseconds(3))
            eventHandler?(.delta(Self.chunk(n)))
        }
        eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic test has no accounts") }
}

@main struct StreamingComposerReviewTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        func wait(_ label: String, until predicate: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while !predicate() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("output/tests/composer-review-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for count in [25, 2000] {
            let directory = root.appendingPathComponent("library-\(count)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let environment = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("sandbox-\(count)"))
            var project = Project(); project.name = "Synthetic composer review"
            var a = Conversation(); a.projectID = project.id; a.focusedAgent = "codex"; a.recipient = "codex"
            a.messages = (0..<count).map { n in
                Message(author: n % 2 == 0 ? "Jason" : "Codex", text: "HISTORY-\(n)\n" + String(repeating: "**Synthetic** paragraph with Unicode 🧵.\n", count: 12), state: n % 2 == 0 ? "sent" : "completed")
            }
            var b = Conversation(); b.projectID = project.id; b.focusedAgent = "codex"; b.recipient = "codex"; b.draft = "B untouched"
            let originalHistory = try encoder.encode(a.messages)
            let file = directory.appendingPathComponent("workspace.json")
            try encoder.encode(ConversationWorkspace(activeID: a.id, conversations: [a, b], projects: [project])).write(to: file)
            var transports: [ComposerReviewTransport] = []
            let store = ConversationStore(directory: directory, transportFactory: { _, _ in
                let result = ComposerReviewTransport(); transports.append(result); return result
            }, workspaceSandbox: environment)
            check(store.storageError == nil, "\(count): isolated fixture opens")
            await store.start()
            try await wait("connected", until: { !store.connecting && store.seats["codex"]?.state == "connected" })
            var bindingWrites = 0, commits = 0
            var composer = NativeComposer(text: Binding(get: { store.conversation.draft }, set: { bindingWrites += 1; store.conversation.draft = $0 }), enabled: true, addURLs: { _ in }, addImage: { _ in }, send: { store.send() }, owner: a.id, commitDraft: { text, id in
                commits += 1; store.setDraft(text, for: id); store.scheduleSave()
            }, onTyping: { store.lastKeystroke = Date() })
            let coordinator = composer.makeCoordinator()
            let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 82))
            coordinator.synchronizeText(in: field)
            // Exercise the synchronous Send flush before the debounce can run.
            store.composerFlush = { [weak coordinator] in coordinator?.commitNow() }
            field.string = "Immediate send 🧵"
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
            check(store.conversation.draft.isEmpty && coordinator.pending != nil, "\(count): text stays local before debounce")
            check(!store.canSend, "\(count): model-based Send eligibility waits for draft commit")
            store.send()
            try await wait("stream began", until: { transports.contains { !$0.prompts.isEmpty } })
            check(commits == 1 && coordinator.pending == nil, "\(count): Send flushes the pending draft exactly once")
            check(store.conversation.messages.last(where: { $0.author == "Jason" })?.text == "Immediate send 🧵", "\(count): immediate Send includes all locally typed Unicode")
            coordinator.synchronizeText(in: field)
            check(field.string.isEmpty, "\(count): sent field clears after model synchronization")

            let revisionsBefore = store.transcriptRevision
            var publications = 0, syncs = 0, damagedSelections = 0
            var expected = ""
            var selection = NSRange(location: 0, length: 0)
            let observation = store.objectWillChange.sink {
                publications += 1
                // objectWillChange fires BEFORE assignment. SwiftUI updates later;
                // synchronizing inline here would read the old draft during a commit
                // and manufacture a clobber that is not a rendered update.
                DispatchQueue.main.async {
                    coordinator.synchronizeText(in: field); syncs += 1
                    if !expected.isEmpty && (field.string != expected || field.selectedRange() != selection) { damagedSelections += 1 }
                }
            }
            var times: [Double] = [], wakeExcess: [Double] = []
            var typingWhileBusy = 0
            for n in 0..<80 {
                let start = ProcessInfo.processInfo.systemUptime
                expected += n % 7 == 0 ? "🧵" : "e\u{301}"
                field.string = expected
                // Keep a UTF-16 selection away from the end, not just an end caret.
                selection = NSRange(location: 0, length: min(2, (expected as NSString).length))
                field.setSelectedRange(selection)
                coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
                coordinator.synchronizeText(in: field)
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                if store.busy { typingWhileBusy += 1 }
                let asleep = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(8))
                wakeExcess.append(max(0, (ProcessInfo.processInfo.systemUptime - asleep) * 1000 - 8))
            }
            check(typingWhileBusy > 0, "\(count): typing overlaps the synthetic stream")
            check(bindingWrites == 0, "\(count): 80 keystrokes cause no direct model binding writes")
            check(field.string == expected && field.selectedRange() == selection, "\(count): local Unicode and selection survive reply synchronization")
            check(coordinator.pending?.owner == a.id, "\(count): uncommitted text remains owned by A")
            let committedBeforePause = commits
            try await wait("debounced commit", until: { coordinator.pending == nil })
            check(commits == committedBeforePause + 1 && store.conversation.draft == expected, "\(count): quiet pause commits the latest draft once")
            try await wait("reply complete", until: { !store.busy })
            observation.cancel()
            check(syncs > 0 && publications > 0, "\(count): the shared store still publishes during typing; coalescing does not silence all publications")
            check(damagedSelections == 0, "\(count): stream publication synchronization never damages field text or selection")
            let expectedReply = (0..<ComposerReviewTransport.chunks).map(ComposerReviewTransport.chunk).joined()
            let replies = store.conversation.messages.filter { $0.author == "Codex" && $0.requestId != nil }
            check(replies.count == 1 && replies[0].text == expectedReply && replies[0].state == "completed", "\(count): all 480 chunks survive batching exactly once")
            check(store.transcriptRevision - revisionsBefore < 100, "\(count): stream revisions coalesce substantially")
            check(transports.reduce(0, { $0 + $1.prompts.count }) == 1, "\(count): editor updates never send an extra request")
            check(try encoder.encode(Array(store.conversation.messages.prefix(count))) == originalHistory, "\(count): upstream history is unchanged")
            check(TranscriptWindow.visible(store.conversation.messages, limit: 25).count == 25 && TranscriptWindow.visible(store.conversation.messages, limit: 15).count == 15, "\(count): either display window leaves the full model intact")

            // A pending edit must be flushed before switching, without writing into B.
            field.string = "A unsaved tail 🧵"
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
            check(store.selectConversation(b.id, reconnect: false), "\(count): idle switch succeeds with pending typing")
            check(store.conversations.first(where: { $0.id == a.id })?.draft == "A unsaved tail 🧵" && store.conversation.draft == "B untouched", "\(count): switch flush belongs to A and never replaces B")
            composer.owner = b.id; coordinator.parent = composer
            coordinator.synchronizeText(in: field)
            check(field.string == "B untouched", "\(count): editor synchronizes the new owner's draft")
            field.string = "B latest"
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: field))
            coordinator.commitNow(); coordinator.commitNow()
            check(store.conversation.draft == "B latest" && coordinator.pending == nil, "\(count): repeated flush is idempotent for B")
            check(store.save(), "\(count): critical save succeeds")
            try await Task.sleep(for: .milliseconds(600))
            let saved = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: file))
            check(saved.conversations.first(where: { $0.id == a.id })?.draft == "A unsaved tail 🧵" && saved.conversations.first(where: { $0.id == b.id })?.draft == "B latest", "\(count): both drafts persist under their own IDs")
            check(try encoder.encode(Array(saved.conversations.first(where: { $0.id == a.id })!.messages.prefix(count))) == originalHistory, "\(count): display limits never trim persisted history")
            let sorted = times.sorted(), wakes = wakeExcess.sorted()
            print("METRICS history=\(count) callbacks=80 callbackP95Ms=\(sorted[Int(Double(sorted.count - 1) * 0.95)]) wakeExcessP95Ms=\(wakes[Int(Double(wakes.count - 1) * 0.95)]) publications=\(publications) explicitEditorSyncs=\(syncs); excludes SwiftUI rendering and key-to-paint latency")
            store.composerFlush = nil; store.disconnect()
        }
        check(TranscriptWindow.initial == 25 && TranscriptWindow.step == 25, "candidate uses 25 initially and 25 per Show earlier")
        let app = try String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)
        check(app.contains("registerFlush:") && app.contains("commitDraft:") && app.contains("onTyping:"), "source contract: production composer opts into all deferred-commit hooks")
        print("StreamingComposerReviewTests: \(checks) checks, \(failures) failures; synthetic editor/store only, not full UI latency")
        if failures > 0 { exit(1) }
    }
}
