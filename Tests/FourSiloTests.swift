import Foundation

@main struct FourSiloTests {
    @MainActor static func main() {
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL: " + label) }
            print("PASS: " + label)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FourSiloTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(directory: root)
        var ids = [store.conversation.id]
        for _ in 0..<3 {
            check(store.newConversation(reconnect: false), "open another isolated room")
            ids.append(store.conversation.id)
        }
        var deck = ConversationDeck(openIDs: ids, focusedID: ids[0], presentation: .columns)
        check(deck.displayedIDs(availableWidth: 900) == ids, "four open rooms survive a narrow horizontally scrolling layout")
        for (index, id) in ids.enumerated() {
            store.setDraft("Draft for room \(index)", for: id)
        }
        for id in ids.reversed() {
            if store.conversation.id != id {
                check(store.selectConversation(id, reconnect: false), "each room can become the active writing destination without real providers")
            }
            check(deck.focus(id), "focus retains all open columns")
            check(deck.openIDs == ids, "focus never reorders the four rooms")
            check(store.conversation.draft == "Draft for room \(ids.firstIndex(of: id)!)", "active room restores only its own draft")
        }
        check(store.save(), "all four drafts reach a durable boundary")
        // Read the durable snapshot directly: a second live store must not acquire
        // the library lock while the first one still owns it.
        guard let data = try? Data(contentsOf: root.appendingPathComponent("workspace.json")),
              let reopened = try? JSONDecoder().decode(ConversationWorkspace.self, from: data) else {
            fatalError("FAIL: durable four-room snapshot decodes")
        }
        for (index, id) in ids.enumerated() {
            check(reopened.conversations.first(where: { $0.id == id })?.draft == "Draft for room \(index)", "each room draft is preserved in the durable snapshot")
        }
        check(deck.close(ids[1]), "hiding one column succeeds")
        check(deck.openIDs == [ids[0], ids[2], ids[3]], "hiding a room preserves the remaining order")
        check(reopened.conversations.filter { ids.contains($0.id) && !$0.archived }.count == 4, "hiding a column does not archive or delete its conversation")
        print("PASS: Four-room navigation and draft persistence; rendered UI remains a separate check")
    }
}
