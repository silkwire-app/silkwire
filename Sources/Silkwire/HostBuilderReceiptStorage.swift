import Foundation

/// Serial receipt writes off MainActor. A stale async callback cannot overwrite
/// a newer final receipt. Physical ownership durability is separately handled by D2.
actor HostBuilderReceiptStorage {
    private var revisions: [URL: UInt64] = [:]
    func save(_ receipt: [String: Any], to path: URL, revision: UInt64) throws {
        guard revision > (revisions[path] ?? 0) else { return }
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        revisions[path] = revision
    }
}
