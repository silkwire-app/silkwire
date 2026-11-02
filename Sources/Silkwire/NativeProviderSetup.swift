import Foundation
import AppKit
import Combine

/// Sign-in is owned by the official provider tools. No auth URL, code, token,
/// private subprocess output or password is persisted, logged or sent to a room.
@MainActor final class NativeProviderSetup: ObservableObject {
    @Published private(set) var agent: String?
    @Published private(set) var message = ""
    private var operation: Task<Void, Never>?
    private var channel: NativeCodexRPC?
    private var generation = UUID()
    private var loginID: String?
    private var loginEvents: [String: Bool] = [:]
    private let codex: String, claude: String
    private let directory: URL?
    private let openBrowser: (URL) -> Bool
    private let loginTimeout: Double
    init(codex: String = ProviderPaths.codex, claude: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path, directory: URL? = nil, loginTimeout: Double = 600, openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.codex = codex; self.claude = claude; self.directory = directory
        self.loginTimeout = loginTimeout; self.openBrowser = openBrowser
    }
    static func validatedOpenAIURL(_ value: String) -> URL? {
        guard value.utf8.count <= 16_384, let url = URL(string: value),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              ["auth.openai.com", "chatgpt.com"].contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.fragment == nil else { return nil }
        return url
    }
    func signIn(_ provider: String, completed: @escaping () -> Void) {
        guard !WorkspaceEnvironment.current.agentTest else { message = "Private agent tests cannot inspect or change provider sign-ins."; return }
        guard agent == nil, ["codex", "claude"].contains(provider) else { return }
        let token = UUID(); generation = token; agent = provider; message = "Checking your existing account…"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                if provider == "codex" { try await self.signInCodex(token) }
                else { try await self.signInClaude(token) }
                guard self.generation == token, !Task.isCancelled else { return }
                self.finish("Signed in. Checking the connection…")
                completed()
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                // Deliberately do not expose provider diagnostics or an OAuth URL.
                self.finish(provider == "codex" ? "ChatGPT sign-in was not confirmed. Try again, or complete sign-in using the official Codex app/CLI, then Check again." : "Claude sign-in was not confirmed. Complete the official Claude Code setup (claude auth login --claudeai), then Check again. No API fallback is used.")
            }
        }
    }
    func cancel() {
        guard agent != nil else { return }
        generation = UUID(); operation?.cancel(); operation = nil
        let old = channel, id = loginID
        channel = nil; loginID = nil; loginEvents.removeAll(); agent = nil
        message = "Sign-in cancelled. Your existing accounts and conversations were not reset."
        // Cancel the provider's pending browser login before closing its owned
        // process. A short bound prevents an unresponsive tool retaining a task.
        if let old {
            Task { if let id { _ = try? await old.request("account/login/cancel", ["loginId": id], timeout: 2) }; old.close() }
        }
    }
    private func finish(_ text: String) {
        channel?.close(); channel = nil; loginID = nil; loginEvents.removeAll()
        agent = nil; operation = nil; message = text
    }
    private func signInCodex(_ token: UUID) async throws {
        let rpc = try NativeCodexRPC(executable: codex, directory: try directory ?? nativeProviderDirectory("Codex"), onEvent: { [weak self] event in
            guard let self, self.generation == token, event["method"] as? String == "account/login/completed",
                  let params = event["params"] as? [String: Any], let id = params["loginId"] as? String, id.utf8.count <= 256,
                  let success = params["success"] as? Bool, self.loginEvents.count < 8 else { return }
            self.loginEvents[id] = success
        }, onClose: { _ in })
        channel = rpc
        _ = try await rpc.request("initialize", ["clientInfo": ["name": "silkwire_signin", "version": "0.1.0"], "capabilities": [:]])
        try check(token); try rpc.write(["method": "initialized"])
        if try await chatGPTAccount(rpc) { return }
        try check(token)
        let login = try await rpc.request("account/login/start", ["type": "chatgpt"])
        // Cancel even if the returned URL is malformed/untrusted.
        if let id = login["loginId"] as? String, !id.isEmpty, id.utf8.count <= 256 { loginID = id }
        guard login["type"] as? String == "chatgpt", let id = loginID,
              let raw = login["authUrl"] as? String, let url = Self.validatedOpenAIURL(raw) else {
            if let id = loginID { _ = try? await rpc.request("account/login/cancel", ["loginId": id], timeout: 2) }
            throw nativeFailure("Invalid provider sign-in response.")
        }
        try check(token)
        guard openBrowser(url) else { _ = try? await rpc.request("account/login/cancel", ["loginId": id], timeout: 2); throw nativeFailure("Browser unavailable.") }
        message = "Finish signing in to ChatGPT in your browser. Silkwire is waiting for the official Codex confirmation."
        let deadline = Date().addingTimeInterval(loginTimeout)
        while Date() < deadline {
            try check(token)
            if let success = loginEvents[id] {
                guard success, try await chatGPTAccount(rpc) else { throw nativeFailure("Provider did not confirm sign-in.") }
                return
            }
            guard !rpc.closed else { throw nativeFailure("Provider sign-in connection closed.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = try? await rpc.request("account/login/cancel", ["loginId": id], timeout: 2)
        throw nativeFailure("Sign-in timed out.")
    }
    private func chatGPTAccount(_ rpc: NativeCodexRPC) async throws -> Bool {
        let result = try await rpc.request("account/read", ["refreshToken": false])
        return (result["account"] as? [String: Any])?["type"] as? String == "chatgpt"
    }
    private func check(_ token: UUID) throws {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }
    private func claudeAccount(_ folder: URL) async throws -> Bool {
        let result = try await NativeProcess.run(executable: claude, arguments: ["auth", "status"], directory: folder, environment: nativeProviderEnvironment(), timeoutSeconds: 10, outputLimit: 64_000)
        guard !result.truncated, result.exitCode == 0,
              let json = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any] else { return false }
        return json["loggedIn"] as? Bool == true && json["authMethod"] as? String == "claude.ai"
    }
    private func signInClaude(_ token: UUID) async throws {
        let folder = try directory ?? nativeProviderDirectory("Claude")
        if try await claudeAccount(folder) { return }
        try check(token)
        message = "Complete the official Claude Code browser sign-in. If no browser opens, cancel and use claude auth login --claudeai, then Check again."
        let result = try await NativeProcess.run(executable: claude, arguments: ["auth", "login", "--claudeai"], directory: folder, environment: nativeProviderEnvironment(), timeoutSeconds: loginTimeout, outputLimit: 128_000)
        try check(token)
        guard result.exitCode == 0, !result.truncated, try await claudeAccount(folder) else { throw nativeFailure("Claude did not confirm subscription sign-in.") }
    }
}
