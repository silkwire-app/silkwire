import Foundation

/// Presentation is independent of conversation/session lifetime. Explicit choices
/// survive resizing; automatic chooses a single partition when two will not fit.
enum ConversationDeckPresentation: String, Codable, CaseIterable {
    case automatic, focus, columns
}

/// Lightweight, value-type navigation state for one window's open conversations.
/// Owns IDs only: never transcripts, drafts, provider sessions, permissions or jobs.
/// Closing a column therefore cannot archive a conversation or stop its work.
///
/// Integration contract:
/// - The workspace/session owner remains authoritative for content and lifetime.
/// - Reconcile restored IDs with the caller's current available conversation IDs
///   before rendering. Decoding this state grants no access and starts no sessions.
/// - A focused ID is a UI destination, not authority to rebind an in-flight send.
/// - In columns mode, feed displayedIDs to a lazy horizontal container so offscreen
///   column views need not remain rendered. The session owner keeps their work alive.
struct ConversationDeck: Codable, Equatable {
    private(set) var openIDs: [UUID]
    private(set) var focusedID: UUID?
    var presentation: ConversationDeckPresentation

    init(openIDs: [UUID] = [], focusedID: UUID? = nil, presentation: ConversationDeckPresentation = .automatic) {
        var seen = Set<UUID>()
        let uniqueIDs = openIDs.filter { seen.insert($0).inserted }
        self.openIDs = uniqueIDs
        self.focusedID = focusedID.flatMap { uniqueIDs.contains($0) ? $0 : nil } ?? uniqueIDs.first
        self.presentation = presentation
    }

    var focusedIndex: Int? { focusedID.flatMap { openIDs.firstIndex(of: $0) } }
    /// One-based position for the “n of N” control. Empty decks have no position.
    var focusedOrdinal: Int? { focusedIndex.map { $0 + 1 } }
    var previousID: UUID? {
        guard let index = focusedIndex, index > 0 else { return nil }
        return openIDs[index - 1]
    }
    var nextID: UUID? {
        guard let index = focusedIndex, index + 1 < openIDs.count else { return nil }
        return openIDs[index + 1]
    }

    /// Opening an existing column focuses it without duplicating or reordering it.
    /// Background opens leave the user's current typing destination unchanged.
    @discardableResult mutating func open(_ id: UUID, availableIDs: Set<UUID>, activate: Bool = true) -> Bool {
        guard availableIDs.contains(id) else { return false }
        if !openIDs.contains(id) { openIDs.append(id) }
        if activate || focusedID == nil { focusedID = id }
        return true
    }

    @discardableResult mutating func focus(_ id: UUID) -> Bool {
        guard openIDs.contains(id) else { return false }
        focusedID = id; return true
    }

    /// Arrows stop at the ends instead of unexpectedly wrapping to another chat.
    @discardableResult mutating func movePrevious() -> Bool {
        guard let id = previousID else { return false }
        focusedID = id; return true
    }
    @discardableResult mutating func moveNext() -> Bool {
        guard let id = nextID else { return false }
        focusedID = id; return true
    }

    /// Hides only this column. Prefer its right neighbour, then its left neighbour.
    /// Closing an inactive column does not move the user's active composer.
    @discardableResult mutating func close(_ id: UUID) -> Bool {
        guard let index = openIDs.firstIndex(of: id) else { return false }
        openIDs.remove(at: index)
        if focusedID == id { focusedID = openIDs.isEmpty ? nil : openIDs[min(index, openIDs.count - 1)] }
        return true
    }

    /// Remove stale, deleted, archived or otherwise unavailable IDs supplied by the
    /// workspace owner. This never opens another chat or mutates the saved library.
    mutating func reconcile(availableIDs: Set<UUID>) {
        let oldIDs = openIDs, oldIndex = focusedIndex ?? 0
        openIDs.removeAll { !availableIDs.contains($0) }
        if focusedID.map({ !openIDs.contains($0) }) ?? true {
            focusedID = oldIDs.dropFirst(oldIndex).first(where: { availableIDs.contains($0) })
                ?? oldIDs.prefix(oldIndex).last(where: { availableIDs.contains($0) })
                ?? openIDs.first
        }
    }

    /// Width is the conversation area's width, after sidebar/library chrome.
    /// The minimum is an integration parameter, not a fixed product breakpoint.
    func resolvedPresentation(availableWidth: Double, minimumColumnWidth: Double = 420) -> ConversationDeckPresentation {
        guard openIDs.count > 1, presentation != .focus else { return .focus }
        if presentation == .columns { return .columns }
        guard availableWidth.isFinite, minimumColumnWidth.isFinite, minimumColumnWidth > 0,
              availableWidth >= minimumColumnWidth * 2 else { return .focus }
        return .columns
    }

    func displayedIDs(availableWidth: Double, minimumColumnWidth: Double = 420) -> [UUID] {
        if resolvedPresentation(availableWidth: availableWidth, minimumColumnWidth: minimumColumnWidth) == .columns { return openIDs }
        return focusedID.map { [$0] } ?? []
    }

    private enum CodingKeys: String, CodingKey { case version, openIDs, focusedID, presentation }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported conversation deck version; retain the saved data.")
        }
        self.init(openIDs: try values.decode([UUID].self, forKey: .openIDs),
                  focusedID: try values.decodeIfPresent(UUID.self, forKey: .focusedID),
                  presentation: try values.decodeIfPresent(ConversationDeckPresentation.self, forKey: .presentation) ?? .automatic)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(openIDs, forKey: .openIDs)
        try values.encodeIfPresent(focusedID, forKey: .focusedID)
        try values.encode(presentation, forKey: .presentation)
    }
}
