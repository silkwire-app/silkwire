import Foundation

// Filesystem installation/recovery in temporary fixtures. Process-list outcomes are
// injected; this does not claim an actual running-app test or touch ~/Applications.
@main struct StagingInstallerReviewTests {
    static func main() throws {
        setbuf(stdout, nil)
        let files = FileManager.default
        let fixture = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-install-review-" + UUID().uuidString)
        let applications = fixture.appendingPathComponent("Applications")
        let installer = StagingInstaller(applications: applications, processPaths: { [] })
        var count = 0
        func check(_ ok: Bool, _ label: String) throws {
            guard ok else { throw nativeFailure("FAIL " + label) }
            count += 1; print("PASS " + label)
        }
        func run(_ executable: String, _ args: [String], at root: URL? = nil) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args; p.currentDirectoryURL = root
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw nativeFailure("Fixture process failed") }
        }
        func bundle(_ path: URL, revision: String, signed: Bool = true) throws -> StagingInstaller.Identity {
            try files.createDirectory(at: path.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try files.copyItem(atPath: "/usr/bin/true", toPath: path.appendingPathComponent("Contents/MacOS/Silkwire").path)
            let info: [String: Any] = ["CFBundleExecutable": "Silkwire", "CFBundleIdentifier": "app.silkwire.staging", "CFBundlePackageType": "APPL", "SilkwireEnvironment": "staging", "SilkwireGitRevision": revision]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path.appendingPathComponent("Contents/Info.plist"))
            if signed { try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", path.path]) }
            return try StagingInstaller.identify(path)
        }
        let a = fixture.appendingPathComponent("a.app"), b = fixture.appendingPathComponent("b.app")
        let identityA = try bundle(a, revision: String(repeating: "a", count: 40))
        let identityB = try bundle(b, revision: String(repeating: "b", count: 40))
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.appendingPathComponent("Contents/MacOS/Silkwire").path)
        try check(StagingInstaller.signatureValid(a), "signature alone still passes after executable permission is removed")
        try check((try? StagingInstaller.identify(a)) == nil, "non-executable candidate refused")
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: a.appendingPathComponent("Contents/MacOS/Silkwire").path)
        _ = try installer.install(candidate: a, reviewed: identityA)
        let failedListing = StagingInstaller(applications: applications, processPaths: { nil })
        try check(failedListing.isRunning(), "failed process listing is treated as potentially running")
        try check((try? failedListing.install(candidate: b, reviewed: identityB)) == nil && installer.installed()?.revision == identityA.revision, "unknown running state refuses replacement before mutation")
        _ = try installer.install(candidate: b, reviewed: identityB)
        guard let backupA = installer.listBackups().first(where: { $0.identity?.revision == identityA.revision }) else { throw nativeFailure("Fixture's signed backup was not listed") }
        _ = try installer.recover(backup: backupA, reviewed: identityA)
        try check(installer.installed()?.manifestSHA256 == identityA.manifestSHA256 && files.fileExists(atPath: backupA.path.path), "signed backup restored exactly and retained")
        let unsignedPath = installer.backups.appendingPathComponent("unsigned/Silkwire Staging.app")
        let unsigned = try bundle(unsignedPath, revision: String(repeating: "c", count: 40), signed: false)
        let badBackup = StagingInstaller.Backup(path: unsignedPath, identity: unsigned, savedAt: nil)
        try check(!unsigned.signatureValid && (try? installer.recover(backup: badBackup, reviewed: unsigned)) == nil && installer.installed()?.revision == identityA.revision, "unsigned backup refused without replacing installed app")

        // Force receipt persistence failure after copying, so real rollback executes.
        let rollbackInstaller = StagingInstaller(applications: fixture.appendingPathComponent("rollback"), processPaths: { [] })
        try files.createDirectory(at: rollbackInstaller.backups, withIntermediateDirectories: true)
        try Data("blocks receipt directory".utf8).write(to: rollbackInstaller.receipts)
        var failure = ""
        do { _ = try rollbackInstaller.install(candidate: a, reviewed: identityA) } catch { failure = error.localizedDescription }
        try check(failure.contains("No previous Staging app was installed") && rollbackInstaller.installed() == nil && !rollbackInstaller.listBackups().isEmpty, "first-install failure retains incomplete copy and does not invent a restored app")
        let replacementInstaller = StagingInstaller(applications: fixture.appendingPathComponent("replacement"), processPaths: { [] })
        _ = try replacementInstaller.install(candidate: a, reviewed: identityA)
        try files.moveItem(at: replacementInstaller.receipts, to: fixture.appendingPathComponent("saved-receipts"))
        try Data("blocks receipt directory".utf8).write(to: replacementInstaller.receipts)
        do { _ = try replacementInstaller.install(candidate: b, reviewed: identityB) } catch { failure = error.localizedDescription }
        try check(failure.contains("previously installed Staging app was put back") && replacementInstaller.installed()?.manifestSHA256 == identityA.manifestSHA256, "failed upgrade actually restores the previous bundle")

        let source = fixture.appendingPathComponent("source")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.appendingPathComponent("main.txt"))
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-q", "-m", "fixture"]] { try run("/usr/bin/git", args, at: source) }
        let digest = try StagingInstaller.sourceDigest(source)
        var built = identityA; built.sourceDigest = digest.digest
        var receipt: [String: Any] = ["id": UUID().uuidString, "owner": "codex", "status": "review", "transfer": ["headCommit": String(repeating: "1", count: 40)]]
        try check(StagingInstaller.provenance(of: built, receipt: receipt, worktree: source).builtFromHead == false, "matching files with a different receipt head cannot claim exact-head provenance")
        receipt["transfer"] = ["headCommit": digest.headCommit]
        try check(StagingInstaller.provenance(of: built, receipt: receipt, worktree: source).builtFromHead == true, "matching digest and actual finished head confirm provenance")
        // The Update button: the installed Staging app replaces itself while it is open.
        // "Running" is simulated by a process listing that reports Staging as open.
        let openNow = StagingInstaller(applications: applications, processPaths: { nil })
        let beforeSelf = openNow.installed()
        try check((try? openNow.installReplacingRunning(candidate: b, reviewed: identityB, running: b)) == nil && openNow.installed()?.manifestSHA256 == beforeSelf?.manifestSHA256, "a Staging app that is not the installed copy cannot update it")
        try check((try? openNow.installReplacingRunning(candidate: b, reviewed: identityB, running: openNow.target)) == nil && openNow.installed()?.manifestSHA256 == beforeSelf?.manifestSHA256, "self updates must wait for exit before taking a matched library backup")
        try check((try? openNow.install(candidate: b, reviewed: identityB)) == nil, "replacements still refuse while Staging is open")
        try check((try? openNow.install(candidate: a, reviewed: identityA))?["action"] as? String == "already-installed", "an already-installed exact build is a read-only success even while Staging is open")

        print("PASS: \(count) installer review checks; temporary fixtures only; running-state tests use synthetic process listings. \(fixture.path)")
    }
}
