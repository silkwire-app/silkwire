import SwiftUI

/// Jason's read/unread markers (like Mail, or Messages' Mark as Unread).
/// A new teammate reply arrives unread (blue U). Clicking marks it read (green R);
/// clicking again marks it unread to come back to later. Scrolling never marks anything.
/// Older messages from before this feature have no marker (unread == nil).
enum ReadMarks {
    static func isUnread(_ message: Message) -> Bool { message.unread == true }
    static func unreadCount(_ messages: [Message]) -> Int { messages.reduce(0) { $0 + (isUnread($1) ? 1 : 0) } }
    /// Read means this version: new text after Jason marked a reply read makes it unread again.
    static func textChanged(_ message: inout Message, newText: String) {
        if message.unread == false, message.text != newText { message.unread = true }
    }
    static func toggle(_ message: inout Message) {
        guard let current = message.unread else { return }
        message.unread = !current
    }
    static func markAllRead(_ messages: inout [Message]) {
        for index in messages.indices where messages[index].unread == true { messages[index].unread = false }
    }
    /// A room's colour: a one-on-one room takes its teammate's colour; the team room takes Silkwire orange.
    static func roomTint(_ conversation: Conversation) -> Color {
        if let agent = conversation.focusedAgent, let name = names[agent] { return SilkwireTheme.identity(name) }
        return SilkwireTheme.accent
    }
}

/// The small circle on each new reply: blue U for unread, green R for read.
struct ReadMarkBadge: View {
    let unread: Bool
    let toggle: () -> Void
    var body: some View {
        // Style guide: a 6 pt accent dot when unread; read messages show only a faint ring
        // (still clickable to mark unread), so the header stays quiet.
        Button(action: toggle) {
            Circle().fill(unread ? SilkwireTheme.accent : Color.clear)
                .overlay(Circle().strokeBorder(unread ? Color.clear : SilkwireTheme.inkSoft.opacity(0.35), lineWidth: 1))
                .frame(width: 6, height: 6).padding(5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(unread ? "Unread. Click to mark as read." : "Read. Click to mark as unread.")
        .accessibilityLabel(unread ? "Unread. Mark as read" : "Read. Mark as unread")
    }
}

/// A room's unread count in a blue circle; hidden when everything is read.
struct UnreadCountBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(String(count))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 19, minHeight: 19)
                .background(Capsule().fill(Color.blue))
                .help(count == 1 ? "1 unread reply" : String(count) + " unread replies")
                .accessibilityLabel(count == 1 ? "1 unread reply" : String(count) + " unread replies")
        }
    }
}
