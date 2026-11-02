import Foundation

/// Long conversations draw only their most recent messages; "Show earlier"
/// reveals more. The full history stays loaded in memory and saved on disk.
/// This only limits how many rows SwiftUI has to lay out and diff, which keeps
/// typing responsive while replies stream in.
enum TranscriptWindow {
    static let initial = 25
    static let step = 25

    /// The newest `limit` items, in their original order.
    static func visible<T>(_ items: [T], limit: Int) -> ArraySlice<T> {
        items[range(count: items.count, limit: limit)]
    }
    static func range(count: Int, limit: Int) -> Range<Int> {
        max(0, count - max(limit, 0))..<max(count, 0)
    }
    /// How many older items are not being drawn.
    static func hiddenCount(count: Int, limit: Int) -> Int { max(0, count - max(limit, 0)) }
    /// The limit after one "Show earlier": one more step, never past the whole history.
    static func earlier(limit: Int, count: Int) -> Int { max(min(count, limit + step), min(limit, count)) }
    /// New messages arriving while someone reads further up should not push the
    /// rows they are reading out of the window. Small arrivals widen the window;
    /// large jumps (switching conversations, loading history) do not.
    static func grown(limit: Int, oldCount: Int, newCount: Int, following: Bool) -> Int {
        guard !following, newCount > oldCount, newCount - oldCount <= 5 else { return limit }
        return limit + (newCount - oldCount)
    }
}
