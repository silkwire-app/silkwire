import Foundation

// Synthetic, ad-hoc-signed bundles in a temporary Applications folder. The real
// ~/Applications and every library are never touched by this suite.
@main struct StagingInstallerTests {
    static func main() throws {
        setbuf(stdout, nil)
        var passed = 0
        func check(_ valid: Bool, _ name: String) throws {
            guard valid else { throw nativeFailure("FAIL " + name) }
            passed += 1; print("PASS " + name)
        }
        let files = FileManager.default
        let fixture = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-install-" + UUID().uuidString)
        let applications = fixture.appendingPathComponent("Applications")
        let realApplications = files.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        let delivered = StagingInstaller()
        try check(delivered.target.path == "/Applications/Silkwire Staging.app" && delivered.backups.path == "/Applications/Silkwire Staging Backups", "production install, rollback and helper reopen share the system Applications target")
        try check(delivered.library.path == files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Silkwire Staging").path, "system app location retains the user's existing Staging library")

        func shell(_ path: String, _ args: [String], at directory: URL? = nil) throws -> Int32 {
            let job = Process(); job.executableURL = URL(fileURLWithPath: path); job.arguments = args; job.currentDirectoryURL = directory
            job.standardOutput = FileHandle.nullDevice; job.standardError = FileHandle.nullDevice
            try job.run(); job.waitUntilExit(); return job.terminationStatus
        }
        func bundle(_ name: String, revision: String, identifier: String = "app.silkwire.staging", executable: String = "/usr/bin/true", digest: String = "", sign: Bool = true) throws -> URL {
            let app = fixture.appendingPathComponent("candidates/\(name)/Silkwire Staging.app")
            try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try files.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try files.copyItem(atPath: executable, toPath: app.appendingPathComponent("Contents/MacOS/Silkwire").path)
            try Data("resource \(name)\n".utf8).write(to: app.appendingPathComponent("Contents/Resources/marker.txt"))
            let info: [String: Any] = ["CFBundleExecutable": "Silkwire", "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "SilkwireEnvironment": "staging", "SilkwireGitRevision": revision, "SilkwireSourceDigest": digest, "SilkwireSourceStatus": "clean"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            if sign { guard try shell("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path]) == 0 else { throw nativeFailure("Cannot ad-hoc sign fixture") } }
            return app
        }
        let installer = StagingInstaller(applications: applications)
        try check(installer.target.path.hasPrefix(fixture.path) && !installer.target.path.hasPrefix(realApplications), "installer is confined to the synthetic Applications folder")

        let working = try bundle("working", revision: String(repeating: "c", count: 40), identifier: "app.silkwire.native.ready.preview")
        try check((try? StagingInstaller.identify(working)) == nil, "a non-Staging bundle cannot be identified as a candidate")
        let a = try bundle("a", revision: String(repeating: "a", count: 40))
        let identityA = try StagingInstaller.identify(a)
        try check(identityA.signatureValid && identityA.revision == String(repeating: "a", count: 40) && identityA.fileCount >= 4 && identityA.executableSHA256.count == 64, "candidate identity records revision, executable hash, files and signature")
        try check(installer.installed() == nil && !installer.isRunning(), "nothing installed or running at the synthetic target")
        let first = try installer.install(candidate: a, reviewed: identityA)
        try check(first["backup"] is NSNull && installer.installed()?.manifestSHA256 == identityA.manifestSHA256 && (first["installed"] as? [String: Any])?["revision"] as? String == identityA.revision, "first install confirms the installed revision and bytes")
        try check(files.fileExists(atPath: first["receiptPath"] as? String ?? "") && first["libraryModified"] as? Bool == false, "install receipt saved; no library modified")
        let backupCount = installer.listBackups().count
        var sameBuildEvents: [String] = []
        let sameBuild = StagingInstaller(applications: applications, library: installer.library, processPaths: { nil }, progress: { sameBuildEvents.append($0) })
        let unchanged = try sameBuild.install(candidate: a, reviewed: identityA)
        try check(unchanged["action"] as? String == "already-installed" && installer.listBackups().count == backupCount && !sameBuildEvents.contains { $0.contains("library") }, "an identical signed build skips quit probing, library scans, backup and replacement")

        let b = try bundle("b", revision: String(repeating: "b", count: 40))
        let identityB = try StagingInstaller.identify(b)
        let second = try installer.install(candidate: b, reviewed: identityB)
        let backupPath = second["backup"] as? String ?? ""
        try check(installer.installed()?.revision == identityB.revision && (try? StagingInstaller.identify(URL(fileURLWithPath: backupPath)))?.manifestSHA256 == identityA.manifestSHA256, "upgrade keeps the previous app as an exact backup")
        try check(installer.listBackups().first?.identity?.revision == identityA.revision, "backups are listed with their identities")

        let c = try bundle("c", revision: String(repeating: "d", count: 40))
        let identityC = try StagingInstaller.identify(c)
        try Data("changed after review\n".utf8).write(to: c.appendingPathComponent("Contents/Resources/marker.txt"))
        var refused = false
        do { _ = try installer.install(candidate: c, reviewed: identityC) } catch { refused = error.localizedDescription.contains("changed after you reviewed") }
        try check(refused && installer.installed()?.revision == identityB.revision, "a candidate changed after review is refused; installed app unchanged")
        let unsigned = try bundle("unsigned", revision: String(repeating: "e", count: 40), sign: false)
        let identityUnsigned = try StagingInstaller.identify(unsigned)
        refused = false
        do { _ = try installer.install(candidate: unsigned, reviewed: identityUnsigned) } catch { refused = error.localizedDescription.contains("signature") }
        try check(!identityUnsigned.signatureValid && refused && installer.installed()?.revision == identityB.revision, "an unsigned candidate is refused")

        // A running Staging app blocks replacement.
        let sleeper = try bundle("sleeper", revision: String(repeating: "f", count: 40), executable: "/bin/sleep")
        let identitySleeper = try StagingInstaller.identify(sleeper)
        _ = try installer.install(candidate: sleeper, reviewed: identitySleeper)
        let running = Process(); running.executableURL = installer.target.appendingPathComponent("Contents/MacOS/Silkwire"); running.arguments = ["30"]
        try running.run()
        Thread.sleep(forTimeInterval: 0.3)
        refused = false
        do { _ = try installer.install(candidate: b, reviewed: identityB) } catch { refused = error.localizedDescription.contains("is open") }
        running.terminate(); running.waitUntilExit()
        try check(refused && installer.installed()?.revision == identitySleeper.revision, "an open Staging app is never replaced")

        // Recovery restores a backup and keeps what it replaces.
        guard let backupA = installer.listBackups().first(where: { $0.identity?.revision == identityA.revision }) else { throw nativeFailure("Backup A missing") }
        let before = installer.listBackups().count
        let recovered = try installer.recover(backup: backupA, reviewed: backupA.identity!)
        try check(installer.installed()?.manifestSHA256 == identityA.manifestSHA256 && installer.listBackups().count == before + 1 && files.fileExists(atPath: backupA.path.path), "recovery restores the backup, keeps the replaced app, and keeps the backup")
        try check((recovered["installed"] as? [String: Any])?["revision"] as? String == identityA.revision && files.fileExists(atPath: recovered["receiptPath"] as? String ?? ""), "recovery receipt confirms the restored revision")
        let outside = StagingInstaller.Backup(path: b, identity: identityB, savedAt: nil)
        refused = false
        do { _ = try installer.recover(backup: outside, reviewed: identityB) } catch { refused = true }
        try check(refused && installer.installed()?.revision == identityA.revision, "recovery only accepts bundles from the backups folder")

        // Provenance: a build matches the finished workspace commit by source digest.
        let workspace = fixture.appendingPathComponent("worktree")
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("print(1)\n".utf8).write(to: workspace.appendingPathComponent("main.swift"))
        try Data("output/\n".utf8).write(to: workspace.appendingPathComponent(".gitignore"))
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-q", "-m", "fixture"]] {
            guard try shell("/usr/bin/git", args, at: workspace) == 0 else { throw nativeFailure("git fixture failed") }
        }
        try files.createDirectory(at: workspace.appendingPathComponent("output"), withIntermediateDirectories: true)
        try Data("build product\n".utf8).write(to: workspace.appendingPathComponent("output/ignored.bin"))
        let digest = try StagingInstaller.sourceDigest(workspace)
        try check(digest.clean && digest.digest.count == 64, "source digest ignores ignored build output")
        var built = identityA; built.sourceDigest = digest.digest
        let receipt: [String: Any] = ["id": UUID().uuidString, "owner": "codex", "status": "review", "transfer": ["headCommit": digest.headCommit]]
        try check(StagingInstaller.provenance(of: built, receipt: receipt, worktree: workspace).builtFromHead == true, "candidate built from the finished head is identified as exactly that commit")
        try Data("print(2)\n".utf8).write(to: workspace.appendingPathComponent("main.swift"))
        try check(StagingInstaller.provenance(of: built, receipt: receipt, worktree: workspace).builtFromHead == false, "a later source change is reported as a mismatch")
        built.sourceDigest = ""
        try check(StagingInstaller.provenance(of: built, receipt: receipt, worktree: workspace).builtFromHead == nil, "a build without a digest is reported as unmatched, not assumed")

        let variantInstaller = StagingInstaller(applications: fixture.appendingPathComponent("different-bytes/Applications"))
        _ = try variantInstaller.install(candidate: a, reviewed: identityA)
        let variant = try bundle("same-revision-different-bytes", revision: identityA.revision)
        let variantID = try StagingInstaller.identify(variant)
        let replaced = try variantInstaller.install(candidate: variant, reviewed: variantID)
        try check(replaced["action"] as? String == "install" && variantInstaller.installed()?.manifestSHA256 == variantID.manifestSHA256 && variantID.manifestSHA256 != identityA.manifestSHA256, "a matching revision with different signed bytes still takes the full backup/install path")

        // Parity with Scripts/build.swift when a fresh Staging build of this checkout exists.
        let local = URL(fileURLWithPath: files.currentDirectoryPath)
        let staged = local.appendingPathComponent("output/staging/Silkwire Staging.app")
        if let identity = try? StagingInstaller.identify(staged), !identity.sourceDigest.isEmpty, let current = try? StagingInstaller.sourceDigest(local), current.digest == identity.sourceDigest {
            try check(true, "build.swift and the installer compute the same source digest for this checkout")
        } else { print("SKIP build/installer digest parity: build digest \((try? StagingInstaller.identify(staged))?.sourceDigest ?? "none"), checkout digest \((try? StagingInstaller.sourceDigest(local))?.digest ?? "unreadable"). Equal only right after swift Scripts/build.swift --staging with no later source edits.") }
        print("\(passed) Staging install checks passed. Synthetic fixture: \(fixture.path)")
    }
}
