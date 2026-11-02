import Foundation

/// Glue between Codex's ConversationDeck (which conversations are open as silos)
/// and the single conversation the window is showing. Pure, so it can be tested
/// without the app. The deck only moves when the window really switched, so a
/// refused switch (a reply still running) never leaves the arrows pointing at a
/// conversation that isn't on screen.
/// Size limits for a conversation column (one at a time or side by side).
enum SiloLayout {
    /// Narrowest a conversation may get: composer, pills and replies stay readable.
    static let minimumColumnWidth: Double = 460
    /// Multi-room columns can be narrower than the legacy chat/reader pair.
    /// Jason: today's narrowest room (600) reads well, so new installs open there; Narrow (460) is opt-in.
    static let defaultRoomWidth: CGFloat = 600
    static let minimumRoomWidth: CGFloat = 460
    static func clampedRoomWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultRoomWidth }
        return min(max(width, minimumRoomWidth), maximumPreferredSiloWidth)
    }
    static func roomWidth(available: CGFloat, columns: Int, preferred: CGFloat) -> CGFloat {
        guard available.isFinite, available > 0, columns > 0 else { return 0 }
        let room = (available - outerMargin * CGFloat(columns + 1)) / CGFloat(columns)
        // Keep a readable minimum and overflow horizontally rather than hiding rooms.
        return min(clampedRoomWidth(preferred), max(minimumRoomWidth, room))
    }
    /// Width of an Alexandria page sliding over three or more rooms: the reader's chosen width,
    /// but always leaving a strip of the rooms visible on the left so you can see they're still there.
    static let slideOverRoomsPeek: CGFloat = 140
    static func slideOverReaderWidth(available: CGFloat, preferred: CGFloat) -> CGFloat {
        guard available.isFinite, available > 0 else { return minimumReaderWidth }
        let room = max(minimumReaderWidth, available - slideOverRoomsPeek)
        return min(clampedReader(preferred.isFinite ? preferred : defaultReaderWidth), room)
    }
    /// Widest a silo grows: messages are 820 points plus their padding. Wider windows
    /// leave open space to the right for Alexandria and future modules.
    static let maximumSiloWidth: CGFloat = 880
    /// Space between the silo's border and the window edges.
    static let outerMargin: CGFloat = 14
    static let cornerRadius: CGFloat = 12
    /// Drawer overlays only the transcript region, never the measured composer.
    static func drawerHeight(available: CGFloat, composerHeight: CGFloat) -> CGFloat {
        guard available.isFinite, composerHeight.isFinite, composerHeight > 0 else { return 0 }
        return max(0, available - outerMargin * 2 - composerHeight - 1)
    }
    /// The silo's width in the space available: as wide as it can be up to the maximum,
    /// always left-aligned, never negative.
    static func siloWidth(available: CGFloat) -> CGFloat {
        guard available.isFinite else { return 0 }
        return min(max(0, available - outerMargin * 2), maximumSiloWidth)
    }
    /// The width you choose for the chat column (drag its edge or the divider). Jason
    /// asked for a narrower default; limits keep replies and the composer readable.
    static let defaultSiloWidth: CGFloat = 740
    // 600: below this the composer's teammate pills and review receipts wrap (Jason).
    static let minimumSiloWidth: CGFloat = 600
    static let maximumPreferredSiloWidth: CGFloat = 960
    /// Narrowest an Alexandria page may be beside chat; below this its contents list
    /// folds away first, and below the reader's own minimum the page overlays instead.
    static let minimumReaderWidth: CGFloat = 560
    static let dividerWidth: CGFloat = 9
    /// Writing-space height: taller by default (was 82, felt cramped), drag the top edge to change.
    static let defaultComposerHeight: CGFloat = 120
    static let minimumComposerHeight: CGFloat = 70
    static let maximumComposerHeight: CGFloat = 420
    static func clampedComposer(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return defaultComposerHeight }
        return min(max(height, minimumComposerHeight), maximumComposerHeight)
    }
    /// Alexandria's width beside chat. It stays anchored to the right rail; on wide
    /// windows the leftover space becomes a gap after chat instead of stretching the page.
    static let defaultReaderWidth: CGFloat = 1060
    static let maximumReaderWidth: CGFloat = 1500
    static func clampedReader(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultReaderWidth }
        return min(max(width, minimumReaderWidth), maximumReaderWidth)
    }
    static func clampedPreferred(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultSiloWidth }
        return min(max(width, minimumSiloWidth), maximumPreferredSiloWidth)
    }
    /// The silo's width given the space available and the width Jason chose.
    static func siloWidth(available: CGFloat, preferred: CGFloat) -> CGFloat {
        guard available.isFinite else { return 0 }
        return min(max(0, available - outerMargin * 2), clampedPreferred(preferred))
    }
    /// Chat and an open Alexandria page side by side, when the window has room.
    /// Chat keeps its chosen width; the page takes the rest. If the page would be too
    /// narrow, chat gives up width down to its minimum; if that still isn't enough,
    /// returns nil and the page opens over the conversation as before.
    static func sideBySide(total: CGFloat, preferred: CGFloat, preferredReader: CGFloat = .greatestFiniteMagnitude) -> (chat: CGFloat, reader: CGFloat, gap: CGFloat)? {
        guard total.isFinite, total > 0 else { return nil }
        let chosen = clampedPreferred(preferred) + outerMargin * 2
        let room = total - chosen - dividerWidth
        let wanted = preferredReader == .greatestFiniteMagnitude ? room : clampedReader(preferredReader)
        if room >= wanted, wanted >= minimumReaderWidth { return (chosen, wanted, room - wanted) }
        if room >= minimumReaderWidth { return (chosen, room, 0) }
        let squeezed = total - dividerWidth - minimumReaderWidth
        guard squeezed >= minimumSiloWidth + outerMargin * 2 else { return nil }
        return (squeezed, minimumReaderWidth, 0)
    }
    /// Width of each silo when two sit side by side, or nil when they don't both fit
    /// at a comfortable width (then only the conversation on screen is shown).
    static func pairWidth(available: CGFloat, preferred: CGFloat) -> CGFloat? {
        guard available.isFinite else { return nil }
        let each = min(clampedPreferred(preferred), (available - outerMargin * 3) / 2)
        return each >= minimumSiloWidth ? each : nil
    }
    /// Two chats plus an open page (Jason: a page must not push the second chat away
    /// when there's room). The page gives way first, down to its comfortable minimum;
    /// then both chats narrow together to theirs. Nil when all three can't fit.
    static func pairSideBySide(total: CGFloat, preferred: CGFloat, preferredReader: CGFloat) -> (chat: CGFloat, reader: CGFloat, gap: CGFloat)? {
        guard total.isFinite, total > 0 else { return nil }
        let silo = clampedPreferred(preferred)
        let chat = silo * 2 + outerMargin * 3
        let wanted = clampedReader(preferredReader)
        let room = total - chat - dividerWidth
        if room >= wanted { return (chat, wanted, room - wanted) }
        if room >= minimumReaderWidth { return (chat, room, 0) }
        let each = (total - dividerWidth - minimumReaderWidth - outerMargin * 3) / 2
        guard each >= minimumSiloWidth else { return nil }
        return (each * 2 + outerMargin * 3, minimumReaderWidth, 0)
    }
    /// Shared height of the top row in the chat header and Alexandria's header,
    /// so both header bands (and their divider lines) line up across the window.
    static let headerRowHeight: CGFloat = 34
    /// Vertical padding around that row in both headers.
    static let headerVerticalPadding: CGFloat = 15
    /// Whether a second column fits beside the first in the given width;
    /// otherwise the one-at-a-time arrows are used instead of squeezing.
    static func fitsSideBySide(availableWidth: Double, columns: Int = 2) -> Bool {
        availableWidth.isFinite && columns > 0 && availableWidth >= minimumColumnWidth * Double(columns)
    }
}

/// Makes it obvious which room you're typing into.
enum SiloIdentity {
    /// Sidebar/seat wording. A teammate who simply isn't part of this one-on-one
    /// is not "Disconnected"; nothing is wrong.
    static func statusLabel(state: String, message: String) -> String {
        message.hasPrefix("Not in this one-on-one") ? "Not in this chat" : "Disconnected"
    }
    /// Recipient pills under the composer. A one-on-one shows only its teammate,
    /// so there are no unchecked pills that look like you could add someone.
    /// If that teammate has left the Project, show none rather than the team.
    static func pills(participants: [String], focusedAgent: String?) -> [String] {
        guard let agent = focusedAgent else { return participants }
        return participants.contains(agent) ? [agent] : []
    }
    /// Whose color marks this silo's top and bottom strip: the teammate in a
    /// one-on-one; nil for team rooms, which use the Silkwire accent.
    static func colorName(focusedAgent: String?, names: [String: String]) -> String? {
        focusedAgent.flatMap { names[$0] }
    }
}

enum SiloNavigator {
    enum Step { case previous, next }

    static func target(_ deck: ConversationDeck, _ step: Step) -> UUID? {
        step == .previous ? deck.previousID : deck.nextID
    }

    /// Records a completed switch. Returns false (and changes nothing) if the
    /// window refused to switch.
    @discardableResult static func commit(_ deck: inout ConversationDeck, to id: UUID, switched: Bool) -> Bool {
        switched ? deck.focus(id) : false
    }

    /// The other open conversation to show beside the one on screen: the next silo,
    /// or the previous one when this is the last. Nil when only one is open.
    static func companion(_ deck: ConversationDeck, current: UUID) -> UUID? {
        guard deck.openIDs.count > 1, let index = deck.openIDs.firstIndex(of: current) else { return nil }
        return index + 1 < deck.openIDs.count ? deck.openIDs[index + 1] : deck.openIDs[index - 1]
    }
    /// Columns keep their places (Jason): the conversation opened earlier stays on
    /// the left whichever one you're typing in, so switching never swaps them.
    static func companionLeads(_ deck: ConversationDeck, current: UUID, companion: UUID) -> Bool {
        guard let a = deck.openIDs.firstIndex(of: companion), let b = deck.openIDs.firstIndex(of: current) else { return false }
        return a < b
    }
    /// "2 of 4", or nil when there is only one silo (the arrows stay hidden).
    static func label(_ deck: ConversationDeck) -> String? {
        guard deck.openIDs.count > 1, let n = deck.focusedOrdinal else { return nil }
        return "\(n) of \(deck.openIDs.count)"
    }

    /// Keeps the deck in step with the window: drops archived or deleted
    /// conversations and makes sure whatever is on screen is an open, focused silo
    /// (however it got there: sidebar, search, a new one-on-one chat).
    static func synced(_ deck: ConversationDeck, current: UUID, available: Set<UUID>) -> ConversationDeck {
        var result = deck
        let all = available.union([current])
        result.reconcile(availableIDs: all)
        result.open(current, availableIDs: all)
        return result
    }

    /// The deck after hiding the silo on screen, and the conversation to show
    /// next. Nil when it is the only silo (there is nothing to slide to).
    static func closing(_ deck: ConversationDeck, current: UUID) -> (deck: ConversationDeck, show: UUID)? {
        var result = deck
        guard deck.openIDs.count > 1, result.close(current), let next = result.focusedID else { return nil }
        return (result, next)
    }

    static func encode(_ deck: ConversationDeck) -> String {
        (try? JSONEncoder().encode(deck)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func decode(_ text: String) -> ConversationDeck {
        guard let data = text.data(using: .utf8), let deck = try? JSONDecoder().decode(ConversationDeck.self, from: data) else { return ConversationDeck() }
        return deck
    }
}
