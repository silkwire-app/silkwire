import Foundation
import AppKit

@main struct TwoComposerTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let a = UUID(), b = UUID(), all: Set<UUID> = [a, b]
        var deck = ConversationDeck()
        deck.open(a, availableIDs: all)
        deck.open(b, availableIDs: all, activate: false)
        check(!SiloNavigator.companionLeads(deck, current: a, companion: b), "typing in the first: the second stays on the right")
        check(SiloNavigator.companionLeads(deck, current: b, companion: a), "typing in the second: the first stays on the left")
        check(!SiloNavigator.companionLeads(deck, current: a, companion: UUID()), "an unknown conversation never takes the left")

        let m = SiloLayout.outerMargin, d = SiloLayout.dividerWidth
        let wide = SiloLayout.pairSideBySide(total: 3400, preferred: 740, preferredReader: 1060)
        check(wide != nil && wide!.chat == 740 * 2 + m * 3 && wide!.reader == 1060, "wide window: two chats and the page at their chosen widths")
        check(wide.map { $0.chat + $0.reader + $0.gap + d } == 3400, "wide window: the pieces fill the space exactly")
        let snug = SiloLayout.pairSideBySide(total: 2200, preferred: 740, preferredReader: 1060)
        check(snug != nil && snug!.chat == 740 * 2 + m * 3 && snug!.reader >= SiloLayout.minimumReaderWidth && snug!.reader < 1060, "less room: the page narrows first")
        let tight = SiloLayout.pairSideBySide(total: 1900, preferred: 740, preferredReader: 1060)
        check(tight != nil && tight!.reader == SiloLayout.minimumReaderWidth && (tight!.chat - m * 3) / 2 >= SiloLayout.minimumSiloWidth, "tighter: chats narrow together, never below their minimum")
        check(tight.map { $0.chat + $0.reader + d <= 1900 } ?? false, "tighter: nothing overflows")
        check(SiloLayout.pairSideBySide(total: 1500, preferred: 740, preferredReader: 1060) == nil, "too narrow for all three: the second chat steps aside")
        check(SiloLayout.pairSideBySide(total: .infinity, preferred: 740, preferredReader: 1060) == nil, "bad geometry: no three-way layout")

        let app = (try? String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)) ?? ""
        check(app.contains("store.setDraft($0, for: other.id)"), "the second writing space saves into its own conversation")
        check(app.contains("owner: other.id"), "the second writing space is bound to its own conversation")
        check(app.contains("registerFlush: { [companionFlush] flush in companionFlush.flushes[other.id] = flush }"), "each companion writing space has its own flush, separate from the main draft")
        check(app.contains("companionFlush.flush()\n        guard store.canChangeConversation"), "sending from a companion column keeps every pending draft")
        check(app.contains("if store.conversation.id == id && store.canSend { store.send() }"), "send only goes to the conversation it was written in")
        check(app.contains("if leading { other(); self } else { self; other() }"), "columns keep their places when switching")
        check(app.contains("onActivate: { activateCompanion(other.id) }"), "clicking the second writing space makes it the main one")
        check(app.contains("guard store.canChangeConversation, store.conversation.id != id else { return }"), "mid-reply, clicking never switches conversations")
        check(app.contains("store.addAttachment(Attachment.fromImage(image), to: other.id)"), "screenshots pasted in the second column go to its own conversation")
        let support = (try? String(contentsOfFile: "Sources/Silkwire/ComposerSupport.swift", encoding: .utf8)) ?? ""
        check(support.contains("override func mouseDown(with event: NSEvent) { onActivate?()"), "only a real click activates, never keyboard focus at launch")

        MainActor.assumeIsolated {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("TwoComposerTests-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ConversationStore(directory: root)
            let first = store.conversation.id
            check(store.newConversation(reconnect: false), "a second conversation opens")
            let second = store.conversation.id
            let image = NSImage(size: NSSize(width: 8, height: 8)); image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
            guard let shot = try? Attachment.fromImage(image) else { fatalError("FAIL: test image") }
            check((try? store.addAttachment(shot, to: first)) != nil, "a screenshot attaches to the conversation beside you")
            check(store.conversations.first { $0.id == first }?.draftAttachments.count == 1, "it is kept with that conversation")
            check(store.conversation.id == second && store.conversation.draftAttachments.isEmpty, "the conversation you're in gets nothing extra")
            let reopened = (try? Data(contentsOf: root.appendingPathComponent("workspace.json"))).flatMap { try? JSONDecoder().decode(ConversationWorkspace.self, from: $0) }
            check(reopened?.conversations.first { $0.id == first }?.draftAttachments.count == 1, "the screenshot is saved to disk with that conversation")
            for _ in 0..<5 { _ = try? store.addAttachment(shot, to: first) }
            check((try? store.addAttachment(shot, to: first)) == nil, "the six-attachment limit applies there too")
            store.removeAttachment(shot.id, from: first)
            check(store.conversations.first { $0.id == first }?.draftAttachments.allSatisfy { $0.id != shot.id } == true, "removing it takes it out of that conversation")
        }
        print("PASS: \(count) two-composer checks")
    }
}
