import Foundation

// Finished teammate changes move between private workspaces as verified Git
// bundles with base/head revisions, reviewable patches and conflict reports.
@main struct TransferTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0
        func check(_ valid: Bool, _ name: String) throws {
            guard valid else { throw nativeFailure("FAIL " + name) }
            passed += 1; print("PASS " + name)
        }
        let stage = try NativeTemporaryDirectory.canonical(FileManager.default.temporaryDirectory).appendingPathComponent("silkwire-transfer-" + UUID().uuidString)
        let env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        func git(_ args: [String], _ directory: URL) async throws -> NativeProcessResult {
            try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: directory, environment: env)
        }
        func repository(_ name: String, readme: String) async throws -> URL {
            let source = stage.appendingPathComponent("Sources/" + name)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(readme.utf8).write(to: source.appendingPathComponent("README.md"))
            try Data("notes\n".utf8).write(to: source.appendingPathComponent("notes.txt"))
            for args in [["init"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-m", "Synthetic source"]] {
                guard try await git(args, source).exitCode == 0 else { throw nativeFailure("Cannot prepare synthetic Git source") }
            }
            return source
        }
        let source = try await repository("app", readme: "# Original\nshared line\n")
        let unrelated = try await repository("other", readme: "# Unrelated\n")
        let sourceHead = try await git(["rev-parse", "HEAD"], source).stdout
        let sandbox = WorkspaceEnvironment(staging: true, library: stage)
        let storage = stage.appendingPathComponent("Team Workspaces/staging/" + UUID().uuidString.lowercased())
        var receipts: [String: [String: Any]] = [:]
        let workspaces = NativeTrustedWorkspaces(storage: storage, sandbox: sandbox, ownership: HostOwnershipDefault.coordinator, receipt: { _, value in if let id = value["id"] as? String { receipts[id] = value } })
        try workspaces.configure(grants: [NativeProjectFolderGrant(id: "app", name: "App", root: source), NativeProjectFolderGrant(id: "other", name: "Other", root: unrelated)], trustedIDs: ["app", "other"])
        func perform(_ agent: String, _ args: [String: Any]) async throws -> [String: Any] { try await workspaces.perform(args, agent: agent, task: "Synthetic transfer task") }
        func write(_ agent: String, _ path: String, _ content: String) async throws {
            let read = try await perform(agent, ["action": "read", "path": path])
            let result = try await perform(agent, ["action": "write", "path": path, "content": content, "expectedSha256": read["sha256"] ?? NSNull()])
            guard result["ok"] as? Bool == true else { throw nativeFailure("Fixture write failed: \(result)") }
        }

        // Two independent finished workspaces that change the same line differently.
        let eveBegin = try await perform("eve", ["action": "begin", "folderId": "app"])
        let eveID = eveBegin["id"] as! String
        try await write("eve", "README.md", "# Eve version\nshared line\n")
        let eveDone = try await perform("eve", ["action": "finish", "summary": "Retitle README for Eve"])
        let transfer = eveDone["transfer"] as? [String: Any] ?? [:]
        try check(transfer["available"] as? Bool == true && transfer["baseCommit"] as? String == sourceHead.trimmingCharacters(in: .whitespacesAndNewlines) && (transfer["headCommit"] as? String)?.count == 40 && transfer["headCommit"] as? String != transfer["baseCommit"] as? String, "finish records base and head revisions of the committed change")
        let saved = NativeTrustedWorkspaces.savedReceipt(storage: storage, id: eveID)!.receipt
        let savedTransfer = saved["transfer"] as? [String: Any] ?? [:]
        let bundle = URL(fileURLWithPath: savedTransfer["bundlePath"] as? String ?? "/missing"), patch = URL(fileURLWithPath: savedTransfer["patchPath"] as? String ?? "/missing")
        try check(NativeScopedRoot.sha256(try Data(contentsOf: bundle)) == savedTransfer["bundleSha256"] as? String && NativeScopedRoot.sha256(try Data(contentsOf: patch)) == savedTransfer["patchSha256"] as? String, "bundle and patch exist with recorded SHA-256")
        try check((savedTransfer["changedFiles"] as? [String]) == ["M README.md"] && savedTransfer["conflictMarkersRemain"] as? Bool == false, "changed files listed; no conflict markers")
        try check(try await git(["bundle", "verify", "-q", bundle.path], source).exitCode == 0, "bundle verifies against the original source history")
        let check1 = stage.appendingPathComponent("patch-check")
        guard try await git(["clone", "-q", source.path, check1.path], stage).exitCode == 0 else { throw nativeFailure("clone failed") }
        try check(try await git(["apply", "--check", patch.path], check1).exitCode == 0, "reviewable patch applies to a fresh copy of the source base")
        try check(try await git(["status", "--porcelain"], source).stdout.isEmpty && (try String(contentsOf: source.appendingPathComponent("README.md"), encoding: .utf8)) == "# Original\nshared line\n", "original source untouched by commit, bundle and patch")
        let text = NativeWorkspaceReceipt.text(saved)
        try check(text.contains("### Transfer") && text.contains("Bundle: ") && text.contains("git fetch '"), "receipt text shows transfer revisions, files and fetch command")

        _ = try await perform("codex", ["action": "begin", "folderId": "app"])
        try await write("codex", "README.md", "# Codex version\nshared line\n")
        let codexDone = try await perform("codex", ["action": "finish", "summary": "Retitle README for Codex"])
        let codexID = codexDone["id"] as! String

        // A3: complete saved diff and live diff of a teammate's work.
        let page = try NativeTrustedWorkspaces.diffPage(saved, startLine: 1, lineCount: 200)
        try check((page["lines"] as? [String])?.contains { $0.hasSuffix("+# Eve version") } == true && page["headCommit"] as? String == transfer["headCommit"] as? String && page["owner"] as? String == "eve", "saved diff page returns full diff lines with revisions and owner")

        // Claude: clean apply, then a real conflict, then resolution.
        let claudeBegin = try await perform("claude", ["action": "begin", "folderId": "app"])
        let claudeID = claudeBegin["id"] as! String
        try await write("claude", "notes.txt", "dirty\n")
        let dirty = try await perform("claude", ["action": "apply", "fromWorkspace": eveID])
        try check(dirty["ok"] as? Bool == false && (dirty["error"] as? String)?.contains("uncommitted") == true, "apply refuses a workspace with uncommitted edits")
        try await write("claude", "notes.txt", "notes\n")
        let live = try await NativeTrustedWorkspaces.liveDiff(worktree: URL(fileURLWithPath: claudeBegin["worktreePath"] as! String), base: claudeBegin["baseCommit"] as! String)
        try check(live.diff.isEmpty, "live diff reflects the current worktree (edit reverted)")
        let own = try await perform("claude", ["action": "apply", "fromWorkspace": claudeID])
        try check(own["ok"] as? Bool == false, "a workspace cannot apply itself or an unfinished workspace")
        let unknown = try? await perform("claude", ["action": "apply", "fromWorkspace": UUID().uuidString])
        try check(unknown == nil, "unknown workspace id refused before any Git operation")
        let clean = try await perform("claude", ["action": "apply", "fromWorkspace": eveID])
        try check(clean["ok"] as? Bool == true && clean["cleanly"] as? Bool == true && clean["sameBase"] as? Bool == true && (clean["conflicts"] as? [String])?.isEmpty == true && clean["sourceHead"] as? String == transfer["headCommit"] as? String, "clean apply reports both revisions, same base and no conflicts")
        let merged = try await perform("claude", ["action": "read", "path": "README.md"])
        try check(merged["content"] as? String == "# Eve version\nshared line\n", "applied change is in the receiving worktree")
        let conflict = try await perform("claude", ["action": "apply", "fromWorkspace": codexID])
        try check(conflict["ok"] as? Bool == false && (conflict["conflicts"] as? [String]) == ["README.md"] && (conflict["mergeBase"] as? String) == transfer["baseCommit"] as? String, "conflicting apply reports the conflicted path and merge base")
        let marked = try await perform("claude", ["action": "read", "path": "README.md"])
        try check((marked["content"] as? String)?.contains("<<<<<<<") == true && (marked["content"] as? String)?.contains("# Codex version") == true, "conflict markers left for the agent to resolve")
        let blocked = try await perform("claude", ["action": "apply", "fromWorkspace": eveID])
        try check(blocked["ok"] as? Bool == false, "no further apply while a conflict is unresolved")
        try await write("claude", "README.md", "# Eve and Codex version\nshared line\n")
        let claudeDone = try await perform("claude", ["action": "finish", "summary": "Combine teammates' README changes"])
        let claudeTransfer = claudeDone["transfer"] as? [String: Any] ?? [:]
        let claudeSaved = NativeTrustedWorkspaces.savedReceipt(storage: storage, id: claudeID)!.receipt
        try check(claudeTransfer["available"] as? Bool == true && claudeTransfer["conflictMarkersRemain"] as? Bool == false && (claudeSaved["applied"] as? [[String: Any]])?.map { $0["cleanly"] as? Bool ?? true } == [true, false], "resolved merge is recorded with both applies in the receipt")
        let parents = try await git(["rev-list", "--parents", "-n", "1", claudeTransfer["headCommit"] as! String], URL(fileURLWithPath: claudeSaved["repositoryPath"] as! String)).stdout.split(separator: " ").count
        try check(parents == 3, "finishing a conflicted apply records a real merge commit")
        try check(NativeWorkspaceReceipt.text(claudeSaved).contains("conflicts: README.md"), "receipt text discloses the conflicted apply")

        // Integrity and history checks.
        _ = try await perform("eve", ["action": "begin", "folderId": "app"])
        let original = try Data(contentsOf: bundle)
        try (original + Data([0])).write(to: bundle)
        let tampered = try await perform("eve", ["action": "apply", "fromWorkspace": codexID])
        try check(tampered["ok"] as? Bool == true, "untampered teammate bundle still applies")
        _ = try await perform("eve", ["action": "finish", "summary": "Took Codex change"])
        _ = try await perform("eve", ["action": "begin", "folderId": "app"])
        let corrupt = try await perform("eve", ["action": "apply", "fromWorkspace": eveID])
        try check(corrupt["ok"] as? Bool == false && (corrupt["error"] as? String)?.contains("does not match") == true, "tampered bundle refused by hash before Git reads it")
        try original.write(to: bundle)
        _ = try await perform("eve", ["action": "finish", "summary": "No change"])
        _ = try await perform("codex", ["action": "begin", "folderId": "other"])
        let foreign = try await perform("codex", ["action": "apply", "fromWorkspace": eveID])
        try check(foreign["ok"] as? Bool == false && (foreign["error"] as? String)?.contains("not in your workspace's history") == true, "change from unrelated history refused with its base revision named")
        _ = try await perform("codex", ["action": "finish", "summary": "No change"])
        try check(try await git(["status", "--porcelain"], source).stdout.isEmpty && (try String(contentsOf: source.appendingPathComponent("README.md"), encoding: .utf8)) == "# Original\nshared line\n", "shared source still unchanged after all transfers")
        print("\(passed) transfer checks passed. Synthetic fixture: \(stage.path)")
    }
}
