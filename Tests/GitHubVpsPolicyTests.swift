import Foundation
import CoreGraphics
import CryptoKit

// GitHub + VPS ask-first rules, connection disconnect/no-key enforcement, the sudo
// and ssh-remote command parsing, and bare-token redaction. Synthetic data only;
// no real GitHub, server, key or network is used.
@MainActor final class StubComputerDriver: ComputerDriving {
    var backendName = "stub"
    var lastSyntheticEvent = Date.distantPast
    func target(for request: ComputerRequest) -> ComputerTarget { ComputerTarget() }
    func screenshot(app: String?, window: String?) async throws -> ComputerScreenshot { throw nativeFailure("no screen in this test") }
    func perform(_ request: ComputerRequest, shouldContinue: @escaping @MainActor () -> Bool) async throws -> [String: Any] { [:] }
}

@main struct GitHubVpsPolicyTests {
    /// OpenSSH encoding of a fresh CryptoKit Ed25519 fixture. No OS account lookup,
    /// shell, existing key or network. Test-only; no generated private bytes are logged.
    static func fixtureKey(_ root: URL) async throws -> AgentSSHKey {
        func number(_ n: UInt32) -> Data { Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]) }
        func string(_ data: Data) -> Data { number(UInt32(data.count)) + data }
        let key = Curve25519.Signing.PrivateKey(), kind = Data("ssh-ed25519".utf8)
        let publicBlob = string(kind) + string(key.publicKey.rawRepresentation)
        let check = UInt32.random(in: .min ... .max)
        var secret = number(check) + number(check) + string(kind) + string(key.publicKey.rawRepresentation)
        secret += string(key.rawRepresentation + key.publicKey.rawRepresentation) + string(Data("silkwire-policy-fixture".utf8))
        var padding: UInt8 = 1
        repeat { secret.append(padding); padding += 1 } while secret.count % 8 != 0
        let encoded = Data("openssh-key-v1\0".utf8) + string(Data("none".utf8)) + string(Data("none".utf8)) + string(Data()) + number(1) + string(publicBlob) + string(secret)
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + encoded.base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----\n"
        let directory = AgentConnections.keyDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let priv = AgentConnections.privateKeyURL(root), pub = AgentConnections.publicKeyURL(root)
        try Data(pem.utf8).write(to: priv, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: priv.path)
        try Data(("ssh-ed25519 " + publicBlob.base64EncodedString() + " silkwire-policy-fixture\n").utf8).write(to: pub, options: .atomic)
        guard let saved = AgentConnections.existing(root) else { throw nativeFailure("Ephemeral fixture key could not be read back") }
        return saved
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if ProcessInfo.processInfo.environment["SILKWIRE_POLICY_EXPECT_SANDBOX"] == "1", !NativeSandboxState.isSandboxed {
            throw nativeFailure("Expected the account-lookup-denied kernel sandbox")
        }
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) } }
        let settings = ComputerAccessSettings(), home = "/Users/alex"
        func req(_ args: [String: Any]) -> ComputerRequest { try! ComputerRequest.validate(args) }
        func decide(_ command: String, cwd: String? = nil, settings s: ComputerAccessSettings = settings) -> AskFirstDecision {
            var a: [String: Any] = ["action": "shell", "command": command]; if let cwd { a["cwd"] = cwd }
            return AskFirstPolicy.evaluate(ComputerActionContext(request: req(a), projectFolders: s.projectFolders, home: home, defaultDirectory: home + "/Projects"), settings: s)
        }
        func rule(_ d: AskFirstDecision) -> String? { if case .ask(let id, _, _) = d { return id }; return nil }

        // Default rules now include the two new ones, on.
        check(settings.rules.contains { $0.id == AskFirstPolicy.githubProtected } && settings.rules.contains { $0.id == AskFirstPolicy.serverOps }, "GitHub and server rules ship on by default")

        // GitHub: ordinary work proceeds; protected ops ask (incl. +refspec and over ssh).
        check(decide("git clone https://github.com/example-org/example-app", cwd: "~/Projects") == .proceed, "clone proceeds")
        check(decide("git checkout -b feature/x && git commit -am wip && git push -u origin feature/x", cwd: "~/Projects/silkwire") == .proceed, "own-branch push proceeds")
        check(decide("gh pr create --fill", cwd: "~/Projects/silkwire") == .proceed, "opening a PR proceeds")
        check(rule(decide("git push origin main", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "push to main asks")
        check(rule(decide("git push origin HEAD:master", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "push to master by refspec asks")
        check(rule(decide("git push -f origin feature/x", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "force-push asks")
        check(rule(decide("git push --force-with-lease origin main", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "force-with-lease asks")
        check(rule(decide("git push origin +feature/x", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "a +refspec force-push to any branch asks")
        check(rule(decide("git push origin +HEAD:feature/y", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "a +HEAD:branch force-push asks")
        check(rule(decide("git push origin --delete feature/old", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "deleting a remote branch asks")
        check(rule(decide("git push origin :feature/old", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "colon-refspec remote delete asks")
        check(rule(decide("git branch -D feature/old", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "force-deleting a local branch asks")
        check(rule(decide("gh pr merge 42 --squash", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "merging a PR asks")
        check(rule(decide("gh repo delete example-org/x --yes")) == AskFirstPolicy.githubProtected, "deleting a repo asks")
        check(rule(decide("ssh deploy@vps 'git -C /srv/app push --force origin main'")) == AskFirstPolicy.githubProtected, "a protected git push over ssh asks")

        // Server: reads proceed; deploys/restarts/config/db ask (local, sudo -u, over ssh).
        let key = "/Users/alex/Library/Application Support/Silkwire Staging/Computer Control/Keys/silkwire-agents"
        check(decide("ssh -i '\(key)' deploy@vps 'tail -n 200 /var/log/nginx/access.log'") == .proceed, "reading a log with the dedicated key via -i proceeds (not credentials)")
        check(decide("ssh vps 'systemctl status silkwire'") == .proceed, "service status proceeds")
        check(decide("ssh vps 'ls -la /var/www && cat /var/www/app/version.txt'") == .proceed, "listing and reading files over ssh proceeds")
        check(rule(decide("ssh vps 'systemctl restart nginx'")) == AskFirstPolicy.serverOps, "restart over ssh asks")
        check(rule(decide("ssh vps 'sudo -u postgres psql -c \"DROP TABLE sessions\"'")) == AskFirstPolicy.serverOps, "sudo -u postgres psql asks (the -u value is not the command)")
        check(rule(decide("ssh vps 'docker-compose -f /srv/app/compose.yml up -d'")) == AskFirstPolicy.serverOps, "docker-compose with -f before the action asks")
        check(rule(decide("ssh vps 'systemctl -H other restart app'")) == AskFirstPolicy.serverOps, "systemctl with a value-flag before the action asks")
        check(rule(decide("ssh vps 'npm run deploy'")) == AskFirstPolicy.serverOps, "a deploy over ssh asks")
        check(rule(decide("ssh vps 'pg_dump app > backup.sql'")) == AskFirstPolicy.serverOps, "a database dump over ssh asks")
        check(rule(decide("ssh vps 'echo cfg | sudo tee /etc/app/config.toml'")) == AskFirstPolicy.serverOps, "writing /etc config over ssh asks")
        check(rule(decide("systemctl restart app")) == AskFirstPolicy.serverOps, "a local service restart also asks")

        // The agent key: used via -i proceeds, but reading the key file itself asks + withholds.
        check(key.range(of: AskFirstPolicy.credentialPath, options: .regularExpression) != nil, "the agent key path is a known credential path")
        check(rule(decide("cat '\(key)'")) == AskFirstPolicy.credentials, "cat of the key file asks")
        check(rule(decide("cat ~/.config/gh/hosts.yml")) == AskFirstPolicy.credentials, "reading the gh token file asks (a case the combined base alone did not cover)")

        // segments resolves sudo value-flags.
        check(AskFirstPolicy.segments("sudo -u postgres psql -c x") == [["psql", "-c", "x"]], "a sudo value-flag consumes its argument")
        check(AskFirstPolicy.segments("sudo -H -u deploy systemctl restart app") == [["systemctl", "restart", "app"]], "mixed sudo flags strip to the real command")

        // Bare-token redaction (combined base redacted only key=value; this also masks `gh auth token`).
        check(HostLane.redact("ghp_0123456789abcdefghijklmnopqrstuvwx").contains("ghp_0123456789") == false, "a bare gh token is masked")
        check(HostLane.redact("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123456").contains("eyJzdWIi") == false, "a bare JWT is masked")
        check(HostLane.redact("the build finished in 3m, commit 1a2b3c4").contains("1a2b3c4"), "ordinary output is left intact")

        // Disconnect / no-key enforcement through the control center.
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GHVps-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Policy tests need a real ephemeral key, not ssh-keygen's account lookup.
        // The production default still uses AgentConnections.create/ssh-keygen;
        // AgentConnectionsTests covers its lifecycle separately.
        let center = ComputerControlCenter(root: root, driver: StubComputerDriver(), live: false, initialIdle: 3600, keyCreator: fixtureKey)
        func perform(_ command: String) async -> [String: Any] {
            await center.perform(req(["action": "shell", "command": command, "cwd": root.path, "timeout": 15]), agent: "claude", conversationID: UUID().uuidString.lowercased(), projectRoots: [], progress: { _ in }).result
        }
        // GitHub stays usable; a disconnected GitHub refuses gh but not local git.
        check(center.connectionConnected(AskFirstPolicy.github), "GitHub is connected by default")
        center.setConnection(AskFirstPolicy.github, connected: false)
        let ghOff = await perform("gh pr status")
        check(ghOff["ok"] as? Bool == false && ghOff["disconnected"] as? String == AskFirstPolicy.github, "a disconnected GitHub refuses gh")
        let localGit = await perform("git status")
        check(localGit["disconnected"] == nil, "a disconnected GitHub still allows local git")
        center.setConnection(AskFirstPolicy.github, connected: true)
        // Server: no key yet -> refused (never Jason's key); with a key -> allowed to run.
        let noKey = await perform("ssh deploy@vps 'uptime'")
        check(noKey["ok"] as? Bool == false && noKey["disconnected"] as? String == AskFirstPolicy.server, "server ssh is refused until a dedicated key exists")
        center.createAgentKey()
        let deadline = Date().addingTimeInterval(20)
        while center.agentKey == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        check(center.agentKey != nil, "the dedicated agent key is created")
        guard let createdKey = center.agentKey else { throw nativeFailure(center.notice ?? "Fixture key creation failed") }
        let withKey = await perform("ssh -o BatchMode=yes -o ConnectTimeout=3 -i '\(createdKey.privateKeyPath)' deploy@silkwire-agent-test.invalid 'echo hi'")
        check(withKey["disconnected"] == nil, "with a dedicated key, ssh is allowed to run (not refused)")
        center.setConnection(AskFirstPolicy.server, connected: false)
        let serverOff = await perform("ssh -i '\(createdKey.privateKeyPath)' deploy@vps 'uptime'")
        check(serverOff["disconnected"] as? String == AskFirstPolicy.server, "a disconnected server refuses ssh even with a key")

        print("GitHubVpsPolicyTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
