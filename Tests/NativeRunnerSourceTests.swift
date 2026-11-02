import Foundation

// Compile the real test runner/core inside an actual host command sandbox. This
// must run from a clean source checkpoint, so its nested checkout has exact provenance.
@main struct NativeRunnerSourceTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = try NativeTemporaryDirectory.createWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let engine = NativeBuilder(onReceipt: { _ in }, storageRoot: root.appendingPathComponent("runs"), ownership: HostOwnershipDefault.coordinator)
        let begin = try await engine.beginTrusted(source: source, task: "Compile and execute native tests inside the host boundary", owner: "codex")
        let command = "/usr/bin/swift -module-cache-path \"$TMPDIR/runner-modules\" Scripts/test.swift BrokerRunningStopReviewTests MemoryProtocolTests WorkspaceTemporaryTests"
        let result = try await engine.trustedOperation(["action": "run", "command": command])
        print(result["output"] as? String ?? "Missing output")
        let finish = try await engine.finishTrusted(summary: "Real source test runner exercised under Seatbelt")
        let evidence = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("native-runner-source-receipt.json")
        try JSONSerialization.data(withJSONObject: finish, options: [.prettyPrinted, .sortedKeys]).write(to: evidence, options: .atomic)
        guard result["ok"] as? Bool == true, result["outputTruncated"] as? Bool == false,
              finish["sourceUnchanged"] as? Bool == true,
              !(finish["nestedCommands"] as? [[String: Any]] ?? []).isEmpty else {
            throw nativeFailure("Actual sandboxed source test runner failed: " + ((try? nativeJSON(result)) ?? "No receipt"))
        }
        print("PASS sandboxed Scripts/test.swift compiled the exact core and ran nested command Stop, memory and scratch tests; base " + (begin["baseCommit"] as? String ?? "missing"))
    }
}
