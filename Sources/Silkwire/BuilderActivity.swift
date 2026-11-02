import SwiftUI

/// Plain-language reading of a Builder receipt, shared by the transcript bar and agent history.
struct BuilderSummary: Equatable {
    var owner = "Builder"
    var task = ""
    var branch = ""
    var receiptState = "unknown"
    var passed = 0
    var failed = 0
    var running = 0
    /// Failed side steps that a later passing build and test run made moot.
    var superseded = 0
    var commands: [(command: String, status: String, key: String)] = []
    /// Distinct commands; counts above describe each one's latest attempt.
    var distinct = 0

    static func == (lhs: BuilderSummary, rhs: BuilderSummary) -> Bool {
        lhs.distinct == rhs.distinct && lhs.owner == rhs.owner && lhs.task == rhs.task && lhs.branch == rhs.branch && lhs.receiptState == rhs.receiptState && lhs.commands.map(\.command) == rhs.commands.map(\.command) && lhs.commands.map(\.status) == rhs.commands.map(\.status) && lhs.commands.map(\.key) == rhs.commands.map(\.key)
    }

    static func parse(_ text: String) -> BuilderSummary {
        var summary = BuilderSummary()
        var pendingCommand: String?
        var pendingEvidence = false
        var pendingCheck: String?
        var fence: String?
        var commandSection = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                if line.hasPrefix(current), line.dropFirst(current.count).allSatisfy({ $0 == current.first! }) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix { $0 == line.first! }); continue
            }
            if line.hasPrefix("## ") {
                // "## Staging work · Eve · review"
                let parts = line.dropFirst(3).components(separatedBy: " · ")
                if parts.first == "Staging work", parts.count >= 3 {
                    summary.owner = parts[1]; summary.receiptState = parts[2]
                } else if parts.first == "Builder", parts.count >= 2 { summary.receiptState = parts[1] }
            } else if line.hasPrefix("Task:"), summary.task.isEmpty {
                summary.task = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Branch:"), summary.branch.isEmpty {
                summary.branch = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("### ") {
                commandSection = !["### Actual diff", "### Diff", "### Builder summary (not test evidence)", "### Transfer"].contains(line)
                pendingCommand = ""; pendingEvidence = false
                pendingCheck = line.hasPrefix("### Check · ") ? String(line.dropFirst("### Check · ".count)) : nil
            } else if commandSection, line.hasPrefix("Command: ") {
                pendingCommand = String(line.dropFirst(9))
            } else if commandSection, pendingCommand != nil, line.hasPrefix("Evidence: ") {
                pendingEvidence = true
            } else if commandSection, let command = pendingCommand, command.isEmpty, !line.isEmpty, !line.hasPrefix("Status:"), !line.hasPrefix("Result:") {
                pendingCommand = line
            } else if commandSection, pendingCommand != nil, line.hasPrefix("Status:") || line.hasPrefix("Result:") {
                let status = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                let stated = status.components(separatedBy: " ").first ?? status
                let exitCode = status.components(separatedBy: " · exit ").last.flatMap(Int.init)
                // Exit evidence wins over a contradictory label. Missing exits never pass.
                var word = exitCode.map { $0 == 0 && stated == "passed" ? "passed" : $0 == 0 && stated == "unconfirmed" ? "unconfirmed" : "failed" } ?? (stated == "running" ? "running" : "unconfirmed")
                // Receipts from before per-step evidence: a compound shell command's
                // final exit cannot prove its earlier steps passed.
                if word == "passed", !pendingEvidence, Self.compound(pendingCommand ?? "") { word = "unconfirmed" }
                let command = pendingCommand ?? ""
                summary.commands.append((command, word, pendingCheck.map { "check:" + $0 } ?? "command:" + command))
                pendingCommand = nil; pendingEvidence = false
            }
        }
        // The latest attempt of each command decides its current result; earlier
        // failures remain visible in `commands`.
        var latest: [String: String] = [:]
        for item in summary.commands { latest[item.key] = item.status }
        summary.passed = latest.values.filter { $0 == "passed" }.count
        summary.failed = latest.values.filter { $0 == "failed" }.count
        // A failed side step (a search or helper script) that was followed by a passing
        // build AND a passing test run was redone, not left broken: it stays listed in
        // Details but no longer turns the whole receipt into "Needs attention".
        // Build and test failures themselves are never superseded.
        let isBuild: (String) -> Bool = { $0.range(of: #"^swift Scripts/build\.swift"#, options: .regularExpression) != nil }
        let isTest: (String) -> Bool = { $0.range(of: #"^swift (Scripts/test\.swift|Tests/run-transports\.swift)( [A-Za-z0-9_-]+)*$"#, options: .regularExpression) != nil }
        let items = summary.commands
        if let lastBuild = items.lastIndex(where: { isBuild($0.command) }), items[lastBuild].status == "passed",
           let lastTest = items.lastIndex(where: { isTest($0.command) }), items[lastTest].status == "passed" {
            let cutoff = min(lastBuild, lastTest)
            var lastIndex: [String: Int] = [:]
            for (i, item) in items.enumerated() { lastIndex[item.key] = i }
            summary.superseded = latest.filter { key, status in
                guard status == "failed", let i = lastIndex[key], i < cutoff else { return false }
                return !isBuild(items[i].command) && !isTest(items[i].command)
            }.count
            summary.failed -= summary.superseded
        }
        summary.running = latest.values.filter { !["passed", "failed"].contains($0) }.count
        summary.distinct = latest.count
        return summary
    }
    static func compound(_ command: String) -> Bool {
        [";", "|", "&&", "$(", "`", "\n"].contains { command.contains($0) }
    }

    func headline(messageState: String) -> String {
        if ["sending", "streaming"].contains(messageState) { return "Ari is spinning…" }
        if ["interrupted", "cancelled", "stopped"].contains(messageState) || ["stopped", "cancelled"].contains(receiptState) { return "Stopped" }
        guard messageState == "completed", ["review", "completed"].contains(receiptState), failed == 0, running == 0 else { return "Needs attention" }
        return "Ready for review"
    }
    var commandDescription: String {
        let total = distinct
        guard total > 0 else { return "No commands recorded" }
        let retries = commands.count > total ? " (latest of \(commands.count) attempts)" : ""
        if failed > 0 { return "\(failed) of \(total) commands failed" + retries }
        if running > 0 { return "\(passed) of \(total) commands confirmed" + retries }
        let redone = superseded > 0 ? " · \(superseded) earlier step\(superseded == 1 ? "" : "s") redone" : ""
        return "\(total - superseded) commands passed" + redone + retries
    }
    var testDescription: String {
        // Only standalone documented test invocations qualify. Shell wrappers can hide exits.
        var latest: [String: (command: String, status: String)] = [:], order: [String] = []
        for item in commands { if latest[item.key] == nil { order.append(item.key) }; latest[item.key] = (item.command, item.status) }
        let tests = order.compactMap { latest[$0] }.filter { $0.command.range(of: #"^swift (Scripts/test\.swift|Tests/run-transports\.swift)( [A-Za-z0-9_-]+)*$"#, options: .regularExpression) != nil }
        guard !tests.isEmpty else { return "No separate test result recorded" }
        return "Test commands: \(tests.filter { $0.status == "passed" }.count) passed, \(tests.filter { $0.status == "failed" }.count) failed, \(tests.filter { !["passed", "failed"].contains($0.status) }.count) unconfirmed"
    }

    /// Short text supplied to agents instead of the full receipt, so build logs don't crowd
    /// conversation out of the shared history window. Full receipts stay available as artifacts.
    static func compact(_ text: String) -> String {
        let summary = parse(text)
        // Only receipts are summarized; other Builder text is kept (bounded) so its
        // content is not replaced by an empty "unknown" receipt line.
        guard summary.receiptState != "unknown" || !summary.commands.isEmpty else { return limitedUTF16(text, to: 4000) }
        var lines = ["Builder receipt · \(summary.owner) · \(summary.receiptState) (full diff and logs available as a shared artifact)"]
        lines.append(summary.commandDescription + "; " + summary.testDescription)
        if !summary.task.isEmpty { lines.append("Task: " + String(summary.task.prefix(160)) + (summary.task.count > 160 ? "…" : "")) }
        if !summary.branch.isEmpty { lines.append("Branch: " + summary.branch) }
        for item in summary.commands.prefix(12) {
            lines.append("- " + String(item.command.prefix(120)) + " → " + item.status)
        }
        if summary.commands.count > 12 { lines.append("- … \(summary.commands.count - 12) more commands") }
        return lines.joined(separator: "\n")
    }
}

/// Compact, collapsed-by-default presentation of Builder work in the transcript.
struct BuilderActivityBar: View {
    let message: Message
    let reduceMotion: Bool
    var stop: (() -> Void)? = nil
    @State private var expanded = false

    private var summary: BuilderSummary { BuilderSummary.parse(message.text) }
    private var isRunning: Bool { ["sending", "streaming"].contains(message.state) }

    private var headline: String {
        summary.headline(messageState: message.state)
    }
    private var needsAttention: Bool { headline == "Needs attention" }
    private var checks: String {
        summary.commandDescription
    }
    private var shortTask: String {
        let task = summary.task.replacingOccurrences(of: "\n", with: " ")
        return task.count > 70 ? String(task.prefix(70)) + "…" : task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Group {
                    if isRunning { WorkingSpider(reduceMotion: reduceMotion) }
                    else { Image(systemName: needsAttention ? "exclamationmark.triangle.fill" : headline == "Stopped" ? "stop.circle" : "checkmark.circle.fill") }
                }
                .foregroundStyle(needsAttention ? Color.orange : SilkwireTheme.accent)
                .frame(width: 18, height: 18)
                Text(headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(needsAttention ? Color.orange : Color.primary)
                Text("· \(summary.owner)").font(.system(size: 13)).foregroundStyle(SilkwireTheme.identity(summary.owner))
                if !shortTask.isEmpty { Text("· " + shortTask).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                Spacer(minLength: 8)
                if isRunning, let stop { Button("Stop", action: stop).buttonStyle(.bordered).accessibilityLabel("Stop this Builder task") }
                if !isRunning { Text(checks).font(.system(size: 11)).foregroundStyle(summary.failed > 0 ? Color.orange : Color.secondary) }
                Button { expanded.toggle() } label: {
                    Label("Details", systemImage: expanded ? "chevron.down" : "chevron.right").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless).font(.system(size: 11))
                .accessibilityHint(expanded ? "Hides the build receipt" : "Shows the full build receipt")
                if !message.text.isEmpty { CopyFeedbackButton(text: message.text, title: "Copy receipt") }
            }
            if expanded {
                Text(summary.testDescription).font(.caption).foregroundStyle(.secondary)
                ScrollView { MessageMarkdown(source: message.text).equatable().frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 420)
                if let detail = message.detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(SilkwireTheme.wash(0.02), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(needsAttention ? Color.orange.opacity(0.35) : SilkwireTheme.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Builder: \(headline), \(summary.owner), \(checks)")
        .id(message.id)
    }
}

/// The default view of a Builder receipt: one quiet line, e.g. "Claude finished a build ·
/// Ready for review". The full receipt card (BuilderActivityBar) is an off-by-default
/// developer setting, and is always one click away.
struct BuilderReceiptLine: View {
    static let cardsKey = "developer.builderReceiptCards"
    let message: Message
    var stop: (() -> Void)? = nil
    var expand: () -> Void
    private var summary: BuilderSummary { BuilderSummary.parse(message.text) }
    static func text(_ message: Message) -> String {
        let summary = BuilderSummary.parse(message.text)
        let who = summary.owner
        if ["sending", "streaming"].contains(message.state) { return "\(who) is building…" }
        return "\(who) finished a build · " + summary.headline(messageState: message.state)
    }
    var body: some View {
        let headline = summary.headline(messageState: message.state)
        HStack(spacing: 8) {
            Button(action: expand) {
                HStack(spacing: 8) {
                    Image(systemName: headline == "Needs attention" ? "exclamationmark.triangle" : headline == "Stopped" ? "stop.circle" : "hammer").font(.caption)
                        .foregroundStyle(headline == "Needs attention" ? Color.orange : Color.secondary)
                    Text(Self.text(message)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = message.createdAt { Text(date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary) }
                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            .help("Show the full Builder receipt")
            if let stop, ["sending", "streaming"].contains(message.state) {
                Button("Stop", action: stop).buttonStyle(SoftAccentButtonStyle(small: true)).tint(.purple)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 3).id(message.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.text(message) + ". Show the full receipt.")
    }
}
