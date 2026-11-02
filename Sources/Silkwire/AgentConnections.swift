import Foundation

/// The dedicated `silkwire-agents` SSH key and the connection status Silkwire shows
/// in Settings → Agents → Connections. The key is Silkwire's own, kept in the Staging
/// library, separate from Jason's personal keys so he can revoke it without losing his
/// own access. Silkwire never adds it to a server; it hands Jason the exact steps.
struct AgentSSHKey: Equatable {
    var privateKeyPath: String
    var publicKey: String
    var fingerprint: String
    var createdAt: Date
}

enum AgentConnections {
    static let comment = "silkwire-agents"

    static func keyDirectory(_ root: URL) -> URL { root.appendingPathComponent("Keys", isDirectory: true) }
    static func privateKeyURL(_ root: URL) -> URL { keyDirectory(root).appendingPathComponent("silkwire-agents") }
    static func publicKeyURL(_ root: URL) -> URL { keyDirectory(root).appendingPathComponent("silkwire-agents.pub") }

    /// The existing key, if one has been created.
    static func existing(_ root: URL) -> AgentSSHKey? {
        let priv = privateKeyURL(root), pub = publicKeyURL(root)
        guard FileManager.default.fileExists(atPath: priv.path),
              let publicKey = (try? String(contentsOf: pub, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !publicKey.isEmpty else { return nil }
        let created = (try? FileManager.default.attributesOfItem(atPath: priv.path)[.creationDate]) as? Date ?? Date()
        return AgentSSHKey(privateKeyPath: priv.path, publicKey: publicKey, fingerprint: fingerprint(publicKey) ?? "", createdAt: created)
    }

    /// Generate the dedicated ed25519 key with ssh-keygen (no passphrase, so agents can
    /// use it non-interactively). Refuses to clobber an existing key.
    static func create(_ root: URL) async throws -> AgentSSHKey {
        if let existing = existing(root) { return existing }
        let directory = keyDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let priv = privateKeyURL(root)
        // A stale private key with no public half: start clean.
        try? FileManager.default.removeItem(at: priv)
        try? FileManager.default.removeItem(at: publicKeyURL(root))
        let keygen = ["/usr/bin/ssh-keygen", "/opt/homebrew/bin/ssh-keygen"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/ssh-keygen"
        let result = try await NativeProcess.run(executable: keygen, arguments: ["-t", "ed25519", "-f", priv.path, "-N", "", "-C", comment, "-q"], directory: directory, environment: nativeProviderEnvironment(), timeoutSeconds: 30)
        guard result.exitCode == 0 else { throw nativeFailure("Could not create the agent key: " + limitedUTF16((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines), to: 300)) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: priv.path)
        guard let key = existing(root) else { throw nativeFailure("The agent key was generated but could not be read back.") }
        return key
    }

    /// Delete the dedicated key. The public key must still be removed from any server by Jason.
    @discardableResult static func delete(_ root: URL) -> Bool {
        let priv = privateKeyURL(root), pub = publicKeyURL(root)
        let a = (try? FileManager.default.removeItem(at: priv)) != nil || !FileManager.default.fileExists(atPath: priv.path)
        let b = (try? FileManager.default.removeItem(at: pub)) != nil || !FileManager.default.fileExists(atPath: pub.path)
        return a && b
    }

    /// The SHA-256 fingerprint ssh-keygen prints, for display. The private key is never read for this.
    static func fingerprint(_ publicKey: String) -> String? {
        let parts = publicKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = sha256Base64(blob)
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Plain-English steps for Jason to authorize the key on his server. Silkwire does not run these.
    static func setupSteps(_ key: AgentSSHKey, host: String = "your-server", user: String = "your-user") -> String {
        """
        Add this key to the Hostinger VPS yourself (Silkwire will not change the server):

        1. The agents' public key (safe to share):
           \(key.publicKey)
        2. On the server, append it to the account the agents should use:
           echo '\(key.publicKey)' >> ~/.ssh/authorized_keys
           Or from this Mac: ssh-copy-id -i "\(key.privateKeyPath)" \(user)@\(host)
        3. Test from this Mac:
           ssh -i "\(key.privateKeyPath)" \(user)@\(host) 'echo connected'
        4. To revoke later: remove that line from the server's authorized_keys, and press
           Disconnect here (which deletes Silkwire's copy of the private key).

        Agents use this key with: ssh -i "\(key.privateKeyPath)" \(user)@\(host) '<command>'.
        Your personal keys are untouched.
        """
    }
}

/// SHA-256 of data, base64 (used for the SSH fingerprint display). CryptoKit is linked.
import CryptoKit
func sha256Base64(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }
