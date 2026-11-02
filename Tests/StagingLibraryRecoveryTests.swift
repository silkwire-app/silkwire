import Foundation
import Darwin

@main struct StagingLibraryRecoveryTests {
    static func main() throws {
        setbuf(stdout, nil)
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("StagingRecovery-" + UUID().uuidString)
        let library = root.appendingPathComponent("Staging Library")
        let installer = StagingInstaller(applications: root.appendingPathComponent("Applications"), library: library)
        func check(_ ok: Bool, _ message: String) throws { guard ok else { throw nativeFailure("FAIL: " + message) }; print("PASS: " + message) }
        func bundle(_ name: String, _ revision: String) throws -> URL {
            let app = root.appendingPathComponent(name + ".app")
            try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try files.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Silkwire").path)
            let info: [String: Any] = ["CFBundleIdentifier": "app.silkwire.staging", "SilkwireEnvironment": "staging", "CFBundleExecutable": "Silkwire", "SilkwireGitRevision": String(repeating: revision, count: 40)]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let job = Process(); job.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); job.arguments = ["--force", "--sign", "-", "--timestamp=none", app.path]
            try job.run(); job.waitUntilExit(); guard job.terminationStatus == 0 else { throw nativeFailure("Fixture signing failed") }; return app
        }
        try files.createDirectory(at: library.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try Data("original conversations".utf8).write(to: library.appendingPathComponent("workspace.json"))
        try Data([0, 1, 2, 3]).write(to: library.appendingPathComponent("Attachments/test.bin"))
        let control = library.appendingPathComponent("Computer Control")
        try files.createDirectory(at: control.appendingPathComponent("Audit"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [["id": "historical-task", "state": "running", "progress": "historical"]]).write(to: control.appendingPathComponent("tasks.json"))
        try Data("old audit\n".utf8).write(to: control.appendingPathComponent("Audit/fixture.jsonl"))
        let keys = control.appendingPathComponent("Keys")
        let key = keys.appendingPathComponent("silkwire-agents")
        try files.createDirectory(at: keys, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("synthetic historical key".utf8).write(to: key)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try Data(#"{"disabledConnections":[]}"#.utf8).write(to: control.appendingPathComponent("settings.json"))
        let a = try bundle("a", "a"), b = try bundle("b", "b")
        let ia = try StagingInstaller.identify(a), ib = try StagingInstaller.identify(b)
        _ = try installer.install(candidate: a, reviewed: ia)
        let lock = Darwin.open(library.appendingPathComponent(".conversation.lock").path, O_RDWR)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw nativeFailure("Fixture lock failed") }
        try check((try? installer.install(candidate: b, reviewed: ib)) == nil && installer.installed()?.revision == ia.revision, "held library lock prevents replacement and inconsistent backup")
        Darwin.close(lock)
        let concurrent = Darwin.open(installer.operationLock.path, O_RDWR)
        guard concurrent >= 0, flock(concurrent, LOCK_EX | LOCK_NB) == 0 else { throw nativeFailure("Operation fixture lock failed") }
        try check((try? installer.install(candidate: b, reviewed: ib)) == nil && installer.installed()?.revision == ia.revision, "concurrent installer operations are serialized before replacement")
        Darwin.close(concurrent)
        let installed = try installer.install(candidate: b, reviewed: ib)
        let backup = URL(fileURLWithPath: installed["backup"] as! String)
        let snapshot = backup.deletingLastPathComponent().appendingPathComponent("Library")
        try check(try Data(contentsOf: snapshot.appendingPathComponent("workspace.json")) == Data("original conversations".utf8), "automatic pre-install backup includes conversations")
        try check(try Data(contentsOf: snapshot.appendingPathComponent("Attachments/test.bin")) == Data([0, 1, 2, 3]), "automatic pre-install backup includes attachments")
        try check(try Data(contentsOf: key) == Data("synthetic historical key".utf8) && Data(contentsOf: snapshot.appendingPathComponent("Computer Control/Keys/silkwire-agents")) == Data("synthetic historical key".utf8), "install preserves the key in the current library and matched backup")
        try check((try files.attributesOfItem(atPath: key.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (try files.attributesOfItem(atPath: snapshot.appendingPathComponent("Computer Control/Keys/silkwire-agents").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "install and backup retain private-key mode 0600")
        try Data("synthetic rotated key".utf8).write(to: key)
        try Data("newer conversations".utf8).write(to: library.appendingPathComponent("workspace.json"))
        let latestTasks: [[String: Any]] = [["id": "already-done", "state": "done", "progress": "real work completed"], ["id": "new-running", "state": "running", "progress": "latest progress", "resumeAfterRestart": true]]
        try JSONSerialization.data(withJSONObject: latestTasks).write(to: control.appendingPathComponent("tasks.json"))
        try Data("old audit\nnew real-world action\n".utf8).write(to: control.appendingPathComponent("Audit/fixture.jsonl"))
        try Data(#"{"disabledConnections":["github"]}"#.utf8).write(to: control.appendingPathComponent("settings.json"))
        let restored = try installer.recover(backup: .init(path: backup, identity: ia, savedAt: nil), reviewed: ia)
        try check(installer.installed()?.manifestSHA256 == ia.manifestSHA256 && (try Data(contentsOf: library.appendingPathComponent("workspace.json"))) == Data("original conversations".utf8), "one recovery operation restores the matched app and library")
        let later = URL(fileURLWithPath: restored["laterLibraryRetained"] as! String)
        try check(try Data(contentsOf: later.appendingPathComponent("workspace.json")) == Data("newer conversations".utf8), "rollback retains newer conversations in a separate recovery point")
        let restoredTasks = try JSONSerialization.jsonObject(with: Data(contentsOf: control.appendingPathComponent("tasks.json"))) as! [[String: Any]]
        try check(restoredTasks.count == 2 && restoredTasks[0]["state"] as? String == "done" && restoredTasks[1]["state"] as? String == "blocked" && restoredTasks[1]["resumeAfterRestart"] as? Bool == false, "rollback keeps latest task history and pauses running work instead of replaying historical tasks")
        try check(try Data(contentsOf: control.appendingPathComponent("settings.json")) == Data(#"{"disabledConnections":["github"]}"#.utf8) && Data(contentsOf: control.appendingPathComponent("Audit/fixture.jsonl")) == Data("old audit\nnew real-world action\n".utf8), "rollback preserves the newest computer-control rules and audit")
        let retainedTasks = try JSONSerialization.jsonObject(with: Data(contentsOf: later.appendingPathComponent("Computer Control/tasks.json"))) as! [[String: Any]]
        try check(retainedTasks[1]["state"] as? String == "running" && (restored["computerControl"] as? [String: Any])?["runningTasksPaused"] as? Int == 1, "the unmodified newer task snapshot is retained and the pause is recorded")
        try check(try Data(contentsOf: key) == Data("synthetic rotated key".utf8) && (try files.attributesOfItem(atPath: key.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "rollback keeps the newest key and its permissions together with newest Disconnect settings")
        try files.removeItem(at: key) // Only the synthetic fixture key.
        try Data(#"{"disabledConnections":["server","github"]}"#.utf8).write(to: control.appendingPathComponent("settings.json"))
        let disconnectedRestore = try installer.recover(backup: .init(path: backup, identity: ia, savedAt: nil), reviewed: ia)
        let disconnected = try JSONSerialization.jsonObject(with: Data(contentsOf: control.appendingPathComponent("settings.json"))) as! [String: Any]
        try check(!files.fileExists(atPath: key.path) && Set(disconnected["disabledConnections"] as! [String]) == Set(["server", "github"]), "rollback preserves Disconnect and never resurrects a deleted key from an older snapshot")
        let disconnectedLater = URL(fileURLWithPath: disconnectedRestore["laterLibraryRetained"] as! String)
        try check(!files.fileExists(atPath: disconnectedLater.appendingPathComponent("Computer Control/Keys/silkwire-agents").path), "retained newer history also records the key deletion")
        try files.moveItem(at: installer.receipts, to: root.appendingPathComponent("saved-receipts"))
        try Data("blocks receipt creation".utf8).write(to: installer.receipts)
        try Data("latest conversations".utf8).write(to: library.appendingPathComponent("workspace.json"))
        try check((try? installer.recover(backup: .init(path: backup, identity: ia, savedAt: nil), reviewed: ia)) == nil && (try Data(contentsOf: library.appendingPathComponent("workspace.json"))) == Data("latest conversations".utf8) && installer.installed()?.manifestSHA256 == ia.manifestSHA256, "receipt failure restores the preceding app and latest library")
        try files.moveItem(at: library, to: root.appendingPathComponent("saved-before-absent-library-check"))
        try check((try? installer.recover(backup: .init(path: backup, identity: ia, savedAt: nil), reviewed: ia)) == nil && !files.fileExists(atPath: library.path) && installer.installed()?.manifestSHA256 == ia.manifestSHA256, "failed recovery preserves an originally absent library and retains incomplete restored data")
        let protected = StagingInstaller(applications: root.appendingPathComponent("protected-applications"), library: root.appendingPathComponent("other-library"))
        try files.createDirectory(at: protected.applications, withIntermediateDirectories: true)
        try files.copyItem(at: a, to: protected.target)
        let protectedInfo = protected.target.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: protectedInfo), format: nil) as! [String: Any]
        info["CFBundleIdentifier"] = "app.silkwire.native.ready.preview"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: protectedInfo)
        let beforeProtected = try StagingInstaller.manifest(protected.target)
        try check((try? protected.install(candidate: b, reviewed: ib)) == nil && (try StagingInstaller.manifest(protected.target)) == beforeProtected, "an existing non-Staging app at the target name is never replaced")
        let point = backup.deletingLastPathComponent().appendingPathComponent("RecoveryPoint.json")
        let savedPoint = root.appendingPathComponent("saved-point.json")
        try files.moveItem(at: point, to: savedPoint)
        try files.createSymbolicLink(at: point, withDestinationURL: savedPoint)
        try check((try? installer.recover(backup: .init(path: backup, identity: ia, savedAt: nil), reviewed: ia)) == nil, "linked recovery metadata is rejected before mutation")
        try files.moveItem(at: point, to: root.appendingPathComponent("retained-point-link"))
        try files.moveItem(at: savedPoint, to: point)
        let savedSnapshot = root.appendingPathComponent("saved-snapshot")
        try files.moveItem(at: snapshot, to: savedSnapshot)
        try files.createSymbolicLink(at: snapshot, withDestinationURL: savedSnapshot)
        try check((try? installer.recover(backup: .init(path: backup, identity: ia, savedAt: nil), reviewed: ia)) == nil, "linked library snapshot root is rejected before mutation")
        try files.moveItem(at: snapshot, to: root.appendingPathComponent("retained-snapshot-link"))
        try files.moveItem(at: savedSnapshot, to: snapshot)
        try Data("tampered snapshot".utf8).write(to: snapshot.appendingPathComponent("workspace.json"))
        try check((try? installer.recover(backup: .init(path: backup, identity: ia, savedAt: nil), reviewed: ia)) == nil, "changed library backup is rejected before mutation")
        print("PASS: StagingLibraryRecoveryTests; synthetic app and library only")
    }
}
