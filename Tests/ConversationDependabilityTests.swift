import Foundation
import AppKit

@main struct ConversationDependabilityTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws { guard condition else { throw nativeFailure("FAIL " + label) }; count += 1; print("PASS " + label) }
        func refused(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { try check(true, label); return }
            throw nativeFailure("FAIL allowed: " + label)
        }
        let now = Date()
        func allowance(_ value: Double, _ date: Date? = now, reset: Double? = nil) -> AllowancePresentation {
            AllowancePresentation(window: UsageWindow(label: "test", remainingPercent: value, resetsAt: reset), checkedAt: date, now: now)
        }
        for (percent, level) in [(100.0, "green"), (75, "green"), (74.99, "amber"), (25, "amber"), (24.99, "red"), (0, "red")] {
            try check(allowance(percent).level.rawValue == level, "remaining allowance threshold \(percent)")
        }
        try check(allowance(80, now.addingTimeInterval(-3601)).level == .neutral && allowance(80, now.addingTimeInterval(-3601)).label.contains("stale"), "stale percentages remain visible and neutral")
        try check(!allowance(80, now.addingTimeInterval(-31 * 60)).stale && allowance(80, now.addingTimeInterval(-31 * 60)).level == .green, "a half-hour-old reading is still shown in colour")
        try check(allowance(80, nil).stale && allowance(80, nil).level == .neutral, "missing timestamp never looks current")
        try check(allowance(.nan).percent == nil && allowance(101).percent == nil && allowance(-1).percent == nil, "unknown and invalid values stay neutral")
        try check(allowance(80, reset: now.timeIntervalSince1970 - 1).percent == nil, "expired allowance is unavailable")
        try check(allowance(80, now.addingTimeInterval(120)).stale, "future timestamp is not fresh")
        let order = ["codex", "eve", "claude"]
        for (index, agent) in order.enumerated() {
            let snapshot = ReplyQueueSnapshot(order: order, agent: agent)
            try check(snapshot.position == index + 1 && snapshot.isFinalSpeaker == (index == 2) && snapshot.prompt.contains("\"isFinalSpeaker\""), "host queue position for \(agent)")
        }
        try check(ReplyQueueSnapshot(order: ["eve"], agent: "eve").isFinalSpeaker, "single recipient is final")
        let literal = #"let value = "-- ' \" * _ | \\ $()""#
        try check(MarkdownBlock.parse("```swift\n" + literal + "\n```").first?.text == literal, "fenced code characters preserved byte for byte")
        try check(MarkdownBlock.parse("Before\n\n---\n\n* * *\n\n___\n\nAfter").map(\.kind) == ["paragraph", "divider", "divider", "divider", "paragraph"], "divider forms render as rules")
        try check(MarkdownTable.cells("| ``a`|b`` | c |") == ["``a`|b``", "c"], "multi-backtick code span protects table pipes")
        let layout = TableRowLayout(weights: [2, 8])
        let widths = layout.widths(700)
        try check(widths.count == 2 && abs(widths.reduce(0, +) - 700) < 0.01 && widths[1] > widths[0], "table assigns long-text columns more width without unused space")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-dependability-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = WorkspaceTaskBoard(root: root)
        let first = try board.begin(owner: "eve", folderID: "source", title: "Table layout", paths: ["Sources/Table.swift"], taskID: nil)
        try board.update(first.id, owner: "eve", status: "active")
        try refused("overlap rejected while workspace active") { _ = try board.begin(owner: "claude", folderID: "source", title: "Same file", paths: ["Sources"], taskID: nil) }
        let second = try board.begin(owner: "claude", folderID: "source", title: "Tests", paths: ["Tests"], taskID: nil)
        try check(second.owner == "claude", "separate assignments can coexist")
        let reopened = WorkspaceTaskBoard(root: root)
        try refused("ownership survives coordinator restart") { _ = try reopened.begin(owner: "codex", folderID: "source", title: "Everything", paths: [], taskID: nil) }
        try refused("active task cannot be handed off") { _ = try board.handoff(first.id, owner: "eve", to: "codex") }
        try board.update(first.id, owner: "eve", status: "review")
        let handoff = try board.handoff(first.id, owner: "eve", to: "codex")
        try check(handoff.nextOwner == "codex", "handoff names recipient")
        try refused("another agent cannot take assigned handoff") { _ = try board.begin(owner: "claude", folderID: "source", title: "Wrong owner", paths: [], taskID: first.id) }
        let accepted = try board.begin(owner: "codex", folderID: "source", title: "Continue", paths: [], taskID: first.id)
        try check(accepted.id == first.id && accepted.owner == "codex" && accepted.paths == first.paths, "recipient keeps exact task scope and identity")
        try refused("path traversal is refused") { _ = try board.begin(owner: "eve", folderID: "source", title: "Escape", paths: ["../outside"], taskID: nil) }
        let review = WorkspaceReviewLedger(root: root.appendingPathComponent("Reviews"))
        let id = UUID().uuidString, head = String(repeating: "a", count: 40), diff = "line one\nline two\nline three"
        let hash = NativeScopedRoot.sha256(Data(diff.utf8))
        let saved: [String: Any] = ["id": id, "owner": "eve", "status": "review", "finishedAt": "now", "diff": diff, "diffTruncated": false,
                                    "transfer": ["available": true, "headCommit": head, "conflictMarkersRemain": false, "conflictScanComplete": true]]
        try refused("unread diff cannot be approved") { _ = try review.record(agent: "claude", saved: saved, head: head, hash: hash, decision: "approved", summary: "Review") }
        review.read(agent: "claude", id: id, page: ["diffSha256": hash, "startLine": 1, "lines": ["1: line one", "2: line two"], "diffTruncated": false])
        try refused("partial diff cannot be approved") { _ = try review.record(agent: "claude", saved: saved, head: head, hash: hash, decision: "approved", summary: "Review") }
        review.read(agent: "claude", id: id, page: ["diffSha256": hash, "startLine": 3, "lines": ["3: line three"], "diffTruncated": false])
        try refused("self review refused") { _ = try review.record(agent: "eve", saved: saved, head: head, hash: hash, decision: "approved", summary: "Self") }
        _ = try review.record(agent: "claude", saved: saved, head: head, hash: hash, decision: "approved", summary: "Read complete diff; tests unverified")
        try check(try review.approved(saved)["reviewer"] as? String == "claude", "approval binds independent reviewer and exact head")
        var changed = saved; changed["diff"] = diff + "changed"
        try refused("changed diff invalidates approval") { _ = try review.approved(changed) }
        _ = try review.record(agent: "claude", saved: saved, head: head, hash: hash, decision: "changesRequested", summary: "Needs revision")
        try refused("changes requested supersedes earlier approval") { _ = try review.approved(saved) }
        let diffRoot = root.appendingPathComponent("diff-fixture")
        try FileManager.default.createDirectory(at: diffRoot, withIntermediateDirectories: true)
        let code = "literal absolute path stays in file content: " + root.path + "\n"
        try Data(code.utf8).write(to: diffRoot.appendingPathComponent("New File.swift"))
        let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", "New File.swift"], directory: diffRoot, environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null"])
        let headers = result.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("diff --git") || $0.hasPrefix("+++") }
        try check(result.exitCode == 1 && headers.allSatisfy { !$0.contains(diffRoot.path) } && result.stdout.contains("+" + code.trimmingCharacters(in: .newlines)), "new-file diff headers are relative while literal code paths survive")
        let requested = URL(string: "https://staging.silkwire.app/?still")!
        let final = URL(string: "https://staging.silkwire.si/")!
        try check(NativeWebInspector.stillRetryURL(requested: requested, final: final, policy: .init())?.absoluteString == "https://staging.silkwire.si/?still", "lost still mode is restored on an approved redirect destination")
        try check(NativeWebInspector.stillRetryURL(requested: requested, final: requested, policy: .init()) == nil && NativeWebInspector.stillRetryURL(requested: requested, final: URL(string: "https://example.com/")!, policy: .init()) == nil, "still retry avoids loops and unapproved destinations")
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        for y in 0..<32 { for x in 0..<32 { image.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        try check(NativeWebInspector.isUniformDark(image.representation(using: .png, properties: [:])!), "black capture is flagged separately from HTTP status")
        for y in 0..<32 { for x in 0..<32 { image.setColor(x < 16 ? NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1) : NSColor(deviceRed: 0.6, green: 0.2, blue: 0.9, alpha: 1), atX: x, y: y) } }
        try check(!NativeWebInspector.isUniformDark(image.representation(using: .png, properties: [:])!), "visible capture is not flagged black")
        print("PASS: \(count) conversation dependability checks")
    }
}
