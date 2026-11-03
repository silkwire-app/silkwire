import Foundation
import Darwin

// Independent review of 483720d. Fixtures only: no real providers, owner library,
// credentials, source repositories, or actual sandbox permission changes.
@main struct CodexStackedFixesReviewTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) }
            else { failures += 1; print("FAIL " + label) }
        }
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("codex-stacked-review-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let oldLogFolder = ConnectionLog.folderOverride
        defer {
            ConnectionLog.folderOverride = oldLogFolder
            try? files.removeItem(at: root)
        }

        // Exercise record(), not just the trimming helper: the raw suffix begins
        // inside a multibyte character, and the newest entry must survive rotation.
        ConnectionLog.folderOverride = root.appendingPathComponent("logs", isDirectory: true)
        try files.createDirectory(at: ConnectionLog.folderOverride!, withIntermediateDirectories: true)
        let unicode = ConnectionLog.line(agent: "eve", event: "fixture", detail: String(repeating: "é", count: 240), at: Date(timeIntervalSince1970: 0))
        let body = Data(String(repeating: unicode, count: 1000).utf8)
        var seed = body, splitFound = false
        for padding in 0...240 {
            var candidate = body
            candidate.append(Data(ConnectionLog.line(agent: "codex", event: "padding", detail: String(repeating: "x", count: padding), at: Date(timeIntervalSince1970: 1)).utf8))
            if candidate[candidate.count - 200_000] & 0xC0 == 0x80 {
                seed = candidate; splitFound = true; break
            }
        }
        check(splitFound && seed.count > 400_000, "rotation fixture crosses a Unicode scalar")
        try seed.write(to: ConnectionLog.url)
        ConnectionLog.record(agent: "codex", event: "after-rotation", detail: "fixture only")
        let rotated = try Data(contentsOf: ConnectionLog.url)
        check(rotated.count <= 201_000, "record rotates the oversized log")
        check(String(data: rotated, encoding: .utf8) != nil, "record preserves UTF-8")
        check(String(decoding: rotated, as: UTF8.self).hasPrefix("1970-"), "record retains a whole first entry")
        check(ConnectionLog.recent(agent: "codex", limit: 1).first?.contains("after-rotation") == true, "newest entry remains readable and filterable")
        check(ConnectionLog.lastWriteError == nil, "successful rotation reports no write error")

        let blocked = root.appendingPathComponent("blocked-log", isDirectory: true)
        try files.createDirectory(at: blocked.appendingPathComponent("connections.log", isDirectory: true), withIntermediateDirectories: true)
        ConnectionLog.folderOverride = blocked
        if case .unreadable(let reason) = ConnectionLog.history(agent: nil) {
            check(!reason.isEmpty, "existing unreadable log has a reason")
        } else { check(false, "existing unreadable log has a reason") }
        ConnectionLog.record(agent: "codex", event: "fixture", detail: "cannot save")
        check(ConnectionLog.lastWriteError != nil, "failed write is exposed")
        ConnectionLog.folderOverride = root.appendingPathComponent("recovered-log", isDirectory: true)
        ConnectionLog.record(agent: "codex", event: "fixture", detail: "saved")
        check(ConnectionLog.lastWriteError == nil, "a later successful save clears the error")

        // Queue state must remain honest in the header as well as the sidebar.
        let now = Date()
        let first = BackgroundJobCard(id: UUID(), agent: "codex", title: "Fixture review", originRequestID: "fixture-1", work: "{}", workspaceID: UUID(), phase: .queued)
        let second = BackgroundJobCard(id: UUID(), agent: "eve", title: "Fixture checks", originRequestID: "fixture-2", work: "{}", workspaceID: UUID(), phase: .queued)
        check(!first.isLive, "a queued card is not live")
        check(BackgroundJobWords.status(first) == "Waiting to start", "sidebar labels a queued job as waiting")
        check(BackgroundJobWords.summary([first], at: now).lowercased().contains("waiting"), "single queued-job header explicitly says waiting")
        check(!BackgroundJobWords.summary([first, second], at: now).lowercased().contains("running"), "two queued jobs are not described as running")
        var running = second
        running.phase = .running
        check(!BackgroundJobWords.summary([first, running], at: now).contains("2 jobs running"), "mixed queued/running header does not count both as running")

        // A path read from repository contents is not itself authorization. These
        // synthetic malformed markers must not broaden preparation to their parent
        // or an unrelated directory. No real home path or secret is involved.
        let source = root.appendingPathComponent("fake-source", isDirectory: true)
        let metadata = root.appendingPathComponent("fake-metadata", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated-data", isDirectory: true)
        for dir in [source, metadata, unrelated] {
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try ("gitdir: " + root.path + "\n").write(to: source.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let rootPaths = NativeBuilder.linkedGitMetadata(for: source).map(\.path)
        check(!rootPaths.contains(root.path), "unvalidated gitdir cannot grant read access to the fixture parent")
        try ("gitdir: " + metadata.path + "\n").write(to: source.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try (unrelated.path + "\n").write(to: metadata.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let commonPaths = NativeBuilder.linkedGitMetadata(for: source).map(\.path)
        check(!commonPaths.contains(unrelated.path), "unvalidated commondir cannot add an unrelated read root")

        let note = HostNativeBuilderJobs.failureNote(["status": "failed", "message": "fixture preparation failed"])
        check(BackgroundJobText.isReportedFailure(note), "reported failure is eligible for a room announcement")
        check(!BackgroundJobText.isReportedFailure("Stopped by the host."), "user stop remains distinct from a reported failure")
        check(!BackgroundJobText.isReportedFailure("Step outcome needs host review; nothing was automatically replayed."), "uncertain exit is not relabeled a confirmed build failure")
        check(BackgroundJobText.ended(first, note: note).contains("fixture preparation failed"), "announcement preserves the failure reason")

        print("\(checks - failures)/\(checks) independent checks passed")
        if failures > 0 { exit(1) }
    }
}
