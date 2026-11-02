import SwiftUI

enum ReplyOrdering: String, CaseIterable {
    case fixed, rotating, random
    var title: String { switch self { case .fixed: return "Fixed"; case .rotating: return "Rotating (Round Robin)"; case .random: return "Random (Shuffle)" } }
    // Shuffle never repeats the previous order, so it visibly mixes things up.
    func arrange(_ selected: [String], round: Int, previous: [String] = []) -> [String] {
        guard selected.count > 1 else { return selected }
        switch self {
        case .fixed: return selected
        case .rotating:
            let offset = max(0, round) % selected.count
            return Array(selected.dropFirst(offset)) + Array(selected.prefix(offset))
        case .random:
            var order = selected.shuffled()
            if order == previous { order = Array(order.dropFirst()) + [order[0]] }
            return order
        }
    }
}

struct SubscriptionHUD: View {
    @ObservedObject var store: ConversationStore
    @AppStorage(FuelGauge.modeKey) private var mode = FuelGauge.Mode.auto.rawValue
    @AppStorage(FuelGauge.pinsKey) private var pins = ""
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Text("Usage").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(FuelGauge.checkedLabel(store.connectionsCheckedAt, now: timeline.date)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    if store.connectionsLoading {
                        ProgressView().controlSize(.mini).accessibilityLabel("Checking connections")
                    } else {
                        Button { store.refreshConnections() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold)) }
                            .buttonStyle(.borderless).help("Check all connections now").accessibilityLabel("Refresh usage for all connections")
                    }
                }
                ForEach(["claude", "codex"], id: \.self) { agent in meters(agent, now: timeline.date) }
            }
        }
        .task {
            // Gentle background refresh: checks once a minute whether 30 idle minutes have passed.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if FuelGauge.shouldAutoRefresh(checkedAt: store.connectionsCheckedAt, loading: store.connectionsLoading, busy: store.busy || store.connecting, now: Date()) {
                    store.refreshConnections()
                }
            }
        }
    }
    private func providerName(_ agent: String) -> String { agent == "codex" ? "OpenAI" : "Anthropic" }
    private func meters(_ agent: String, now: Date) -> some View {
        let detail = store.connectionDetails.first { $0.agent == agent }
        let pinned = FuelGauge.decodePins(pins)[agent]
        let windows = FuelGauge.sidebarWindows(detail?.usage ?? [], mode: FuelGauge.Mode(rawValue: mode) ?? .auto, pinned: pinned, now: now)
        return VStack(alignment: .leading, spacing: 5) {
            if windows.isEmpty { row(agent, window: nil, pinned: false, checked: detail?.checkedAt, now: now) }
            ForEach(windows, id: \.label) { window in row(agent, window: window, pinned: window.label == pinned, checked: detail?.checkedAt, now: now) }
        }
    }
    private func row(_ agent: String, window: UsageWindow?, pinned: Bool, checked: Date?, now: Date) -> some View {
        let name = providerName(agent)
        let presentation = AllowancePresentation(window: window, checkedAt: checked, now: now)
        let provider = agent == "codex" ? "Codex" : "Claude"
        let reason = window.map { pinned ? "Showing the \($0.label) window you chose. " : "Showing the \($0.label) window, the lowest remaining percentage. " } ?? ""
        let freshness = presentation.stale ? ", reading may be out of date" : ""
        // Anthropic doesn't share subscription usage with other apps (Jason's decision: no
        // workarounds). Say where the numbers live instead of a bare "Not available".
        let inClaudeCode = window == nil && agent != "codex"
        let valueText = inClaudeCode ? "Shown in Claude Code" : presentation.label
        return Button { store.connectionsPresented = true } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(name)
                    if let window { Text(window.label).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    Text(valueText).lineLimit(1).foregroundStyle(inClaudeCode ? .secondary : .primary)
                }.font(.system(size: 10))
                if let window {
                    ProgressView(value: window.remainingPercent, total: 100).tint(presentation.color)
                } else {
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(name + (window.map { " subscription allowance, \(Int($0.remainingPercent)) percent of the \($0.label) window remaining" + freshness } ?? (inClaudeCode ? " subscription usage is shown in Claude Code; type /usage there" : " subscription usage not available")))
        .help(inClaudeCode ? "Anthropic doesn't share subscription usage with other apps. To see your session and weekly limits, type /usage in Claude Code. If you get close to a limit, Claude Code may tell Silkwire, and the meter appears here." : reason + "Reported by \(provider); not a combined allowance for other connections. Open Connections → All for every meter and reset time. Last check: \(checked?.formatted() ?? "not checked").")
    }
}
