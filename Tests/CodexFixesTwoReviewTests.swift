import Foundation
import Darwin

// Independent synthetic re-review of d731d21. No real home, providers, credentials,
// external repositories, or sandbox-policy execution. Tests inspect computed roots.
@main struct CodexFixesTwoReviewTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) }
            else { failures += 1; print("FAIL " + label) }
        }
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("codex-fixes-two-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func put(_ text: String, _ url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let common = root.appendingPathComponent("unrelated-data", isDirectory: true)
        let gitdir = common.appendingPathComponent("worktrees/fixture", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try put("gitdir: " + gitdir.path + "\n", source.appendingPathComponent(".git"))
        check(NativeBuilder.linkedGitMetadata(for: source).isEmpty, "missing metadata back-pointer is rejected")
        try put(source.appendingPathComponent(".git").path + "\n", gitdir.appendingPathComponent("gitdir"))
        try put("../..\n", gitdir.appendingPathComponent("commondir"))
        check(NativeBuilder.linkedGitMetadata(for: source).isEmpty, "matching pointers without Git-shaped directories are rejected")

        // Add only the names the validator checks. This is not a repository:
        // HEAD is invalid, objects and refs are empty, and worktree HEAD is absent.
        // A coherent back-pointer is still fixture-authored data, not a host witness.
        try put("not a Git HEAD\n", common.appendingPathComponent("HEAD"))
        try fm.createDirectory(at: common.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: common.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try put("synthetic unrelated document\n", common.appendingPathComponent("private-document.txt"))
        let computed = NativeBuilder.linkedGitMetadata(for: source)
        print("Computed fixture read roots: " + computed.map(\.lastPathComponent).joined(separator: ", "))
        check(computed.isEmpty, "a coherent but entirely forged metadata layout cannot authorize an unrelated directory")
        check(!computed.map(\.path).contains(common.path), "an unrelated payload directory is not granted wholesale by marker shape")

        // The earlier malformed commondir case must remain closed too.
        try put(root.path + "\n", gitdir.appendingPathComponent("commondir"))
        check(NativeBuilder.linkedGitMetadata(for: source).isEmpty, "commondir escaping its derived common directory is rejected")
        try put("../..\n", gitdir.appendingPathComponent("commondir"))
        try put(root.appendingPathComponent("other/.git").path + "\n", gitdir.appendingPathComponent("gitdir"))
        check(NativeBuilder.linkedGitMetadata(for: source).isEmpty, "another worktree's back-pointer is rejected")

        let date = Date()
        let queued = BackgroundJobCard(id: UUID(), agent: "codex", title: "Fixture review", originRequestID: "one", work: "{}", workspaceID: UUID(), phase: .queued)
        var running = queued
        running.phase = .running
        check(BackgroundJobWords.summary([queued], at: date).lowercased().contains("waiting"), "single queued header explicitly says waiting")
        check(!BackgroundJobWords.summary([queued, queued], at: date).contains("running"), "all-queued header does not claim running work")
        let mixed = BackgroundJobWords.summary([queued, running], at: date)
        check(mixed.contains("1 running, 1 waiting"), "mixed header separates running and waiting counts")
        check(queued.isLive == false && running.isLive, "only actual running work is live")

        print("\(checks - failures)/\(checks) independent re-review checks passed")
        if failures > 0 { exit(1) }
    }
}
