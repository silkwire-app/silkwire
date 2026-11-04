import Foundation

// Failures must be visible and honest: the connection log reports when it cannot be
// read or written, trims only at whole lines, and a background job that fails says
// why. Synthetic temporary files only; nothing touches a real library.
@main struct HonestFailureTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("honest-failure-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ConnectionLog.folderOverride
        defer { ConnectionLog.folderOverride = previous; try? files.removeItem(at: root) }

        // Trimming keeps whole entries and never splits a character.
        let unicode = ConnectionLog.line(agent: "eve", event: "fixture", detail: String(repeating: "é", count: 240), at: Date(timeIntervalSince1970: 0))
        let body = Data(String(repeating: unicode, count: 1000).utf8)
        var big = body
        var splitFound = false
        for pad in 0..<8 {
            var candidate = body
            candidate.append(Data(ConnectionLog.line(agent: "codex", event: "newest", detail: "last" + String(repeating: "x", count: pad), at: Date(timeIntervalSince1970: 1)).utf8))
            if candidate[candidate.count - 200_000] & 0xC0 == 0x80 { big = candidate; splitFound = true; break }
        }
        check(splitFound, "fixture's raw 200 KB cut lands inside a character")
        let trimmed = ConnectionLog.trimmed(big)
        check(trimmed.count <= 200_000 && trimmed.count > 150_000, "oversized log is cut to about half")
        check(String(data: trimmed, encoding: .utf8) != nil, "trimmed log is still valid UTF-8")
        let text = String(decoding: trimmed, as: UTF8.self)
        check(text.hasPrefix("1970-") && text.hasSuffix("\n"), "trimmed log starts and ends at a whole entry")
        check(text.contains("codex newest last"), "newest entry survives trimming")
        check(ConnectionLog.trimmed(Data("short\n".utf8)) == Data("short\n".utf8), "small logs are untouched")

        // Missing, readable and unreadable histories are told apart.
        ConnectionLog.folderOverride = root.appendingPathComponent("fresh", isDirectory: true)
        check(ConnectionLog.history(agent: nil) == .empty, "no file yet reads as nothing recorded")
        ConnectionLog.record(agent: "eve", event: "connected", detail: "one")
        check(ConnectionLog.lastWriteError == nil, "a good save clears the write error")
        if case .entries(let lines) = ConnectionLog.history(agent: "eve") { check(lines.count == 1 && lines[0].contains("eve connected one"), "saved entry reads back") }
        else { check(false, "saved entry reads back") }
        check(ConnectionLog.history(agent: "codex") == .empty, "another teammate's filter is empty, not an error")

        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        try files.createDirectory(at: blocked.appendingPathComponent("connections.log", isDirectory: true), withIntermediateDirectories: true)
        ConnectionLog.folderOverride = blocked
        if case .unreadable(let reason) = ConnectionLog.history(agent: nil) { check(!reason.isEmpty, "an unreadable history is reported, with a reason") }
        else { check(false, "an unreadable history is reported, with a reason") }
        check(ConnectionLog.recent(agent: nil).isEmpty, "old recent() stays safe on an unreadable log")
        ConnectionLog.record(agent: "eve", event: "dropped", detail: "two")
        check(ConnectionLog.lastWriteError != nil, "a failed save is remembered, not swallowed")
        ConnectionLog.folderOverride = root.appendingPathComponent("fresh", isDirectory: true)
        ConnectionLog.record(agent: "eve", event: "reconnected", detail: "three")
        check(ConnectionLog.lastWriteError == nil, "the next good save clears it again")

        // A failed background build says why, without tool noise.
        let real: [String: Any] = ["status": "failed", "message": "Choose a Git App Source folder. 2026-11-03 00:11:18.499 xcodebuild[74057:2028891]  DVTFilePathFSEvents: Failed to start fs event stream.\n2026-11-03 00:11:18.582 xcodebuild[74057:2028886] [MT] DVTDeveloperPaths: Failed to get length\nfatal: not a git repository: (null)\n"]
        let note = HostNativeBuilderJobs.failureNote(real)
        check(note.hasPrefix("Didn't finish:"), "failure note leads with a plain outcome (" + note + ")")
        check(note.contains("Choose a Git App Source folder") && note.contains("not a git repository") && !note.contains("DVT") && !note.contains("xcodebuild["), "failure note keeps the real reason and drops tool noise")
        check(HostNativeBuilderJobs.failureNote(["status": "failed"]).contains("no reason was recorded"), "an empty failure still says so")
        check(HostNativeBuilderJobs.failureNote(["status": "failed", "message": String(repeating: "x", count: 5000)]).utf16.count <= 600, "failure note is bounded")

        let card = BackgroundJobCard(id: UUID(), agent: "codex", title: "Run test and build checks", originRequestID: "r", work: "{}", workspaceID: UUID(), phase: .needsReview)
        let posted = BackgroundJobText.ended(card, note: note)
        check(posted.hasPrefix("**Codex · Run test and build checks · Didn't finish**") && posted.contains("not a git repository"), "room line names who, what, and why")
        check(BackgroundJobText.ended(card, note: "  ").contains("No reason was recorded"), "room line never goes silent on a blank reason")
        check(BackgroundJobText.isReportedFailure(note), "a recorded build failure is announced in the room")
        check(!BackgroundJobText.isReportedFailure("Stopped by the host."), "a stop stays quiet (no room post)")
        check(!BackgroundJobText.isReportedFailure("Step outcome needs host review; nothing was automatically replayed."), "an unproved exit stays quiet (no room post)")

        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
