import Foundation
import AppKit

@MainActor final class DeckReviewTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    var closes = 0
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = identity ?? ProviderIdentity(id: "synthetic-deck-" + UUID().uuidString, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        for index in 0..<40 {
            try await Task.sleep(for: .milliseconds(10))
            eventHandler?(.delta("chunk-\(index)|"))
        }
        eventHandler?(.finished(status: "completed", message: nil))
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() { closes += 1 }
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic deck review; no accounts") }
}

// Uses real store save/switch/send paths plus SiloNavigator. The small adapter
// mirrors the current UI transaction and is pinned with source contracts below.
// It does NOT drive a rendered SwiftUI view or test keyboard/focus/scroll feel,
// AppStorage/multiple windows, background sessions or real provider accounts.
@main struct ConversationDeckReviewTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("output/tests/deck-review-" + UUID().uuidString)
        let library = root.appendingPathComponent("library")
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        var project = Project(); project.name = "Synthetic silo review"; project.participants = ["eve"]
        func fixture(_ title: String) -> Conversation {
            var value = Conversation(); value.title = title; value.projectID = project.id
            value.focusedAgent = "eve"; value.recipient = "eve"
            value.draft = title + " private draft 🕸️"
            value.draftAttachments = [Attachment(name: title + ".txt", mimeType: "text/plain", data: Data((title + " attachment").utf8))]
            value.identities["eve"] = ProviderIdentity(id: "synthetic-session-" + title, started: true)
            value.messages = [Message(author: "Jason", text: title + " history only", state: "sent")]
            return value
        }
        let a = fixture("A"), b = fixture("B"), c = fixture("C")
        let workspaceURL = library.appendingPathComponent("workspace.json")
        try JSONEncoder().encode(ConversationWorkspace(activeID: a.id, conversations: [a, b, c], projects: [project])).write(to: workspaceURL)
        var transports: [DeckReviewTransport] = []
        let sandbox = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        let store = ConversationStore(directory: library, transportFactory: { _, _ in
            let transport = DeckReviewTransport(); transports.append(transport); return transport
        }, workspaceSandbox: sandbox)
        defer { store.disconnect() }
        check(store.storageError == nil && store.conversation.id == a.id, "synthetic library opens on the authoritative active conversation")
        var deck = ConversationDeck(openIDs: [a.id, b.id, c.id], focusedID: a.id)
        var savedDeck = SiloNavigator.encode(deck)
        func sync() {
            deck = SiloNavigator.synced(deck, current: store.conversation.id, available: Set(store.conversations.filter { !$0.archived }.map(\.id)))
            savedDeck = SiloNavigator.encode(deck)
        }
        func slide() -> Bool {
            guard let target = SiloNavigator.target(deck, .next) else { return false }
            let switched = store.selectConversation(target, reconnect: false)
            guard switched else { return false }
            SiloNavigator.commit(&deck, to: target, switched: true)
            savedDeck = SiloNavigator.encode(deck); return true
        }
        func close() -> Bool {
            guard let next = SiloNavigator.closing(deck, current: store.conversation.id), store.selectConversation(next.show, reconnect: false) else { return false }
            deck = next.deck; savedDeck = SiloNavigator.encode(deck); return true
        }
        for flag in ["connecting", "builder"] {
            let before = deck, saved = savedDeck
            if flag == "connecting" { store.connecting = true } else { store.builderRunning = true }
            check(!slide() && !close(), flag + " blocks both switching and close transaction")
            check(deck == before && savedDeck == saved && store.conversation.id == a.id, flag + " refusal preserves on-screen ID and saved deck")
            store.connecting = false; store.builderRunning = false
        }
        await store.start()
        try await wait("synthetic connection") { !store.connecting && store.seats["eve"]?.state == "connected" }
        store.conversation.draftAttachments = []
        store.conversation.draft = "Synthetic request in A, not B"
        store.send()
        check(store.busy, "real synthetic send becomes busy before navigation")
        store.conversation.draft = "A next draft while replying 👻"
        let busyDeck = deck, busySaved = savedDeck
        let closesBefore = transports.reduce(0) { $0 + $1.closes }
        check(!slide() && !close(), "active streaming request refuses both navigation transactions")
        check(deck == busyDeck && savedDeck == busySaved && store.conversation.id == a.id, "busy refusal keeps model, saved hint and actual conversation aligned")
        check(transports.reduce(0) { $0 + $1.closes } == closesBefore, "busy navigation never closes the active synthetic session")
        try await wait("completed synthetic reply") { !store.busy }
        let expected = (0..<40).map { "chunk-\($0)|" }.joined()
        check(store.conversation.messages.contains { $0.author == "Eve" && $0.text == expected && $0.state == "completed" }, "refused navigation leaves the full reply attached to A")
        check(transports.reduce(0) { $0 + $1.prompts.count } == 1, "navigation attempts do not duplicate or retarget the request")
        check(slide() && store.conversation.id == b.id && deck.focusedID == b.id, "idle slide commits only after real store selection succeeds")
        check(store.conversation.draft == b.draft && store.conversation.draftAttachments.first?.data == b.draftAttachments.first?.data, "B receives its own draft and attachment rather than A's")
        check(store.conversation.identities["eve"]?.id == b.identities["eve"]?.id && store.conversation.messages.map(\.text) == b.messages.map(\.text), "same-agent B retains separate session and transcript")
        store.conversation.draft = "B edited draft"
        check(close() && store.conversation.id == c.id && deck.openIDs == [a.id, c.id], "closing B switches right and removes only its open-column hint")
        check(store.conversations.count == 3 && store.conversations.allSatisfy { !$0.archived }, "real library retains all conversations unarchived after hide")
        check(store.conversations.first { $0.id == b.id }?.draft == "B edited draft", "closing durably checkpoints the hidden conversation's edited draft")
        check(store.selectConversation(b.id, reconnect: false), "hidden conversation remains reopenable from the saved library")
        sync()
        check(deck.openIDs == [a.id, c.id, b.id] && deck.focusedID == b.id, "reopening hidden B appends one silo, with the actual ID focused")
        check(store.conversation.draft == "B edited draft" && store.conversation.draftAttachments.first?.id == b.draftAttachments.first?.id, "reopened hidden conversation restores draft and attachment identity")
        check(store.selectConversation(a.id, reconnect: false), "original active conversation is reopenable")
        sync()
        check(store.conversation.draft == "A next draft while replying 👻" && store.conversation.messages.contains { $0.text == expected }, "A's next draft and completed reply survive other silo work")
        check(store.save(), "review fixture reaches a critical durable save")
        let persisted = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: workspaceURL))
        check(persisted.conversations.count == 3 && persisted.conversations.allSatisfy { !$0.archived }, "saved workspace is complete and unarchived, not a copy of visible columns")
        check(persisted.conversations.first { $0.id == b.id }?.identities["eve"]?.id == b.identities["eve"]?.id, "hidden chat's provider identity remains associated with its own conversation")
        let restored = SiloNavigator.synced(SiloNavigator.decode(savedDeck), current: persisted.activeID, available: Set(persisted.conversations.map(\.id)))
        check(restored == deck, "serialized hints reconcile with authoritative saved active ID")
        let stale = ConversationDeck(openIDs: [UUID(), b.id, a.id], focusedID: b.id)
        let reconciled = SiloNavigator.synced(stale, current: persisted.activeID, available: Set(persisted.conversations.map(\.id)))
        check(reconciled.openIDs == [b.id, a.id] && reconciled.focusedID == a.id, "stale restored hints drop foreign IDs and cannot override active workspace selection")
        check(store.archiveConversation(c.id), "synthetic archive uses the actual store boundary")
        sync()
        check(!deck.openIDs.contains(c.id) && store.conversations.first { $0.id == c.id }?.archived == true, "inactive archived chat drops from navigation without deleting its history")

        // A failed critical save must not advance or close the on-screen silo.
        store.disconnect()
        let retained = library.appendingPathComponent("retained.json")
        try files.moveItem(at: workspaceURL, to: retained)
        let retainedBytes = try Data(contentsOf: retained)
        try files.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
        let beforeFailure = deck, beforeFailureHint = savedDeck
        check(!slide() && store.storageError != nil, "critical write failure refuses real selection and reports a storage fence")
        check(!close() && deck == beforeFailure && savedDeck == beforeFailureHint && store.conversation.id == a.id, "failed-save navigation retains actual conversation, open list and saved hint")
        let retainedAfter = try Data(contentsOf: retained)
        check(retainedAfter == retainedBytes && store.conversation.draft == "A next draft while replying 👻", "write failure retains previous durable bytes and in-memory draft")

        // These contracts detect drift from the mirrored UI transaction; they
        // supplement, not replace, a rendered interaction test.
        let source = try String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)
        func section(_ start: String, _ end: String) -> String {
            guard let first = source.range(of: start), let last = source.range(of: end, range: first.upperBound..<source.endIndex) else { return "" }
            return String(source[first.lowerBound..<last.lowerBound])
        }
        let slideSource = section("private func slide(", "private func closeSilo()")
        check(slideSource.contains("let switched = store.selectConversation(target)") && slideSource.contains("if !switched") && slideSource.contains("return }") && slideSource.contains("SiloNavigator.commit"), "UI slide source retains selection-before-commit refusal guard")
        let closeSource = section("private func closeSilo()", "@ViewBuilder private var siloControls")
        check(closeSource.contains("guard store.selectConversation(next.show) else") && closeSource.contains("return }") && closeSource.contains("deck = next.deck"), "UI close source retains selection-before-removal refusal guard")
        check(!closeSource.contains("archiveConversation") && !closeSource.contains("deleteConversation"), "close UI is not wired to archive or delete actions")
        check(source.contains(".onAppear { deck = SiloNavigator.decode(savedDeck); syncDeck() }") && source.contains("syncDeck(); shownLimit = TranscriptWindow.initial"), "UI restores hints and synchronizes conversation changes with the reviewed navigator")
        print("ConversationDeckReviewTests: \(checks) checks, \(failures) failures; synthetic store/controller integration and source contracts, not rendered UI or concurrent-session acceptance.")
        if failures > 0 { exit(1) }
    }
}
