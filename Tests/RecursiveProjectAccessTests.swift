import Foundation

@main struct RecursiveProjectAccessTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL " + label) }
            checks += 1; print("PASS " + label)
        }
        func refused(_ operation: () async throws -> Void) async -> Bool {
            do { try await operation(); return false } catch { print("Expected refusal: " + error.localizedDescription); return true }
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-recursive-" + UUID().uuidString)
        let projects = fixture.appendingPathComponent("Projects"), source = projects.appendingPathComponent("Team/Example")
        let outside = fixture.appendingPathComponent("Documents/Codex/handoff/outputs"), library = fixture.appendingPathComponent("Staging")
        for directory in [source, outside, library] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let content = Data("hello project\n".utf8)
        try content.write(to: source.appendingPathComponent("feature.txt"))
        try Data("Review the exact candidate.\n".utf8).write(to: outside.appendingPathComponent("review-report.txt"))
        let environment = WorkspaceEnvironment(staging: true, library: library)
        try check(environment.permitsReading(projects) && environment.permitsReading(outside), "entire Projects and a separate Documents handoff folder can be explicitly granted")
        try check(!environment.permitsReading(fm.homeDirectoryForCurrentUser) && !environment.permitsReading(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")), "broad home and live application libraries stay outside routine grants")
        let id = UUID().uuidString.lowercased(), grant = NativeProjectFolderGrant(id: id, name: "All Projects", root: projects)
        let reader = NativeProjectAccess()
        let request = NativeProjectReadRequest(action: "read", folderID: id, path: "Team/Example/feature.txt", startLine: 1, lineCount: 100)
        try check(await refused { _ = try reader.perform(request) }, "eligible paths alone grant no broker access")
        reader.update(grants: [grant])
        let read = try reader.perform(request)
        try check((read["lines"] as? [String])?.first == "1: hello project", "one Projects grant reads a repository several subfolders below it")
        let selected = try NativeScopedRoot(projects).directoryURL("Team/Example")
        try check(selected.path == NativeScopedRoot(source).root.path, "workspace source selection uses a relative repository under the same recursive grant")
        try fm.createSymbolicLink(at: projects.appendingPathComponent("escape"), withDestinationURL: outside)
        try check(await refused { _ = try NativeScopedRoot(projects).directoryURL("escape") }, "recursive source selection cannot follow a link outside its grant")
        try check(await refused { _ = try NativeScopedRoot(projects).directoryURL("../Documents") }, "recursive source selection cannot escape through a parent path")
        reader.update(grants: [])
        try check(await refused { _ = try reader.perform(request) }, "removing the root grant blocks its descendants")

        // Real persistence with ordinary bookmarks; native security-scope issuance
        // is covered separately by NativeBookmarkTests, never faked as passing here.
        do {
            let store = ConversationStore(environment: environment, workspaceSandbox: environment)
            var project = store.activeProject!
            project.trustedStaging = true
            project.folders = [ProjectFolder(name: "All Projects", path: projects.path, bookmark: try projects.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), builderAllowed: true)]
            try check(store.updateProject(project, reconnect: false), "save a standing recursive read/edit/build/test grant")
            try check(store.newConversation(reconnect: false) && store.trustedStagingAvailable, "a new room retains the same root grant")
            store.shutdown()
        }
        do {
            let store = ConversationStore(environment: environment, workspaceSandbox: environment)
            let folder = store.activeProject!.connectedFolders[0]
            let resolved = try nativeResolveProjectFolder(folder)
            try check(try NativeScopedRoot(resolved).root.path == NativeScopedRoot(projects).root.path && store.trustedStagingAvailable, "restart resolves the original bookmark and retains trusted recursive access")
            await store.revokeStagingAccess(store.activeProject!.id)
            try check(!store.trustedStagingAvailable, "revoking trusted execution disables work across the recursive root")
            store.shutdown()
        }

        let gitEnvironment = ["PATH": "/usr/bin:/bin", "HOME": fixture.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
        func git(_ args: [String]) async throws -> String {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null"] + args, directory: source, environment: gitEnvironment)
            guard result.exitCode == 0 else { throw nativeFailure(result.stderr) }; return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q"]); _ = try await git(["add", "feature.txt"])
        _ = try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-qm", "Example"])
        let revision = try await git(["rev-parse", "HEAD"]), before = try await git(["show-ref"])
        let bundle = outside.appendingPathComponent("candidate.bundle")
        _ = try await git(["bundle", "create", bundle.path, "HEAD"])
        let hash = NativeScopedRoot.sha256(try Data(contentsOf: bundle))
        let restored = try await StagingBundleImport.restore(root: outside, path: "candidate.bundle", revision: revision, sha256: hash, destination: fixture.appendingPathComponent("imported"))
        let identity = try StagingInstaller.sourceDigest(restored)
        try check(identity.headCommit == revision && identity.clean && (try Data(contentsOf: restored.appendingPathComponent("feature.txt"))) == content, "outside bundle imports exact clean committed source into a new private directory")
        try check(try await git(["show-ref"]) == before && (try Data(contentsOf: source.appendingPathComponent("feature.txt"))) == content, "bundle import leaves original files and branches unchanged")
        try check(await refused { _ = try await StagingBundleImport.restore(root: outside, path: "candidate.bundle", revision: revision, sha256: String(repeating: "0", count: 64), destination: fixture.appendingPathComponent("wrong-hash")) }, "mismatched bundle hash is refused")
        try check(!fm.fileExists(atPath: fixture.appendingPathComponent("wrong-hash").path), "mismatched input creates no destination")
        try check(await refused { _ = try await StagingBundleImport.restore(root: outside, path: "candidate.bundle", revision: String(repeating: "0", count: 40), sha256: hash, destination: fixture.appendingPathComponent("wrong-revision")) }, "missing exact revision cannot substitute an older source")
        try fm.createSymbolicLink(at: outside.appendingPathComponent("linked.bundle"), withDestinationURL: bundle)
        try check(await refused { _ = try await StagingBundleImport.restore(root: outside, path: "linked.bundle", revision: revision, sha256: hash, destination: fixture.appendingPathComponent("linked-import")) }, "bundle imports cannot follow file links")
        var authorizations = 0
        try check(await refused {
            _ = try await StagingBundleImport.restore(root: outside, path: "candidate.bundle", revision: revision, sha256: hash, destination: fixture.appendingPathComponent("revoked"), authorize: {
                authorizations += 1
                if authorizations > 2 { throw nativeFailure("Grant revoked") }
            })
        }, "import rechecks authorization before starting each Git operation")
        try check(!fm.fileExists(atPath: fixture.appendingPathComponent("revoked/source/.git").path), "revoked import cannot initialize or check out a repository")
        let coordinator = NativeTrustedWorkspaces(storage: library.appendingPathComponent("Team Workspaces/test"), sandbox: environment, ownership: HostOwnershipDefault.coordinator, receipt: { _, _ in })
        try coordinator.configure(grants: [NativeProjectFolderGrant(id: id, name: "Handoff", root: outside)], trustedIDs: [])
        try check(await refused { _ = try await coordinator.perform(["action": "begin", "folderId": id, "bundle": "candidate.bundle", "revision": revision, "sha256": hash], agent: "codex", task: "Review candidate") }, "read access alone cannot import source or begin execution")

        if let actualPath = ProcessInfo.processInfo.environment["SILKWIRE_HANDOFF_DIRECTORY"] {
            let actual = URL(fileURLWithPath: actualPath)
            try check(environment.permitsReading(actual), "actual Codex outputs directory is eligible for an explicit saved grant")
            let actualReader = NativeProjectAccess()
            actualReader.update(grants: [NativeProjectFolderGrant(id: id, name: "Outside review", root: actual)])
            for name in ["review-report.txt", "review-receipt.json"] {
                let result = try actualReader.perform(NativeProjectReadRequest(action: "read", folderID: id, path: name, startLine: 1, lineCount: 100))
                try check(!(result["lines"] as? [String] ?? []).isEmpty, "production Project broker reads actual handoff file: " + name)
            }
            let saved = try JSONSerialization.jsonObject(with: NativeScopedRoot(actual).readData("review-receipt.json")) as! [String: Any]
            let savedHead = saved["headRevision"] as! String
            let savedHash = ((saved["artifacts"] as! [String: Any])["silkwire-staging-review.bundle"] as! [String: Any])["sha256"] as! String
            let handoff = try await StagingBundleImport.restore(root: actual, path: "silkwire-staging-review.bundle", revision: savedHead, sha256: savedHash, destination: fixture.appendingPathComponent("actual-handoff"))
            try check(try StagingInstaller.sourceDigest(handoff).headCommit == savedHead, "production importer restores the actual outside-Codex handoff bundle at its receipt revision")
        }
        print("RecursiveProjectAccessTests: \(checks) checks passed. No live app grants, accounts or libraries changed; no native command execution claimed.")
    }
}
