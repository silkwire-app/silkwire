import Foundation

// Tracks the actual diff lines supplied by the host reader to each reviewer.
// A decision binds to that exact finished head and full, untruncated diff.
@MainActor final class WorkspaceReviewLedger {
    private var coverage: [String: Set<Int>] = [:]
    private let root: URL
    init(root: URL) { self.root = root }
    private func key(_ agent: String, _ id: String, _ hash: String) -> String { agent + ":" + id.lowercased() + ":" + hash }
    func read(agent: String, id: String, page: [String: Any]) {
        guard let hash = page["diffSha256"] as? String, let start = page["startLine"] as? Int, let lines = page["lines"] as? [String],
              page["live"] as? Bool != true, page["diffTruncated"] as? Bool != true else { return }
        coverage[key(agent, id, hash), default: []].formUnion(start..<(start + lines.count))
    }
    func record(agent: String, saved: [String: Any], head: String, hash: String, decision: String, summary: String) throws -> [String: Any] {
        guard let id = saved["id"] as? String, let owner = saved["owner"] as? String, owner != agent,
              saved["status"] as? String == "review", saved["finishedAt"] != nil, saved["diffTruncated"] as? Bool != true,
              let transfer = saved["transfer"] as? [String: Any], transfer["available"] as? Bool == true, transfer["headCommit"] as? String == head,
              transfer["conflictMarkersRemain"] as? Bool == false, transfer["conflictScanComplete"] as? Bool == true,
              let diff = saved["diff"] as? String, NativeScopedRoot.sha256(Data(diff.utf8)) == hash,
              ["approved", "changesRequested"].contains(decision), !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.utf16.count <= 8000 else {
            throw nativeFailure("Review needs another teammate's finished transferable head, exact diff hash, decision and summary.")
        }
        let count = diff.isEmpty ? 0 : diff.components(separatedBy: "\n").count
        let supplied = coverage[key(agent, id, hash)] ?? []
        guard count > 0, supplied.count >= count, (1...count).allSatisfy({ supplied.contains($0) }) else { throw nativeFailure("Read every page of this finished diff through READ_PROJECT before recording a review. Live, shortened and truncated diffs cannot satisfy review coverage.") }
        let value: [String: Any] = ["workspaceId": id, "owner": owner, "reviewer": agent, "headCommit": head, "diffSha256": hash,
                                    "decision": decision, "summary": summary, "at": ISO8601DateFormatter().string(from: Date()), "linesSupplied": count,
                                    "note": "Teammate review attestation; does not certify tests, integration or installation."]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: root.appendingPathComponent(id.lowercased() + ".json"), options: .atomic)
        return value
    }
    func approved(_ saved: [String: Any]) throws -> [String: Any] {
        guard let id = saved["id"] as? String, UUID(uuidString: id) != nil,
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(id.lowercased() + ".json"))) as? [String: Any],
              value["decision"] as? String == "approved", value["reviewer"] as? String != saved["owner"] as? String,
              let transfer = saved["transfer"] as? [String: Any], value["headCommit"] as? String == transfer["headCommit"] as? String,
              value["diffSha256"] as? String == NativeScopedRoot.sha256(Data((saved["diff"] as? String ?? "").utf8)) else {
            throw nativeFailure("This exact head has no approving independent teammate review. Nothing integrated.")
        }
        return value
    }
}
