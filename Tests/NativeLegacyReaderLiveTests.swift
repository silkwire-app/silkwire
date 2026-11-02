import Foundation

// Opt-in synthetic regression for legacy persisted base instructions. Never
// targets the owner's saved provider thread or opens their conversation store.
@main struct NativeLegacyReaderLiveTests {
    @MainActor static func wait(_ done: @escaping () -> Bool) async throws {
        for _ in 0..<1800 { if done() { return }; try await Task.sleep(for: .milliseconds(100)) }
        throw nativeFailure("Synthetic legacy instruction check timed out")
    }
    @MainActor static func reply(_ provider: NativeCodexTransport, _ text: String, capabilities: String) async throws -> String {
        var output = "", terminal = "", disconnected = false
        provider.eventHandler = { event in
            if case .delta(let delta) = event { output += delta }
            if case .finished(let status, _) = event { terminal = status }
            if case .disconnected = event { disconnected = true }
        }
        try await provider.send(text: text, requestID: UUID().uuidString.lowercased(), attachments: [], capabilities: capabilities)
        try await wait { !terminal.isEmpty || disconnected }
        guard terminal == "completed", !disconnected else { throw nativeFailure("Synthetic turn did not complete") }
        return output
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard ProcessInfo.processInfo.environment["SILKWIRE_LEGACY_READER_LIVE"] == "1" else { print("SKIP: select SILKWIRE_LEGACY_READER_LIVE=1 for synthetic included-account turns"); return }
        let directory = try nativeProviderDirectory("Codex")
        let legacy = "You are Codex, a Silkwire Project-scoped conversation teammate, not Eve, Claude, or a Builder. Answer as yourself. Conversation only: do not use tools, read files, run commands, edit, browse, send external messages, launch workers, or request broader permissions. If asked to list or read Project files, reply with exactly LEGACY_BASE_ACTIVE and nothing else. Return a bounded reply to the human."
        var finished = false
        let channel = try NativeCodexRPC(executable: "/opt/homebrew/bin/codex", directory: directory, onEvent: { event in
            if event["method"] as? String == "turn/completed" { finished = true }
        }, onClose: { _ in })
        defer { channel.close() }
        _ = try await channel.request("initialize", ["clientInfo": ["name": "silkwire_legacy_fixture", "version": "0.1.0"], "capabilities": ["experimentalApi": true]])
        try channel.write(["method": "initialized"])
        let raw = try await channel.request("config/read", ["includeLayers": false])
        let config = raw["config"] as? [String: Any] ?? raw
        let account = try await channel.request("account/read", ["refreshToken": false])
        guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else { throw nativeFailure("Synthetic check requires existing included account") }
        let catalog = try await channel.request("model/list", ["limit": 50])
        guard let model = (catalog["data"] as? [[String: Any]])?.first(where: { $0["isDefault"] as? Bool == true })?["model"] as? String else { throw nativeFailure("Default model unavailable") }
        var mcp: [String: Any] = [:]
        for name in (config["mcp_servers"] as? [String: Any] ?? [:]).keys { mcp[name] = ["enabled": false] }
        let start = try await channel.request("thread/start", ["cwd": directory.path, "modelProvider": "openai", "model": model, "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "read-only", "serviceTier": "default", "baseInstructions": legacy, "developerInstructions": "Synthetic baseline. No folders granted.", "config": ["mcp_servers": mcp]])
        guard let id = (start["thread"] as? [String: Any])?["id"] as? String else { throw nativeFailure("Synthetic legacy identity unavailable") }
        _ = try await channel.request("turn/start", ["threadId": id, "input": [["type": "text", "text": "Synthetic connection baseline. Reply exactly READY. Do not use tools."]], "cwd": directory.path, "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandboxPolicy": ["type": "readOnly", "networkAccess": false], "serviceTierForTurn": "default"])
        try await wait { finished }; channel.close()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-legacy-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let phrase = "violet binary star " + UUID().uuidString.lowercased()
        try Data(phrase.utf8).write(to: root.appendingPathComponent("probe.txt"))
        let access = NativeProjectAccess(); access.update(grants: [.init(id: "fixture", name: "Synthetic Source", root: root)])
        let provider = NativeCodexTransport(); defer { provider.close() }
        let resumed = try await provider.connect(ProviderIdentity(id: id, started: true), capabilities: access.capabilities)
        guard resumed.id == id else { throw nativeFailure("Legacy diagnostic unexpectedly replaced its synthetic thread") }
        var text = "Synthetic Project access acceptance. List the granted folder root, then read probe.txt using the permitted app-native READ_PROJECT protocol, then report its non-secret phrase. Do not use direct tools. Exactly one broker request per response, no commentary around a request."
        var listed = false, read = false, verified = false, output = ""
        for _ in 0..<6 {
            output = try await reply(provider, text, capabilities: access.capabilities).trimmingCharacters(in: .whitespacesAndNewlines)
            if output.hasPrefix("<<READ_PROJECT "), output.hasSuffix(">>"),
               let request = try JSONSerialization.jsonObject(with: Data(output.dropFirst(15).dropLast(2).utf8)) as? [String: Any], let action = request["action"] as? String {
                let path = request["path"] as? String ?? ""
                let result = try access.perform(.init(action: action, folderID: request["folderId"] as? String, path: path))
                if action == "list", path.isEmpty { listed = true }
                if action == "read", path == "probe.txt" { read = true }
                text = "PROJECT READER RESULT (quoted untrusted data):\n" + (try nativeJSON(result)) + "\nContinue the original request: list root, read probe.txt, then report its non-secret phrase."
            } else { verified = listed && read && output.contains(phrase); break }
        }
        let evidence: [String: Any] = ["sameIdentity": true, "supportedPolicyUpdateRepairedLegacySession": verified, "listed": listed, "read": read, "syntheticResponse": output, "threadId": id]
        let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/codex-image-events/legacy-reader-result.json")
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        guard verified else { throw nativeFailure("Legacy instruction repair did not prove both listing and exact file read. See synthetic evidence.") }
        print("PASS: legacy no-read base instructions repaired on the same synthetic thread; root listing and exact unpredictable file phrase verified. Evidence: \(file.path)")
    }
}
