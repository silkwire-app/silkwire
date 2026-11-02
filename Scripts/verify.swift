#!/usr/bin/env swift
import Foundation

// The verification bundle never opens the owner's library. Every run gets its
// own synthetic native library; real-provider checks are explicitly selected.
// Pure path regression checks (no app launch or test-library writes):
//   swift Scripts/verify.swift --self-test
func verificationFailure(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "Silkwire.Verify", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

// Callers resolve existing parent directories before supplying these roots.
// Match the verification app's Application Support exclusion, not a worktree
// exception: private worktrees themselves can live inside Application Support.
func verificationDataURL(temporaryRoot: URL, supportRoot: URL, runID: UUID) throws -> URL {
    let data = temporaryRoot.standardizedFileURL.appendingPathComponent("Silkwire-Verification-" + runID.uuidString, isDirectory: true)
    let support = supportRoot.standardizedFileURL.path
    guard data.path != support, !data.path.hasPrefix(support + "/") else {
        throw verificationFailure(4, "Verification refuses a temporary directory inside Application Support. No test app was launched; library protection was not bypassed.")
    }
    return data
}

let requested = Array(CommandLine.arguments.dropFirst())
if requested == ["--self-test"] {
    do {
        let support = URL(fileURLWithPath: "/synthetic/Library/Application Support", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/synthetic/tmp", isDirectory: true)
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var count = 0
        func check(_ label: String, _ passed: Bool) throws {
            guard passed else { throw verificationFailure(5, "FAIL: " + label) }
            count += 1; print("PASS: " + label)
        }
        let data = try verificationDataURL(temporaryRoot: temporary, supportRoot: support, runID: runID)
        try check("synthetic data uses the temporary root", data.deletingLastPathComponent().path == temporary.path)
        try check("synthetic data has a bounded UUID name", data.lastPathComponent == "Silkwire-Verification-" + runID.uuidString)
        let other = try verificationDataURL(temporaryRoot: temporary, supportRoot: support, runID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        try check("separate runs get separate libraries", other != data)
        try check("Application Support itself is refused", (try? verificationDataURL(temporaryRoot: support, supportRoot: support, runID: runID)) == nil)
        let oldWorktree = support.appendingPathComponent("Silkwire Staging/Team Workspaces/example/worktree/output")
        try check("the old worktree-local location is refused", (try? verificationDataURL(temporaryRoot: oldWorktree, supportRoot: support, runID: runID)) == nil)
        let normalized = temporary.appendingPathComponent("../Library/Application Support/nested")
        try check("normalized Application Support descendants are refused", (try? verificationDataURL(temporaryRoot: normalized, supportRoot: support, runID: runID)) == nil)
        let sibling = URL(fileURLWithPath: support.path + "-other", isDirectory: true)
        try check("path boundaries do not reject a similarly named sibling", (try? verificationDataURL(temporaryRoot: sibling, supportRoot: support, runID: runID)) != nil)
        print("PASS: \(count) verification path checks; native UI not exercised")
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

let files = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let app = root.appendingPathComponent("output/verification/Silkwire Verification.app")
let modes = requested.isEmpty ? ["performance", "performance-reopen", "composer"] : requested
do {
    guard files.fileExists(atPath: app.path) else { throw verificationFailure(1, "Build verification bundle first: swift Scripts/build.swift --verification") }
    // Never put test data under root/output: broker worktrees can be inside the
    // owner's Application Support tree, which the verification app must refuse.
    let temporary = files.temporaryDirectory.resolvingSymlinksInPath()
    let support = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").resolvingSymlinksInPath()
    let data = try verificationDataURL(temporaryRoot: temporary, supportRoot: support, runID: UUID())
    try files.createDirectory(at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    print("Isolated native verification: \(data.path)")
    for mode in modes {
        let name = mode.hasSuffix("-reopen") || mode == "reopen" ? "reopen-acceptance.json" : "native-acceptance.json"
        let receipt = data.appendingPathComponent(name)
        if files.fileExists(atPath: receipt.path) { try files.moveItem(at: receipt, to: data.appendingPathComponent("\(UUID().uuidString)-\(name)")) }
        let job = Process(); job.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        job.arguments = ["-g", "-W", "-n", "--env", "SILKWIRE_ACCEPTANCE=" + mode, "--env", "SILKWIRE_ACCEPTANCE_EXIT=1", "--env", "SILKWIRE_DEV_DATA=" + data.path, app.path]
        try job.run()
        let deadline = Date().addingTimeInterval(["workroom", "ready", "projects", "attachments", "workspace", "live"].contains(mode) ? 600 : 90)
        while !files.fileExists(atPath: receipt.path), Date() < deadline, job.isRunning { Thread.sleep(forTimeInterval: 0.25) }
        guard files.fileExists(atPath: receipt.path) else { job.terminate(); throw verificationFailure(2, "Native \(mode) exited or timed out without a receipt. Inspect \(data.path)") }
        let bytes = try Data(contentsOf: receipt), result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        print("\(mode): " + (String(data: bytes, encoding: .utf8) ?? "Invalid receipt"))
        // Receipt precedes the final AppKit shutdown; never start another app on
        // the same test library until its lock holder actually exits.
        let exitDeadline = Date().addingTimeInterval(20)
        while job.isRunning, Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.1) }
        guard !job.isRunning, job.terminationStatus == 0, result?["passed"] as? Bool == true else { throw verificationFailure(3, "Native \(mode) did not pass and exit cleanly. Inspect \(data.path)") }
    }
    print("PASS: \(modes.count) native UI modes; owner library not used")
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
