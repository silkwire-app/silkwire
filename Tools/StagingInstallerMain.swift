import Foundation
import AppKit
import Darwin

// Operator-only bootstrap for working app versions that predate the install sheet.
// Shares the exact installation/recovery implementation, and the exclusive host
// lane (StagingInstallLane over HostExecutionCoordinator), with the app. No seed,
// promotion or provider operation is exposed here. Deferred operations wait for
// the caller to exit before making a matched app/library recovery point.
/// Thread-safe stop flag for SIGTERM/SIGINT: while waiting for the lane it withdraws
/// the request; once admitted the install itself always finishes and is joined.
final class HelperStop: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    private var sources: [DispatchSourceSignal] = []
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func install() {
        for value in [SIGTERM, SIGINT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
            source.setEventHandler { [weak self] in guard let self else { return }; self.lock.lock(); self.stopped = true; self.lock.unlock() }
            source.resume(); sources.append(source)
        }
    }
}

@main struct StagingInstallerMain {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let usage = """
        Silkwire Staging installer (operator-run)
        Target: /Applications/Silkwire Staging.app
          review APP                    Read identity and manifest; change nothing
          backups                       List retained bundles; change nothing
          install APP EXPECTED_MANIFEST  Back up and install reviewed Staging app
          restore APP EXPECTED_MANIFEST  Restore reviewed app from backup folder
        Install and restore run in Silkwire's exclusive host lane: they wait for running
        Silkwire work to finish (Ctrl-C withdraws) and new work waits until they end.
        Quit Silkwire Staging before install/restore. App and library are backed up together.
        """
        guard let action = args.first, action != "--help" else { print(usage); return }
        let failure: @Sendable (Int, String) -> NSError = { code, text in NSError(domain: "Silkwire.Installer", code: code, userInfo: [NSLocalizedDescriptionKey: text]) }
        let stop = HelperStop(); stop.install()
        let lane = StagingInstallLane(coordinator: .application, observeSelfForks: true)
        let status: @MainActor (String) -> Void = { fputs("[Staging] " + $0 + "\n", stderr) }
        do {
            let installer = StagingInstaller(progress: { fputs("[Staging] " + $0 + "\n", stderr) })
            var result: Any
            // after-exit-ACTION PID APP MANIFEST [--exclusive-operation UUID]
            let handoff = args.count == 6 && args[4] == "--exclusive-operation" ? UUID(uuidString: args[5]) : nil
            if ["after-exit-install", "after-exit-restore"].contains(action), args.count == 4 || handoff != nil, let pid = Int32(args[1]), pid > 1 {
                let app = URL(fileURLWithPath: args[2]), manifest = args[3]
                let started = Date()
                // The app that handed off is identified by kernel unique ID, never by PID: it
                // started this helper, and the kernel keeps its unique ID as this process's
                // parent even after it exits. It is running only while PID `pid` still
                // belongs to that exact process, so a recycled PID never counts as Staging.
                guard case .live(let me) = try StagingInstallWorkload.identity(getpid()), getppid() == pid || getppid() == 1 else {
                    throw failure(1, "This update helper was not started by the Staging app it was asked to wait for. Nothing installed.")
                }
                let creator = me.parent
                let appRunning: @Sendable () -> Bool = {
                    if case .live(let id)? = try? StagingInstallWorkload.identity(pid), id.unique == creator { return true }
                    return false
                }
                // With a handoff the app keeps running (and its work keeps running) until we
                // hold the lane; it then quits. An older app quits at once, so bound the wait.
                // The app quits as soon as it sees us hold the lane, possibly between our
                // reservation and begin: once our record exists, its exit is expected.
                let registry = lane.coordinator.storage.directory
                let mayOperate: @MainActor () -> Bool = handoff.map { operation in {
                    guard !stop.requested else { return false }
                    if appRunning() { return true }
                    guard let records = try? PhysicalWorkOwnership(directory: registry, capacity: HostOwnershipStorage.capacity).snapshot() else { return true }
                    return records.contains { $0.operationID == operation && $0.holdsResources }
                } } ?? { !stop.requested && Date().timeIntervalSince(started) < 300 }
                let restoring = action == "after-exit-restore"
                let box = try await lane.run(restoring ? .rollback : .install, operationID: handoff ?? UUID(), requester: UUID(),
                                             resource: installer.applications, mayOperate: mayOperate, status: status) { () throws -> ResultBox in
                    let deadline = Date().addingTimeInterval(120)
                    while appRunning(), Date() < deadline, !stop.requested { Thread.sleep(forTimeInterval: 0.1) }
                    guard !stop.requested else { throw failure(1, "The update was cancelled before it started. Nothing installed.") }
                    guard !appRunning() else { throw failure(1, "Staging did not finish quitting. Nothing installed.") }
                    let identity = try StagingInstaller.identify(app)
                    guard identity.manifestSHA256 == manifest else { throw failure(2, "The selected build changed. Nothing installed.") }
                    if restoring { return ResultBox(try installer.recover(backup: .init(path: app, identity: identity, savedAt: nil), reviewed: identity)) }
                    return ResultBox(try installer.install(candidate: app, reviewed: identity))
                }
                result = box.value
                NSWorkspace.shared.open(installer.target)
            } else if action == "review", args.count == 2 {
                result = try StagingInstaller.identify(URL(fileURLWithPath: args[1])).asJSON
            } else if action == "backups", args.count == 1 {
                result = installer.listBackups().map { backup -> [String: Any] in
                    ["path": backup.path.path, "identity": backup.identity?.asJSON ?? [:]]
                }
            } else if ["install", "restore"].contains(action), args.count == 3 {
                let app = URL(fileURLWithPath: args[1]), manifest = args[2]
                let restoring = action == "restore"
                let box = try await lane.run(restoring ? .rollback : .install, requester: UUID(), resource: installer.applications,
                                             mayOperate: { !stop.requested }, status: status) { () throws -> ResultBox in
                    let identity = try StagingInstaller.identify(app)
                    guard identity.manifestSHA256 == manifest else { throw NSError(domain: "Silkwire.StagingInstaller", code: 2, userInfo: [NSLocalizedDescriptionKey: "Manifest differs from the review. Nothing changed."]) }
                    if restoring { return ResultBox(try installer.recover(backup: .init(path: app, identity: identity, savedAt: nil), reviewed: identity)) }
                    return ResultBox(try installer.install(candidate: app, reviewed: identity))
                }
                result = box.value
            } else {
                fputs(usage + "\n", stderr); exit(2)
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs(StagingInstallLane.describe(error) + "\n", stderr)
            if action.hasPrefix("after-exit-") && !stop.requested {
                let application = NSApplication.shared
                application.setActivationPolicy(.regular); application.finishLaunching(); application.activate(ignoringOtherApps: true)
                let alert = NSAlert(); alert.messageText = "Silkwire Staging update did not finish"; alert.informativeText = StagingInstallLane.describe(error); alert.runModal()
            }
            exit(1)
        }
    }
}

/// Carries an installer receipt across the lane's joined task.
struct ResultBox: @unchecked Sendable { let value: [String: Any]; init(_ value: [String: Any]) { self.value = value } }
