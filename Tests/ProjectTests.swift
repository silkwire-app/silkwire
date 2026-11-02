import Foundation

@main struct ProjectTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-project-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var old = Conversation(); old.draft = "Keep my exact draft"; old.recipient = "claude"
        old.messages = [Message(author: "Jason", text: "Old question", state: "sent"), Message(author: "Claude", text: "Original response", state: "completed")]
        old.identities["claude"] = ProviderIdentity(id: "original-persistent-session", started: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "activeID": old.id.uuidString, "conversations": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))], "preferences": ["completionChime": false]])
        try data.write(to: root.appendingPathComponent("workspace.json"))
        var otherProjectID = UUID(), otherRoomID = UUID()
        do {
            let store = ConversationStore(directory: root)
            precondition(store.storageError == nil && store.projects.count == 1 && store.activeProject?.name == "Silkwire")
            precondition(store.conversation.id == old.id && store.conversation.draft == old.draft && store.conversation.messages.map(\.id) == old.messages.map(\.id))
            precondition(store.conversation.recipient == "claude" && store.conversation.identities["claude"]?.id == "original-persistent-session")
            let backup = try Data(contentsOf: root.appendingPathComponent("workspace.pre-projects.json")); precondition(backup == data)
            precondition(store.preferences.completionChime == false)
            store.setSidebarVisible(false); store.setReduceMotion(true)
            var next = Project(); next.name = "Engineering"; next.icon = "rocket"; next.color = "mint"; next.participants = ["codex"]
            otherProjectID = next.id
            store.busy = true; precondition(!store.createProject(next, reconnect: false)); store.busy = false
            precondition(store.createProject(next, reconnect: false))
            otherRoomID = store.conversation.id
            precondition(store.activeProject?.id == next.id && store.conversation.identities.isEmpty && store.conversation.messages.isEmpty && store.conversation.draft.isEmpty)
            precondition(store.targets == ["codex"])
            store.conversation.draft = "Project two draft"; store.conversation.identities["codex"] = ProviderIdentity(id: "project-two-session"); store.save()
            next.name = "Renamed engineering"; precondition(store.updateProject(next, reconnect: false))
            precondition(store.conversation.id == otherRoomID && store.conversation.identities["codex"]?.id == "project-two-session")
            precondition(store.newConversation(reconnect: false) && store.conversation.projectID == next.id)
            precondition(store.conversation.messages.isEmpty && store.conversation.identities.isEmpty)
            var invalid = next; invalid.participants = []
            precondition(!store.updateProject(invalid, reconnect: false))
            invalid.participants = ["codex", "codex"]; precondition(!store.updateProject(invalid, reconnect: false))
            next.participants = ["eve", "codex"]; precondition(store.updateProject(next, reconnect: false))
            precondition(store.targets == ["eve", "codex"])
            precondition(store.selectConversation(old.id, reconnect: false))
            precondition(store.conversation.draft == old.draft && store.conversation.identities["claude"]?.id == "original-persistent-session")
            precondition(!store.preferences.completionChime && !store.preferences.sidebarVisible && store.preferences.reduceMotion)
        }
        do {
            let reopened = ConversationStore(directory: root)
            precondition(reopened.storageError == nil && reopened.projects.count == 2 && reopened.conversations.count == 3)
            precondition(reopened.conversation.id == old.id && !reopened.preferences.completionChime && !reopened.preferences.sidebarVisible && reopened.preferences.reduceMotion)
            precondition(reopened.projects.first { $0.id == otherProjectID }?.name == "Renamed engineering")
            precondition(reopened.selectConversation(otherRoomID, reconnect: false))
            precondition(reopened.conversation.draft == "Project two draft" && reopened.conversation.identities["codex"]?.id == "project-two-session")
        }
        let fresh = root.appendingPathComponent("fresh")
        do { let store = ConversationStore(directory: fresh); precondition(store.preferences.completionChime && store.preferences.sidebarVisible && !store.preferences.reduceMotion); store.setChime(false) }
        do { let store = ConversationStore(directory: fresh); precondition(!store.preferences.completionChime) }
        let recipientRoot = root.appendingPathComponent("recipient-removal")
        do {
            let store = ConversationStore(directory: recipientRoot)
            let originalRoom = store.conversation.id
            store.conversation.recipient = "claude"; store.conversation.draft = "Only Claude should receive this"; store.save()
            precondition(store.newConversation(reconnect: false))
            var project = store.activeProject!; project.participants = ["eve", "codex"]
            precondition(store.updateProject(project, reconnect: false))
            precondition(store.selectConversation(originalRoom, reconnect: false))
            store.seats["eve"] = Seat(state: "connected"); store.seats["codex"] = Seat(state: "connected")
            precondition(store.conversation.recipient == "claude" && store.targets.isEmpty && !store.canSend)
            store.conversation.recipient = "codex"
            precondition(store.targets == ["codex"] && store.canSend)
        }
        let invalidRoot = root.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
        let invalid = ConversationWorkspace(activeID: old.id, conversations: [old], projects: [Project()])
        let bytes = try JSONEncoder().encode(invalid)
        try bytes.write(to: invalidRoot.appendingPathComponent("workspace.json"))
        do {
            let store = ConversationStore(directory: invalidRoot)
            precondition(store.storageError != nil && !store.canSend && !store.canChangeConversation)
            let retained = try Data(contentsOf: invalidRoot.appendingPathComponent("workspace.json")); precondition(retained == bytes)
        }
        print("PASS: exact v1 Project migration; IDs/history/drafts/recipients/sessions; muted preference preserved; Project create/rename/participant scope; independent conversations; busy guards; reopen; defaults; invalid cross-Project references preserved")
    }
}
