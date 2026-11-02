import Foundation

/// Where the conversation should stay while the team replies.
///
/// Jason: once I press Send I've read what's above, so start me at the top of the new
/// replies rather than letting them run off below the fold. With "Start new replies at
/// my message" on, the message you just sent is held at the top of the window while
/// replies arrive below it. Short replies still fit on screen (the view can't scroll
/// past the end), so nothing changes for them; long replies are read from their start.
///
/// Sending appends your message and every teammate's waiting reply in one batch, so these
/// look through everything added since the last update, not just the final row (Codex review).
enum ReplyScroll {
    static let userAuthor = "Jason"

    private static func isPass(_ message: Message) -> Bool {
        message.author == "Silkwire" && (message.detail == "Pass continuation" || message.detail == "Task continuation")
    }

    /// The newest input (your message or a Pass) among the rows added since `oldCount`.
    private static func newestInput(oldCount: Int, messages: [Message]) -> Message? {
        guard messages.count > oldCount else { return nil }
        return messages[max(0, oldCount)...].last { $0.author == userAuthor || isPass($0) }
    }

    /// The held message after the transcript grows from `oldCount` to `messages.count`.
    /// A new message of yours becomes the held message; Pass (no new message of yours) or
    /// the setting being off clears it so the view follows the newest reply as before;
    /// anything else (replies arriving) keeps the current one.
    static func pinAfterAppend(oldCount: Int, messages: [Message], enabled: Bool, current: UUID?) -> UUID? {
        guard enabled else { return nil }
        guard let input = newestInput(oldCount: oldCount, messages: messages) else { return current }
        return input.author == userAuthor ? input.id : nil
    }

    /// Sending means everything above has been read: resume following from the new message,
    /// even if you had scrolled up earlier and following was paused.
    static func sendResumesFollowing(oldCount: Int, messages: [Message], autoScroll: Bool) -> Bool {
        autoScroll && newestInput(oldCount: oldCount, messages: messages)?.author == userAuthor
    }
}
