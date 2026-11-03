import SwiftUI

struct ConnectionsView: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var setup = NativeProviderSetup()
    @State private var selected = "all"
    @AppStorage(FuelGauge.modeKey) private var gaugeMode = FuelGauge.Mode.auto.rawValue
    @AppStorage(FuelGauge.pinsKey) private var gaugePins = ""
    private let providerNames = ["eve": "OpenClaw", "claude": "Anthropic", "codex": "OpenAI"]
    private var detail: ConnectionDetail? { store.connectionDetails.first { $0.agent == selected } }
    private var seat: Seat { store.seats[selected] ?? Seat() }
    private var installed: Bool {
        if let detail { return detail.installed }
        if selected == "eve" { return true }
        let path = selected == "codex" ? ProviderPaths.codex : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        return FileManager.default.isExecutableFile(atPath: path)
    }
    private var unavailable: Bool { setup.agent != nil || store.busy || store.connecting || store.storageError != nil }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Connections").font(.title2.weight(.semibold)); Spacer()
                if store.connectionsLoading { ProgressView().controlSize(.small) }
                Button("Check again") { store.refreshConnections() }.disabled(store.connectionsLoading || setup.agent != nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Connect your existing accounts. Sign-in stays with OpenAI, Anthropic or your OpenClaw setup—not Silkwire.").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { setup.cancel(); selected = "all" } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gauge.medium").frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("All").fontWeight(.medium)
                            Text("Usage overview").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if selected == "all" { Image(systemName: "checkmark").font(.caption) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected == "all" ? SilkwireTheme.accent.opacity(0.16) : SilkwireTheme.wash(0.025), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityLabel("All connections usage overview")
                ForEach(agents, id: \.self) { agent in
                    Button { setup.cancel(); selected = agent } label: {
                        HStack(spacing: 8) {
                            InitialCircle(name: names[agent]!, size: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(names[agent]!).fontWeight(.medium)
                                Text(stateName(store.seats[agent]?.state ?? "disconnected")).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if selected == agent { Image(systemName: "checkmark").font(.caption) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected == agent ? SilkwireTheme.accent.opacity(0.16) : SilkwireTheme.wash(0.025), in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }
            ConnectionHistoryCard(agent: selected == "all" ? nil : selected)
            if selected == "all" { allConnectionsCard } else {
            connectionCard
            if setup.agent == selected || !setup.message.isEmpty {
                HStack(alignment: .top) {
                    if setup.agent != nil { ProgressView().controlSize(.small) }
                    Text(setup.message).font(.callout).textSelection(.enabled)
                    Spacer()
                    if setup.agent != nil { Button("Cancel sign-in") { setup.cancel() } }
                }.padding(12).background(SilkwireTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let detail {
                DisclosureGroup("Account, model and usage") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(detail.account).font(.callout).textSelection(.enabled)
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            GridRow { Text("Model").foregroundStyle(.secondary); Text(detail.model) }
                            GridRow { Text("Effort").foregroundStyle(.secondary); Text(detail.effort) }
                            GridRow { Text("Speed").foregroundStyle(.secondary); Text(detail.speed) }
                            GridRow { Text("Permissions").foregroundStyle(.secondary); Text(detail.permissions) }
                        }.font(.caption)
                        Text("Uses the connector’s current default. Model switching is not enabled in this preview.").font(.caption2).foregroundStyle(.secondary)
                        if detail.usage.isEmpty { Text("Usage: Not reported").font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(detail.usage.enumerated()), id: \.offset) { _, window in
                            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                                let presentation = AllowancePresentation(window: window, checkedAt: detail.checkedAt, now: timeline.date)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(window.label); Spacer(); Text(presentation.label) }.font(.caption)
                                    if let percent = presentation.percent { ProgressView(value: percent, total: 100).tint(presentation.color) }
                                    else { Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3) }
                                    if let reset = window.resetsAt, reset.isFinite { Text("Resets \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                                    Text("Usage checked: " + (detail.checkedAt?.formatted() ?? "not recorded")).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !detail.models.isEmpty { DisclosureGroup("Reported model catalog") { Text(detail.models.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).padding(.top, 4) } }
                        if let note = detail.note { Text(note).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(store.connectionsLoading ? "Checking account and model details…" : "Account and model details have not been confirmed. Check again to diagnose without sending a message.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            projectFiles
            }
            RevisionStatusView(store: store)
            if let date = store.connectionsCheckedAt { Text("Checked \(date.formatted(date: .omitted, time: .shortened)) · A catalog does not prove model entitlement. Missing usage is Not reported, not unlimited.").font(.caption2).foregroundStyle(.secondary) }
        }.padding(24) }
        .frame(width: min(800, (NSScreen.main?.visibleFrame.width ?? 1000) - 100), height: min(740, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
        .background(SilkwireTheme.sidebar).tint(SilkwireTheme.accent)
        .onAppear { if ProcessInfo.processInfo.environment["SILKWIRE_ACCEPTANCE"]?.hasPrefix("design") != true { store.refreshConnections() } }
        .onDisappear { setup.cancel() }
    }
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(stateName(seat.state), systemImage: seat.state == "connected" ? "checkmark.circle.fill" : seat.state == "connecting" ? "arrow.triangle.2.circlepath" : "exclamationmark.circle")
                    .foregroundStyle(seat.state == "connected" ? Color.green : Color.orange).font(.headline)
                Spacer()
                if seat.state == "connecting" {
                    Button("Cancel team connection") { store.disconnect() }.disabled(store.busy)
                        .help("Stops the pending room connection. No account is signed out and no message is resent.")
                } else if seat.state == "connected" {
                    Button("Disconnect") { store.disconnectAgent(selected) }.disabled(unavailable)
                } else if seat.state == "needsStop" {
                    Button("Stop previous reply") { store.stopPrevious(selected) }.buttonStyle(.borderedProminent).disabled(unavailable)
                } else {
                    Button("Connect \(names[selected]!)") { store.recoverAgent(selected) }
                        .buttonStyle(.borderedProminent).disabled(unavailable || !store.participants.contains(selected) || !installed)
                    if store.conversation.identities[selected] != nil {
                        Button("Stop previous reply") { store.stopPrevious(selected) }.disabled(unavailable)
                            .help("Checks and stops only a previous reply owned by this saved session; never resends your message.")
                    }
                }
            }
            Text(seat.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if !store.participants.contains(selected) { Text("Add \(names[selected]!) to this Project in Project settings before connecting.").font(.caption).foregroundStyle(.orange) }
            Divider()
            if selected == "eve" {
                Text("Eve · OpenClaw").fontWeight(.semibold)
                Text("Uses your local OpenClaw Gateway and its existing account setup. There is no separate provider login for Eve here. Start or configure OpenClaw, then Connect Eve. Existing Gateway permissions are unchanged.").font(.callout).foregroundStyle(.secondary)
                Link("OpenClaw setup guide ↗", destination: URL(string: "https://docs.openclaw.ai/start/getting-started")!).font(.callout)
            } else {
                Text(selected == "codex" ? "Codex · OpenAI / ChatGPT" : "Claude · Anthropic").fontWeight(.semibold)
                if !installed {
                    Text(selected == "codex" ? "Install the official Codex CLI first. Silkwire does not download or install tools automatically." : "Install the official Claude Code CLI first. Silkwire does not download or install tools automatically.").font(.callout).foregroundStyle(.secondary)
                    Link("Official installation guide ↗", destination: URL(string: selected == "codex" ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!).font(.callout)
                } else {
                    Text(detail?.signedIn == true ? "Your existing subscription sign-in is available. Connect above to check the saved conversation session." : "Use your existing subscription. Sign in with the provider in your browser, then Silkwire checks the account and saved session. No API-account fallback.").font(.callout).foregroundStyle(.secondary)
                    if detail?.signedIn != true {
                        Button(selected == "codex" ? "Sign in with ChatGPT…" : "Sign in with Claude…") {
                            let agent = selected
                            setup.signIn(agent) {
                                store.refreshConnections()
                                if store.seats[agent]?.state == "disconnected" { store.recoverAgent(agent) }
                            }
                        }.disabled(unavailable || store.environment.agentTest)
                    }
                }
            }
            Text("Silkwire never asks for your provider password or API key. Signing in does not send a chat message or replace a saved conversation.").font(.caption2).foregroundStyle(.secondary)
        }.padding(16).background(SilkwireTheme.wash(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
    private var projectFiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project files · \(store.activeProject?.name ?? "Current Project")").font(.headline)
            Text("Reading is shared across this Project’s agents. Editing and building are granted separately. Folder access is independent of provider sign-in.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.activeProject?.connectedFolders ?? []) { folder in
                HStack(alignment: .top) {
                    Image(systemName: "folder").foregroundStyle(SilkwireTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(folder.name).fontWeight(.medium)
                        Text(folder.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        if let issue = store.folderIssues[folder.id] { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        Text("Reading: " + store.accessDescription(folder, agent: selected)).font(.caption).foregroundStyle(.secondary)
                        Text(store.builderDescription(folder, agent: selected)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Verify access") { store.verifyAccess(folder, agent: selected) }.disabled(store.busy || store.connecting || !store.participants.contains(selected) || seat.state != "connected" || store.folderIssues[folder.id] != nil)
                }
            }
            if store.activeProject?.connectedFolders.isEmpty ?? true { Text("No folders connected. Add App Source, Project Notes or Design Assets in Project settings.").font(.caption).foregroundStyle(.secondary) }
            Text("Verify checks the native broker; an actual agent file request verifies its reader path. Builder runs only when explicitly started in an isolated workspace. No automatic merge, push or deployment.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var allConnectionsCard: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("All connections").font(.headline)
                    Spacer()
                    Text(FuelGauge.checkedLabel(store.connectionsCheckedAt, now: timeline.date)).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Sidebar shows", selection: $gaugeMode) {
                    Text("Lowest remaining per provider").tag(FuelGauge.Mode.auto.rawValue)
                    Text("Every meter").tag(FuelGauge.Mode.all.rawValue)
                }.pickerStyle(.menu).fixedSize()
                Text("“Show in sidebar” pins one meter for a provider in place of its lowest one.").font(.caption2).foregroundStyle(.secondary)
                ForEach(agents, id: \.self) { agent in providerUsage(agent, now: timeline.date) }
                Text("Missing usage is Not reported, not unlimited. Readings refresh on their own every 30 minutes while Silkwire is idle, and turn grey if over an hour old.").font(.caption2).foregroundStyle(.secondary)
            }.padding(16).background(SilkwireTheme.wash(0.025), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func providerUsage(_ agent: String, now: Date) -> some View {
        let detail = store.connectionDetails.first { $0.agent == agent }
        let pins = FuelGauge.decodePins(gaugePins)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                InitialCircle(name: names[agent] ?? agent, size: 20)
                Text("\(names[agent] ?? agent) · \(providerNames[agent] ?? "")").fontWeight(.medium)
                Spacer()
                Text(stateName(store.seats[agent]?.state ?? "disconnected")).font(.caption2).foregroundStyle(.secondary)
            }
            if let detail, !detail.usage.isEmpty {
                ForEach(Array(detail.usage.enumerated()), id: \.offset) { _, window in
                    let presentation = AllowancePresentation(window: window, checkedAt: detail.checkedAt, now: now)
                    let pinned = pins[agent] == window.label
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(window.label)
                            Spacer()
                            Text(presentation.label)
                            Button(pinned ? "In sidebar ✓" : "Show in sidebar") { togglePin(agent, window.label) }
                                .buttonStyle(.borderless).font(.caption2).disabled(presentation.percent == nil && !pinned)
                        }.font(.caption)
                        if let percent = presentation.percent { ProgressView(value: percent, total: 100).tint(presentation.color) }
                        else { Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3) }
                        if let reset = window.resetsAt, reset.isFinite { Text("Resets \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            } else {
                Text(detail == nil ? (store.connectionsLoading ? "Checking…" : "Not checked yet") : "Usage: Not reported").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).background(SilkwireTheme.wash(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
    private func togglePin(_ agent: String, _ label: String) {
        var pins = FuelGauge.decodePins(gaugePins)
        pins[agent] = pins[agent] == label ? nil : label
        gaugePins = FuelGauge.encodePins(pins)
    }
    private func stateName(_ state: String) -> String {
        switch state { case "connected": return "Connected"; case "connecting": return "Connecting…"; case "needsStop": return "Previous reply needs attention"; default: return "Not connected" }
    }
}
