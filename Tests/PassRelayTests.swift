import Foundation
import AppKit

// Pass and Send-while-working, end to end through the store and native room with
// synthetic teammates. Claude always passes here; Eve and Codex keep working.
@MainActor final class RelayProbeTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    var reply: () -> String
    init(reply: @escaping () -> String) { self.reply = reply }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false)
        self.identity = value
        return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        try? await Task.sleep(for: .milliseconds(30))
        eventHandler?(.delta(reply()))
        eventHandler?(.finished(status: "completed", message: nil))
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport: no account inspection") }
}

@main struct PassRelayTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func wait(_ label: String, seconds: Double = 30, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        check(ConversationStore.isPass("PASS") && ConversationStore.isPass(" pass. "), "a bare PASS reply counts as passing")
        check(!ConversationStore.isPass("PASS: all checks succeeded") && !ConversationStore.isPass("PASS — nothing to add") && !ConversationStore.isPass("Pass, tests green"), "short results that start with PASS are kept, never hidden as a pass")
        check(!ConversationStore.isPass("Password reset flow is done.") && !ConversationStore.isPass("PASS\nbut here is a long explanation"), "real replies that merely start with 'pass' are not passes")

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/tests/PassRelay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var project = Project(); project.name = "Synthetic relay regression"
        var conversation = Conversation(); conversation.projectID = project.id; conversation.recipient = "eve,claude,codex"
        try JSONEncoder().encode(ConversationWorkspace(activeID: conversation.id, conversations: [conversation], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))

        var allPass = false
        var transports: [String: RelayProbeTransport] = [:]
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in
            let t = RelayProbeTransport(reply: { agent == "claude" || allPass ? "PASS" : "\(agent) made progress." })
            transports[agent] = t; return t
        }, workspaceSandbox: stage)
        defer { store.disconnect() }
        guard store.storageError == nil else { print("FAIL: library"); exit(1) }
        await store.start()
        try await wait("connection") { !store.connecting && agents.allSatisfy { store.seats[$0]?.state == "connected" } }
        store.conversation.recipient = "eve,claude,codex"
        check(!store.canPass, "Pass waits until the team has said something")

        // Prompt, then Pass immediately: up to six substantive replies, shared.
        store.conversation.draft = "Build the multi-tenancy layer."
        store.send()
        check(store.busy && store.canPass, "Pass is available right after sending")
        store.pass()
        check(store.relayActive, "Pass during the first round keeps the team going afterwards")
        try await wait("relay end") { !store.busy && !store.relayActive }
        let replies = store.conversation.messages.filter { $0.author != "Jason" && $0.state == "completed" }
        let substantive = replies.filter { !ConversationStore.isPass($0.text) }
        check(substantive.count == ConversationStore.relayLimit, "the pass uses exactly the shared pool of six substantive replies (got \(substantive.count))")
        check(substantive.filter { $0.author == "Eve" }.count == 3 && substantive.filter { $0.author == "Codex" }.count == 3, "when Claude passes, Eve and Codex split the six replies three each")
        check(replies.filter { $0.author == "Claude" }.count == 1 && replies.first { $0.author == "Claude" }?.text == ConversationStore.passedText, "Claude passes once, shown quietly, and sits out the rest")
        let passPrompts = store.conversation.messages.filter { $0.author == "Jason" && $0.text.hasPrefix("Pass.") }
        check(passPrompts.count == 1, "one Pass click during a reply produces only one Jason Pass entry (got \(passPrompts.count))")
        let automatic = store.conversation.messages.filter { $0.author == "Silkwire" && $0.detail == "Pass continuation" }
        check(automatic.count == 1 && automatic.allSatisfy { $0.state == "sent" && $0.text.contains("not a new click") }, "later rounds are explicitly labelled automatic continuation, not another Jason click")

        // Jason's screenshot case: one late, idle Pass spans multiple rounds.
        let jasonBeforeIdle = passPrompts.count
        let automaticBeforeIdle = automatic.count
        check(store.canPass, "a late Pass is available after all earlier replies finish")
        store.pass()
        store.pass() // Duplicate activation while this Pass is active must do nothing.
        try await wait("late idle pass") { !store.busy && !store.relayActive }
        let idlePasses = store.conversation.messages.filter { $0.author == "Jason" && $0.text.hasPrefix("Pass.") }
        let idleAutomatic = store.conversation.messages.filter { $0.author == "Silkwire" && $0.detail == "Pass continuation" }
        check(idlePasses.count == jasonBeforeIdle + 1, "one late Pass plus a repeated activation still records exactly one Jason action")
        check(idleAutomatic.count == automaticBeforeIdle + 2, "a late Pass continues automatically through the remaining two rounds")
        check(store.relayUsed == ConversationStore.relayLimit, "labelling automatic continuation does not reset or expand the six-reply pool")
        let savedPasses = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: library.appendingPathComponent("workspace.json")))
        let savedMessages = savedPasses.conversations.first { $0.id == store.conversation.id }!.messages
        check(savedMessages.filter { $0.author == "Jason" && $0.text.hasPrefix("Pass.") }.count == idlePasses.count &&
            savedMessages.filter { $0.author == "Silkwire" && $0.detail == "Pass continuation" }.count == idleAutomatic.count,
            "saved transcript preserves the difference between a click and automatic continuation")
        check(transports["eve"]?.prompts.last?.contains("reply with exactly PASS") == true, "teammates are told how to pass and to stay within the current task")

        // Everyone passes: the pass ends after one round instead of looping.
        allPass = true
        let before = store.conversation.messages.count
        check(store.canPass, "Pass is available when idle after a conversation")
        store.pass()
        try await wait("all-pass end") { !store.busy && !store.relayActive }
        check(store.conversation.messages.count - before == 4 && store.status.contains("Everyone passed"), "when everyone passes the round ends and Jason is told")
        allPass = false

        // Talk any time: Send while working sends at once (nothing queues), and the team
        // answers it as each teammate frees up.
        store.conversation.draft = "First request."
        store.send()
        check(store.busy, "first request is in progress")
        store.conversation.draft = "FORGOT-THIS-SENTENCE-882"
        check(store.canSend, "the composer stays usable while the team works")
        store.send()
        check(!store.hasQueued && store.conversation.draft.isEmpty && store.conversation.messages.contains { $0.author == "Jason" && $0.text == "FORGOT-THIS-SENTENCE-882" }, "Send while working sends at once: into the transcript, composer cleared, nothing queued")
        try await wait("mid-round delivery") { !store.busy && store.conversation.messages.contains { $0.author == "Jason" && $0.text == "FORGOT-THIS-SENTENCE-882" && $0.state == "sent" } }
        check(transports["eve"]?.prompts.last?.contains("FORGOT-THIS-SENTENCE-882") == true, "the addition reaches the team")
        check(transports.values.allSatisfy { $0.prompts.filter { $0.contains("FORGOT-THIS-SENTENCE-882") }.count <= 1 }, "each teammate receives the addition at most once")

        // A waiting addition saved by an earlier build comes back to the composer after a
        // restart: never lost, never sent automatically.
        let restarted = root.appendingPathComponent("restarted")
        try FileManager.default.createDirectory(at: restarted, withIntermediateDirectories: true)
        var legacy = store.conversation; legacy.queuedText = "SAVED-ADDITION-209"; legacy.draft = ""
        try JSONEncoder().encode(ConversationWorkspace(activeID: legacy.id, conversations: [legacy], projects: [project])).write(to: restarted.appendingPathComponent("workspace.json"))
        let reopened = ConversationStore(directory: restarted, transportFactory: { _, _ in RelayProbeTransport(reply: { "ok" }) }, workspaceSandbox: stage)
        defer { reopened.disconnect() }
        await reopened.start()
        check(!reopened.hasQueued && reopened.conversation.draft.contains("SAVED-ADDITION-209"), "after a restart a legacy waiting addition is back in the composer, not lost and not sent automatically")

        // Stop with two messages live: neither unsent one is lost, and none is dispatched.
        store.conversation.draft = "Another request."
        store.send()
        store.conversation.draft = "KEEP-ME-551"
        store.send()
        check(store.busy && !store.hasQueued, "two messages are live at once")
        store.stop()
        try await wait("stop settles") { !store.busy }
        check(store.conversation.draft.contains("KEEP-ME-551") && store.conversation.draft.contains("Another request."), "Stop before dispatch returns both unsent messages to the composer")
        check(!transports.values.contains { $0.prompts.contains { $0.contains("KEEP-ME-551") } }, "a message stopped before dispatch is never sent")

        print("PassRelayTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
