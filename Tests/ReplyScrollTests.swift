import Foundation

@main struct ReplyScrollTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        func msg(_ author: String, _ detail: String? = nil) -> Message { Message(author: author, text: "x", state: "completed", requestId: nil, detail: detail) }

        let earlier = [msg("Jason"), msg("Claude"), msg("Codex")]
        let sent = msg("Jason")
        let afterSend = earlier + [sent]

        // Pressing Send holds your new message at the top.
        check(ReplyScroll.pinAfterAppend(oldCount: earlier.count, messages: afterSend, enabled: true, current: nil) == sent.id, "your new message becomes the held message")
        // Replies arriving keep it held.
        let replying = afterSend + [msg("Eve"), msg("Claude")]
        check(ReplyScroll.pinAfterAppend(oldCount: afterSend.count, messages: replying, enabled: true, current: sent.id) == sent.id, "replies arriving keep your message held at the top")
        // Streaming text (no new rows) keeps it held.
        check(ReplyScroll.pinAfterAppend(oldCount: replying.count, messages: replying, enabled: true, current: sent.id) == sent.id, "a reply growing in place keeps your message held")
        // A newer message of yours replaces the older one.
        let next = msg("Jason")
        check(ReplyScroll.pinAfterAppend(oldCount: replying.count, messages: replying + [next], enabled: true, current: sent.id) == next.id, "your next message replaces the earlier held one")
        // Pass has no new message of yours: follow the newest reply as before.
        let pass = msg("Silkwire", "Pass continuation")
        check(ReplyScroll.pinAfterAppend(oldCount: replying.count, messages: replying + [pass], enabled: true, current: sent.id) == nil, "Pass releases the hold and follows the newest reply")
        // Setting off: behave exactly as before.
        check(ReplyScroll.pinAfterAppend(oldCount: earlier.count, messages: afterSend, enabled: false, current: nil) == nil, "with the setting off nothing is held")
        check(ReplyScroll.pinAfterAppend(oldCount: afterSend.count, messages: replying, enabled: false, current: sent.id) == nil, "turning the setting off releases a hold")

        // Sending resumes following even if you had scrolled up before.
        check(ReplyScroll.sendResumesFollowing(oldCount: earlier.count, messages: afterSend, autoScroll: true), "pressing Send resumes following")
        check(!ReplyScroll.sendResumesFollowing(oldCount: afterSend.count, messages: replying, autoScroll: true), "replies arriving don't override your scrolling")
        check(!ReplyScroll.sendResumesFollowing(oldCount: earlier.count, messages: afterSend, autoScroll: false), "with auto-scroll off, Send doesn't move the view")

        // The preference defaults on and survives older saved files that lack it.
        check(WorkspacePreferences().startRepliesAtPrompt, "the setting is on by default")
        let old = try! JSONDecoder().decode(WorkspacePreferences.self, from: Data("{\"autoScrollReplies\":true}".utf8))
        check(old.startRepliesAtPrompt, "older saved preferences turn it on")
        var off = WorkspacePreferences(); off.startRepliesAtPrompt = false
        let round = try! JSONDecoder().decode(WorkspacePreferences.self, from: try! JSONEncoder().encode(off))
        check(!round.startRepliesAtPrompt, "turning it off is remembered")

        // The transcript uses it.
        let app = (try? String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)) ?? ""
        check(!app.contains("bringPromptToTop") && !app.contains("holdForReading") && !app.contains("scrollForRound"), "normal chat: Send no longer pins your prompt to the top (Nov 2)")
        check(!app.contains("followBottom(proxy) }\n                else") && !app.contains("stopAtPromptIfFull"), "new teammate rows and growing replies never move the view")
        // Jason's prompt is the stopper (Nov 2).
        check(TranscriptFlow.roundScroll(hasPrompt: true, promptTop: 500, contentBottom: 900, viewport: 700) == .bottom, "a short reply scrolls fully into view while the prompt stays on screen")
        check(TranscriptFlow.roundScroll(hasPrompt: true, promptTop: 300, contentBottom: 1400, viewport: 700) == .prompt, "a reply that would push the prompt off stops with the prompt at the top")
        check(TranscriptFlow.roundScroll(hasPrompt: true, promptTop: 208, contentBottom: 900, viewport: 700) == .bottom, "exactly fitting still follows")
        check(TranscriptFlow.roundScroll(hasPrompt: true, promptTop: nil, contentBottom: 900, viewport: 700) == .prompt, "a prompt scrolled far above stays the stopper")
        check(TranscriptFlow.roundScroll(hasPrompt: false, promptTop: 10, contentBottom: 4000, viewport: 700) == .bottom, "with the setting off, replies follow the bottom as before")
        check(TranscriptFlow.keepsRoundPrompt(currentTop: 120, viewport: 700), "a stacked prompt joins the set while the first is still on screen")
        check(!TranscriptFlow.keepsRoundPrompt(currentTop: -40, viewport: 700), "once the first prompt is read past, a new prompt starts a new set")
        check(!TranscriptFlow.keepsRoundPrompt(currentTop: nil, viewport: 700), "no current set: the new prompt starts one")
        check(app.contains("Start new replies at my message"), "the setting appears in conversation options")
        // Send flow (Nov 2): composer empties first, prompt arrives pre-collapsed.
        let storeSource = (try? String(contentsOfFile: "Sources/Silkwire/ConversationStore.swift", encoding: .utf8)) ?? ""
        // Talk any time: the attachments it took are kept on its own outgoing record (restored if unsent).
        check(storeSource.contains("if fromDraft { conversation.draft = \"\"; conversation.draftAttachments = [] }") && storeSource.contains("attachments: fromDraft ? conversation.draftAttachments : []"), "Send empties the composer before anything else happens")
        // Talk any time: each unsent message restores its own draft (save failure, rejection, room loss).
        check(storeSource.components(separatedBy: "restoreUnsentDraft(request)").count >= 4, "a prompt that can't be saved or is rejected returns to the composer")
        check(app.contains("message.author == \"Jason\", [\"sending\", \"sent\"].contains(message.state), !expanded { jasonLine }"), "your prompt appears already collapsed")
        check(!app.contains("noteReveals") && !app.contains("stopAtPromptIfFull"), "no old reveal or stopper machinery competes with the glide")
        check(app.contains("if store.preferences.autoScrollReplies && messageSearch.isEmpty { followBottom(proxy) }"), "Send takes you to the live end")
        check(app.contains(".onChange(of: replyRevision) { _, _ in noteSpeakers(); glideToLatest(proxy) }") && app.contains("guard following, !followGlide"), "auto-scroll follows new words as a gentle glide, and only while following")
        check(TranscriptFlow.glideDuration >= 0.5 && TranscriptFlow.glideInterval >= 300, "the glide is slow enough not to fly")
        check(app.contains("background(SilkwireTheme.canvas, in: Capsule())"), "Last read and Latest buttons are solid, not see-through")
        check(app.contains("Last read ↑") && app.contains("Latest ↓"), "Last read and Latest buttons are there")
        check(TranscriptFlow.isAtEnd(contentEnd: 602, viewport: 600), "scrolled to the end: following resumes")
        let a = UUID(), b = UUID(), c = UUID()
        let f1 = TranscriptFlow.floorHolders([a, b, c], typing: [a, b, c])
        check(f1.shown == [a] && f1.waiting == [b, c], "only the first to start speaking types; the rest wait their turn")
        let f2 = TranscriptFlow.floorHolders([a, b, c], typing: [b, c])
        check(f2.shown == [a, b] && f2.waiting == [c], "when the first finishes, the next one takes the floor")
        let f3 = TranscriptFlow.floorHolders([a, b, c], typing: [a])
        check(f3.shown == [a] && f3.waiting == [b, c], "a finished reply still waits for the speaker before it")
        let j = UUID()
        check(TranscriptFlow.speakingOrder([j, c, a, b], id: { $0 }, seq: [a: 1, b: 2, c: 3]) == [j, a, b, c], "replies show in speaking order; your message keeps its place")
        check(app.contains("TranscriptFlow.floorHolders(") && app.contains("noteSpeakers()"), "the transcript gives one teammate the floor at a time")
        check(!TranscriptFlow.isAtEnd(contentEnd: 640, viewport: 600), "a little above the end stays paused")
        print("PASS: \(count) reply scroll checks")
    }
}
