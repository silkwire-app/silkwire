import Foundation
import Darwin

// The command bridge in front of the REAL native Builder job adapter
// (HostNativeBuilderJobs, NativeBuilder's isolated Git preparation and Seatbelt
// commands). A teammate's finished private workspace is the source. Also checks the
// bridge's refusals directly. Commands are /usr/bin/true. No provider or network.
// Requires a host that may apply sandbox-exec, as the other native suites do.
@main struct BackgroundJobNativeBridgeTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let files = FileManager.default
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        let fixture = try NativeTemporaryDirectory.canonical(files.temporaryDirectory).appendingPathComponent("silkwire-job-bridge-" + UUID().uuidString)
        defer { try? files.removeItem(at: fixture) }
        let projects = fixture.appendingPathComponent("Projects"), source = projects.appendingPathComponent("Example")
        let library = fixture.appendingPathComponent("Staging")
        for directory in [source, library] { try files.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("synthetic\n".utf8).write(to: source.appendingPathComponent("README.md"))
        let env = ["PATH": "/usr/bin:/bin", "HOME": fixture.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        func git(_ args: [String], in directory: URL = source) async throws -> String {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null"] + args, directory: directory, environment: env)
            guard result.exitCode == 0 else { throw nativeFailure(result.stderr) }; return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q"]); _ = try await git(["add", "."])
        _ = try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-qm", "Example"])

        let room = UUID(), projectID = UUID()
        let coordinator = HostExecutionCoordinator(directory: fixture.appendingPathComponent("registry"))
        let storage = library.appendingPathComponent("Team Workspaces/staging/" + room.uuidString.lowercased())
        let grant = NativeProjectFolderGrant(id: "projects", name: "Projects", root: projects)
        let workspaces = NativeTrustedWorkspaces(storage: storage, sandbox: WorkspaceEnvironment(staging: true, library: library), ownership: coordinator, conversationID: room,
            verifyPhysicalExit: { _ in .verified(evidence: "fixture: this workspace ran no commands; its host Git operations were awaited") }, receipt: { _, _ in })
        try workspaces.configure(grants: [grant], trustedIDs: [grant.id])
        _ = try await workspaces.perform(["action": "begin", "folderId": grant.id, "path": "Example"], agent: "codex", task: "Prepare a candidate")
        _ = try await workspaces.perform(["action": "write", "path": "change.txt", "content": "candidate\n", "expectedSha256": NSNull()], agent: "codex", task: "Continue")
        let checkpoint = try await workspaces.perform(["action": "checkpoint", "summary": "Candidate"], agent: "codex", task: "Continue")
        let finished = try await workspaces.perform(["action": "finish", "summary": "Candidate"], agent: "codex", task: "Finish")
        guard let workspaceID = (finished["id"] as? String).flatMap(UUID.init(uuidString:)), let worktree = finished["worktreePath"] as? String else { print("FAIL: workspace fixture"); exit(1) }
        let worktreeURL = URL(fileURLWithPath: worktree).resolvingSymlinksInPath()
        check(finished["status"] as? String == "review" && !workspaces.active("codex"), "a teammate's private workspace is finished, releasing its slot")

        // The bridge, reading this room's storage and a job card's exact request.
        let jobID = UUID()
        var request = "{\"action\":\"run\",\"checks\":[{\"name\":\"build\",\"command\":\"/usr/bin/true\"},{\"name\":\"test\",\"command\":\"/usr/bin/true\"}]}"
        var refusals: [String] = []
        let bridge = BackgroundJobCommandBridge(library: { $0 == room ? .init(projectID: projectID, storage: storage) : nil },
            requested: { job, conversation in job == jobID && conversation == room ? ("codex", workspaceID, request) : nil },
            refused: { _, _, reason in refusals.append(reason) })
        let scope = try await bridge.scope(conversationID: room, workspaceID: workspaceID, agentID: "codex")
        check(scope.sourceRevision == checkpoint["headCommit"] as? String && scope.projectID == projectID && scope.workspaceID == workspaceID, "the scope is the workspace's exact committed revision")
        check(await bridge.authorize(scope), "authorize re-resolves the same scope")
        let context = BackgroundWorkContext(item: BackgroundWorkItem(id: jobID, scope: scope, sessionID: UUID(), title: "Run build and test checks", limits: .init(totalSteps: 1, stepsPerSlice: 1)), stepID: UUID(), mayPerformOperation: { true })
        let planned = try? await bridge.plan(context)
        check(planned?.source.path == worktreeURL.path && planned?.build == "/usr/bin/true" && planned?.test == "/usr/bin/true" && planned?.edit == false, "the plan is the requested build and test in the teammate's own worktree")

        // Refusals, each with a plain reason, for untrusted request data.
        func refused(_ json: String, _ expect: String, _ label: String) async {
            request = json; refusals = []
            let failed = (try? await bridge.plan(context)) == nil
            check(failed && refusals.last?.contains(expect) == true, label + " (" + (refusals.last ?? "no reason") + ")")
        }
        await refused("{\"action\":\"write\",\"path\":\"x\"}", "only take WORK_PROJECT run steps", "a non-run step is refused")
        await refused("{\"action\":\"run\",\"command\":\"true\",\"path\":\"/etc\"}", "fields Silkwire doesn't accept", "an extra field (such as a path) is refused")
        await refused("{\"action\":\"run\",\"checks\":[{\"name\":\"lint\",\"command\":\"true\"}]}", "\"lint\" isn't one of them", "a check other than build/test is refused")
        await refused("{\"action\":\"run\",\"checks\":[{\"name\":\"build\",\"command\":\"a\"},{\"name\":\"test\",\"command\":\"b\"},{\"name\":\"x\",\"command\":\"c\"}]}", "at most two", "more than two checks are refused")
        await refused("{\"action\":\"run\",\"command\":\"   \"}", "1–4,000 characters", "an empty command is refused")
        await refused("not json", "isn't readable WORK_PROJECT JSON", "unreadable JSON is refused")
        let otherAgent = BackgroundWorkContext(item: BackgroundWorkItem(id: jobID, scope: BackgroundWorkScope(projectID: projectID, conversationID: room, workspaceID: workspaceID, agentID: "claude", sourceRevision: scope.sourceRevision), sessionID: UUID(), title: "x", limits: .init(totalSteps: 1, stepsPerSlice: 1)), stepID: UUID(), mayPerformOperation: { true })
        request = "{\"action\":\"run\",\"command\":\"/usr/bin/true\"}"; refusals = []
        check((try? await bridge.plan(otherAgent)) == nil && refusals.last?.contains("different teammate") == true, "a scope for another teammate is refused")
        check((try? await bridge.scope(conversationID: room, workspaceID: workspaceID, agentID: "claude")) == nil, "a teammate can't claim another teammate's workspace")
        check((try? await bridge.scope(conversationID: UUID(), workspaceID: workspaceID, agentID: "codex")) == nil, "a workspace from another conversation is refused")
        try Data("dirty\n".utf8).write(to: worktreeURL.appendingPathComponent("untracked.txt"))
        refusals = []
        check((try? await bridge.plan(context)) == nil && refusals.last?.contains("uncommitted changes") == true, "an uncommitted change is refused")
        check(!(await bridge.authorize(scope)), "and authorization fails while it's there")
        try files.removeItem(at: worktreeURL.appendingPathComponent("untracked.txt"))
        check(await bridge.authorize(scope), "authorization returns once it's clean again")
        check(BackgroundJobCommandBridge.eligible(["action": "run", "command": "swift build"]) && !BackgroundJobCommandBridge.eligible(["action": "run", "checks": [["name": "lint", "command": "x"]]]), "the room hands off only runs the bridge accepts")

        // The real native Builder job adapter, behind the real host service.
        request = "{\"action\":\"run\",\"checks\":[{\"name\":\"build\",\"command\":\"/usr/bin/true\"},{\"name\":\"test\",\"command\":\"/usr/bin/true\"}]}"
        let ledger = fixture.appendingPathComponent("ledger"), runs = fixture.appendingPathComponent("runs")
        try files.createDirectory(at: ledger, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let verification = BackgroundJobExitVerification(coordinator: coordinator)
        let native = HostNativeBuilderJobs(coordinator: coordinator, storageRoot: runs, plan: { try await bridge.plan($0) },
            verifyExit: { await verification.verifyExit($0) })
        let execution = HostBackgroundExecution(coordinator: coordinator, resolve: { try await bridge.resolve($0) }, cancel: native.cancel, join: native.join)
        let service = try await HostBackgroundJobService.open(storage: BackgroundWorkStorageSession.open(directory: ledger, projectID: projectID, conversationID: room),
            execution: execution, verifyRecovery: verification.verifyRecovery, authorize: { await bridge.authorize($0) }, execute: native.execute)
        let id = try await service.submit(.init(operationID: jobID, scope: scope, workDescription: "Run build and test checks", limits: .init(totalSteps: 1, stepsPerSlice: 1)))
        let deadline = Date().addingTimeInterval(120)
        while ![.completed, .failed, .needsReview].contains(service.snapshot(id)?.state) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let receiptFile = (try? files.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil))?.first?.appendingPathComponent("receipt.json")
        let receipt = receiptFile.flatMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] } ?? [:]
        let steps = receipt["steps"] as? [[String: Any]] ?? []
        check(URL(fileURLWithPath: receipt["sourcePath"] as? String ?? "").resolvingSymlinksInPath().path == worktreeURL.path && receipt["baseCommit"] as? String == scope.sourceRevision,
              "NativeBuilder cloned the teammate's finished worktree at the authorized revision")
        check(steps.count == 2 && steps.allSatisfy { $0["status"] as? String == "passed" } && receipt["sourceUnchanged"] as? Bool == true, "it ran the exact build and test in its isolated copy and left the source unchanged")
        let held = try await service.heldPhysicalOperations()
        check(service.snapshot(id)?.state == .completed && service.pendingResults.count == 1 && held.isEmpty
              && (receipt["physicalCleanup"] as? [String: Any])?["policy"] as? String == "sandboxed-private-practical-release"
              && (receipt["physicalCleanup"] as? [String: Any])?["kernelWholeWorkloadProof"] as? Bool == false,
              "successful sandboxed job publishes its real result and releases with explicitly practical cleanup evidence")
        check(try await coordinator.storage.snapshot().filter(\.holdsResources).isEmpty,
              "native job cleanup leaves no held admission from either exact execution")
        try await service.shutdown()
        if failures > 0 { print("Receipt: " + ((try? nativeJSON(receipt.filter { ["status", "message", "sourcePath", "baseCommit", "sourceUnchanged"].contains($0.key) })) ?? "")) }
        print("BackgroundJobNativeBridgeTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
