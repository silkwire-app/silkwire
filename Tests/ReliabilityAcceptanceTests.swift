import Foundation

@main struct ReliabilityAcceptanceTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL " + label) }
            checks += 1; print("PASS " + label)
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-reliability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var watchdog = EveConnectionWatchdog(now: 0)
        try check(!watchdog.isDead(at: 1, tickSeconds: 30), "healthy watchdog")
        try check(!watchdog.isDead(at: 70, tickSeconds: 30), "delayed processing gets bounded catch-up")
        try check(!watchdog.isDead(at: 74.9, tickSeconds: 30), "queued frames get the entire five-second window")
        try check(watchdog.isDead(at: 81, tickSeconds: 30), "a second freeze cannot renew grace without a real frame")
        var recovery = EveConnectionWatchdog(now: 0)
        _ = recovery.isDead(at: 70, tickSeconds: 30)
        recovery.receivedFrame(at: 72)
        try check(!recovery.isDead(at: 76, tickSeconds: 30), "an incoming frame recovers the actual watchdog policy")
        _ = recovery.isDead(at: 140, tickSeconds: 30)
        try check(recovery.isDead(at: 145, tickSeconds: 30), "a later genuine disconnect expires at the bounded deadline")
        var dead = EveConnectionWatchdog(now: 0)
        for second in 1...60 { try check(!dead.isDead(at: Double(second), tickSeconds: 30), "regular watchdog tick \(second)") }
        try check(dead.isDead(at: 61, tickSeconds: 30), "genuine disconnection has no extra grace when the UI was responsive")

        let sandbox = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("Staging"))
        var project = Project(); project.name = "Authorized fixture"
        project.trustedStaging = true
        var conversation = Conversation(); conversation.projectID = project.id
        conversation.identities["eve"] = ProviderIdentity(id: "synthetic-session", started: true)
        conversation.draft = "Diagnostic draft"
        project.folders = [ProjectFolder(name: "fixture", path: root.path, bookmark: Data([1]), builderAllowed: true)]
        var workspace = ConversationWorkspace(activeID: conversation.id, conversations: [conversation], projects: [project]); workspace.environment = "staging"
        try FileManager.default.createDirectory(at: sandbox.library, withIntermediateDirectories: true)
        let foreignProject = Project()
        var foreignRoom = Conversation(); foreignRoom.projectID = foreignProject.id; foreignRoom.draft = "PRIVATE-OTHER-PROJECT"
        workspace.projects.append(foreignProject); workspace.conversations.append(foreignRoom)
        let original = try JSONEncoder().encode(workspace)
        try original.write(to: sandbox.library.appendingPathComponent("workspace.json"))
        let diagnosticWorktree = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: diagnosticWorktree, withIntermediateDirectories: true)
        let copied = diagnosticWorktree.appendingPathComponent("output/diagnostics/fixture")
        let copyReceipt = try StagingDiagnosticCopy.create(library: sandbox.library, destination: copied, projectID: project.id, workspace: diagnosticWorktree)
        let copy = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: copied.appendingPathComponent("workspace.json")))
        try check(try Data(contentsOf: sandbox.library.appendingPathComponent("workspace.json")) == original, "diagnostics never writes the original")
        try check(copy.projects.count == 1 && copy.conversations.count == 1 && !String(decoding: try Data(contentsOf: copied.appendingPathComponent("workspace.json")), as: UTF8.self).contains("PRIVATE-OTHER-PROJECT"), "diagnostics cannot expose another Project’s private conversations")
        try check(copyReceipt["sourceSnapshotSHA256"] == StagingInstaller.sha(original), "diagnostic receipt identifies the exact source snapshot")
        try check(copy.conversations[0].draft == conversation.draft && copy.conversations[0].identities.isEmpty && copy.projects[0].connectedFolders.isEmpty && copy.projects[0].trustedStaging == false, "copied content carries no provider identities or standing permissions")

        let escaped = root.appendingPathComponent("escape-worktree"), outside = root.appendingPathComponent("outside-protected-fixture")
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escaped.appendingPathComponent("output"), withDestinationURL: outside)
        var escapedCopyRefused = false
        do { _ = try StagingDiagnosticCopy.create(library: sandbox.library, destination: escaped.appendingPathComponent("output/diagnostics/attempt"), projectID: project.id, workspace: escaped) }
        catch { escapedCopyRefused = true }
        try check(escapedCopyRefused && (try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty, "a workspace-created output link cannot redirect a privileged diagnostic write")
        let linkedWorkspace = root.appendingPathComponent("linked-worktree")
        try FileManager.default.createSymbolicLink(at: linkedWorkspace, withDestinationURL: outside)
        var linkedRootRefused = false
        do { _ = try StagingDiagnosticCopy.create(library: sandbox.library, destination: linkedWorkspace.appendingPathComponent("output/diagnostics/attempt"), projectID: project.id, workspace: linkedWorkspace) }
        catch { linkedRootRefused = true }
        try check(linkedRootRefused && (try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty, "a replaced worktree root cannot redirect diagnostics")

        let storage = root.appendingPathComponent("Team Workspaces")
        let artifacts = ProjectArtifactStore(storage: storage, projectID: project.id)
        let foreign = ProjectArtifactStore(storage: storage, projectID: UUID())
        let id = UUID().uuidString
        let finished = root.appendingPathComponent("archived-room/codex/" + id)
        try FileManager.default.createDirectory(at: finished.appendingPathComponent("transfer"), withIntermediateDirectories: true)
        let bundle = Data("synthetic-transfer".utf8), patch = Data("synthetic-diff".utf8)
        try bundle.write(to: finished.appendingPathComponent("transfer/changes.bundle"))
        try patch.write(to: finished.appendingPathComponent("transfer/changes.patch"))
        let receipt: [String: Any] = ["id": id, "owner": "codex", "status": "review", "finishedAt": "2026-10-28T00:00:00Z", "task": "PRIVATE-TRANSCRIPT-SENTINEL", "identities": ["eve": "PRIVATE-IDENTITY"], "trustedFolderIDs": ["PRIVATE-GRANT"], "steps": [["command": "fixture", "status": "passed", "exitCode": 0, "output": "PRIVATE-RAW-OUTPUT"]], "agentSummary": "PRIVATE-SUMMARY", "diff": "reviewable source diff", "diffTruncated": false,
            "transfer": ["available": true, "headCommit": String(repeating: "a", count: 40), "baseCommit": String(repeating: "b", count: 40), "bundleSha256": StagingInstaller.sha(bundle), "patchSha256": StagingInstaller.sha(patch)]]
        try artifacts.record(receipt, from: finished)
        try check(artifacts.saved(id) != nil && foreign.saved(id) == nil, "finished archived-room output is reusable only within its Project")
        let shared = artifacts.saved(id)!
        let sharedBytes = try Data(contentsOf: shared.root.appendingPathComponent("receipt.json"))
        try check(!String(decoding: sharedBytes, as: UTF8.self).contains("PRIVATE-"), "sharing outputs excludes task prompts, identities and room grants")
        try check(try Data(contentsOf: shared.root.appendingPathComponent("transfer/changes.bundle")) == bundle, "shared transfer bytes are retained and hash checked")
        let reader = NativeProjectAccess(); reader.updateArtifacts(artifacts.artifacts())
        let catalog = try reader.perform(NativeProjectReadRequest(action: "artifacts"))
        try check(catalog["total"] as? Int == 1 && reader.hasArtifact(id), "another room can discover the Project output through the read-only broker")

        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "source feature to retain\n".write(to: source.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        func git(_ args: [String], at directory: URL) throws {
            let result = Process(); result.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            result.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "-c", "commit.gpgsign=false"] + args
            result.currentDirectoryURL = directory; result.standardOutput = FileHandle.nullDevice; result.standardError = FileHandle.nullDevice
            try result.run(); result.waitUntilExit(); try check(result.terminationStatus == 0, "source fixture git " + args[0])
        }
        try git(["init", "-q"], at: source); try git(["add", "feature.txt"], at: source); try git(["commit", "-qm", "Retained feature"], at: source)
        let digest = try StagingInstaller.sourceDigest(source), archive = root.appendingPathComponent("source.bundle")
        let privateTestArea = root.appendingPathComponent("assigned-runtime-data")
        try FileManager.default.createDirectory(at: privateTestArea, withIntermediateDirectories: true)
        _ = try StagingDiagnosticCopy.create(library: sandbox.library, destination: privateTestArea.appendingPathComponent("output/diagnostics/private-copy"), projectID: project.id, workspace: privateTestArea)
        try git(["add", "-A"], at: source)
        let afterDiagnostics = try StagingInstaller.sourceDigest(source)
        try check(afterDiagnostics.clean && afterDiagnostics.digest == digest.digest, "diagnostic transcripts cannot enter a source checkpoint, transfer or build archive even without a repository output ignore rule")
        try git(["bundle", "create", archive.path, "HEAD"], at: source)
        let manifest = StagingSourceArchive.Manifest(revision: digest.headCommit, sourceDigest: digest.digest, bundleSHA256: StagingInstaller.sha(try Data(contentsOf: archive)))
        let restored = try StagingSourceArchive.restore(archive: archive, manifest: manifest, destination: root.appendingPathComponent("recovered"))
        try check(try StagingInstaller.sourceDigest(restored).digest == digest.digest, "installed source recovery preserves the exact source digest and revision")
        do { _ = try StagingSourceArchive.restore(archive: archive, manifest: manifest, destination: restored); throw nativeFailure("Existing source overwritten") }
        catch { try check(try StagingInstaller.sourceDigest(restored).digest == digest.digest, "recovery refuses to overwrite an existing checkout or unfinished branch") }

        // A queued broker operation must recheck the current grant before it starts.
        let coordinator = NativeTrustedWorkspaces(storage: sandbox.library.appendingPathComponent("Queued Work"), sandbox: sandbox, ownership: HostOwnershipDefault.coordinator, receipt: { _, _ in })
        try FileManager.default.createDirectory(at: sandbox.sources.appendingPathComponent("queued-source"), withIntermediateDirectories: true)
        let queuedSource = sandbox.sources.appendingPathComponent("queued-source")
        try FileManager.default.createDirectory(at: queuedSource, withIntermediateDirectories: true)
        try coordinator.configure(grants: [NativeProjectFolderGrant(id: "source", name: "source", root: queuedSource)], trustedIDs: ["source"])
        let queued = Task { @MainActor in
            do { _ = try await coordinator.perform(["action": "begin", "folderId": "source"], agent: "codex", task: "Queued before revocation"); return false }
            catch { return error.localizedDescription.contains("not granted") }
        }
        try coordinator.configure(grants: [], trustedIDs: [])
        let refused = await queued.value
        try check(refused && !coordinator.active("codex"), "revocation refuses a previously queued operation before workspace creation")

        // Exercise the Staging environment itself: the former default depended on it.
        do {
            let freshEnvironment = WorkspaceEnvironment(staging: true, library: root.appendingPathComponent("fresh-staging"))
            let fresh = ConversationStore(directory: freshEnvironment.library, environment: freshEnvironment, workspaceSandbox: sandbox)
            try check(fresh.storageError == nil && !fresh.trustsStaging(fresh.activeProject!), "fresh Staging itself starts cautious, with no implicit environment grant")
        }
        // Real store persistence: defaults, Project-wide standing grant, restart, and revocation.
        let grantsLibrary = root.appendingPathComponent("grants")
        var projectID: UUID!
        do {
            let store = ConversationStore(directory: grantsLibrary, workspaceSandbox: sandbox)
            try check(!store.trustsStaging(store.activeProject!), "fresh install starts cautious")
            store.persistenceWriter = { data, url in
                precondition(!Thread.isMainThread, "A synchronous durability boundary must still encode and write off-main")
                try data.write(to: url, options: .atomic)
            }
            try check(store.save(), "synchronous durability boundaries perform their actual persistence work off-main")
            var granted = store.activeProject!; granted.trustedStaging = true; projectID = granted.id
            try check(store.updateProject(granted, reconnect: false), "explicit standing access can be saved")
            try check(store.newConversation(reconnect: false) && store.trustsStaging(store.activeProject!), "another room in the same Project retains the grant")
        }
        do {
            let store = ConversationStore(directory: grantsLibrary, workspaceSandbox: sandbox)
            try check(store.trustsStaging(store.activeProject!), "standing access survives restart")
            await store.revokeStagingAccess(projectID)
            try check(!store.trustsStaging(store.activeProject!), "revocation immediately removes standing access")
        }
        do {
            let store = ConversationStore(directory: grantsLibrary, workspaceSandbox: sandbox)
            try check(!store.trustsStaging(store.activeProject!), "revocation survives restart")
        }
        print("\(checks) reliability acceptance checks passed. Synthetic fixture: \(root.path)")
    }
}
