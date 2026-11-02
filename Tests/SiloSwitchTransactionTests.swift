import Foundation
import AppKit

// Real persistence boundaries, synthetic workspaces only. No provider connections.
@main struct SiloSwitchTransactionTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("output/tests/switch-transaction-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let project = Project()
        var a = Conversation(); a.projectID = project.id; a.title = "A"; a.draft = "A original"
        var b = Conversation(); b.projectID = project.id; b.title = "B"; b.focusedAgent = "eve"; b.recipient = "eve"; b.draft = "B draft"; b.unread = true
        a.messages = [Message(author: "Jason", text: "A history", state: "sent")]
        b.messages = [Message(author: "Jason", text: "B history", state: "sent")]
        let file = root.appendingPathComponent("workspace.json")
        var workspace = ConversationWorkspace(activeID: a.id, conversations: [a, b], projects: [project])
        workspace.environment = "staging"
        try JSONEncoder().encode(workspace).write(to: file)
        let environment = WorkspaceEnvironment(staging: true, library: root)
        let store = ConversationStore(directory: root, environment: environment, workspaceSandbox: environment)
        precondition(store.storageError == nil)
        let aID = store.conversation.id
        store.conversation.draft = "A unsaved edit 🧵"
        let before = store.persistenceWriteCount
        precondition(store.selectConversation(b.id, reconnect: false))
        precondition(store.persistenceWriteCount == before + 1, "switch must perform exactly one durable write")
        let saved = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: file))
        precondition(saved.activeID == b.id)
        precondition(saved.conversations.first { $0.id == aID }?.draft == "A unsaved edit 🧵")
        precondition(saved.conversations.first { $0.id == b.id }?.unread == false)
        precondition(store.conversation.draft == "B draft" && store.targets == ["eve"])
        precondition(store.conversation.messages.map(\.text) == ["B history"])
        let after = store.persistenceWriteCount
        precondition(!store.selectConversation(b.id, reconnect: false))
        precondition(!store.selectConversation(UUID(), reconnect: false))
        precondition(store.persistenceWriteCount == after)
        store.busy = true
        precondition(!store.selectConversation(aID, reconnect: false))
        precondition(store.conversation.id == b.id && store.persistenceWriteCount == after)
        store.busy = false
        // Force atomic-write failure without changing any real library or credentials.
        let backup = root.appendingPathComponent("saved.json")
        try files.moveItem(at: file, to: backup)
        try files.createDirectory(at: file, withIntermediateDirectories: false)
        store.conversation.draft = "B unsaved edit survives failure"
        precondition(!store.selectConversation(aID, reconnect: false))
        precondition(store.storageError != nil && store.conversation.id == b.id)
        precondition(store.conversation.draft == "B unsaved edit survives failure")
        precondition(store.persistenceWriteCount == after)
        let original = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: backup))
        precondition(original.activeID == b.id && original.conversations.first { $0.id == aID }?.draft == "A unsaved edit 🧵")
        print("PASS switch uses one atomic write, preserves isolated drafts/history and selection, refuses busy/invalid destinations, and rolls back a failed write without losing the current draft")
    }
}
