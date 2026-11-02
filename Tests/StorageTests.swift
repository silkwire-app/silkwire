import Foundation

@main struct StorageTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-storage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let normal = root.appendingPathComponent("normal")
        var id = UUID()
        do {
            let store = ConversationStore(directory: normal)
            precondition(store.storageError == nil)
            id = store.conversation.id
            store.conversation.draft = "A saved draft"
            store.conversation.messages = [Message(author: "Jason", text: "Original question", state: "sent"), Message(author: "Eve", text: "Partial", state: "streaming"), Message(author: "Claude", text: "", state: "queued")]
            store.conversation.identities["eve"] = ProviderIdentity(id: "owned-session", started: true, runId: "owned-run", requestId: "owned-request")
            precondition(store.save())
            let blocked = ConversationStore(directory: normal)
            precondition(blocked.storageError != nil && !blocked.canSend)
        }
        do {
            let reopened = ConversationStore(directory: normal)
            precondition(reopened.storageError == nil)
            precondition(reopened.conversation.id == id && reopened.conversation.draft == "A saved draft")
            precondition(reopened.conversation.messages.map(\.state) == ["sent", "unconfirmed", "cancelled"])
            precondition(reopened.conversation.identities["eve"]?.runId == "owned-run")
            precondition(!reopened.busy && !reopened.canSend)
        }
        let corrupt = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let file = corrupt.appendingPathComponent("conversation.json"), bytes = Data("{broken but must be preserved".utf8)
        try bytes.write(to: file)
        do {
            let store = ConversationStore(directory: corrupt)
            precondition(store.storageError != nil && !store.canSend && !store.save())
            let retained = try Data(contentsOf: file)
            precondition(retained == bytes)
        }
        let legacy = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let original = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "draft": "Legacy draft", "threadID": "original-codex-thread", "messages": []])
        try original.write(to: legacy.appendingPathComponent("conversation.json"))
        do {
            let store = ConversationStore(directory: legacy)
            precondition(store.storageError == nil && store.conversation.draft == "Legacy draft")
            precondition(store.conversation.identities["codex"]?.id == "original-codex-thread")
            let backup = try Data(contentsOf: legacy.appendingPathComponent("conversation.pre-four-seat.json"))
            precondition(backup == original)
        }
        let library = root.appendingPathComponent("library")
        var firstID = UUID(), secondID = UUID()
        do {
            let store = ConversationStore(directory: library)
            firstID = store.conversation.id
            store.renameConversation("Orbit research")
            store.conversation.draft = "First draft"
            store.conversation.recipient = "claude"
            store.conversation.messages = [Message(author: "Jason", text: "Unique nebula question", state: "sent")]
            store.conversation.identities["claude"] = ProviderIdentity(id: "first-room-session")
            precondition(store.save())
            store.busy = true
            precondition(!store.newConversation(reconnect: false))
            store.busy = false; store.connecting = true
            precondition(!store.newConversation(reconnect: false))
            store.connecting = false
            precondition(store.newConversation(reconnect: false))
            secondID = store.conversation.id
            precondition(secondID != firstID && store.conversation.messages.isEmpty && store.conversation.identities.isEmpty && store.conversation.draft.isEmpty)
            store.renameConversation("Store planning")
            store.conversation.draft = "Second draft"
            store.conversation.messages = [Message(author: "Codex", text: "Second-room-only answer", state: "completed")]
            store.conversation.identities["codex"] = ProviderIdentity(id: "second-room-session")
            precondition(store.save())
            precondition(store.conversation.markdown.contains("Second-room-only answer") && !store.conversation.markdown.contains("Unique nebula"))
            precondition(store.conversations.filter { $0.matches("NEBULA") }.map(\.id) == [firstID])
            store.busy = true
            precondition(!store.selectConversation(firstID, reconnect: false))
            store.busy = false
            precondition(store.selectConversation(firstID, reconnect: false))
            precondition(store.conversation.draft == "First draft" && store.conversation.recipient == "claude")
            precondition(store.conversation.identities["claude"]?.id == "first-room-session" && store.conversation.identities["codex"] == nil)
            precondition(store.conversation.messages.count == 1 && store.conversation.messages[0].text == "Unique nebula question")
            precondition(!store.selectConversation(UUID(), reconnect: false))
            store.renameConversation("  ")
            precondition(store.conversation.title == "Orbit research")
        }
        do {
            let reopened = ConversationStore(directory: library)
            precondition(reopened.storageError == nil && reopened.conversations.count == 2 && reopened.conversation.id == firstID)
            precondition(reopened.selectConversation(secondID, reconnect: false))
            precondition(reopened.conversation.draft == "Second draft" && reopened.conversation.messages.count == 1)
        }
        let migration = root.appendingPathComponent("legacy")
        let workspaceBackup = try Data(contentsOf: migration.appendingPathComponent("conversation.pre-workspace.json")); precondition(workspaceBackup == original)
        let retainedOriginal = try Data(contentsOf: migration.appendingPathComponent("conversation.json")); precondition(retainedOriginal == original)
        // A corrupt/unsupported library must never fall back to an older legacy transcript.
        let unsupported = root.appendingPathComponent("unsupported")
        try FileManager.default.createDirectory(at: unsupported, withIntermediateDirectories: true)
        try original.write(to: unsupported.appendingPathComponent("conversation.json"))
        let future = Data("{\"version\":2,\"activeID\":\"\(UUID().uuidString)\",\"conversations\":[]}".utf8)
        try future.write(to: unsupported.appendingPathComponent("workspace.json"))
        do {
            let store = ConversationStore(directory: unsupported)
            precondition(store.storageError != nil && !store.canSend && !store.newConversation(reconnect: false))
            let retainedFuture = try Data(contentsOf: unsupported.appendingPathComponent("workspace.json")); precondition(retainedFuture == future)
        }
        let duplicates = ConversationWorkspace(activeID: id, conversations: [])
        do { try duplicates.validate(); preconditionFailure("Empty library accepted") } catch {}
        let broken = root.appendingPathComponent("save-failure")
        do {
            let store = ConversationStore(directory: broken)
            try FileManager.default.moveItem(at: broken.appendingPathComponent("workspace.json"), to: broken.appendingPathComponent("preserved.json"))
            try FileManager.default.createDirectory(at: broken.appendingPathComponent("workspace.json"), withIntermediateDirectories: false)
            store.conversation.draft = "Unsaved but retained in memory"
            precondition(!store.save() && !store.canSend && !store.newConversation(reconnect: false))
            precondition(store.conversation.draft == "Unsaved but retained in memory")
        }
        let code = MarkdownBlock.parse("# Heading\n\n- First\n- Second\n\n```swift\nlet x = 1\n```\n\n> Quoted\n\n1. Ordered")
        precondition(code.map(\.kind) == ["heading", "bullet", "bullet", "code", "quote", "number"])
        precondition(code[3].text == "let x = 1")
        precondition(MarkdownBlock.parse("```\npartial stream").first?.text == "partial stream")
        print("PASS: legacy storage gates plus workspace migration, independent drafts/history/identities/recipients, busy-switch guard, library reopen, scoped search/export, unsupported-data preservation, save-failure fence and Markdown parsing")
    }
}
