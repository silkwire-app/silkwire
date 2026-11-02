import Foundation

// The dedicated silkwire-agents SSH key: a real ssh-keygen ed25519 key in a temp
// library, separate from Jason's keys. No real server or personal key is touched.
@main struct AgentConnectionsTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AgentConnections-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        check(AgentConnections.existing(root) == nil, "no agent key exists until one is created")
        let key = try await AgentConnections.create(root)
        check(FileManager.default.fileExists(atPath: key.privateKeyPath), "the private key is written into the Staging library")
        check(key.publicKey.hasPrefix("ssh-ed25519 ") && key.publicKey.contains("silkwire-agents"), "a labelled ed25519 public key is produced")
        check(key.fingerprint.hasPrefix("SHA256:") && key.fingerprint.count > 10, "a SHA-256 fingerprint is shown")

        // The private key lives only in the dedicated library location, not among Jason's ~/.ssh keys.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        check(key.privateKeyPath.contains("/Keys/silkwire-agents") && !key.privateKeyPath.hasPrefix(home + "/.ssh/"), "the key is Silkwire's own, not in the personal ~/.ssh")
        let mode = (try FileManager.default.attributesOfItem(atPath: key.privateKeyPath)[.posixPermissions] as? NSNumber)?.intValue
        check(mode == 0o600, "the private key is owner-read/write only")

        // Creating again returns the same key rather than clobbering it.
        let again = try await AgentConnections.create(root)
        check(again.publicKey == key.publicKey, "create is idempotent; an existing key is kept")

        // The setup steps show the public key and never read the private key out.
        let steps = AgentConnections.setupSteps(key, host: "vps.example", user: "deploy")
        let privateKeyText = try String(contentsOfFile: key.privateKeyPath, encoding: .utf8)
        check(steps.contains(key.publicKey) && steps.contains("authorized_keys") && steps.contains("ssh -i"), "the steps show the public key and how to authorize it")
        check(!steps.contains("PRIVATE KEY") && !steps.contains(privateKeyText), "the steps never include the private key")

        // The private-key path is recognized as a credential path, so reading it asks and redacts.
        check(key.privateKeyPath.range(of: AskFirstPolicy.credentialPath, options: .regularExpression) != nil, "the agent key path is a known credential path")
        let readKey = try HostLane.read(ComputerRequest.validate(["action": "read", "path": key.privateKeyPath]))
        check(readKey["redacted"] as? Bool == true, "reading the agent key comes back flagged redacted")

        // Disconnect deletes Silkwire's copy.
        check(AgentConnections.delete(root) && AgentConnections.existing(root) == nil, "Disconnect removes Silkwire's copy of the key")
        check(!FileManager.default.fileExists(atPath: key.privateKeyPath), "the private key file is gone after Disconnect")

        print("AgentConnectionsTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
