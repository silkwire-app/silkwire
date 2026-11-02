import AppKit
import Foundation

@main struct InstallerResponsivenessTests {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await checks(); app.terminate(nil) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func checks() async throws {
        setbuf(stdout, nil)
        let files = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/Silkwire-InstallerUITest-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var count = 0
        func check(_ good: Bool, _ label: String) throws { guard good else { throw NSError(domain: "InstallerUITest", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; count += 1; print("PASS: " + label) }
        func wait(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<160 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
            throw NSError(domain: "InstallerUITest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out: " + label])
        }
        func fixture(_ name: String, _ letter: String) throws -> URL {
            let app = root.appendingPathComponent(name + ".app")
            try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try files.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Silkwire").path)
            let info: [String: Any] = ["CFBundleIdentifier": "app.silkwire.staging", "SilkwireEnvironment": "staging", "CFBundleExecutable": "Silkwire", "SilkwireGitRevision": String(repeating: letter, count: 40)]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); sign.arguments = ["--force", "--sign", "-", "--timestamp=none", app.path]
            try sign.run(); sign.waitUntilExit(); guard sign.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }; return app
        }
        let delivered = CandidateInstallerEnvironment.delivered()
        try check(delivered.registry == HostExecutionCoordinator.application.storage.directory, "shipping installer takes the app's exclusive host lane, not a private registry")
        try check(delivered.applications.path == "/Applications" && StagingInstaller(applications: delivered.applications, library: delivered.library).target.path == "/Applications/Silkwire Staging.app", "shipping installer and reopen closure select the system Staging target")
        let candidate = try fixture("candidate", "b"), previous = try fixture("previous", "a")
        let identity = try StagingInstaller.identify(candidate), manifest = root.appendingPathComponent("candidate.json")
        try JSONSerialization.data(withJSONObject: identity.asJSON).write(to: manifest)
        var ticks = 0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { ticks += 1 } }
        defer { heartbeat.invalidate() }
        func environment(_ name: String) -> CandidateInstallerEnvironment {
            CandidateInstallerEnvironment(candidate: candidate, manifest: manifest, applications: root.appendingPathComponent(name + "/Applications"), library: root.appendingPathComponent(name + "/Library"), registry: root.appendingPathComponent(name + "/host-ownership"), requestQuit: { true }, isRunning: { false }, openInstalled: {})
        }
        var startup = environment("startup"); startup.beforeValidation = { Thread.sleep(forTimeInterval: 0.8) }
        let first = CandidateInstallerController(environment: startup); first.exitHandler = {}; first.show()
        let initial = ticks
        try await Task.sleep(for: .milliseconds(300))
        try check(first.window.isVisible && ticks - initial >= 5 && !first.elapsed.stringValue.isEmpty, "window and heartbeat are live before deliberately slow validation finishes")
        try await wait("startup ready") { !first.busy }
        try check(first.primary.isEnabled, "candidate checks complete off the main thread")
        first.cancelOrClose()

        var timeout = environment("timeout"); timeout.quitTimeout = 1; timeout.isRunning = { true }
        let second = CandidateInstallerController(environment: timeout); second.exitHandler = {}; second.show()
        try await wait("timeout ready") { !second.busy }; second.install()
        try await wait("waiting label") { second.status.stringValue.contains("Waiting for Silkwire Staging") }
        let waitingTicks = ticks; try await Task.sleep(for: .milliseconds(300))
        try check(second.window.isVisible && second.cancel.isEnabled && ticks - waitingTicks >= 5, "quit wait keeps the window responsive with visible status and Cancel")
        try await wait("quit timeout") { !second.busy }
        try check(second.status.stringValue.contains("No backup or replacement started") && !files.fileExists(atPath: timeout.applications.path), "quit timeout reports the wait and performs no mutation")
        second.cancelOrClose()

        var waiting = environment("cancel"); waiting.isRunning = { true }
        var exited = false
        let third = CandidateInstallerController(environment: waiting); third.exitHandler = { exited = true }; third.show()
        try await wait("cancel ready") { !third.busy }; third.install()
        try await wait("cancel wait") { third.status.stringValue.contains("Waiting for Silkwire Staging") }
        third.cancelOrClose(); try await Task.sleep(for: .milliseconds(350))
        try check(exited && !third.window.isVisible && !files.fileExists(atPath: waiting.applications.path), "Cancel during quit wait closes without installing")

        var success = environment("success")
        try files.createDirectory(at: success.library, withIntermediateDirectories: true)
        let original = Data("Synthetic conversations and sign-ins fixture only".utf8)
        try original.write(to: success.library.appendingPathComponent("workspace.json"))
        let installer = StagingInstaller(applications: success.applications, library: success.library)
        _ = try installer.install(candidate: previous, reviewed: StagingInstaller.identify(previous))
        success.beforeInstall = { Thread.sleep(forTimeInterval: 0.8) }
        var events: [String] = []
        let fourth = CandidateInstallerController(environment: success); fourth.exitHandler = {}; fourth.statusObserver = { events.append($0) }; fourth.show()
        try await wait("success ready") { !fourth.busy }; fourth.install()
        try await wait("backup phase") { fourth.status.stringValue.contains("recovery point") }
        let backupTicks = ticks; try await Task.sleep(for: .milliseconds(300))
        try check(fourth.window.isVisible && !fourth.cancel.isEnabled && ticks - backupTicks >= 5 && fourth.applicationShouldTerminate(NSApp) == .terminateCancel, "slow backup worker leaves AppKit responsive and prevents unsafe mid-copy cancellation")
        try await wait("installed") { fourth.completed }
        try check(installer.installed()?.manifestSHA256 == identity.manifestSHA256 && events.contains { $0.contains("Checking Staging library before backup") } && events.contains { $0.contains("Verifying the library backup") }, "actual install reports verification and backup phases and preserves candidate bytes")
        let backups = installer.listBackups()
        let saved = backups.first { $0.identity?.revision == String(repeating: "a", count: 40) }!
        try check(try Data(contentsOf: saved.path.deletingLastPathComponent().appendingPathComponent("Library/workspace.json")) == original && Data(contentsOf: success.library.appendingPathComponent("workspace.json")) == original, "successful responsive install retains the previous app with a byte-exact library backup")
        let lane = (try? JSONSerialization.jsonObject(with: Data(contentsOf: success.registry.appendingPathComponent("ownership.json")))) as? [String: Any]
        let laneRecords = (lane?["records"] as? [[String: Any]]) ?? []
        try check(laneRecords.count == 1 && (laneRecords.first?["owner"] as? [String: Any])?["kind"] as? String == "exclusiveOperation" && laneRecords.first?["phase"] as? String == "finished",
                  "the install ran as one exclusive host operation and released it with exit evidence")
        try check(fourth.window.frame.width <= 700 && !fourth.receiptButton.isHidden && fourth.primary.isEnabled, "completion keeps the window bounded and exposes its saved receipt")
        try await Task.sleep(for: .milliseconds(100))
        let content = fourth.window.contentView!, rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("completed.png"))
        fourth.cancelOrClose()
        var already = success
        var quitRequested = false, opened = false, scanned = false
        already.requestQuit = { quitRequested = true; return false }
        already.beforeInstall = { scanned = true }
        already.openInstalled = { opened = true }
        let fifth = CandidateInstallerController(environment: already); fifth.exitHandler = {}; fifth.show()
        try await wait("already installed ready") { !fifth.busy }
        try check(fifth.completed && fifth.primary.title == "Open Staging" && fifth.status.stringValue.contains("No backup or reinstallation"), "identical candidate offers Open Staging instead of another installation")
        fifth.install()
        try check(opened && !quitRequested && !scanned, "Open Staging skips the quit, backup and mutation workers")
        try JSONSerialization.data(withJSONObject: ["passed": count, "fixtureRoot": root.path, "heartbeatTicks": ticks, "phases": events], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("results.json"))
        print("PASS: \(count) installer responsiveness checks. Evidence: \(root.path)")
    }
}
