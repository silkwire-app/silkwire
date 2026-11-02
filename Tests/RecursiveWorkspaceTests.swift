import Foundation

// Requires a host permitted to apply sandbox-exec. Failure is a real native
// acceptance failure; the suite has no executor bypass or success substitution.
@main struct RecursiveWorkspaceTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let fixture = try NativeTemporaryDirectory.canonical(fm.temporaryDirectory).appendingPathComponent("silkwire-recursive-work-" + UUID().uuidString)
        let projects = fixture.appendingPathComponent("Projects"), source = projects.appendingPathComponent("Team/Example")
        let library = fixture.appendingPathComponent("Staging"), handoff = projects.appendingPathComponent("ReviewOut")
        for root in [source, handoff, library] { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        try Data("print(\"before\")\n".utf8).write(to: source.appendingPathComponent("hello.swift"))
        try Data("Review input\n".utf8).write(to: handoff.appendingPathComponent("report.txt"))
        let env = ["PATH": "/usr/bin:/bin", "HOME": fixture.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        func git(_ args: [String]) async throws -> String {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null"] + args, directory: source, environment: env)
            guard result.exitCode == 0 else { throw nativeFailure(result.stderr) }; return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q"]); _ = try await git(["add", "hello.swift"])
        _ = try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-qm", "Example"])
        let head = try await git(["rev-parse", "HEAD"]), bundle = handoff.appendingPathComponent("review.bundle")
        _ = try await git(["bundle", "create", bundle.path, "HEAD"])
        let grant = NativeProjectFolderGrant(id: "all-projects", name: "All Projects", root: projects)
        var receipt: [String: Any] = [:]
        let coordinator = NativeTrustedWorkspaces(storage: library.appendingPathComponent("Team Workspaces/fixture"), sandbox: WorkspaceEnvironment(staging: true, library: library), ownership: HostOwnershipDefault.coordinator, receipt: { _, value in receipt = value })
        try coordinator.configure(grants: [grant], trustedIDs: [grant.id])
        func check(_ value: Bool, _ message: String) throws { guard value else { throw nativeFailure(message) }; print("PASS " + message) }
        do {
            let begun = try await coordinator.perform(["action": "begin", "folderId": grant.id, "path": "Team/Example"], agent: "codex", task: "Edit a project under the shared Projects root")
            try check(begun["baseCommit"] as? String == head, "recursive grant begins at the exact descendant repository")
        } catch {
            let evidence: [String: Any] = ["status": receipt["status"] ?? "missing", "message": receipt["message"] ?? error.localizedDescription, "baseCommit": receipt["baseCommit"] ?? "missing", "sourceUnchanged": receipt["sourceUnchanged"] ?? NSNull(), "commandSteps": (receipt["steps"] as? [[String: Any]] ?? []).count]
            print("Native recursive workspace failure: " + (try nativeJSON(evidence)))
            throw error
        }
        let read = try await coordinator.perform(["action": "read", "path": "hello.swift"], agent: "codex", task: "Continue")
        let reader = NativeProjectAccess(); reader.update(grants: [grant])
        _ = try reader.perform(NativeProjectReadRequest(action: "read", folderID: grant.id, path: "ReviewOut/report.txt"))
        try check(coordinator.active("codex"), "reading another file under Projects leaves the private workspace active")
        let edit = try await coordinator.perform(["action": "write", "path": "hello.swift", "content": "print(\"after\")\n", "expectedSha256": read["sha256"]!], agent: "codex", task: "Continue")
        try check(edit["ok"] as? Bool == true, "authorized source edit succeeds without another approval")
        let run = try await coordinator.perform(["action": "run", "command": "/usr/bin/swiftc -module-cache-path \"$TMPDIR/modules\" hello.swift -o hello && ./hello"], agent: "codex", task: "Continue")
        try check(run["status"] as? String == "passed" && run["output"] as? String == "after\n", "actual private build and execution return passing evidence")
        let finished = try await coordinator.perform(["action": "finish", "summary": "Prepared greeting change for review"], agent: "codex", task: "Finish")
        try check(finished["status"] as? String == "review" && finished["sourceUnchanged"] as? Bool == true, "finished review leaves original project source unchanged")
        let imported = try await coordinator.perform(["action": "begin", "folderId": grant.id, "bundle": "ReviewOut/review.bundle", "revision": head, "sha256": NativeScopedRoot.sha256(try Data(contentsOf: bundle))], agent: "claude", task: "Review an outside Git bundle")
        try check(imported["baseCommit"] as? String == head && imported["bundleImport"] != nil, "same standing root grant imports a bundle into a distinct owned workspace")
        try coordinator.configure(grants: [], trustedIDs: [])
        var denied = false
        do { _ = try await coordinator.perform(["action": "read", "path": "hello.swift"], agent: "claude", task: "Revoked") } catch { denied = true }
        try check(denied && !coordinator.active("claude"), "revocation stops the imported workspace and refuses subsequent operations")
        print("PASS full recursive Project workspace acceptance")
    }
}
