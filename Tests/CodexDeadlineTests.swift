import Foundation

// Codex replies are only interrupted when they stop making progress or exceed the
// absolute ceiling - never just for being longer than 3 minutes.
@main struct CodexDeadlineTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            print("PASS: \(name)")
        }
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        check(!ReplyDeadlinePolicy.expired(startedAt: start, lastActivity: start, now: at(3.5)), "a reply past the old 3-minute cutoff keeps going")
        check(!ReplyDeadlinePolicy.expired(startedAt: start, lastActivity: at(1), now: at(16)), "a single 15-minute build with no streamed text is not cut off")
        check(!ReplyDeadlinePolicy.expired(startedAt: start, lastActivity: at(44), now: at(45)), "a 45-minute reply that keeps making progress continues")
        check(ReplyDeadlinePolicy.expired(startedAt: start, lastActivity: at(1), now: at(21.5)), "a reply silent for over 20 minutes is interrupted")
        check(ReplyDeadlinePolicy.expired(startedAt: start, lastActivity: at(60.5), now: at(60.6)), "no reply runs past the 60-minute ceiling, even when active")
        check(ReplyDeadlinePolicy.idleLimit > 15 * 60, "idle limit outlasts one 15-minute broker command")
        check(ReplyDeadlinePolicy.checkInterval <= 10, "stalls are noticed promptly")
        check(ReplyDeadlinePolicy.message(startedAt: start, lastActivity: at(1), now: at(22)).contains("no progress"), "stall message explains the stall")
        check(ReplyDeadlinePolicy.message(startedAt: start, lastActivity: at(60), now: at(61)).contains("60-minute"), "ceiling message explains the ceiling")
        check(ReplyDeadlinePolicy.message(startedAt: start, lastActivity: at(1), now: at(22)).contains("Nothing resent"), "interrupted replies are never silently resent")
        check(ReplyDeadlinePolicy.shouldDisconnect(taskCancelled: false, replyStillActive: true, sameConnection: true), "a stalled active reply on the live connection is stopped")
        check(!ReplyDeadlinePolicy.shouldDisconnect(taskCancelled: false, replyStillActive: false, sameConnection: true), "a reply that finished during the interrupt never disconnects Codex")
        check(!ReplyDeadlinePolicy.shouldDisconnect(taskCancelled: true, replyStillActive: true, sameConnection: true), "a cancelled timer never disconnects Codex")
        check(!ReplyDeadlinePolicy.shouldDisconnect(taskCancelled: false, replyStillActive: true, sameConnection: false), "an old timer never tears down a newer connection")
    }
}
