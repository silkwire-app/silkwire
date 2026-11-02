import Foundation

// End-to-end host workflow on a synthetic source: task claims, checkpoint, finish,
// independent full-diff review, reviewed integration and handoff. No live agents.
@main struct ReviewedIntegrationTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0
        func check(_ valid: Bool, _ name: String) throws {
            guard valid else { throw nativeFailure("FAIL " + name) }
            passed += 1; print("PASS " + name)
        }
        let stage = try NativeTemporaryDirectory.canonical(FileManager.default.temporaryDirectory).appendingPathComponent("silkwire-reviewed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        let env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        func git(_ args: [String], _ directory: URL) async throws -> NativeProcessResult {
            try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: directory, environment: env)
        }
        let source = stage.appendingPathComponent("Sources/app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# Original\n".utf8).write(to: source.appendingPathComponent("README.md"))
        try Data("notes\n".utf8).write(to: source.appendingPathComponent("notes.txt"))
        for args in [["init"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-m", "Synthetic source"]] {
            guard try await git(args, source).exitCode == 0 else { throw nativeFailure("Cannot prepare synthetic Git source") }
        }
        let sourceHead = try await git(["rev-parse", "HEAD"], source).stdout
        let sandbox = WorkspaceEnvironment(staging: true, library: stage)
        let storage = stage.appendingPathComponent("Team Workspaces/staging/" + UUID().uuidString.lowercased())
        let workspaces = NativeTrustedWorkspaces(storage: storage, sandbox: sandbox, ownership: HostOwnershipDefault.coordinator, receipt: { _, _ in })
        try workspaces.configure(grants: [NativeProjectFolderGrant(id: "app", name: "App", root: source)], trustedIDs: ["app"])
        func perform(_ agent: String, _ args: [String: Any]) async throws -> [String: Any] { try await workspaces.perform(args, agent: agent, task: "Synthetic reviewed task") }
        func refused(_ agent: String, _ args: [String: Any]) async -> Bool {
            guard let result = try? await perform(agent, args) else { return true }
            return result["ok"] as? Bool == false
        }
        func write(_ agent: String, _ path: String, _ content: String) async throws {
            let read = try? await perform(agent, ["action": "read", "path": path])
            let result = try await perform(agent, ["action": "write", "path": path, "content": content, "expectedSha256": read?["sha256"] ?? NSNull()])
            guard result["ok"] as? Bool == true else { throw nativeFailure("Fixture write failed: \(result)") }
        }

        let eveBegin = try await perform("eve", ["action": "begin", "folderId": "app", "taskTitle": "Retitle README", "paths": ["README.md"]])
        let eveID = eveBegin["id"] as! String, eveTask = eveBegin["taskId"] as? String ?? ""
        try check(!eveTask.isEmpty, "begin records a shared task claim")
        try check(await refused("codex", ["action": "begin", "folderId": "app", "paths": ["README.md"]]), "overlapping claim refused while the owner works")
        try await write("eve", "README.md", "# Reviewed title\n")
        let checkpoint = try await perform("eve", ["action": "checkpoint", "summary": "Before build"])
        try check(checkpoint["ok"] as? Bool == true && (checkpoint["headCommit"] as? String)?.count == 40 && workspaces.active("eve"), "checkpoint records a head and keeps the workspace active")
        let eveDone = try await perform("eve", ["action": "finish", "summary": "Retitle README"])
        let head = (eveDone["transfer"] as? [String: Any])?["headCommit"] as? String ?? ""
        try check(head.count == 40, "finish records a transferable head")
        let saved = NativeTrustedWorkspaces.savedReceipt(storage: storage, id: eveID)!.receipt
        let diff = saved["diff"] as? String ?? "", hash = NativeScopedRoot.sha256(Data(diff.utf8))
        try check(!diff.isEmpty && !diff.contains(source.path) && !diff.contains(stage.path), "finished diff has no absolute fixture paths")

        _ = try await perform("codex", ["action": "begin", "folderId": "app", "taskTitle": "Notes", "paths": ["notes.txt"]])
        try check(await refused("codex", ["action": "integrate", "fromWorkspace": eveID]), "integration without review is refused")
        let review: [String: Any] = ["action": "review", "fromWorkspace": eveID, "headCommit": head, "diffSha256": hash, "decision": "approved", "summary": "Read full diff"]
        try check(await refused("claude", review), "review before reading the diff is refused")
        try check(await refused("eve", review), "self-review is refused")
        var start = 1
        while true {
            let page = try NativeTrustedWorkspaces.diffPage(saved, startLine: start, lineCount: 200)
            workspaces.noteDiffRead(agent: "claude", id: eveID, page: page)
            let count = (page["lines"] as? [String])?.count ?? 0
            start += count
            if count == 0 || start > page["totalLines"] as? Int ?? 0 { break }
        }
        var wrongHead = review; wrongHead["headCommit"] = String(repeating: "0", count: 40)
        try check(await refused("claude", wrongHead), "review bound to a different head is refused")
        let approved = try await perform("claude", review)
        try check((approved["review"] as? [String: Any])?["reviewer"] as? String == "claude", "independent full-diff review recorded")
        let integrated = try await perform("codex", ["action": "integrate", "fromWorkspace": eveID])
        try check(integrated["ok"] as? Bool == true && (integrated["integrationReview"] as? [String: Any])?["headCommit"] as? String == head, "reviewed integration applies the approved head and records its review")
        let merged = try await perform("codex", ["action": "read", "path": "README.md"])
        try check(merged["content"] as? String == "# Reviewed title\n", "integrated change is in the integrator's private workspace")
        let codexDone = try await perform("codex", ["action": "finish", "summary": "Integrated reviewed README"])
        let codexSaved = NativeTrustedWorkspaces.savedReceipt(storage: storage, id: codexDone["id"] as! String)!.receipt
        try check((codexSaved["reviewedIntegrations"] as? [[String: Any]])?.first?["reviewer"] as? String == "claude", "final receipt carries reviewed-integration evidence")

        try check(await refused("eve", ["action": "handoff", "taskId": eveTask, "to": "eve"]), "handoff to self refused")
        _ = try await perform("eve", ["action": "handoff", "taskId": eveTask, "to": "claude"])
        try check(await refused("codex", ["action": "begin", "folderId": "app", "taskId": eveTask]), "only the named recipient can accept a handoff")
        let accepted = try await perform("claude", ["action": "begin", "folderId": "app", "taskId": eveTask])
        try check(accepted["taskId"] as? String == eveTask, "recipient continues the same task")
        try check(await refused("claude", ["action": "release", "taskId": eveTask, "reason": "test"]), "active workspace cannot release its task")

        let finalStatus = try await git(["status", "--porcelain"], source).stdout, finalHead = try await git(["rev-parse", "HEAD"], source).stdout
        try check(finalStatus.isEmpty && finalHead == sourceHead && (try String(contentsOf: source.appendingPathComponent("README.md"), encoding: .utf8)) == "# Original\n", "connected source unchanged")
        print("PASS: \(passed) reviewed integration checks")
    }
}
