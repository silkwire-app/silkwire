import Foundation

// Pure checks for the transcript window that keeps long conversations light to
// draw. Does not measure rendered SwiftUI frame times.
@main struct TranscriptWindowTests {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        let empty: [Int] = []
        check(TranscriptWindow.visible(empty, limit: 50).isEmpty, "empty conversation draws nothing")
        check(TranscriptWindow.hiddenCount(count: 0, limit: 50) == 0, "empty conversation hides nothing")

        let short = Array(0..<12)
        check(Array(TranscriptWindow.visible(short, limit: 50)) == short, "short conversation is drawn in full and in order")
        check(TranscriptWindow.hiddenCount(count: 12, limit: 50) == 0, "short conversation offers no Show earlier")

        let long = Array(0..<2000)
        let shown = TranscriptWindow.visible(long, limit: TranscriptWindow.initial)
        check(shown.count == 25, "long conversation draws only 25 rows")
        check(shown.first == 1975 && shown.last == 1999, "drawn rows are the newest, oldest-first")
        check(long.count == 2000, "full history is untouched")
        check(TranscriptWindow.hiddenCount(count: 2000, limit: 25) == 1975, "hidden count reports older messages")

        var limit = TranscriptWindow.initial
        limit = TranscriptWindow.earlier(limit: limit, count: 2000)
        check(limit == 50 && TranscriptWindow.visible(long, limit: limit).first == 1950, "Show earlier reveals one more step")
        for _ in 0..<100 { limit = TranscriptWindow.earlier(limit: limit, count: 2000) }
        check(limit == 2000 && TranscriptWindow.hiddenCount(count: 2000, limit: limit) == 0, "repeated Show earlier stops at the whole history")
        check(TranscriptWindow.earlier(limit: 50, count: 70) == 70, "last step reveals only what remains")

        check(TranscriptWindow.visible(short, limit: 0).isEmpty && TranscriptWindow.visible(short, limit: -5).isEmpty, "zero or negative limits never crash")
        check(TranscriptWindow.hiddenCount(count: 12, limit: -5) == 12, "negative limit hides everything safely")

        check(TranscriptWindow.grown(limit: 50, oldCount: 200, newCount: 202, following: false) == 52, "replies arriving while reading earlier keep the rows being read")
        check(TranscriptWindow.grown(limit: 50, oldCount: 200, newCount: 202, following: true) == 50, "following the bottom keeps the window small")
        check(TranscriptWindow.grown(limit: 50, oldCount: 10, newCount: 2000, following: false) == 50, "switching to a long conversation does not balloon the window")
        check(TranscriptWindow.grown(limit: 50, oldCount: 200, newCount: 199, following: false) == 50, "deleted messages never grow the window")

        print("\(checks - failures) of \(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
