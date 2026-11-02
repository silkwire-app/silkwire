import Foundation

// Independent review regression: dispatchMessage appends the input and all queued
// teammate rows synchronously, before SwiftUI observes the new message count.
// These synthetic arrays mirror that production batch; no providers or live data.
@main struct ReplyScrollBatchTests {
    static func main() {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS: " + label) }
            else { failures += 1; print("FAIL: " + label) }
        }
        func input(_ author: String, request: String, detail: String? = nil) -> Message {
            Message(author: author, text: "Synthetic input", state: "sending", requestId: request, detail: detail)
        }
        func queued(_ authors: [String], request: String) -> [Message] {
            authors.map { Message(author: $0, text: "", state: "queued", requestId: request) }
        }
        let previous = Message(author: "Jason", text: "Earlier prompt", state: "sent", requestId: "earlier")
        let earlier = [previous, Message(author: "Claude", text: "Earlier reply", state: "completed", requestId: "earlier")]
        for authors in [["Codex"], ["Eve", "Claude", "Codex"]] {
            let request = "send-\(authors.count)", sent = input("Jason", request: "send-\(authors.count)")
            let batch = earlier + [sent] + queued(authors, request: request)
            check(ReplyScroll.pinAfterAppend(oldCount: earlier.count, messages: batch, enabled: true, current: nil) == sent.id,
                  "batched Send plus \(authors.count) queued replies pins the new prompt")
            check(ReplyScroll.pinAfterAppend(oldCount: earlier.count, messages: batch, enabled: true, current: previous.id) == sent.id,
                  "batched Send plus \(authors.count) queued replies replaces an earlier pin")
            check(ReplyScroll.sendResumesFollowing(oldCount: earlier.count, messages: batch, autoScroll: true),
                  "batched Send plus \(authors.count) queued replies resumes following")
            check(!ReplyScroll.sendResumesFollowing(oldCount: earlier.count, messages: batch, autoScroll: false),
                  "disabled auto-scroll stays off for \(authors.count) queued replies")
            let passRequest = "pass-\(authors.count)"
            let pass = input("Silkwire", request: passRequest, detail: "Pass continuation")
            let continuation = earlier + [pass] + queued(authors, request: passRequest)
            check(ReplyScroll.pinAfterAppend(oldCount: earlier.count, messages: continuation, enabled: true, current: previous.id) == nil,
                  "batched Pass continuation plus \(authors.count) queued replies releases the old pin")
            check(!ReplyScroll.sendResumesFollowing(oldCount: earlier.count, messages: continuation, autoScroll: true),
                  "Pass continuation does not impersonate a new user Send")
        }
        let replyOnly = earlier + queued(["Eve"], request: "earlier")
        check(ReplyScroll.pinAfterAppend(oldCount: earlier.count, messages: replyOnly, enabled: true, current: previous.id) == previous.id,
              "ordinary reply appends preserve the current pin")
        check(!ReplyScroll.sendResumesFollowing(oldCount: earlier.count, messages: replyOnly, autoScroll: true),
              "ordinary reply appends do not override manual scrolling")
        print("ReplyScrollBatchTests: \(checks) checks, \(failures) failures; synthetic append batches only, not mounted scroll geometry")
        if failures > 0 { exit(1) }
    }
}
