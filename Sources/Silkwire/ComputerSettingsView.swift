import AppKit
import SwiftUI

/// Settings → Computer (Staging only): who may drive, Jason's ask-first list,
/// macOS permissions, durable tasks and the audit log.
struct ComputerSettingsView: View {
    @ObservedObject var center: ComputerControlCenter
    @State private var newTitle = ""
    @State private var newPhrases = ""
    @State private var newFolder = ""
    @State private var agentFilter = "all"
    @State private var permissionsChecked = Date()
    @State private var preview: ComputerAuditEntry?
    @State private var showPublicKey = false

    var body: some View {
        Group {
            Section("Computer control · Staging") {
                Text("Teammates can see the screen, click, type, open apps, read UI elements and run commands as you, with real network and full disk access. They drive only after you've been idle, and any real mouse or keyboard input from you pauses them at once.").font(.callout)
                ForEach(agents, id: \.self) { agent in
                    Toggle("\(names[agent] ?? agent) may control this Mac", isOn: Binding(get: { center.settings.enabled(agent) }, set: { value in center.update { $0.enabledAgents[agent] = value } }))
                }
                Stepper(value: Binding(get: { center.settings.idleSeconds }, set: { value in center.update { $0.idleSeconds = value } }), in: 5...300, step: 5) {
                    Text("Wait until I've been idle \(Int(center.settings.idleSeconds)) seconds")
                }
                Text("“Let them drive” on the banner skips the wait until your next input. Builder's private-workspace lane for review builds is unchanged.").font(.caption).foregroundStyle(.secondary)
            }
            Section("macOS permissions") {
                let _ = permissionsChecked
                permissionRow("Accessibility (pointer, keyboard, UI elements)", granted: NativeComputerDriver.accessibilityGranted, pane: "Privacy_Accessibility")
                permissionRow("Screen Recording (screenshots)", granted: NativeComputerDriver.screenRecordingGranted, pane: "Privacy_ScreenCapture")
                HStack {
                    Button("Request access…") { NativeComputerDriver.requestPermissions(); permissionsChecked = Date() }
                    Button("Check again") { permissionsChecked = Date() }
                }
                Text(center.driver.backendName).font(.caption).foregroundStyle(.secondary)
                Text("macOS ties these grants to this exact build. After installing a new Staging build, grant them again if the rows show Off.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Connections") {
                Text("What the agents can reach through the shell. Secrets are used but never shown here or in the audit log.").font(.caption).foregroundStyle(.secondary)
                Toggle("GitHub (Jason's existing sign-in)", isOn: Binding(get: { center.connectionConnected(AskFirstPolicy.github) }, set: { center.setConnection(AskFirstPolicy.github, connected: $0) }))
                Text("On: clone, branch, commit, push to their own branch and open PRs freely; merging to main, force-pushing and deleting branches ask first. Off: push/pull/fetch/clone/gh are refused; local Git still works.").font(.caption).foregroundStyle(.secondary)
                Toggle("Server (Hostinger VPS)", isOn: Binding(get: { center.connectionConnected(AskFirstPolicy.server) }, set: { center.setConnection(AskFirstPolicy.server, connected: $0) }))
                if center.connectionConnected(AskFirstPolicy.server) {
                    if let key = center.agentKey {
                        Text("Agent key: \(key.fingerprint)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button(showPublicKey ? "Hide setup steps" : "Show public key and setup steps") { showPublicKey.toggle() }
                            Button("Copy public key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.publicKey, forType: .string) }
                            Button("Disconnect") { center.deleteAgentKey() }.tint(.red)
                        }
                        if showPublicKey {
                            Text(AgentConnections.setupSteps(key)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .padding(8).background(SilkwireTheme.wash(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                        Text("Read logs, status and files freely. Deploys, service restarts, config changes and databases ask first. This key is separate from your personal keys.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No dedicated agent key yet. Create one, then add its public key to the VPS yourself; Silkwire never changes the server.").font(.caption).foregroundStyle(.secondary)
                        Button("Create agent SSH key") { center.createAgentKey() }
                    }
                } else {
                    Text("Off: ssh, scp and rsync to a server are refused.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Ask me first") {
                Text("Agents ask before these. Everything else proceeds and is recorded in the audit log.").font(.caption).foregroundStyle(.secondary)
                ForEach(center.settings.rules) { rule in
                    HStack {
                        Toggle(isOn: Binding(get: { rule.enabled }, set: { value in center.update { settings in if let i = settings.rules.firstIndex(where: { $0.id == rule.id }) { settings.rules[i].enabled = value } } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.title)
                                if !rule.phrases.isEmpty { Text("Matches: " + rule.phrases.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if !rule.builtIn {
                            Button { center.update { $0.rules.removeAll { $0.id == rule.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove this rule")
                        }
                    }
                }
                HStack {
                    TextField("New rule, e.g. Production deploys", text: $newTitle)
                    TextField("Phrases, comma-separated", text: $newPhrases)
                    Button("Add") {
                        let phrases = newPhrases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        center.update { $0.rules.append(AskFirstRule(id: "custom-" + UUID().uuidString.lowercased(), title: newTitle.trimmingCharacters(in: .whitespaces), phrases: phrases)) }
                        newTitle = ""; newPhrases = ""
                    }.disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || newPhrases.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Custom phrases match commands, app and window names, paths, web addresses and typed text, ignoring case.").font(.caption).foregroundStyle(.secondary)
                Text("Project folders (deleting inside these never asks)").font(.subheadline)
                ForEach(center.settings.projectFolders, id: \.self) { folder in
                    HStack { Text(folder).font(.system(.callout, design: .monospaced)); Spacer(); Button { center.update { $0.projectFolders.removeAll { $0 == folder } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless) }
                }
                HStack {
                    TextField("~/Projects or /absolute/path", text: $newFolder)
                    Button("Add folder") { center.update { $0.projectFolders.append(newFolder.trimmingCharacters(in: .whitespaces)) }; newFolder = "" }
                        .disabled(!(newFolder.hasPrefix("/") || newFolder.hasPrefix("~/")) || newFolder.trimmingCharacters(in: .whitespaces).count < 3)
                }
                Text("Each Project's granted folders count too. These checks recognize common commands and apps; they are not a sandbox, so review the audit log.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent tasks") {
                let shown = center.tasks.suffix(12).reversed()
                if shown.isEmpty { Text("No agent tasks yet.").foregroundStyle(.secondary) }
                ForEach(Array(shown)) { task in ComputerTaskRow(task: task, center: center) }
            }
            Section("Audit log") {
                Picker("Show", selection: $agentFilter) {
                    Text("Everyone").tag("all")
                    ForEach(agents, id: \.self) { Text(names[$0] ?? $0).tag($0) }
                }.pickerStyle(.segmented)
                let entries = center.recent.filter { agentFilter == "all" || $0.agent == agentFilter }.prefix(150)
                if entries.isEmpty { Text("No computer actions recorded yet.").foregroundStyle(.secondary) }
                ForEach(Array(entries)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.at.formatted(date: .abbreviated, time: .standard)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(names[entry.agent] ?? entry.agent) · \(entry.summary)").font(.callout).lineLimit(2).help(entry.command ?? entry.summary)
                            Text([entry.outcome, entry.rule, entry.target, entry.detail].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(entry.outcome == "denied" || entry.outcome == "failed" ? .orange : .secondary).lineLimit(2)
                            if let warning = entry.persistenceWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                            if let output = entry.fullOutput { Button("Show shell output") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)]) }.font(.caption) }
                        }
                        Spacer()
                        if entry.screenshot != nil { Button { preview = entry } label: { Image(systemName: "photo") }.buttonStyle(.borderless).help("Show the screenshot recorded with this action") }
                    }
                }
                Button("Show audit folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([center.auditDirectory]) }
                Text("Every action is recorded with its time, teammate, outcome and, for screen actions, a screenshot. Logs stay on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $preview) { entry in AuditScreenshotView(entry: entry, url: center.screenshotURL(entry)) }
    }
    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(granted ? .green : .orange)
            Text(title); Spacer(); Text(granted ? "On" : "Off").foregroundStyle(.secondary)
            if !granted { Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!) } }
        }
    }
}

private struct AuditScreenshotView: View {
    let entry: ComputerAuditEntry
    let url: URL?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(names[entry.agent] ?? entry.agent) · \(entry.summary)").font(.headline)
            Text(entry.at.formatted(date: .complete, time: .standard) + " · " + entry.outcome).font(.caption).foregroundStyle(.secondary)
            if let url, let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 900, maxHeight: 600) }
            else { Text("The screenshot file is missing.").foregroundStyle(.orange) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20)
    }
}

struct ComputerTaskRow: View {
    let task: AgentTask
    @ObservedObject var center: ComputerControlCenter
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(task.state == "running" ? Color.purple : task.state == "blocked" ? .orange : task.state == "done" ? .green : .secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(names[task.agent] ?? task.agent) · \(task.title)").font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed((task.finishedAt ?? context.date).timeIntervalSince(task.startedAt))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("· \(task.steps) steps").font(.caption).foregroundStyle(.secondary)
                }
                if !task.progress.isEmpty { Text(task.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if task.active { Button("Stop") { center.stopTask(task.id) }.tint(.red).help("Stop this task. Its teammate stops driving, and Silkwire won't continue it.") }
        }
    }
    private var label: String {
        if task.resumeAfterRestart && task.state == "running" { return "Resumes when its conversation reconnects" }
        if let agent = center.wheel.agent, agent == task.agent, task.state == "running" {
            switch center.wheel { case .driving: return "Driving"; case .waiting: return "Waiting to drive"; case .paused: return "Paused: you have the wheel"; case .none: break }
        }
        return ["running": "Working", "blocked": "Needs you", "done": "Done", "stopped": "Stopped"][task.state] ?? task.state
    }
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Above the composer: this conversation's running tasks, questions waiting for
/// Jason, and who has the wheel. Hidden when there is nothing to show.
struct ComputerTaskStrip: View {
    @ObservedObject var center: ComputerControlCenter
    let conversationID: String
    var body: some View {
        let tasks = center.tasks.filter { $0.conversationID == conversationID && $0.active }
        let approvals = center.pending.filter { $0.conversationID == conversationID }
        if !tasks.isEmpty || !approvals.isEmpty || center.wheel != .none {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(approvals) { approval in
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(names[approval.agent] ?? approval.agent) asks first: \(approval.summary)").font(.callout.weight(.medium)).lineLimit(2)
                            Text(approval.ruleTitle + " · " + approval.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if !approval.detail.isEmpty, approval.detail != approval.summary { Text(approval.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
                        }
                        Spacer(minLength: 4)
                        Button("Deny") { center.resolve(approval.id, allow: false) }
                        Button("Allow once") { center.resolve(approval.id, allow: true) }.buttonStyle(.borderedProminent).tint(.orange)
                    }
                }
                ForEach(tasks) { task in ComputerTaskRow(task: task, center: center) }
                if center.wheel != .none, tasks.isEmpty || !tasks.contains(where: { $0.agent == center.wheel.agent }) {
                    HStack {
                        Text(wheelText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if case .driving = center.wheel {} else { Button("Let them drive") { center.letThemDrive() }.controlSize(.small) }
                        Button("Stop") { center.stopDriving() }.controlSize(.small).tint(.red)
                    }
                }
            }
            .padding(10)
            .background(SilkwireTheme.wash(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SilkwireTheme.line))
        }
    }
    private var wheelText: String {
        switch center.wheel {
        case .driving(let agent): return "\(names[agent] ?? agent) is driving · move the mouse to take over"
        case .waiting(let agent, let remaining): return "\(names[agent] ?? agent) wants to drive · starts when you're idle \(remaining) s"
        case .paused(let agent, let remaining): return "You have the wheel · \(names[agent] ?? agent) resumes after \(remaining) s idle"
        case .none: return ""
        }
    }
}
