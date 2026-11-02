import Foundation

@main struct NativeBookmarkTests {
    static func main() throws {
        let directory = try NativeTemporaryDirectory.canonical(FileManager.default.temporaryDirectory).appendingPathComponent("silkwire-bookmark-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            _ = try directory.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            print("PASS native security-scoped bookmark creation on a synthetic directory")
        } catch {
            throw NSError(domain: "Silkwire.TestCapability", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native test capability failed: create a read-only security-scoped bookmark for a synthetic temporary folder. " + error.localizedDescription])
        }
    }
}
