import Foundation
import AppKit

// Team memory end to end: a teammate saves a note in a finished reply, Silkwire
// stores it in the Project, and after a restart the note reaches the next
// agent's actual input. Synthetic transports only; no provider or real library.
@MainActor final class MemoryProbeTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    let reply: String
    init(reply: String) { self.reply = reply }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: UUID().uuidString, started: false)
        self.identity = value
        return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        eventHandler?(.delta(reply))
        eventHandler?(.finished(status: "completed", message: nil))
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic transport: no account inspection") }
}

@main struct TeamMemoryTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(30)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        // Extraction
        let reply = "Sounds good.\n<<REMEMBER {\"kind\":\"decision\",\"text\":\"Jason chose Avenir Next for messages.\"}>>\nMore text."
        let extracted = TeamMemory.extract(from: reply)
        check(extracted.notes.count == 1 && extracted.notes.first?.kind == "decision" && extracted.notes.first?.text == "Jason chose Avenir Next for messages.", "a REMEMBER line becomes one saved note")
        check(!extracted.text.contains("<<REMEMBER") && !extracted.text.contains("📌") && extracted.text.contains("Sounds good.") && extracted.text.contains("More text.") && TeamMemory.notice(extracted.notes) == "Saved 1 team note · decision · see Settings › Memory", "the marker line is removed, the rest of the reply is unchanged, and one quiet notice summarises it")
        let malformed = "<<REMEMBER {not json}>>\n<<REMEMBER {\"kind\":\"rumor\",\"text\":\"x\"}>>"
        let bad = TeamMemory.extract(from: malformed)
        check(bad.notes.isEmpty && bad.text == malformed, "malformed or unknown-kind markers are left visible, never silently dropped")
        let many = (0..<8).map { "<<REMEMBER {\"kind\":\"done\",\"text\":\"item \($0)\"}>>" }.joined(separator: "\n")
        let capped = TeamMemory.extract(from: many)
        check(capped.notes.count == TeamMemory.perReplyLimit && capped.omittedNotes == 3 && !capped.text.contains("<<REMEMBER"), "at most five notes per reply; valid excess protocol stays hidden")
        check(TeamMemory.extract(from: "plain reply").text == "plain reply", "replies without markers are untouched")

        // Merge and render
        let old = MemoryNote(kind: "decision", text: "Keep Archivo for the wordmark.", author: "Eve", createdAt: Date(timeIntervalSince1970: 1_000))
        let merged = TeamMemory.merge([old], adding: [MemoryNote(kind: "decision", text: "keep archivo for the wordmark.", author: "Codex"), MemoryNote(kind: "unfinished", text: "Wire memory into replies.", author: "Claude")])
        check(merged.count == 2, "exact repeats are not saved twice")
        let rendered = TeamMemory.render(merged)
        check(rendered.hasPrefix(TeamMemory.header) && rendered.contains("[unfinished] Wire memory into replies.") && rendered.contains("<<REMEMBER"), "agents receive the notes plus how to save new ones")
        check((rendered.range(of: "Wire memory")?.lowerBound ?? rendered.endIndex) < (rendered.range(of: "Archivo")?.lowerBound ?? rendered.startIndex), "newest notes come first")
        let crowd = (0..<200).map { MemoryNote(kind: "done", text: "Finished task number \($0) with a reasonably long description attached.", author: "Claude", createdAt: Date(timeIntervalSince1970: Double($0))) }
        let bounded = TeamMemory.render(crowd)
        check(bounded.utf16.count <= TeamMemory.deliveredLimit && bounded.contains("older notes saved but not shown here for length"), "a large memory stays within its budget and says how many older notes were left out")
        check(TeamMemory.render([]).contains("(No saved notes yet.)"), "an empty memory still explains how to save notes")
        let full = TeamMemory.merge((0..<300).map { MemoryNote(kind: $0 == 0 ? "decision" : "done", text: "n\($0)", author: "Eve") }, adding: [MemoryNote(kind: "preference", text: "newest", author: "Eve")])
        check(full.count == TeamMemory.storedLimit && full.contains { $0.text == "n0" } && full.contains { $0.text == "newest" }, "when full, finished notes make room before decisions")

        // End to end with a restart
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-memory-" + UUID().uuidString)
        let stage = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var project = Project(); project.name = "Synthetic memory regression"
        var conversation = Conversation(); conversation.projectID = project.id; conversation.recipient = "eve"
        try JSONEncoder().encode(ConversationWorkspace(activeID: conversation.id, conversations: [conversation], projects: [project])).write(to: library.appendingPathComponent("workspace.json"))

        let saying = "Noted.\n<<REMEMBER {\"kind\":\"decision\",\"text\":\"MEMORY-TOKEN-417: Jason wants memory before the Pass button.\"}>>"
        var first: [String: MemoryProbeTransport] = [:]
        let store = ConversationStore(directory: library, transportFactory: { agent, _ in let t = MemoryProbeTransport(reply: saying); first[agent] = t; return t }, workspaceSandbox: stage)
        check(store.storageError == nil, "synthetic library opens")
        guard store.storageError == nil else { exit(1) }
        await store.start()
        try await wait("first connection") { !store.connecting && store.seats["eve"]?.state == "connected" }
        store.conversation.recipient = "eve"; store.conversation.draft = "Please remember this."
        store.send()
        try await wait("first reply") { first["eve"]?.prompts.isEmpty == false && !store.busy }
        check(first["eve"]?.prompts.first?.contains("PROJECT MEMORY") == true && first["eve"]?.prompts.first?.contains("(No saved notes yet.)") == true, "agents see the memory section, empty at first")
        check(store.activeProject?.memory?.contains { $0.text.contains("MEMORY-TOKEN-417") && $0.kind == "decision" && $0.author == "Eve" } == true, "the note is saved to the Project with its author")
        let shown = store.conversation.messages.last { $0.author == "Eve" }?.text ?? ""
        let shownDetail = store.conversation.messages.last { $0.author == "Eve" }?.detail ?? ""
        check(shownDetail.hasPrefix("Saved 1 team note") && !shown.contains("<<REMEMBER") && !shown.contains("📌"), "Jason sees one quiet saved-note line, not the raw marker or an emoji")
        var edited = store.activeProject!; edited.memory = []
        _ = store.updateProject(edited, reconnect: false)
        check(store.activeProject?.memory?.count == 1, "editing Project settings never wipes team memory")
        store.disconnect()
        // The running store holds the library lock, so the restart opens a byte-for-byte
        // copy of what was saved to disk: only persisted memory can survive.
        let restarted = root.appendingPathComponent("restarted")
        try FileManager.default.createDirectory(at: restarted, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: library.appendingPathComponent("workspace.json"), to: restarted.appendingPathComponent("workspace.json"))

        var second: [String: MemoryProbeTransport] = [:]
        let reopened = ConversationStore(directory: restarted, transportFactory: { agent, _ in let t = MemoryProbeTransport(reply: "Got it."); second[agent] = t; return t }, workspaceSandbox: stage)
        defer { reopened.disconnect() }
        check(reopened.storageError == nil && reopened.activeProject?.memory?.count == 1, "the note survives a restart")
        if reopened.storageError != nil { print("storage: " + (reopened.storageError ?? "")) }
        await reopened.start()
        try await wait("second connection") { !reopened.connecting && reopened.seats["eve"]?.state == "connected" }
        reopened.conversation.recipient = "eve"; reopened.conversation.draft = "What did we decide?"
        reopened.send()
        try await wait("second reply") { second["eve"]?.prompts.isEmpty == false && !reopened.busy }
        let prompt = second["eve"]?.prompts.first ?? ""
        check(prompt.contains("MEMORY-TOKEN-417: Jason wants memory before the Pass button.") && prompt.contains("[decision]"), "after a restart the saved decision reaches the next agent's actual input")
        check(prompt.utf16.count <= ContextBudget.promptCap, "memory is counted inside the 32,000-character send limit")
        if let note = reopened.activeProject?.memory?.first { reopened.forgetMemory(note, projectID: reopened.activeProject!.id) }
        check(reopened.activeProject?.memory?.isEmpty == true, "Jason can forget a note")

        print("TeamMemoryTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
