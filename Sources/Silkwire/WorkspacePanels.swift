import SwiftUI

struct ProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var project: Project
    @State private var conversationName = ""
    var isNew: Bool
    @ObservedObject var store: ConversationStore
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            HStack { ProjectIcon(project: project, size: 32); Text(isNew ? "Create Project" : "Project Settings").font(.title2.weight(.semibold)); Spacer() }
            VStack(alignment: .leading, spacing: 8) { Text("Project name").font(.headline); TextField("Project name", text: $project.name).textFieldStyle(.roundedBorder).accessibilityLabel("Project name") }
            if isNew { VStack(alignment: .leading, spacing: 8) { Text("First conversation").font(.headline); TextField("Conversation name", text: $conversationName).textFieldStyle(.roundedBorder) } }
            HStack(spacing: 24) {
                Picker("Icon", selection: $project.icon) {
                    Text("Spider").tag("spider"); Text("Rocket").tag("rocket"); Text("Planet").tag("planet"); Text("Folder").tag("folder"); Text("Star").tag("star")
                }
                Picker("Color", selection: $project.color) { Text("Violet").tag("violet"); Text("Mint").tag("mint"); Text("Peach").tag("peach"); Text("Blue").tag("blue"); Text("Silver").tag("silver") }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Participants").font(.headline)
                Text("Jason is always here. Choose who can receive new messages in this Project.").font(.callout).foregroundStyle(.secondary)
                ForEach(agents, id: \.self) { agent in
                    Toggle(isOn: Binding(get: { project.participants.contains(agent) }, set: { enabled in
                        if enabled { project.participants = agents.filter { $0 == agent || project.participants.contains($0) } }
                        else { project.participants.removeAll { $0 == agent } }
                    })) { HStack { InitialCircle(name: names[agent]!); Text(names[agent]!).foregroundStyle(SilkwireTheme.identity(names[agent]!)) } }.toggleStyle(.checkbox)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker("Reply order", selection: Binding(get: { project.replyOrder ?? "rotating" }, set: { project.replyOrder = $0 })) {
                    ForEach(ReplyOrdering.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Text("Rotating changes the first speaker each turn. Random shuffles once per turn; order stays fixed while replies run.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Trusted Staging: let the team edit, build and test", isOn: Binding(get: { store.trustsStaging(project) }, set: { project.trustedStaging = $0 })).toggleStyle(.checkbox)
                Text("Allow this Project’s teammates to read, edit, build, test and copy Staging data for diagnostics in private workspaces. This choice is remembered across rooms and restarts. Installation, original libraries, account changes, pushes and publishing need separate approval.").font(.caption).foregroundStyle(.secondary)
                if !isNew, let saved = store.projects.first(where: { $0.id == project.id }), store.trustsStaging(saved) {
                    Button("Revoke standing access now") {
                        project.trustedStaging = false
                        Task { await store.revokeStagingAccess(project.id) }
                    }.help("Stops active and queued Staging work immediately, then saves the revocation.")
                }
                if store.environment.staging { Button("Recover exact installed Staging source") { Task { await store.useInstalledStagingSource() } }.disabled(!store.canChangeConversation) }
                HStack { Text("Project folders").font(.headline); Spacer(); Button("Add folder…") { chooseFolder() }.disabled(project.connectedFolders.count >= 8) }
                Text("A folder grant includes its subfolders. Choose your entire Projects folder once to cover all your projects, or another folder such as Documents or an external drive. Grants are remembered for this Project’s team.").font(.caption).foregroundStyle(.secondary)
                ForEach(project.connectedFolders) { folder in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Folder name", text: Binding(get: { project.connectedFolders.first { $0.id == folder.id }?.name ?? "" }, set: { value in editFolder(folder.id) { $0.name = limitedUTF16(value, to: 80) } })).textFieldStyle(.roundedBorder)
                            Button("Remove") { project.folders = project.connectedFolders.filter { $0.id != folder.id }; project.folderPath = nil; project.folderBookmark = nil }
                        }
                        Toggle("Allow private editing, builds, tests and Git bundle imports", isOn: Binding(get: { project.connectedFolders.first { $0.id == folder.id }?.builderAllowed == true }, set: { enabled in editFolder(folder.id) { $0.builderAllowed = enabled } })).toggleStyle(.checkbox).font(.caption)
                            .disabled(!store.environment.permitsReading(URL(fileURLWithPath: folder.path)))
                        if !store.environment.permitsReading(URL(fileURLWithPath: folder.path)) { Text("This folder is unavailable or protected. Choose an ordinary Project folder.").font(.caption2).foregroundStyle(.secondary) }
                        Text(folder.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("All Project agents can read allowed files.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).background(SilkwireTheme.wash(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                if project.connectedFolders.isEmpty { Text("No folders connected. Provider sign-in does not grant file access.").font(.caption).foregroundStyle(.secondary) }
                Text("Reference reads exclude hidden files, secrets, dependencies, build output, links and binaries. Trusted Staging adds private editing/build/test workspaces and local Git bundle imports from folders you enable. Originals stay unchanged. Removing a grant stops future operations, not content already supplied.").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Project brief").font(.headline)
                Text("Approved direction, current task, open questions. Saved here and supplied to each selected agent on every turn, separate from recent history.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { project.brief ?? "" }, set: { project.brief = limitedUTF16($0, to: 2000) })).font(.callout).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SilkwireTheme.wash(0.15)))
                Text("\(project.brief?.utf16.count ?? 0) / 2,000 characters").font(.caption2).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(isNew ? "Create Project" : "Save") {
                project.name = String(project.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                let saved = isNew ? store.createProject(project, conversationTitle: String(conversationName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))) : store.updateProject(project)
                if saved { dismiss() }
            }.buttonStyle(.borderedProminent).disabled(!store.canChangeConversation || !validFolderGrant(project) || project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.participants.isEmpty || (isNew && conversationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)).keyboardShortcut(.defaultAction) }
        }.padding(28) }.frame(width: 610, height: min(isNew ? 860 : 820, (NSScreen.main?.visibleFrame.height ?? 900) - 100)).tint(SilkwireTheme.accent)
    }
    private func editFolder(_ id: UUID, _ change: (inout ProjectFolder) -> Void) {
        var folders = project.connectedFolders
        if let i = folders.firstIndex(where: { $0.id == id }) { change(&folders[i]) }
        project.folders = folders; project.folderPath = nil; project.folderBookmark = nil
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Share a Project folder read-only"; panel.prompt = "Choose folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if store.environment.staging { panel.directoryURL = store.environment.projectsRoot }
        panel.message = "Choose a named read-only root. All agents in this Project share read-only access. No editing or access above/beside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path != "/" else { store.status = "Choose a specific Project folder, not the whole disk."; return }
        guard store.environment.permitsReading(canonical) else { store.status = "That folder is protected or unavailable. Choose a specific ordinary folder for this Project."; return }
        do {
            let bookmark = try canonical.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            guard !project.connectedFolders.contains(where: { $0.path == canonical.path }) else { store.status = "That folder is already connected."; return }
            var folders = project.connectedFolders
            let suggested = folders.isEmpty ? "App Source" : folders.count == 1 ? "Project Notes" : folders.count == 2 ? "Design Assets" : canonical.lastPathComponent
            folders.append(ProjectFolder(name: suggested, path: canonical.path, bookmark: bookmark))
            project.folders = folders; project.folderPath = nil; project.folderBookmark = nil
        } catch { store.status = "Could not retain this folder’s read-only grant. \(error.localizedDescription)" }
    }

}
struct NativeSettingsView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var notifications: CompletionNotifications
    var body: some View {
        UnifiedSettingsView(store: store, notifications: notifications)
    }
}
struct NativeHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { SilkwireSpider().fill(SilkwireTheme.accent).frame(width: 34, height: 34); Text("Silkwire Help").font(.title2.weight(.semibold)); Spacer() }
            Text("Projects keep related conversations and participants together. Each conversation keeps its own history, draft and agent sessions.")
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 10) {
                row("⌘N", "New conversation in the current Project")
                row("⌘F", "Find in the current conversation")
                row("⌃⌘S", "Hide or show the sidebar")
                row("⌘,", "Settings")
                row("⌘↩", "Send")
                row("Esc", "Stop the active reply and remaining queue")
            }
            Divider()
            Text("Connection recovery").font(.headline)
            Text("Use the ··· menu beside an agent in the sidebar to connect, disconnect or stop a previous reply. Connect checks the saved session without resending your message or restarting healthy teammates.")
            Text("Connections in the sidebar shows account and provider details. History and drafts stay saved when a connection closes; nothing replays automatically.").font(.callout).foregroundStyle(.secondary)
            Text("Search opens beside the conversation title with ⌘F. Conversation options beside Builder contains auto-scroll; Resume appears when following is paused. The ⓘ beside Saved on this Mac opens per-agent history counts and shared-folder details inside the conversation.").font(.callout).foregroundStyle(.secondary)
            Text("One conversation works at a time. Finish or Stop its reply before switching. Export saves the selected conversation as Markdown.").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 520)
    }
    private func row(_ key: String, _ description: String) -> some View { GridRow { Text(key).font(.system(.body, design: .monospaced)).foregroundStyle(SilkwireTheme.accent); Text(description) } }
}

struct ConversationNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool
    var create: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New conversation").font(.title2.weight(.semibold))
            TextField("Conversation name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 420).tint(SilkwireTheme.accent).onAppear { focused = true }
    }
}

struct BuilderView: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var folderID: UUID?
    @State private var task = ""
    @State private var build = ""
    @State private var test = ""
    @State private var edit = true
    private var sources: [ProjectFolder] { (store.activeProject?.connectedFolders ?? []).filter { $0.builderAllowed == true } }
    private var source: ProjectFolder? { sources.first { $0.id == folderID } ?? sources.first }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Builder · Codex").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("A concrete task, an isolated workspace, and evidence returned to this conversation. You approve integration after reviewing the diff; nothing merges, pushes or deploys automatically.").font(.callout).foregroundStyle(.secondary)
            if sources.isEmpty { Text("Enable Codex Builder editing & execution for an App Source folder in Project settings first. Reading remains shared with the Project team.").foregroundStyle(.orange) }
            else {
                Picker("App Source", selection: Binding(get: { source?.id ?? UUID() }, set: { folderID = $0 })) { ForEach(sources) { folder in Text(folder.name).tag(folder.id) } }
                if let source { Text(source.path).font(.caption).textSelection(.enabled) }
                Text("Task").font(.headline)
                TextEditor(text: Binding(get: { task }, set: { task = limitedUTF16($0, to: 24000) })).font(.callout).frame(height: 100).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SilkwireTheme.wash(0.16)))
                Toggle("Let Codex edit in the isolated workspace", isOn: $edit).toggleStyle(.checkbox)
                TextField("Exact build command", text: $build).textFieldStyle(.roundedBorder)
                TextField("Exact test command", text: $test).textFieldStyle(.roundedBorder)
                Text("Start authorizes this task and these local commands in a private copy of committed source. A clean Git source is required. Network and writes outside the run are blocked; no installs or deployment. Provide at least one build or test command; a blank step is not run.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if store.builderRunning { ProgressView().controlSize(.small); Button("Stop Builder") { store.stopBuilder() }.tint(.red) }
                    else { Button("Start isolated build") { if let source { store.startBuilder(folder: source, task: task, build: build, test: test, edit: edit) } }.buttonStyle(.borderedProminent).disabled(!store.canChangeConversation || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && test.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || build.utf16.count > 4000 || test.utf16.count > 4000) }
                    Spacer(); Text(store.builderStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !store.builderWorktree.isEmpty { HStack { Text(store.builderWorktree).font(.caption2).textSelection(.enabled); Spacer(); Button("Show workspace") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.builderWorktree) } } }
            if !store.builderOutput.isEmpty { Divider(); Text(store.builderOutput).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(24) }.frame(width: 760, height: min(820, (NSScreen.main?.visibleFrame.height ?? 950) - 100)).tint(SilkwireTheme.accent)
        .onAppear { task = limitedUTF16(store.builderTaskDraft.isEmpty ? store.conversation.draft : store.builderTaskDraft, to: 24000) }
    }
}

