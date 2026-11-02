import SwiftUI
import AppKit

// The same thresholds and validity rules apply in the sidebar and Connections.
struct AllowancePresentation {
    enum Level: String { case green, amber, red, neutral }
    let percent: Double?
    let stale: Bool
    init(window: UsageWindow?, checkedAt: Date?, now: Date) {
        stale = checkedAt.map { now.timeIntervalSince($0) > FuelGauge.staleAfter || $0 > now.addingTimeInterval(60) } ?? true
        percent = window.flatMap { value in
            guard value.remainingPercent.isFinite, (0...100).contains(value.remainingPercent),
                  value.resetsAt.map({ $0.isFinite && $0 > now.timeIntervalSince1970 }) ?? true else { return nil }
            return value.remainingPercent
        }
    }
    var level: Level {
        guard !stale, let percent else { return .neutral }
        return percent >= 75 ? .green : percent >= 25 ? .amber : .red
    }
    var color: Color { switch level { case .green: return .green; case .amber: return .orange; case .red: return .red; case .neutral: return .gray } }
    var label: String { percent.map { "\(Int($0))% left" + (stale ? " · stale" : "") } ?? "Not available" }
}

// The sidebar "fuel gauge": one compact line per connection, showing the usage window
// that will run out first, plus when the readings were last checked. Every window and
// reset time stays available in Connections for anyone who wants the full detail.
enum FuelGauge {
    /// What the sidebar shows: each provider's lowest remaining percentage, or every meter.
    /// A meter pinned with "Show in sidebar" replaces its provider's automatic choice.
    enum Mode: String { case auto, all }
    /// A reading greys out after an hour. Allowances rarely move fast enough to need more,
    /// and a calm gauge is easier to trust than one that keeps flagging itself.
    static let staleAfter: TimeInterval = 60 * 60
    /// While Silkwire is open and idle, readings refresh themselves every 30 minutes.
    static let autoRefreshAfter: TimeInterval = 30 * 60
    /// Refreshes only when nothing is replying or connecting, never before a first check,
    /// and never while another check is already running.
    static func shouldAutoRefresh(checkedAt: Date?, loading: Bool, busy: Bool, now: Date) -> Bool {
        guard !loading, !busy, let checkedAt else { return false }
        return now.timeIntervalSince(checkedAt) >= autoRefreshAfter
    }
    static let modeKey = "silkwire.fuelGauge.mode"
    static let pinsKey = "silkwire.fuelGauge.pins"
    static func validWindows(_ windows: [UsageWindow], now: Date) -> [UsageWindow] {
        windows.filter { window in
            window.remainingPercent.isFinite && (0...100).contains(window.remainingPercent)
                && (window.resetsAt.map { $0.isFinite && $0 > now.timeIntervalSince1970 } ?? true)
        }
    }
    /// The window with the lowest remaining percentage among the provider's valid readings.
    static func mostConstrained(_ windows: [UsageWindow], now: Date) -> UsageWindow? {
        validWindows(windows, now: now).min { $0.remainingPercent < $1.remainingPercent }
    }
    static func sidebarWindows(_ windows: [UsageWindow], mode: Mode, pinned: String?, now: Date) -> [UsageWindow] {
        let valid = validWindows(windows, now: now)
        if mode == .all { return valid.sorted { $0.remainingPercent < $1.remainingPercent } }
        if let pinned, let chosen = valid.first(where: { $0.label == pinned }) { return [chosen] }
        return mostConstrained(windows, now: now).map { [$0] } ?? []
    }
    /// Pins are saved as one "agent=window label" line per provider.
    static func decodePins(_ text: String) -> [String: String] {
        var pins: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let agent = String(line[..<equals]), label = String(line[line.index(after: equals)...])
            if !agent.isEmpty, !label.isEmpty { pins[agent] = label }
        }
        return pins
    }
    static func encodePins(_ pins: [String: String]) -> String {
        pins.keys.sorted().compactMap { agent in pins[agent].map { "\(agent)=\($0)" } }.joined(separator: "\n")
    }
    static func checkedLabel(_ checkedAt: Date?, now: Date) -> String {
        guard let checkedAt else { return "Not checked yet" }
        let seconds = now.timeIntervalSince(checkedAt)
        // A check time well in the future means a clock problem, not a fresh reading.
        if seconds < -60 { return "Check time unclear" }
        if seconds < 60 { return "Checked just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Checked \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Checked \(hours) hr ago" }
        return "Checked \(hours / 24) d ago"
    }
}

// Measures each control at its intrinsic size and moves whole controls to a new
// row. Names, identity icons and selection marks never wrap independently.
struct PillFlowLayout: Layout {
    var spacing: CGFloat = 8
    private func positions(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], height: CGFloat) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (points, y + rowHeight)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        return CGSize(width: width, height: positions(subviews, width: width).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = positions(subviews, width: bounds.width).points
        for (index, view) in subviews.enumerated() { view.place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y), anchor: .topLeading, proposal: .unspecified) }
    }
}

struct ReplyQueueSnapshot {
    let order: [String]
    let agent: String
    var position: Int? { order.firstIndex(of: agent).map { $0 + 1 } }
    var isFinalSpeaker: Bool { order.last == agent }
    var prompt: String {
        "CURRENT REPLY QUEUE (host supplied): " + ((try? nativeJSON(["order": order, "speaker": agent, "position": position.map { $0 as Any } ?? NSNull(), "count": order.count, "isFinalSpeaker": isFinalSpeaker])) ?? "{}") +
        ". This is the dispatch order for this request, including shuffle. Earlier disconnected or cancelled speakers may have no reply. The final-speaker flag describes queue position, not task completion."
    }
}
