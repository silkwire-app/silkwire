import Foundation

/// Opt-in synthetic provider check. Never supplies owner conversation text or prints account diagnostics.
@main struct NativeProviderLiveTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let providers: [(String, NativeAgentTransport)] = [("codex", NativeCodexTransport()), ("claude", NativeClaudeTransport())]
        for (name, provider) in providers {
            var terminal: String?, text = "", disconnected = false
            provider.eventHandler = { event in
                switch event {
                case .delta(let delta): text += delta
                case .replace(let replacement): text = replacement
                case .finished(let status, _): terminal = status
                case .disconnected: disconnected = true
                default: break
                }
            }
            let identity = try await provider.connect(nil, capabilities: "No Project folders connected. No file access, editing, tools, or execution granted.")
            guard !identity.id.isEmpty else { throw nativeFailure("\(name) identity missing") }
            print("PASS \(name) official CLI connected with existing included account and restricted boundary")
            let detail = try await provider.connectionDetail()
            guard detail.signedIn else { throw nativeFailure("\(name) included sign-in not confirmed") }
            print("PASS \(name) connection details checked without changing sign-in or default model")
            if !CommandLine.arguments.contains("--connect-only") {
                try await provider.send(text: "Synthetic integration check only. Reply exactly: SILKWIRE_NATIVE_OK", requestID: UUID().uuidString.lowercased(), attachments: [], capabilities: "No Project folders connected. No file access, editing, tools, or execution granted.")
                for _ in 0..<1800 where terminal == nil && !disconnected { try await Task.sleep(nanoseconds: 100_000_000) }
                guard terminal == "completed", text.trimmingCharacters(in: .whitespacesAndNewlines) == "SILKWIRE_NATIVE_OK" else { provider.close(); throw nativeFailure("\(name) synthetic reply was not confirmed; provider text withheld.") }
                print("PASS \(name) synthetic streamed reply completed with exact final text")
                guard let saved = provider.identity else { throw nativeFailure("Provider identity not persisted") }
                provider.close()
                let updatedCapabilities = "Updated Project capabilities: still no folders, editing, tools, or execution granted."
                let resumed = try await provider.connect(saved, capabilities: updatedCapabilities)
                guard resumed.id == saved.id, resumed.started == true else { throw nativeFailure("\(name) saved provider identity was replaced") }
                print("PASS \(name) reconnect preserved started provider identity")
                text = ""; terminal = nil; disconnected = false
                try await provider.send(text: "Synthetic resumed integration check only. Reply exactly: SILKWIRE_RESUMED_OK", requestID: UUID().uuidString.lowercased(), attachments: [], capabilities: updatedCapabilities)
                for _ in 0..<1800 where terminal == nil && !disconnected { try await Task.sleep(nanoseconds: 100_000_000) }
                guard terminal == "completed", text.trimmingCharacters(in: .whitespacesAndNewlines) == "SILKWIRE_RESUMED_OK" else { provider.close(); throw nativeFailure("\(name) resumed reply was not confirmed; provider text withheld.") }
                print("PASS \(name) resumed synthetic turn completed after capability refresh")
            }
            provider.close()
        }
    }
}
