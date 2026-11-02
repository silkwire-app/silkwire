import SwiftUI
import AppKit

/// Jason's "Install in Staging": identify a candidate, back up, install, confirm the
/// installed version, and restore a matched recovery point with one click.
struct StagingInstallView: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.dismiss) private var dismiss
    struct Candidate: Identifiable {
        var id: String { identity.path }
        let identity: StagingInstaller.Identity
        let provenance: StagingInstaller.Provenance?
        /// The finished workspace's own summary, shown as "What's new".
        var whatsNew: String? = nil
    }
    @State private var installer = StagingInstaller()
    @State private var installed: StagingInstaller.Identity?
    @State private var candidates: [Candidate] = []
    @State private var backups: [StagingInstaller.Backup] = []
    @State private var selected: Candidate?
    @State private var working = false
    @State private var message = ""
    @State private var result: [String: Any]?
    @State private var showOlder = false
    @State private var loaded = false
    @State private var showAdvanced = false
    /// Set by Cancel while the install waits for running work; withdraws the request.
    @State private var cancelRequested = false
    @State private var waitingForLane = false
    /// Why an earlier install still holds the exclusive lane, from recovery.
    @State private var laneHeld = ""
    private var lane: StagingInstallLane { .application }
    private var versionLabels: [String: String] { StagingVersion.labels((installed.map { [$0] } ?? []) + candidates.map(\.identity) + backups.compactMap(\.identity)) }

    // One calm line first; the technical evidence lives under Advanced.
    @ViewBuilder private var headline: some View {
        if !loaded {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking for updates…").foregroundStyle(.secondary) }
        } else if store.environment.staging, let newest = candidates.first, newest.identity.manifestSHA256 != installed?.manifestSHA256 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Silkwire Staging \(StagingVersion.label(newest.identity, in: versionLabels)) is ready").font(.title3.weight(.semibold))
                if let notes = newest.whatsNew, !notes.isEmpty { Text("What's new: " + notes).font(.callout).foregroundStyle(.secondary).lineLimit(6).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button("Try This Build") { selected = newest; install(newest) }.buttonStyle(.borderedProminent)
                        .disabled(working || !newest.identity.signatureValid || !installer.isInstalledCopy(Bundle.main.bundleURL))
                    Button("Later") { dismiss() }
                }
            }
        } else if !store.environment.staging {
            Text("Choose a build under Advanced to install it.").font(.callout).foregroundStyle(.secondary)
        } else {
            Label("You're up to date" + (installed.map { " · " + StagingVersion.label($0, in: versionLabels) } ?? ""), systemImage: "checkmark.circle").font(.title3.weight(.semibold))
        }
        Text("Installs at /Applications/Silkwire Staging.app. Your current Staging app and library are backed up together before updating. Rollback keeps newer conversations separately, preserves computer-control history and pauses running agent tasks. Your working Silkwire and sign-ins stay unchanged.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let latest = backups.first(where: { $0.hasRecoveryPoint && $0.identity?.signatureValid == true && $0.identity?.manifestSHA256 != installed?.manifestSHA256 }) {
            Button("Roll Back to Previous Build") { recover(latest) }.disabled(working || store.environment.agentTest)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Silkwire Staging Updates").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            headline
            // Versions, fingerprints, older builds and backups: still here, one click away.
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) { VStack(alignment: .leading, spacing: 14) {
            GroupBox("Installed now") {
                if let installed {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Running " + StagingVersion.label(installed, in: versionLabels)).font(.headline)
                        if let built = StagingVersion.builtText(installed) { Text(built).font(.caption).foregroundStyle(.secondary) }
                        DisclosureGroup("Details") { identityRows(installed) }.font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else { Text(loaded ? "No Silkwire Staging app is installed at \(installer.target.path)." : "Checking…").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }
            GroupBox("Available updates") {
                VStack(alignment: .leading, spacing: 8) {
                    if candidates.isEmpty && loaded { Text("No built Staging app found in this conversation's private workspaces. A teammate can build one with swift Scripts/build.swift --staging, or choose a bundle.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(candidates.enumerated()).filter { showOlder || $0.offset < 3 }.map(\.element)) { candidate in
                        Button { selected = candidate } label: {
                            HStack {
                                Image(systemName: selected?.id == candidate.id ? "largecircle.fill.circle" : "circle")
                                Text(StagingVersion.label(candidate.identity, in: versionLabels)).font(.system(.body, design: .monospaced))
                                if candidate.id == candidates.first?.id { Text("Newest").font(.caption.weight(.semibold)).foregroundStyle(SilkwireTheme.stagingTint) }
                                if candidate.identity.manifestSHA256 == installed?.manifestSHA256 { Text("Installed").font(.caption).foregroundStyle(.secondary) }
                                Text(candidate.provenance.map { (names[$0.owner] ?? $0.owner) + (StagingVersion.builtText(candidate.identity).map { " · " + $0 } ?? "") } ?? URL(fileURLWithPath: candidate.identity.path).deletingLastPathComponent().lastPathComponent).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }.buttonStyle(.plain)
                    }
                    if candidates.count > 3 { Button(showOlder ? "Hide older builds" : "Older builds (\(candidates.count - 3))") { showOlder.toggle() }.buttonStyle(.borderless).font(.caption) }
                    HStack { Button("Choose app…") { choose() }; Button("Refresh") { refresh() }; Spacer() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let selected {
                GroupBox("Selected candidate") {
                    VStack(alignment: .leading, spacing: 6) {
                        identityRows(selected.identity)
                        if let provenance = selected.provenance {
                            Text("Workspace \(provenance.receiptID) · \(names[provenance.owner] ?? provenance.owner) · \(provenance.status)" + (provenance.headCommit.map { " · head \($0.prefix(12))" } ?? "")).font(.caption)
                            Label(provenance.detail, systemImage: provenance.builtFromHead == true ? "checkmark.seal" : "exclamationmark.triangle").font(.caption).foregroundStyle(provenance.builtFromHead == true ? Color.secondary : Color.orange)
                        }
                        if !selected.identity.signatureValid { Label("Code signature does not verify; it cannot be installed.", systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption) }
                        Button("Try This Build") { install(selected) }.buttonStyle(.borderedProminent).disabled(working || store.environment.agentTest || !selected.identity.signatureValid || (store.environment.staging && !installer.isInstalledCopy(Bundle.main.bundleURL)))
                        if store.environment.staging && !installer.isInstalledCopy(Bundle.main.bundleURL) { Text("This Staging app isn't the copy in your Applications folder, so it can't update itself.").font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            if !backups.isEmpty {
                GroupBox("Backups") {
                    ScrollView { VStack(alignment: .leading, spacing: 6) {
                        ForEach(backups) { backup in
                            HStack {
                                Text(backup.identity?.shortRevision ?? "unreadable").font(.system(.caption, design: .monospaced))
                                Text(backup.path.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(backup.hasRecoveryPoint ? "Roll Back" : "Restore App Only") { recover(backup) }.disabled(working || backup.identity == nil || store.environment.agentTest)
                            }
                        }
                    } }.frame(maxHeight: 120)
                }
            }
            } }
            if working && loaded { HStack { ProgressView().controlSize(.small); if waitingForLane { Button("Cancel") { cancelRequested = true } } } }
            if loaded, !working, installer.hasInterruptedOperation { Text("An earlier Staging install or rollback was interrupted. The next install or rollback first puts back the app (and library) that were in place before it.").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if loaded, !working, !laneHeld.isEmpty { Text(laneHeld).font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled).foregroundStyle(result == nil ? Color.orange : Color.primary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(22).frame(width: 640)
        .onAppear { refresh() }
    }
    @ViewBuilder private func identityRows(_ identity: StagingInstaller.Identity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Revision \(identity.revision)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Source \(identity.sourceStatus)" + (identity.sourceDigest.isEmpty ? "" : " · digest \(identity.sourceDigest.prefix(16))…")).font(.caption)
            Text("Executable SHA-256 \(identity.executableSHA256.prefix(16))… · \(identity.fileCount) files · signature \(identity.signatureValid ? "verified" : "INVALID")").font(.caption).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func refresh() {
        let storage = store.workspaceStorage.appendingPathComponent(store.conversation.id.uuidString.lowercased())
        let installer = installer
        working = true
        Task { @MainActor in
            let held = await lane.recoverInterrupted().compactMap { if case .retained(_, let reason) = $0 { return reason }; return nil }
            laneHeld = held.isEmpty ? "" : "An earlier Staging install still holds the exclusive lane, so new work waits. " + held.joined(separator: " ")
            if !held.isEmpty { lane.keepRecovering() }
        }
        Task.detached(priority: .userInitiated) {
            let current = installer.installed(), backups = installer.listBackups()
            var found: [Candidate] = []
            for agent in agents {
                let folder = storage.appendingPathComponent(agent)
                for run in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                    let app = run.appendingPathComponent("worktree/output/staging/Silkwire Staging.app")
                    guard FileManager.default.fileExists(atPath: app.path), let identity = try? StagingInstaller.identify(app) else { continue }
                    let receipt = NativeTrustedWorkspaces.savedReceipt(storage: storage, id: run.lastPathComponent)?.receipt
                    var candidate = Candidate(identity: identity, provenance: receipt.map { StagingInstaller.provenance(of: identity, receipt: $0, worktree: run.appendingPathComponent("worktree")) })
                    candidate.whatsNew = ((receipt?["agentSummary"] ?? receipt?["summary"]) as? String).map { String($0.prefix(600)) }
                    found.append(candidate)
                }
            }
            func builtAt(_ candidate: Candidate) -> Date { ((try? FileManager.default.attributesOfItem(atPath: candidate.identity.path))?[.modificationDate] as? Date) ?? .distantPast }
            let discovered = found.sorted { builtAt($0) > builtAt($1) }
            await MainActor.run {
                installed = current; self.backups = backups; candidates = discovered; working = false; loaded = true
                if let chosen = selected, !discovered.contains(where: { $0.id == chosen.id }), chosen.provenance != nil { selected = nil }
                if selected == nil, let newest = discovered.first, newest.identity.revision != current?.revision { selected = newest }
            }
        }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowedContentTypes = [.applicationBundle]; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let candidate = Candidate(identity: try StagingInstaller.identify(url), provenance: nil); candidates.append(candidate); selected = candidate; message = ""; result = nil }
        catch { message = error.localizedDescription; result = nil }
    }
    private func install(_ candidate: Candidate) {
        guard !store.environment.agentTest else { return }
        if store.environment.staging { handOff(action: "install", app: URL(fileURLWithPath: candidate.identity.path), identity: candidate.identity); return }
        let installer = installer
        working = true; message = "Backing up and installing…"; result = nil
        Task { @MainActor in
            do {
                let source = URL(fileURLWithPath: candidate.identity.path)
                let receipt = try await runExclusive(.install) { try installer.install(candidate: source, reviewed: candidate.identity) }
                let confirmed = receipt["installed"] as? [String: Any]
                result = receipt; working = false
                message = "Installed and verified revision \(confirmed?["revision"] as? String ?? "?") (executable SHA-256 \((confirmed?["executableSHA256"] as? String ?? "").prefix(16))…, matches the candidate). Previous app kept at \(receipt["backup"] as? String ?? "— (none was installed)"). Receipt: \(receipt["receiptPath"] as? String ?? "")"
                refresh()
            } catch { working = false; result = nil; message = StagingInstallLane.describe(error); refresh() }
        }
    }
    private func recover(_ backup: StagingInstaller.Backup) {
        guard let identity = backup.identity else { return }
        guard !store.environment.agentTest else { return }
        if store.environment.staging { handOff(action: "restore", app: backup.path, identity: identity); return }
        let installer = installer
        working = true; message = "Restoring backup…"; result = nil
        Task { @MainActor in
            do {
                let receipt = try await runExclusive(.rollback) { try installer.recover(backup: backup, reviewed: identity) }
                result = receipt; working = false; message = "Restored revision \(identity.revision) and verified it. The replaced app was kept at \(receipt["retainedPrevious"] as? String ?? "— (none)")."; refresh()
            } catch { working = false; result = nil; message = StagingInstallLane.describe(error); refresh() }
        }
    }
    /// The installer call runs only inside the coordinator's exclusive lane: it waits for
    /// running jobs (Cancel withdraws), and new work waits while it runs.
    private func runExclusive(_ action: StagingInstallLane.Action, _ body: @escaping @Sendable () throws -> [String: Any]) async throws -> [String: Any] {
        cancelRequested = false; waitingForLane = true
        defer { waitingForLane = false }
        let box = try await lane.run(action, requester: store.conversation.id, resource: installer.applications,
                                     mayOperate: { !cancelRequested }, status: { text in
                                         message = text
                                         if text.hasPrefix("Running the Staging") { waitingForLane = false }
                                     }) { ReceiptBox(value: try body()) }
        return box.value
    }
    /// Staging cannot replace itself while open, so the helper installs after we exit.
    /// The helper first takes the exclusive lane under an operation we name; only once
    /// it HOLDS the lane (every running job has finished and none can start) do we save
    /// and quit. Until then running work continues, and Cancel withdraws the request.
    private func handOff(action: String, app: URL, identity: StagingInstaller.Identity) {
        guard installer.isInstalledCopy(Bundle.main.bundleURL), !store.environment.agentTest, !working else { return }
        // The helper lives outside the app being replaced and waits for our exit.
        let helper = (action == "install" ? app : Bundle.main.bundleURL).appendingPathComponent("Contents/Helpers/silkwire-staging-installer")
        let operation = UUID()
        let job = Process(); job.executableURL = helper
        job.arguments = ["after-exit-" + action, String(getpid()), app.path, identity.manifestSHA256, "--exclusive-operation", operation.uuidString]
        do {
            guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw nativeFailure("This build has no update helper. Use the delivered Try This Build app after quitting Staging.") }
            try job.run()
        } catch { message = error.localizedDescription; return }
        working = true; waitingForLane = true; cancelRequested = false; result = nil
        message = "Waiting for running Silkwire work to finish before updating. Running work is never stopped for an update."
        Task { @MainActor in
            defer { waitingForLane = false }
            while true {
                if !job.isRunning {
                    working = false
                    message = job.terminationStatus == 2
                        ? "That build's update helper predates exclusive installs, so it cannot update safely while work may run. Nothing was installed; use the delivered Try This Build app."
                        : "The update helper stopped before it could start (exit \(job.terminationStatus)). Nothing was installed."
                    return
                }
                if cancelRequested {
                    job.terminate(); working = false; message = "Update cancelled. Nothing was installed."; return
                }
                if let state = try? await lane.coordinator.admissionState() {
                    if state.exclusiveHeld?.operationID == operation { break }
                    if let text = StagingInstallLane.waitingText(state, for: operation, action: action == "install" ? "update" : "rollback") { message = text }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            // The helper holds the lane: nothing runs and nothing new can start.
            message = "Saving and quitting so the update can install…"
            store.composerFlush?(); store.shutdown()
            guard store.storageError == nil else {
                job.terminate(); working = false
                message = (store.storageError ?? "Could not save Staging.") + " The update was cancelled; nothing was installed."; return
            }
            NSApp.terminate(nil)
        }
    }
}

/// Carries an installer receipt across the lane's joined task.
private struct ReceiptBox: @unchecked Sendable { let value: [String: Any] }
