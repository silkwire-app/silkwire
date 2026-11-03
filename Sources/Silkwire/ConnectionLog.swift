import SwiftUI
import AppKit

/// One shared, plain-text history of every teammate's connection: connects, drops,
/// reconnects and failures, each with its reason. Lives in this app's own library
/// (Diagnostics/connections.log). Only timings, states, reasons and exit codes are
/// written, never message text or credentials. Kept small: past 400 KB the oldest half
/// is dropped.
enum ConnectionLog {
    static var folderOverride: URL?
    static var url: URL { (folderOverride ?? WorkspaceEnvironment.current.library.appendingPathComponent("Diagnostics", isDirectory: true)).appendingPathComponent("connections.log") }
    private static let lock = NSLock()

    static func line(agent: String, event: String, detail: String, at date: Date = Date()) -> String {
        let clean = String(detail.replacingOccurrences(of: "\n", with: " ").prefix(240))
        return "\(ISO8601DateFormatter().string(from: date)) \(agent) \(event) \(clean)\n"
    }
    /// The last reason a new entry could not be saved, or nil once a save succeeds.
    /// Shown in Connection history so a broken log is never mistaken for a quiet one.
    private(set) static var lastWriteError: String?

    /// Keeps the newest half of an oversized log, starting at a whole line. Cutting at a

    /// (one byte, never inside a multi-byte character) means the result is always
    /// complete entries and valid UTF-8 if the input was.
    static func trimmed(_ data: Data, over limit: Int = 400_000, keep: Int = 200_000) -> Data {
        guard data.count > limit else { return data }
        let tail = data.suffix(keep)
        guard let newline = tail.firstIndex(of: 0x0A) else { return Data() }
        return Data(tail[tail.index(after: newline)...])
    }

    static func record(agent: String, event: String, detail: String) {
        let entry = Data(line(agent: agent, event: event, detail: detail).utf8)
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var existing = Data()
            if FileManager.default.fileExists(atPath: url.path) { existing = try Data(contentsOf: url) }
            existing = trimmed(existing)
            existing.append(entry)
            try existing.write(to: url, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
        }
    }

    enum History: Equatable {
        case entries([String])
        case empty
        case unreadable(String)
    }

    /// Newest first, optionally only one teammate's lines. A missing file is an honest
    /// "nothing yet"; a file that exists but cannot be read is reported as such.
    static func history(agent: String?, limit: Int = 40) -> History {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .unreadable(error.localizedDescription) }
        // Decode leniently so one damaged byte cannot hide the whole history.
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init).filter { line in
            guard let agent else { return true }
            let parts = line.split(separator: " ", maxSplits: 2)
            return parts.count > 1 && parts[1] == agent
        }
        return lines.isEmpty ? .empty : .entries(Array(lines.suffix(limit).reversed()))
    }

    /// Newest first, optionally only one teammate's lines (empty when nothing can be shown).
    static func recent(agent: String?, limit: Int = 40) -> [String] {
        if case .entries(let lines) = history(agent: agent, limit: limit) { return lines }
        return []
    }
}

/// Connections › "Connection history": what happened to each teammate's link, and why.
struct ConnectionHistoryCard: View {
    let agent: String?
    @State private var expanded = false
    @State private var lines: [String] = []
    @State private var problem: String?
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if lines.isEmpty && problem == nil {
                    Text("Nothing recorded yet. Connects, drops and reconnects will appear here with their reasons.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Button("Refresh") { reload() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConnectionLog.url]) }.disabled(!FileManager.default.fileExists(atPath: ConnectionLog.url.path))
                    Spacer()
                    Text("Times, reasons and codes only. No messages or passwords.").font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 4)
            }.padding(.top, 6)
        } label: {
            Label(agent == nil ? "Connection history" : "Connection history for \(names[agent!] ?? agent!)", systemImage: "waveform.path.ecg").font(.callout.weight(.medium))
        }
        .padding(12).background(SilkwireTheme.wash(0.025), in: RoundedRectangle(cornerRadius: 9))
        .onAppear(perform: reload)
        .onChange(of: agent) { _, _ in reload() }
        .onChange(of: expanded) { _, open in if open { reload() } }
    }
    private func reload() {
        switch ConnectionLog.history(agent: agent) {
        case .entries(let found): lines = found; problem = nil
        case .empty: lines = []; problem = nil
        case .unreadable(let reason): lines = []; problem = "Couldn't read the connection history: \(reason)"
        }
        if let failed = ConnectionLog.lastWriteError {
            problem = (problem.map { $0 + " " } ?? "") + "The latest entry couldn't be saved: \(failed)"
        }
    }
}
