import Foundation

// Explicit release acceptance of this repository's complete packaging command
// inside the same private execution boundary offered to the room teammates.
@main struct TrustedAppBuildTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard ProcessInfo.processInfo.environment["SILKWIRE_TRUSTED_APP_BUILD"] == "1" else { print("SKIP full app sandbox build: opt in with SILKWIRE_TRUSTED_APP_BUILD=1 from a clean committed worktree"); return }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let evidence = source.appendingPathComponent("output/trusted-app-build/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let engine = NativeBuilder(onReceipt: { _ in }, storageRoot: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-full-app-" + UUID().uuidString), ownership: HostOwnershipDefault.coordinator)
        let start = try await engine.beginTrusted(source: source, task: "Verify full app packaging and StorageTests inside trusted private workspace", owner: "eve")
        print("Private full-build workspace: \(start["worktreePath"] ?? "missing")")
        for command in ["/usr/bin/swift Scripts/build.swift --staging", "/usr/bin/swift Scripts/test.swift StorageTests"] {
            print("RUN " + command)
            let result = try await engine.trustedOperation(["action": "run", "command": command])
            let output = result["output"] as? String ?? ""
            print(output)
            guard result["ok"] as? Bool == true, (result["exitCode"] as? NSNumber)?.intValue == 0, result["timedOut"] as? Bool != true else {
                _ = try? await engine.finishTrusted(summary: "Full app sandbox gate failed")
                throw nativeFailure("Full app sandbox gate failed; inspect retained workspace and receipt.")
            }
        }
        let receipt = try await engine.finishTrusted(summary: "Full Silkwire Staging packaging and StorageTests passed inside private command sandbox")
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("receipt.json"), options: [.atomic])
        guard receipt["sourceUnchanged"] as? Bool == true, receipt["status"] as? String == "review", let path = receipt["worktreePath"] as? String,
              FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: path).appendingPathComponent("output/staging/Silkwire Staging.app/Contents/MacOS/Silkwire").path) else { throw nativeFailure("Full app/source preservation evidence missing.") }
        print("PASS complete app packaging, local tests and original-source preservation through trusted command sandbox. Receipt: " + evidence.appendingPathComponent("receipt.json").path)
    }
}
