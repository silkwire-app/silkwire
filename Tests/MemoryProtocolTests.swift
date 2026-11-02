import Foundation

@main struct MemoryProtocolTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL " + label) }
            checks += 1; print("PASS " + label)
        }
        let note = "A quote: \"keep {this} >> safe\"."
        let object = try nativeJSON(["kind": "decision", "text": note])
        let marker = "<<REMEMBER " + object + ">>"
        let reply = "Before. " + marker + " After."
        for split in 0...reply.count {
            let partial = String(reply.prefix(split))
            let shown = Message(author: "Claude", text: partial, state: "streaming").forDisplay.text
            try check(!shown.contains("<<") && !shown.contains("REMEMBER") && !shown.contains("kind") && !shown.contains(note), "Claude stream prefix \(split) hides complete and partial control text")
        }
        let extracted = TeamMemory.extract(from: reply)
        try check(extracted.notes.count == 1 && extracted.notes[0].text == note && extracted.text == "Before.  After.", "inline JSON handles escaped quotes, braces and delimiters inside a note")
        let multiline = "First\n<<REMEMBER\n{\n\"kind\": \"done\",\n\"text\": \"One task\"\n}\n>>\nLast"
        let multi = TeamMemory.extract(from: multiline)
        try check(multi.notes.count == 1 && !multi.text.contains("REMEMBER") && multi.text.contains("Last"), "multiline completed markers are processed")
        try check(TeamMemory.extract(from: marker + marker).notes.count == 1, "duplicate markers in one response produce one note")
        let display = Message(author: "Claude", text: reply, state: "completed").forDisplay
        try check(display.text == extracted.text, "legacy completed Claude replies use the same display filter")
        try check(Message(author: "Jason", text: reply, state: "sent").forDisplay.text == reply, "Jason can still discuss literal protocol examples")
        try check(TeamMemory.extract(from: "<<REMEMBER {bad}>>").text == "<<REMEMBER {bad}>>", "malformed completed markers remain diagnosable")
        try check(TeamMemory.visibleText("Normal <text> and <<other>>", streaming: true) == "Normal <text> and <<other>>", "ordinary angle brackets are preserved")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-protocol-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = Project(); project.name = "Synthetic protocol"
        var conversation = Conversation(); conversation.projectID = project.id
        try JSONEncoder().encode(ConversationWorkspace(activeID: conversation.id, conversations: [conversation], projects: [project])).write(to: root.appendingPathComponent("workspace.json"))
        let store = ConversationStore(directory: root)
        defer { store.disconnect() }
        let request = UUID().uuidString
        store.conversation.messages.append(Message(author: "Claude", text: reply + marker, state: "completed", requestId: request))
        store.captureMemory(request: request, agent: "claude")
        store.captureMemory(request: request, agent: "claude")
        try check(store.activeProject?.memory?.count == 1 && store.activeProject?.memory?.first?.text == note, "terminal replay saves a duplicate Claude note only once")
        // A provider may replay the whole completed text rather than a delta.
        store.conversation.messages[store.conversation.messages.count - 1].text = reply
        store.captureMemory(request: request, agent: "claude")
        try check(store.activeProject?.memory?.count == 1 && store.conversation.messages.last?.text == extracted.text, "completed replacement replay stays hidden without another save")
        let records = store.libraryPages.filter { ProjectMemory.isRecord($0) }
        try check(records.count == 1 && records.first?.id == store.activeProject?.memory?.first?.id, "Alexandria retains a single source-linked note")
        print("MemoryProtocolTests: \(checks) checks passed")
    }
}
