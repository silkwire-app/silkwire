import SwiftUI

/// Navigation only: selecting a tab never connects a provider or changes a grant.
enum AppSettingsSection: String, CaseIterable, Identifiable {
    case aboutYou, general, appearance, agents, projects, memory, development
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aboutYou: return "About You"
        case .general: return "General"
        case .appearance: return "Appearance"
        case .agents: return "Agents"
        case .projects: return "Projects"
        case .memory: return "Memory"
        case .development: return "Development"
        }
    }
    var symbol: String {
        switch self {
        case .aboutYou: return "person.crop.circle"
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .agents: return "person.2"
        case .projects: return "folder"
        case .memory: return "bookmark"
        case .development: return "hammer"
        }
    }
}

struct UnifiedSettingsView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var notifications: CompletionNotifications
    @AppStorage("composer.sidePanel") private var sideComposer = false
    @AppStorage("composer.sideHeight") private var sideHeight = 420.0
    @AppStorage(BuilderReceiptLine.cardsKey) private var builderReceiptCards = false
    @AppStorage(ThemeChoice.storageKey) private var themeRaw = ThemeChoice.midnight.rawValue
    @State private var selected: AppSettingsSection = .general
    @State private var showConnections = false
    @State private var editingProject: Project?

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.storageError {
                Text("Settings changes are unavailable while local storage needs attention. \(error)")
                    .font(.callout).foregroundStyle(.orange).padding()
            }
            TabView(selection: $selected) {
                ForEach(AppSettingsSection.allCases) { section in
                    Form { content(section) }
                        .formStyle(.grouped)
                        .tabItem { Label(section.title, systemImage: section.symbol) }
                        .tag(section)
                        .accessibilityIdentifier("settings.\(section.rawValue)")
                }
            }
        }
        .frame(width: 640, height: min(680, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
        .tint(SilkwireTheme.accent)
        .onAppear { notifications.refresh() }
        .sheet(isPresented: $showConnections) { ConnectionsView(store: store) }
        .sheet(item: $editingProject) { project in ProjectEditor(project: project, isNew: false, store: store) }
    }

    @ViewBuilder private func content(_ section: AppSettingsSection) -> some View {
        switch section {
        case .aboutYou: AboutYouSettingsView(projects: store.projects.map { (id: $0.id, name: $0.name) })
        case .general: general
        case .appearance: appearance
        case .agents: agentSettings
        case .projects: projectSettings
        case .memory:
            TeamMemorySettingsView(store: store)
            MemorySettingsView()
        case .development: development
        }
    }

    private var general: some View {
        Group {
            Section("Completion") {
                Toggle("Play a chime when the team finishes", isOn: Binding(get: { store.preferences.completionChime }, set: { store.setChime($0) }))
                Text("One chime for a completed turn. Reopening history, reconnecting and Stop do not play completion sounds.").font(.caption).foregroundStyle(.secondary)
                Button("Enable background alerts…") { notifications.enableBackgroundAlerts() }
                Text(notifications.permission).font(.caption).foregroundStyle(.secondary)
            }
            Section("Composer") {
                Toggle("Tall side composer", isOn: $sideComposer)
                Slider(value: $sideHeight, in: 240...700, step: 20) { Text("Writing height") }
                Text("A higher writing panel beside the conversation. Drag the divider to adjust width. Narrow windows use the bottom layout.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Conversation") {
                Toggle("Auto-scroll replies by default", isOn: Binding(get: { store.preferences.autoScrollReplies }, set: { store.setAutoScroll($0) }))
                Text("Scrolling upward temporarily pauses following without changing this saved preference.").font(.caption).foregroundStyle(.secondary)
                Toggle("Text completion and predictive suggestions", isOn: Binding(get: { store.preferences.textCompletion }, set: { store.setTextCompletion($0) }))
                Toggle("Correct spelling automatically", isOn: Binding(get: { store.preferences.automaticCorrection }, set: { store.setAutomaticCorrection($0) }))
                Text("Suggestions use macOS language and keyboard support. Automatic correction is separate so code and agent names stay under your control.").font(.caption).foregroundStyle(.secondary)
            }
            Section("On this Mac") {
                Text("Conversations, drafts, Project organization and preferences are saved locally.")
                Text("Local storage is separate from the excerpts supplied to a connected provider when you send a message.").font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(store.storageError != nil)
    }

    private var appearance: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(get: { ThemeChoice.decode(themeRaw) }, set: { themeRaw = $0.rawValue })) {
                ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text("Midnight is the classic dark look. Parchment is warm paper with dark ink. Match System follows your Mac’s light or dark setting.").font(.caption).foregroundStyle(.secondary)
            Toggle("Reduce motion", isOn: Binding(get: { store.preferences.reduceMotion }, set: { store.setReduceMotion($0) }))
            Text("Your Mac’s Reduce Motion setting is always respected. Identity colors stay fixed; status is shown separately.").font(.caption).foregroundStyle(.secondary)
        }.disabled(store.storageError != nil)
    }

    private var agentSettings: some View {
        Group {
            Section("Agent connections") {
                Text("Manage your existing Codex, Claude and OpenClaw connections using the same Connections panel available from the room.")
                Button("Open Connections…") { showConnections = true }
                    .disabled(store.storageError != nil)
                Text("Opening this panel checks connection details. It does not send a chat message. Signing in remains a separate action, and does not grant file access.").font(.caption).foregroundStyle(.secondary)
            }
            // Staging only: computer control switches, ask-first list, tasks and audit log.
            if let center = store.computer { ComputerSettingsView(center: center) }
        }
    }

    private var projectSettings: some View {
        Section("Current Project") {
            if let project = store.activeProject {
                Text(project.name).font(.headline)
                Text("Manage participants, reply order, the Project brief and named folder grants in the existing Project editor.")
                Button("Edit Project…") { editingProject = project }
                    .disabled(!store.canChangeConversation || store.storageError != nil)
                if !store.canChangeConversation {
                    Text("Finish or stop the current reply before editing this Project.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Create or select a Project in the room to manage its settings.")
            }
            Text("App Settings does not replace or reset any Project grants. Memory access will be a separate connection, not an expansion of source-folder permissions.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var development: some View {
        Group {
            Section("Development preview") {
                Text("No automatic updates or cloud history sync.")
                Text("Private builds, review and installation are separate steps. Opening Settings does not start work, install an app or change provider sign-ins.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Developer") {
                Toggle("Show Builder receipt cards in conversations", isOn: $builderReceiptCards)
                Text("Off: each build shows as one quiet line, such as “Claude finished a build · Ready for review”. Click it for the full receipt.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Build and source") { RevisionStatusView(store: store) }
        }
    }
}

/// An honest availability screen, not a permission or vault-connection implementation.
/// Do not add a working picker until the native memory broker enforces its scope.
struct MemorySettingsView: View {
    var body: some View {
        Section("Selective Recall") {
            Label("Local Obsidian connection — not available yet", systemImage: "info.circle")
                .font(.headline)
            Text("This Settings foundation does not link, search or write an Obsidian vault. Existing Project folder grants are unchanged.")
            Text("The first connection will use a Mac folder picker and a dedicated Silkwire collection, rather than treating a pasted link as permission.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section("Planned access choices") {
            Label("Read selected notes", systemImage: "doc.text.magnifyingglass")
            Label("Save curated memories", systemImage: "square.and.pencil")
            Label("Supply relevant excerpts to selected agents", systemImage: "person.2")
            Text("These are planned choices, not enabled permissions. Local storage does not mean the model runs locally. A folder may also sync through Obsidian or another service.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Worth remembering") {
            Text("Shared and teammate collections, with ordinary Markdown notes: what we kept, why it matters, contributors, source links and useful pictures. Not automatic daily diaries or transcript hoarding.")
            Text("Recall should show its sources and let you correct, exclude or delete notes. Remembered content is context, never an instruction or a new grant.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
