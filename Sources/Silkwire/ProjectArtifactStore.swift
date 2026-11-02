import Foundation

/// Explicit Project outputs only. No transcript, task prompt, provider identity or folder grant is copied.
struct ProjectArtifactStore {
    let root: URL
    init(storage: URL, projectID: UUID) { root = storage.appendingPathComponent("Project Artifacts/" + projectID.uuidString.lowercased()) }
    func record(_ receipt: [String: Any], from workspace: URL) throws {
        guard let id = receipt["id"] as? String, let uuid = UUID(uuidString: id),
              let owner = receipt["owner"] as? String, agents.contains(owner),
              receipt["finishedAt"] != nil, ["review", "failed", "stopped"].contains(receipt["status"] as? String ?? "") else { return }
        if let existing = saved(id), existing.receipt["finishedAt"] as? String == receipt["finishedAt"] as? String,
           existing.receipt["status"] as? String == receipt["status"] as? String,
           (existing.receipt["transfer"] as? [String: Any])?["bundleSha256"] as? String == (receipt["transfer"] as? [String: Any])?["bundleSha256"] as? String {
            return // Finished output is immutable. Do not rehash/copy every bundle on every room change.
        }
        let target = root.appendingPathComponent(uuid.uuidString)
        let keys: Set<String> = ["id", "owner", "status", "mode", "branch", "baseCommit", "checkpoint", "finishedAt", "checks", "diff", "diffTruncated", "steps", "sourceUnchanged", "applied"]
        var output = receipt.filter { keys.contains($0.key) }
        if let steps = receipt["steps"] as? [[String: Any]] {
            let publicEvidence: Set<String> = ["command", "status", "exitCode", "outputTruncated", "timedOut", "check", "evidence", "startedAt", "finishedAt", "absorbedNonzero"]
            output["steps"] = steps.map { $0.filter { publicEvidence.contains($0.key) } }
        }
        output["outputPolicy"] = "Raw command output and private summaries stay in the originating room; source diff, transfer and recorded check outcomes are shared."
        output["scope"] = "Project artifact; carries no room permissions or private transcript"
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if var transfer = receipt["transfer"] as? [String: Any], transfer["available"] as? Bool == true {
            let directory = target.appendingPathComponent("transfer")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, hashKey, pathKey) in [("changes.bundle", "bundleSha256", "bundlePath"), ("changes.patch", "patchSha256", "patchPath")] {
                let source = workspace.appendingPathComponent("transfer/" + name)
                guard (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let expected = transfer[hashKey] as? String,
                      let bytes = try? Data(contentsOf: source), StagingInstaller.sha(bytes) == expected else {
                    throw nativeFailure("Project artifact \(id): \(name) does not match its finished receipt. Nothing shared.")
                }
                let file = directory.appendingPathComponent(name)
                try bytes.write(to: file, options: .atomic); transfer[pathKey] = file.path
            }
            transfer.removeValue(forKey: "fetchCommand")
            output["transfer"] = transfer
        }
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: target.appendingPathComponent("receipt.json"), options: .atomic)
    }
    func saved(_ id: String) -> (agent: String, root: URL, receipt: [String: Any])? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let directory = root.appendingPathComponent(uuid.uuidString)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("receipt.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (value["id"] as? String).flatMap(UUID.init(uuidString:)) == uuid,
              let owner = value["owner"] as? String, agents.contains(owner), value["finishedAt"] != nil else { return nil }
        return (owner, directory, value)
    }
    func catalogPage(start: Int, count: Int) throws -> [String: Any] {
        guard start > 0, (1...200).contains(count) else { throw nativeFailure("Use a positive artifact offset and 1–200 results.") }
        let files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let page: [[String: String]] = files.dropFirst(min(files.count, start - 1)).prefix(count).compactMap { file in
            guard let saved = saved(file.lastPathComponent) else { return nil }
            return ["id": file.lastPathComponent.lowercased(), "owner": saved.agent, "receiptStatus": saved.receipt["status"] as? String ?? "unknown", "kind": "finished Project artifact"]
        }
        return ["artifacts": page, "total": files.count, "startLine": start, "scope": "finished outputs in the current Project only; no transcripts or room permissions"]
    }
    @MainActor func artifacts() -> [NativeBuildArtifact] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(8).compactMap { file in
            guard let saved = saved(file.lastPathComponent) else { return nil }
            return NativeBuildArtifact(id: file.lastPathComponent.lowercased(), text: NativeWorkspaceReceipt.text(saved.receipt), state: saved.receipt["status"] as? String == "review" ? "completed" : "failed")
        }
    }
}
