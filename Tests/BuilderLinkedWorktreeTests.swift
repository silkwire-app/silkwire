import Foundation

// Background runs build from a teammate's private workspace, which is a linked Git
// worktree. Its `.git` is a file pointing at metadata in a sibling repository. The
// preparation sandbox must be allowed to read that metadata, or every run fails
// at once with "not a git repository". Synthetic temporary repositories only.
@main struct BuilderLinkedWorktreeTests {
    static func main() throws {
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func git(_ args: [String], in dir: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "user.name=t", "-c", "user.email=t@t.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")]) }
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("builder-linked-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The host's own layout: <store>/<conversation>/<agent>/<run>/{repository,worktree}.
        let store = root.appendingPathComponent("store")
        let run = store.appendingPathComponent("conversation/claude/run")
        let repository = run.appendingPathComponent("repository"), worktree = run.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repository)
        try "hello\n".write(to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"], in: repository)
        try git(["commit", "-q", "-m", "one"], in: repository)
        try git(["worktree", "add", "-q", "-b", "w", worktree.path], in: repository)

        let linked = NativeBuilder.linkedGitMetadata(for: worktree, hostStores: [store])
        check(NativeBuilder.linkedGitMetadata(for: worktree, hostStores: []).isEmpty, "a real worktree outside any host-registered store adds nothing")
        check(NativeBuilder.linkedGitMetadata(for: worktree, hostStores: [root]).isEmpty, "the store must be the exact registered one, not a parent of it")
        let gitDir = repository.appendingPathComponent(".git/worktrees/worktree").resolvingSymlinksInPath().path
        let common = repository.appendingPathComponent(".git").resolvingSymlinksInPath().path
        check(linked.map(\.path).contains(gitDir), "a linked worktree exposes its own gitdir")
        check(linked.map(\.path).contains(common), "a linked worktree exposes the shared repository metadata")
        check(linked.count == 2, "nothing beyond the worktree's own Git metadata is added")
        check(NativeBuilder.linkedGitMetadata(for: repository, hostStores: [store]).isEmpty, "an ordinary repository adds nothing")
        check(NativeBuilder.linkedGitMetadata(for: root, hostStores: [store]).isEmpty, "a folder without Git adds nothing")

        // The .git file is repository content: a claim, not permission (Codex review, Nov 3).
        // A second folder that points at the real worktree's metadata is refused, because
        // Git's back-pointer names the real worktree, not the impostor.
        let impostor = root.appendingPathComponent("impostor")
        try FileManager.default.createDirectory(at: impostor, withIntermediateDirectories: true)
        try ("gitdir: " + gitDir + "\n").write(to: impostor.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        check(NativeBuilder.linkedGitMetadata(for: impostor, hostStores: [store]).isEmpty, "another folder can't borrow a worktree's metadata")
        // A worktrees-shaped folder whose commondir points elsewhere is refused.
        let fakeCommon = root.appendingPathComponent("fake/.git"), fakeDir = fakeCommon.appendingPathComponent("worktrees/x")
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        let fakeTree = root.appendingPathComponent("faketree")
        try FileManager.default.createDirectory(at: fakeTree, withIntermediateDirectories: true)
        try ("gitdir: " + fakeDir.path + "\n").write(to: fakeTree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try (fakeTree.appendingPathComponent(".git").path + "\n").write(to: fakeDir.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        try (root.path + "\n").write(to: fakeDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        check(NativeBuilder.linkedGitMetadata(for: fakeTree, hostStores: [store]).isEmpty, "a commondir pointing outside its own repository is refused")
        // Same shape with a matching commondir but no real Git directory behind it is refused.
        try ("../..\n").write(to: fakeDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        check(NativeBuilder.linkedGitMetadata(for: fakeTree, hostStores: [store]).isEmpty, "metadata without a real Git directory behind it is refused")

        let nested = worktree.appendingPathComponent("a/b/c/worktree")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try ("gitdir: " + gitDir + "\n").write(to: nested.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        check(NativeBuilder.linkedGitMetadata(for: nested, hostStores: [store]).isEmpty, "a fake layout built inside a worktree is refused (wrong depth under the store)")

        let profile = NativeBuilder.privatePreparationSandbox(writable: [root.appendingPathComponent("run")], readable: [worktree] + linked)
        let escaped: (String) -> String = { $0.replacingOccurrences(of: "/", with: "\\/") }
        check(profile.contains(escaped(gitDir)) && profile.contains(escaped(common)), "the preparation sandbox may read that metadata")
        let writeRule = profile.split(separator: "\n").first { $0.contains("deny file-write*") }.map(String.init) ?? ""
        check(!writeRule.isEmpty && !writeRule.contains(escaped(common)), "the metadata stays read-only")

        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
