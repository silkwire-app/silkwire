import AppKit
import Foundation

/// Dependencies are explicit so UI tests use signed fixture apps and a fake quit
/// handshake. The shipping entry point always selects the fixed Staging targets.
struct CandidateInstallerEnvironment {
    let candidate: URL
    let manifest: URL
    let applications: URL
    let library: URL
    /// Ownership registry whose exclusive lane the install takes. Tests pass a private
    /// one; the shipping entry point uses the app's registry, never a default.
    let registry: URL
    var quitTimeout: TimeInterval = 120
    var beforeValidation: () -> Void = {}
    var beforeInstall: () -> Void = {}
    var requestQuit: () -> Bool
    var isRunning: () -> Bool
    var openInstalled: () -> Void

    @MainActor static func delivered() -> Self {
        let installer = StagingInstaller(), resources = Bundle.main.resourceURL!
        return Self(candidate: resources.appendingPathComponent("Silkwire Staging.app"), manifest: resources.appendingPathComponent("candidate.json"),
                    applications: installer.applications, library: installer.library, registry: HostExecutionCoordinator.application.storage.directory,
                    requestQuit: {
                        for running in NSRunningApplication.runningApplications(withBundleIdentifier: "app.silkwire.staging")
                        where running.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == installer.target.standardizedFileURL.resolvingSymlinksInPath() {
                            if !running.terminate() { return false }
                        }
                        return true
                    }, isRunning: { installer.isRunning() }, openInstalled: { NSWorkspace.shared.open(installer.target) })
    }
}

private final class InstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false, mutating = false
    func cancel() -> Bool { lock.lock(); defer { lock.unlock() }; guard !mutating else { return false }; cancelled = true; return true }
    func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() } }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func beginMutation() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() }; mutating = true }
    func finish() { lock.lock(); mutating = false; lock.unlock() }
}

@MainActor final class CandidateInstallerController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let environment: CandidateInstallerEnvironment
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let status = NSTextField(wrappingLabelWithString: "Opening the delivered candidate…")
    let elapsed = NSTextField(labelWithString: "")
    let revision = NSTextField(wrappingLabelWithString: "The window stays available while checks and backups run.")
    let primary = NSButton(title: "Try This Build", target: nil, action: nil)
    let rollback = NSButton(title: "Roll Back Previous Build", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let receiptButton = NSButton(title: "Show Receipt", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let worker = DispatchQueue(label: "app.silkwire.candidate-installer", qos: .userInitiated)
    private var gate = InstallCancellation()
    private var timer: Timer?
    private var started = Date()
    private var identity: StagingInstaller.Identity?
    private var backup: StagingInstaller.Backup?
    private var receiptURL: URL?
    /// Install and rollback take the exclusive host lane before Staging is asked to quit,
    /// so no running Silkwire work is ever stopped by an update.
    private lazy var lane = StagingInstallLane(coordinator: environment.registry == HostExecutionCoordinator.application.storage.directory
        ? .application : HostExecutionCoordinator(directory: environment.registry), observeSelfForks: true)
    private var laneTask: Task<Void, Never>?
    private(set) var completed = false
    private(set) var busy = true
    var exitHandler: () -> Void = { NSApp.terminate(nil) }
    var statusObserver: (String) -> Void = { _ in }

    init(environment: CandidateInstallerEnvironment) { self.environment = environment; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) { show() }
    func show() {
        window.title = "Try This Build — Silkwire Staging"; window.delegate = self; window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Try this Silkwire Staging build")
        heading.font = .boldSystemFont(ofSize: 21)
        revision.font = .systemFont(ofSize: 13)
        status.font = .systemFont(ofSize: 14, weight: .medium); status.setAccessibilityIdentifier("installer-status")
        elapsed.textColor = .secondaryLabelColor; elapsed.setAccessibilityIdentifier("installer-elapsed")
        let explanation = NSTextField(wrappingLabelWithString: "Installs at /Applications/Silkwire Staging.app. Staging saves and quits before its current app and complete library are backed up together. Your stable Silkwire and sign-ins stay unchanged.\n\nRollback retains newer conversations separately, preserves computer-control history and pauses running agent tasks.")
        for field in [revision, status, elapsed, explanation] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.preferredMaxLayoutWidth = 612
        }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        let activity = NSStackView(views: [spinner, status]); activity.orientation = .horizontal; activity.spacing = 10
        for button in [primary, rollback, cancel, receiptButton] { button.target = self }
        receiptButton.action = #selector(showReceipt); receiptButton.isHidden = true
        primary.action = #selector(install); primary.keyEquivalent = "\r"; primary.isEnabled = false
        rollback.action = #selector(recover); rollback.isEnabled = false
        cancel.action = #selector(cancelOrClose); cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [rollback, NSView(), receiptButton, cancel, primary]); buttons.orientation = .horizontal; buttons.spacing = 10
        let stack = NSStackView(views: [heading, revision, explanation, activity, elapsed, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24), activity.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, self.busy else { return }
            self.elapsed.stringValue = "Elapsed: \(Int(Date().timeIntervalSince(self.started))) seconds · window remains responsive"
        } }
        // Return to AppKit before any filesystem, hashing, codesign or process work.
        DispatchQueue.main.async { [weak self] in self?.load() }
    }
    private func update(_ text: String) { status.stringValue = text; statusObserver(text) }
    private func progress() -> (String) -> Void {
        { [weak self] text in DispatchQueue.main.async { self?.update(text) } }
    }
    private func load() {
        let config = environment, report = progress(), gate = self.gate
        worker.async { [weak self] in
            do {
                config.beforeValidation()
                try gate.check(); report("Checking the delivered candidate bytes and signature…")
                let identity = try StagingInstaller.identify(config.candidate)
                let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: config.manifest)) as? [String: Any]
                guard identity.signatureValid, identity.manifestSHA256 == manifest?["manifestSHA256"] as? String else { throw Self.failure("The delivered candidate changed or its signature is invalid. Nothing installed.") }
                let installer = StagingInstaller(applications: config.applications, library: config.library)
                report("Checking the installed Staging build…")
                let installed = installer.installed()
                report("Looking for the latest matched app/library recovery point…")
                let folders = (try? FileManager.default.contentsOfDirectory(at: installer.backups, includingPropertiesForKeys: [.creationDateKey])) ?? []
                let ordered = folders.sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) }
                var backup: StagingInstaller.Backup?
                for folder in ordered {
                    try gate.check()
                    let path = folder.appendingPathComponent("Silkwire Staging.app")
                    // Skip legacy app-only backups before hashing or invoking codesign.
                    guard StagingInstaller.Backup(path: path, identity: nil, savedAt: nil).hasRecoveryPoint,
                          let prior = try? StagingInstaller.identify(path), prior.signatureValid, prior.manifestSHA256 != installed?.manifestSHA256 else { continue }
                    backup = .init(path: path, identity: prior, savedAt: nil); break
                }
                try gate.check()
                let selectedBackup = backup
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.identity = identity; self.backup = selectedBackup; self.busy = false; self.spinner.stopAnimation(nil)
                    self.revision.stringValue = "Candidate \(identity.shortRevision) · Installed \(installed?.shortRevision ?? "none")"
                    if installed?.manifestSHA256 == identity.manifestSHA256, installed?.signatureValid == true {
                        self.completed = true; self.primary.title = "Open Staging"; self.cancel.title = "Done"
                        self.update("This exact build is already installed and verified. No backup or reinstallation is needed.")
                        self.elapsed.stringValue = "Open Staging to continue."
                    } else {
                        self.update("Ready. Staging will be asked to save and quit only after you choose an action.")
                        self.elapsed.stringValue = selectedBackup == nil ? "No matched rollback point yet; this install creates one first." : "A matched rollback point is available."
                    }
                    self.primary.isEnabled = true; self.rollback.isEnabled = selectedBackup != nil
                }
            } catch { DispatchQueue.main.async { self?.failed(error) } }
        }
    }
    @objc func install() {
        if completed { environment.openInstalled(); exitHandler(); return }
        begin(rollback: false)
    }
    @objc func recover() { begin(rollback: true) }
    private func begin(rollback restoring: Bool) {
        guard !busy, let identity, !restoring || backup?.identity != nil else { return }
        completed = false; busy = true; started = Date(); gate = InstallCancellation(); spinner.startAnimation(nil)
        primary.isEnabled = false; rollback.isEnabled = false; cancel.isEnabled = true
        update("Waiting for running Silkwire work to finish before asking Staging to quit. Cancel is available.")
        let config = environment, report = progress(), backup = self.backup, gate = self.gate
        laneTask = Task { @MainActor [weak self, lane] in
            defer { self?.laneTask = nil }
            do {
                let box = try await lane.run(restoring ? .rollback : .install, requester: UUID(), resource: config.applications,
                                             mayOperate: { !gate.isCancelled }, status: { report($0) }) { () throws -> CandidateReceipt in
                    try gate.check()
                    report("Asking Silkwire Staging to save and quit…")
                    guard config.requestQuit() else { throw Self.failure("Staging declined the normal quit request. Quit it normally and try again. No backup or replacement started.") }
                    let start = Date()
                    while config.isRunning() {
                        try gate.check()
                        let seconds = Date().timeIntervalSince(start)
                        guard seconds < config.quitTimeout else { throw Self.failure("Staging has not finished quitting after \(Int(config.quitTimeout)) seconds. No backup or replacement started. Finish any save prompt in Staging, quit it normally, then try again.") }
                        report("Waiting for Silkwire Staging to save and quit · \(Int(seconds)) of \(Int(config.quitTimeout)) seconds. Cancel is available.")
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                    try gate.beginMutation()
                    DispatchQueue.main.async { self?.cancel.isEnabled = false; self?.cancel.title = "Working…" }
                    report("Staging has quit. Creating its matched app/library recovery point…")
                    config.beforeInstall()
                    let installer = StagingInstaller(applications: config.applications, library: config.library, progress: report)
                    let receipt: [String: Any]
                    if restoring, let backup, let prior = backup.identity { receipt = try installer.recover(backup: backup, reviewed: prior) }
                    else { receipt = try installer.install(candidate: config.candidate, reviewed: identity) }
                    return CandidateReceipt(value: receipt)
                }
                gate.finish()
                let receipt = box.value
                do {
                    guard let self else { return }
                    self.completed = true; self.busy = false; self.spinner.stopAnimation(nil)
                    let unchanged = receipt["action"] as? String == "already-installed"
                    self.update(unchanged ? "This exact build is already installed and verified. No backup or replacement was needed." : restoring ? "Staging rolled back. Restored bytes and signature verified." : "Staging is ready. Installed bytes and signature verified.")
                    if let path = receipt["receiptPath"] as? String { self.receiptURL = URL(fileURLWithPath: path); self.receiptButton.isHidden = false }
                    self.elapsed.stringValue = unchanged ? "Open Staging to continue." : "Receipt saved with the matched app/library recovery point."
                    self.primary.title = "Open Staging"; self.primary.isEnabled = true; self.cancel.title = "Done"; self.cancel.isEnabled = true
                }
            } catch { gate.finish(); self?.failed(error) }
        }
    }
    @objc private func showReceipt() { if let receiptURL { NSWorkspace.shared.activateFileViewerSelecting([receiptURL]) } }
    private func failed(_ error: Error) {
        busy = false; spinner.stopAnimation(nil)
        update("Update did not finish: " + StagingInstallLane.describe(error))
        elapsed.stringValue = "You can close this window or retry after resolving the reported problem."
        primary.isEnabled = identity != nil; rollback.isEnabled = backup != nil
        cancel.title = "Close"; cancel.isEnabled = true
    }
    @objc func cancelOrClose() {
        guard gate.cancel() else { update("Finishing the matched backup/install. Keep this window open until the receipt is saved."); return }
        timer?.invalidate(); timer = nil; window.orderOut(nil); exitHandler()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelOrClose(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard gate.cancel() else { return .terminateCancel }
        // Never exit while holding the exclusive lane: let the cancelled worker return first.
        guard let laneTask else { return .terminateNow }
        Task { @MainActor in await laneTask.value; NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    nonisolated private static func failure(_ text: String) -> NSError { NSError(domain: "Silkwire.Candidate", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

/// Carries an installer receipt across the lane's joined task.
struct CandidateReceipt: @unchecked Sendable { let value: [String: Any] }

#if !INSTALLER_UI_TESTING
@main struct TryThisBuildMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let controller = CandidateInstallerController(environment: .delivered())
        app.setActivationPolicy(.regular); app.delegate = controller; app.run()
        withExtendedLifetime(controller) {}
    }
}
#endif
