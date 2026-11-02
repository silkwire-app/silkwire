import Foundation
import AppKit
final class MemoryPasteboard: NativeAttachmentPasteboard {
    var text: String?
    var data: [NSPasteboard.PasteboardType: Data] = [:]
    var urls: [URL] = []
    func clearContents() -> Int { text = nil; data = [:]; urls = []; return 1 }
    func setString(_ string: String, forType: NSPasteboard.PasteboardType) -> Bool { text = string; return true }
    func string(forType: NSPasteboard.PasteboardType) -> String? { text }
    func setData(_ value: Data, forType type: NSPasteboard.PasteboardType) { data[type] = value }
    func writeObjects(_ values: [NSPasteboardWriting]) { urls = values.compactMap { ($0 as? NSURL).map { $0 as URL } } }
    func availableType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? { types.first { data[$0] != nil || ($0 == .fileURL && !urls.isEmpty) || ($0 == .string && text != nil) } }
    var attachmentURLs: [URL] { urls }
    var attachmentImage: NSImage? { data[.png].flatMap(NSImage.init(data:)) ?? data[.tiff].flatMap(NSImage.init(data:)) }
    func releaseGlobally() {}
}
@main struct RefinementTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-refinement-\(UUID())")
        let token = Attachment(name: "context.txt", mimeType: "text/plain", data: Data("FILE-TOKEN-427".utf8))
        var firstID = UUID(), secondID = UUID(), identity = "retained-session"
        do {
            let store = ConversationStore(directory: root); firstID = store.conversation.id
            store.renameConversation("Original conversation"); store.conversation.draft = "Retained first draft"
            store.conversation.identities["claude"] = ProviderIdentity(id: identity, started: true)
            store.conversation.messages = [Message(author: "Jason", text: "Retained transcript", state: "sent")]
            try store.addAttachment(token)
            store.conversation.recipient = "eve,codex"; store.save()
            precondition(store.targets == ["eve", "codex"])
            store.toggleRecipient("eve"); precondition(store.targets == ["codex"])
            store.toggleRecipient("codex"); precondition(store.targets.isEmpty)
            store.toggleRecipient("claude"); precondition(store.targets == ["claude"])
            store.conversation.recipient = "eve,removed"; precondition(store.targets.isEmpty)
            store.conversation.recipient = "eve,codex"; store.save()
            precondition(store.archiveConversation(firstID)); precondition(store.conversation.archived && !store.canSend)
            precondition(store.archiveConversation(firstID, archived: false))
            precondition(store.conversation.messages.count == 1 && store.conversation.identities["claude"]?.id == identity)
            let count = store.conversations.count
            store.newConversationPresented = true; store.newConversationPresented = false
            precondition(store.conversations.count == count && store.conversation.id == firstID)
            precondition(store.newConversation(title: "Named before creation", reconnect: false)); secondID = store.conversation.id
            precondition(store.conversation.title == "Named before creation" && store.conversation.draftAttachments.isEmpty)
            store.renameConversation("Renamed inactive", id: firstID)
            precondition(store.selectConversation(firstID, reconnect: false))
            precondition(store.conversation.title == "Renamed inactive" && store.conversation.draftAttachments.first?.id == token.id && store.conversation.draft == "Retained first draft")
            store.busy = true; precondition(!store.deleteConversation(firstID) && !store.archiveConversation(firstID)); store.busy = false
            precondition(store.archiveConversation(secondID)); store.save()
        }
        do {
            let store = ConversationStore(directory: root)
            precondition(store.storageError == nil && store.conversation.id == firstID && store.targets == ["eve", "codex"])
            precondition(store.conversation.draftAttachments.first?.data == token.data && store.conversation.identities["claude"]?.id == identity)
            precondition(store.conversations.first { $0.id == secondID }?.archived == true)
            precondition(store.deleteConversation(secondID) && store.conversations.count == 1)
            precondition(store.deleteConversation(firstID) && store.conversations.count == 1 && store.conversation.id != firstID)
        }
        let migrationRoot = root.appendingPathComponent("v2-migration")
        try FileManager.default.createDirectory(at: migrationRoot, withIntermediateDirectories: true)
        let project = Project(); var room = Conversation(); room.projectID = project.id; room.recipient = "claude"; room.draft = "Original v2 draft"; room.identities["claude"] = ProviderIdentity(id: "original-v2-session", started: true)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as! [String: Any]; old.removeValue(forKey: "archived"); old.removeValue(forKey: "draftAttachments")
        let original = try JSONSerialization.data(withJSONObject: ["version": 2, "activeID": room.id.uuidString, "conversations": [old], "projects": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))], "preferences": ["completionChime": false, "sidebarVisible": true, "reduceMotion": false]])
        try original.write(to: migrationRoot.appendingPathComponent("workspace.json"))
        do {
            let migrated = ConversationStore(directory: migrationRoot)
            let backup = try Data(contentsOf: migrationRoot.appendingPathComponent("workspace.pre-refinement.json"))
            precondition(migrated.storageError == nil && backup == original && migrated.conversation.id == room.id && migrated.conversation.recipient == "claude" && migrated.conversation.draft == room.draft && !migrated.preferences.completionChime && migrated.conversation.identities["claude"]?.id == "original-v2-session")
        }
        print("PASS: exact version-2 backup and preserved v2 draft/recipient/identity/muted preference")
        let v3Root = root.appendingPathComponent("v3-migration")
        try FileManager.default.createDirectory(at: v3Root, withIntermediateDirectories: true)
        let v3Bytes = try JSONSerialization.data(withJSONObject: ["version": 3, "activeID": room.id.uuidString, "conversations": [old], "projects": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))], "preferences": ["completionChime": false, "sidebarVisible": true, "reduceMotion": false]])
        try v3Bytes.write(to: v3Root.appendingPathComponent("workspace.json"))
        do { let migrated = ConversationStore(directory: v3Root); let backup = try Data(contentsOf: v3Root.appendingPathComponent("workspace.pre-ready.json")); precondition(migrated.storageError == nil && backup == v3Bytes && migrated.conversation.id == room.id && migrated.preferences.autoScrollReplies && migrated.preferences.textCompletion && !migrated.preferences.completionChime) }
        print("PASS: byte-exact v3 backup, retained IDs/mute and new preference defaults")
        let preferencesRoot = root.appendingPathComponent("preferences")
        do { let store = ConversationStore(directory: preferencesRoot); precondition(store.preferences.autoScrollReplies && store.preferences.textCompletion && !store.preferences.automaticCorrection); store.setAutoScroll(false); store.setTextCompletion(false); store.setAutomaticCorrection(true) }
        do { let store = ConversationStore(directory: preferencesRoot); precondition(!store.preferences.autoScrollReplies && !store.preferences.textCompletion && store.preferences.automaticCorrection) }
        print("PASS: saved Auto-scroll/completion/correction defaults and reopen; native PNG/TIFF Paste menu and Cmd-V responder paths")
        let unsupported = root.appendingPathComponent("unsupported.pdf"); try Data("pretend PDF".utf8).write(to: unsupported)
        do { _ = try Attachment.load(unsupported); preconditionFailure("Unsupported PDF accepted") } catch {}
        let text = root.appendingPathComponent("token.md"); try token.data.write(to: text); let loaded = try Attachment.load(text); precondition(loaded.text == token.text)
        let message = Message(author: "Eve", text: "Orbit orbit\nORBIT again\nNo match here", state: "completed")
        let hits = SearchHit.find(in: [message], query: "orbit")
        precondition(hits.count == 3 && hits[0].line == 0 && hits[1].line == 0 && hits[2].line == 1 && Set(hits.map(\.id)).count == 3)
        precondition(SearchHit.find(in: [message], query: "").isEmpty)
        let board = MemoryPasteboard()
        precondition(copyText("Exact clipboard content", pasteboard: board) && board.string(forType: .string) == "Exact clipboard content")
        let field = AttachmentTextView(); field.isEditable = true
        var pastedURLs: [URL] = []; field.addURLs = { pastedURLs = $0 }
        board.clearContents(); board.writeObjects([text as NSURL]); precondition(field.consume(board) && pastedURLs == [text])
        board.clearContents(); board.setString("ordinary pasted text", forType: .string); precondition(!field.consume(board))
        let image = NSImage(size: NSSize(width: 120, height: 80)); image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 120, height: 80).fill(); image.unlockFocus()
        let attachment = try Attachment.fromImage(image)
        board.clearContents(); board.setData(attachment.data, forType: .png); var pastedImage = false; field.addImage = { _ in pastedImage = true }; precondition(field.consume(board) && pastedImage)
        field.attachmentPasteboard = board
        precondition(field.readablePasteboardTypes.contains(.png) && field.readablePasteboardTypes.contains(.tiff))
        let menu = NSMenu(title: "Edit"); let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"); paste.target = field; menu.addItem(paste); menu.update()
        precondition(paste.isEnabled && field.validateUserInterfaceItem(paste))
        pastedImage = false; menu.performActionForItem(at: 0); precondition(pastedImage)
        pastedImage = false
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        precondition(field.performKeyEquivalent(with: event) && pastedImage)
        let tiff = image.tiffRepresentation!; board.clearContents(); board.setData(tiff, forType: .tiff); pastedImage = false
        field.paste(nil); precondition(pastedImage)
        field.isEditable = false; precondition(!field.consume(board))
        board.releaseGlobally()
        print("PASS: isolated clipboard adapter; search occurrence offsets/count and empty query; exact successful clipboard write; file/image paste routing; disabled paste fence")
        print("PASS: multi-recipient persistence and removed-agent fencing; name/cancel; archive/restore; targeted rename; delete guards; transcript/draft/session/attachment reopen; unsupported type rejection")
    }
}
