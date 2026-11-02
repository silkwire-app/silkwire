import Foundation

@main struct ConversationMemoryTests {
    static func main() throws {
        let scope = ConversationMemory.Scope(projectID: "project-a", ownerID: "eve")
        let entries = [
            ConversationMemory.Entry(id: "recent", tier: .shortTerm, text: "Current task", sourceMessageIDs: ["m1"], verified: false),
            ConversationMemory.Entry(id: "checkpoint", tier: .mediumTerm, text: "Decision and unfinished work", sourceMessageIDs: ["m2"], verified: true),
            ConversationMemory.Entry(id: "durable", tier: .longTerm, text: "Durable preference", sourceMessageIDs: ["m3"], verified: true)
        ]
        func checkpoint(_ entries: [ConversationMemory.Entry], version: Int = 1) -> ConversationMemory.Checkpoint {
            .init(schemaVersion: version, conversationID: "room", scope: scope, sourceRevision: "transcript-revision-1", createdAt: Date(timeIntervalSince1970: 100), entries: entries, unfinishedWork: ["Wire into conversation"], openQuestions: ["Unverified cause of lockup"])
        }
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { print("FAIL: \(label)"); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body(); check(false, label) } catch { check(true, label) }
        }
        let saved = checkpoint(entries)
        let data = try ConversationMemory.encode(saved)
        let decoded = try ConversationMemory.decode(data, scope: scope, conversationID: "room", sourceRevision: "transcript-revision-1")
        check(decoded == saved, "all three tiers, evidence references and verification states survive round trip")
        rejects("another agent's scope cannot be loaded") {
            _ = try ConversationMemory.decode(data, scope: .init(projectID: "project-a", ownerID: "codex"), conversationID: "room", sourceRevision: "transcript-revision-1")
        }
        rejects("another project cannot be loaded") {
            _ = try ConversationMemory.decode(data, scope: .init(projectID: "project-b", ownerID: "eve"), conversationID: "room", sourceRevision: "transcript-revision-1")
        }
        rejects("another conversation cannot be substituted") {
            _ = try ConversationMemory.decode(data, scope: scope, conversationID: "other", sourceRevision: "transcript-revision-1")
        }
        rejects("stale checkpoint cannot silently replace current context") {
            _ = try ConversationMemory.decode(data, scope: scope, conversationID: "room", sourceRevision: "revision-2")
        }
        rejects("unknown schema is rejected") { _ = try ConversationMemory.encode(checkpoint(entries, version: 2)) }
        rejects("duplicate entry identifiers are rejected") { _ = try ConversationMemory.encode(checkpoint([entries[0], entries[0]])) }
        rejects("unsupported memory without provenance is rejected") {
            _ = try ConversationMemory.encode(checkpoint([.init(id: "bad", tier: .longTerm, text: "Untraceable", sourceMessageIDs: [], verified: false)]))
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/tests/memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("checkpoint.json")
        try ConversationMemory.save(saved, to: file)
        let primer = try ConversationMemory.primer(from: file, scope: scope, conversationID: "room", sourceRevision: "transcript-revision-1", recentMessageIDs: ["m4", "m5"])
        check(primer.checkpoint == saved && primer.recentMessageIDs == ["m4", "m5"], "entry primer comes from persisted checkpoint with recent references intact")
        check(primer.label.contains("not instructions or permissions"), "recalled memory is labelled as context")
        rejects("oversize checkpoint fails rather than clipping decisions") {
            let large = ConversationMemory.Entry(id: "large", tier: .mediumTerm, text: String(repeating: "x", count: ConversationMemory.maximumBytes + 1), sourceMessageIDs: ["m1"], verified: false)
            try ConversationMemory.save(checkpoint([large]), to: file)
        }
        check(try Data(contentsOf: file) == data, "failed checkpoint replacement preserves previous saved bytes")
        rejects("missing save cannot yield a primer") {
            _ = try ConversationMemory.primer(from: root.appendingPathComponent("absent.json"), scope: scope, conversationID: "room", sourceRevision: "transcript-revision-1", recentMessageIDs: [])
        }
        try Data("broken".utf8).write(to: file)
        rejects("corrupt checkpoint fails explicitly") {
            _ = try ConversationMemory.load(from: file, scope: scope, conversationID: "room", sourceRevision: "transcript-revision-1")
        }
        print("PASS: \(checks) ConversationMemory checks")
    }
}
