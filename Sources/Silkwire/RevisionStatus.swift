import Foundation
import SwiftUI

struct SourceRevision: Identifiable, Equatable {
    let id: String
    let name: String
    let head: String?
    let modified: Bool?
    let isSilkwire: Bool
    let error: String?
    static func inspect(id: String, name: String, root: URL) async -> SourceRevision {
        let env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0"]
        do {
            let head = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "rev-parse", "--verify", "HEAD"], directory: root, environment: env, timeoutSeconds: 10, outputLimit: 1024)
            let status = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "status", "--porcelain=v1", "--untracked-files=all"], directory: root, environment: env, timeoutSeconds: 10, outputLimit: 65536)
            let revision = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.exitCode == 0, status.exitCode == 0,
                  revision.range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) != nil else { throw nativeFailure("Revision unavailable (not a readable Git source).") }
            return SourceRevision(id: id, name: name, head: revision, modified: !status.stdout.isEmpty || status.truncated,
                                  isSilkwire: FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Silkwire/SilkwireApp.swift").path), error: nil)
        } catch { return SourceRevision(id: id, name: name, head: nil, modified: nil, isSilkwire: false, error: error.localizedDescription) }
    }
    func mismatch(running: String?) -> Bool { isSilkwire && head != nil && running != nil && (head != running || modified == true) }
}

struct RevisionStatusView: View {
    @ObservedObject var store: ConversationStore
    @State private var sources: [SourceRevision] = []
    @State private var checked: Date?
    @State private var checking = false
    private let running = Bundle.main.object(forInfoDictionaryKey: "SilkwireGitRevision") as? String
    private var folderKey: String { (store.activeProject?.connectedFolders ?? []).map { $0.id.uuidString + $0.path }.joined() }
    var body: some View {
        DisclosureGroup("Build, source and workspace revisions") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Running build: " + (running ?? "not recorded")).textSelection(.enabled)
                let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Silkwire Staging.app/Contents/Info.plist")
                let installed = (NSDictionary(contentsOf: path) as? [String: Any])?["SilkwireGitRevision"] as? String
                Text("Installed Staging: " + (installed ?? "unavailable")).textSelection(.enabled)
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name + ": " + (source.head ?? source.error ?? "unavailable") + (source.modified == true ? " · modified" : "")).textSelection(.enabled)
                        if source.mismatch(running: running) { Label("Connected source differs from the running build. New workspaces start from that source, not from the installed app.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }
                ForEach(store.trustedReceipts.keys.sorted(), id: \.self) { id in
                    let receipt = store.trustedReceipts[id] ?? [:]
                    let transfer = receipt["transfer"] as? [String: Any]
                    Text("\(receipt["owner"] as? String ?? "Teammate") workspace \(id.prefix(8)) · \(receipt["status"] as? String ?? "unknown")\nBase: \(receipt["baseCommit"] as? String ?? "unavailable")\nHead: \(transfer?["headCommit"] as? String ?? "not finished")").textSelection(.enabled)
                }
                HStack { Button(checking ? "Checking…" : "Check revisions") { Task { await refresh() } }.disabled(checking); if let checked { Text("Checked " + checked.formatted()).foregroundStyle(.secondary) } }
                Text("Revision checks are read-only snapshots. Different revisions do not establish which one contains newer work.").foregroundStyle(.secondary)
            }.font(.caption).padding(.top, 8)
        }.task(id: folderKey) { await refresh() }
    }
    @MainActor private func refresh() async {
        guard !checking else { return }; checking = true; defer { checking = false }
        let key = folderKey, folders = store.activeProject?.connectedFolders ?? []
        var values: [SourceRevision] = []
        for folder in folders {
            guard let root = try? nativeResolveProjectFolder(folder), store.environment.permitsReading(root) else {
                values.append(SourceRevision(id: folder.id.uuidString, name: folder.name, head: nil, modified: nil, isSilkwire: false, error: "Current folder grant unavailable")); continue
            }
            let scoped = root.startAccessingSecurityScopedResource(); defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            values.append(await SourceRevision.inspect(id: folder.id.uuidString, name: folder.name, root: root))
        }
        guard key == folderKey else { return }
        sources = values; checked = Date()
    }
}
