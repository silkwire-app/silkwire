import Foundation

@main struct WorkroomTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-workroom-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var project = Project(); project.name = "Existing Silkwire"
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        project.folderPath = source.path
        project.folderBookmark = try source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var room = Conversation(); room.projectID = project.id; room.draft = "Keep exact draft"; room.messages = [Message(author: "Codex", text: "Existing answer", state: "completed")]; room.identities["codex"] = ProviderIdentity(id: "keep-this-session", started: true)
        var workspace = ConversationWorkspace(activeID: room.id, conversations: [room], projects: [project]); workspace.version = 4
        let original = try JSONEncoder().encode(workspace); try original.write(to: root.appendingPathComponent("workspace.json"))
        var folderID = UUID()
        do {
            let store = ConversationStore(directory: root)
            precondition(store.storageError == nil && store.activeProject?.connectedFolders.count == 1)
            precondition(store.activeProject?.connectedFolders.first?.builderAllowed != true)
            let backup = try Data(contentsOf: root.appendingPathComponent("workspace.pre-workroom.json")); precondition(backup == original)
            precondition(store.conversation.draft == room.draft && store.conversation.messages.map(\.id) == room.messages.map(\.id) && store.conversation.identities["codex"]?.id == "keep-this-session")
            var updated = store.activeProject!
            var folders = updated.connectedFolders
            folders[0].name = "App Source"; folders[0].builderAllowed = true
            let notes = root.appendingPathComponent("notes"); try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            folders.append(ProjectFolder(name: "Project Notes", path: notes.path, bookmark: try notes.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)))
            folderID = folders[1].id; updated.folders = folders; updated.folderPath = nil; updated.folderBookmark = nil
            updated.brief = "Approved: native first. Current task: verify a small change. Open: browser later."
            precondition(store.updateProject(updated, reconnect: false))
            precondition(store.activeProject?.connectedFolders.count == 2 && store.targets == agents)
            for agent in agents { precondition(store.accessDescription(folders[0], agent: agent).contains("Configured")) }
            var invalid = updated; invalid.folders!.append(folders[0]); precondition(!store.updateProject(invalid, reconnect: false))
            invalid = updated; invalid.brief = String(repeating: "x", count: 2001); precondition(!store.updateProject(invalid, reconnect: false))
            store.conversation.historyContext = ["eve": HistoryContextSnapshot(supplied: 12, total: 48, shortened: true, requestID: "fixture-last-eve"), "codex": HistoryContextSnapshot(supplied: 14, total: 50, shortened: true, requestID: "fixture-last-codex")]
            precondition(store.save())
            store.builderRunning = true; precondition(!store.canChangeConversation && !store.canSend && !store.updateProject(project, reconnect: false)); store.builderRunning = false
        }
        do {
            let store = ConversationStore(directory: root)
            precondition(store.storageError == nil && store.activeProject?.connectedFolders.count == 2 && store.activeProject?.brief?.contains("native first") == true)
            precondition(store.activeProject?.connectedFolders[1].id == folderID && store.activeProject?.connectedFolders[0].builderAllowed == true)
            precondition(store.conversation.historyContext?["eve"]?.supplied == 12 && store.conversation.historyContext?["codex"]?.total == 50 && store.conversation.historyContext?["claude"] == nil)
            let originalRoomID = store.conversation.id
            precondition(store.newConversation(reconnect: false))
            precondition(store.conversation.historyContext == nil)
            precondition(store.selectConversation(originalRoomID, reconnect: false))
            precondition(store.conversation.historyContext?["eve"]?.requestID == "fixture-last-eve")
            var project = store.activeProject!; project.folders = []; precondition(store.updateProject(project, reconnect: false))
            precondition(store.activeProject?.connectedFolders.isEmpty == true)
            precondition(store.conversation.identities["codex"]?.id == "keep-this-session")
        }
        let retainedBackup = try Data(contentsOf: root.appendingPathComponent("workspace.pre-workroom.json")); precondition(retainedBackup == original)
        let saved = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json"))); precondition(saved.version == 5)
        let unicodeAttachment = root.appendingPathComponent("unicode.txt")
        try String(repeating: "🕷", count: 7000).write(to: unicodeAttachment, atomically: true, encoding: .utf8)
        var rejectedUnicode = false; do { _ = try Attachment.load(unicodeAttachment) } catch { rejectedUnicode = true }; precondition(rejectedUnicode)
        precondition(limitedUTF16(String(repeating: "🕷", count: 1001), to: 2000).utf16.count == 2000)
        precondition(limitedUTF16("A👨‍👩‍👧‍👦B", to: 8) == "A")
        print("PASS: exact v4 backup; preserved IDs/history/draft/sessions; legacy grant; named roots/brief/Builder grant reopen; shared reads; invalid grants rejected; active Builder fences switching; removal persists without changing sessions")
    }
}
