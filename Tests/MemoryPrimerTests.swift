import Foundation

@main struct MemoryPrimerTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { print("FAIL: " + label); exit(1) }
            checks += 1; print("PASS: " + label)
        }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body() } catch { check(true, label); return }
            check(false, label)
        }
        let scope = ConversationMemory.Scope(projectID: "project", ownerID: "codex")
        let entries = [
            ConversationMemory.Entry(id: "short", tier: .shortTerm, text: "Current exchange", sourceMessageIDs: ["m1"], verified: false),
            ConversationMemory.Entry(id: "medium", tier: .mediumTerm, text: "Decision near the end: preserve this entire sentence.", sourceMessageIDs: ["m2"], verified: true),
            ConversationMemory.Entry(id: "long", tier: .longTerm, text: "A saved preference with quotes: \"hello\"\nEmoji: 🧑🏽‍💻", sourceMessageIDs: ["m3"], verified: true)
        ]
        let checkpoint = ConversationMemory.Checkpoint(schemaVersion: 1, conversationID: "room", scope: scope, sourceRevision: "r1", createdAt: Date(timeIntervalSince1970: 100), entries: entries, unfinishedWork: ["Finish memory hookup"], openQuestions: ["Cause still unverified"])
        let data = try ConversationMemory.encode(checkpoint)
        let known: Set<String> = ["m1", "m2", "m3", "m4"]
        func render(_ bytes: Data = data, scope s: ConversationMemory.Scope = scope, room: String = "room", revision: String = "r1", ids: Set<String> = known, recent: [String] = ["m4"], budget: Int = 8000) throws -> MemoryPrimer.Rendered {
            try MemoryPrimer.render(checkpointData: bytes, scope: s, conversationID: room, sourceRevision: revision, knownMessageIDs: ids, recentMessageIDs: recent, maximumUTF16: budget)
        }
        let result = try render()
        check(result.entryCount == 3 && result.recentReferenceCount == 1, "primer accounts for all three memory tiers and recent references")
        check(result.text.hasPrefix(MemoryPrimer.header) && result.text.hasSuffix(MemoryPrimer.footer), "complete primer is labelled quoted data, not instructions or permissions")
        check(result.usedUTF16 == result.text.utf16.count && result.usedUTF16 <= 8000, "budget measures the complete rendered envelope")
        let json = String(result.text.dropFirst(MemoryPrimer.header.count).dropLast(MemoryPrimer.footer.count))
        let payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let savedBytes = try JSONSerialization.data(withJSONObject: payload["checkpoint"]!)
        let recalled = try ConversationMemory.decode(savedBytes, scope: scope, conversationID: "room", sourceRevision: "r1")
        check(recalled == checkpoint, "all text, source links, tasks, questions and verification flags survive rendering exactly")
        check(recalled.entries.first?.verified == false, "unverified memory is never promoted to verified")
        check(payload["recentMessageIDs"] as? [String] == ["m4"], "recent IDs remain references rather than invented message text")
        check(try render() == result, "same checkpoint renders deterministically")
        check(try render(budget: result.usedUTF16) == result, "an exact-fit complete primer is accepted")
        do {
            _ = try render(budget: result.usedUTF16 - 1)
            check(false, "one-unit overflow must fail")
        } catch MemoryPrimer.Failure.exceedsBudget(let required, let limit) {
            check(required == result.usedUTF16 && limit == result.usedUTF16 - 1, "overflow reports required and available space without clipping")
        }
        check(try render() == result && data == ConversationMemory.encode(checkpoint), "failed rendering leaves prior context and checkpoint bytes unchanged")
        rejects("zero budget fails explicitly") { _ = try render(budget: 0) }
        rejects("negative budget fails explicitly") { _ = try render(budget: -1) }
        rejects("another owner's checkpoint is refused") { _ = try render(scope: .init(projectID: "project", ownerID: "eve")) }
        rejects("another project's checkpoint is refused") { _ = try render(scope: .init(projectID: "other", ownerID: "codex")) }
        rejects("another conversation's checkpoint is refused") { _ = try render(room: "other") }
        rejects("stale revision is refused") { _ = try render(revision: "r2") }
        rejects("unknown source reference is refused") { _ = try render(ids: ["m1", "m2", "m4"]) }
        rejects("unknown recent reference is refused") { _ = try render(recent: ["missing"]) }
        rejects("duplicate recent references are refused") { _ = try render(recent: ["m4", "m4"]) }
        rejects("blank recent references are refused") { _ = try render(recent: ["   "]) }
        rejects("corrupt checkpoint is refused") { _ = try render(Data("broken".utf8)) }
        check(try render(recent: []).recentReferenceCount == 0, "arrival without recent messages is supported")
        print("PASS: \(checks) MemoryPrimer checks")
    }
}
