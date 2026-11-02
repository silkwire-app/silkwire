#!/usr/bin/env swift
import Foundation
import CryptoKit

import Darwin

enum NativeSandboxState {
    /// Ask the kernel, never an inherited environment flag. A missing API means
    /// no optimization: the normal sandbox launcher must succeed or fail closed.
    static var isSandboxed: Bool {
        guard let library = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_LAZY) else { return false }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "sandbox_check") else { return false }
        let check = unsafeBitCast(symbol, to: (@convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32).self)
        return check(getpid(), nil, 0) == 1
    }
    /// Read system-owned toolchain selection, avoiding xcrun/xcodebuild service
    /// discovery inside a command sandbox. These paths grant no permissions.
    static var appleToolchain: (compiler: String, sdk: String, developer: String)? {
        let files = FileManager.default
        let selected = URL(fileURLWithPath: "/var/db/xcode_select_link").resolvingSymlinksInPath()
        let developer = files.fileExists(atPath: selected.path) ? selected : URL(fileURLWithPath: "/Library/Developer/CommandLineTools")
        for (compiler, sdk) in [("Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"), ("usr/bin/swiftc", "SDKs/MacOSX.sdk")] {
            let executable = developer.appendingPathComponent(compiler), platform = developer.appendingPathComponent(sdk)
            if files.isExecutableFile(atPath: executable.path), files.fileExists(atPath: platform.path) {
                return (executable.path, platform.path, developer.path)
            }
        }
        return nil
    }
}

import Darwin

let files = FileManager.default
let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("output/tests")
let nativeAcceptance = ["NativeEveSocketTests", "NativePasteboardTests", "NativeBookmarkTests", "TrustedWorkspaceTests", "TrustedRoomTests", "TransferTests", "ReviewedIntegrationTests", "RecursiveWorkspaceTests"]
var testEnvironment = ProcessInfo.processInfo.environment
func run(_ arguments: [String], log: FileHandle? = nil) throws {
    let job = Process(); job.executableURL = URL(fileURLWithPath: arguments[0]); job.arguments = Array(arguments.dropFirst()); job.currentDirectoryURL = root
    job.environment = testEnvironment
    if let log { job.standardOutput = log; job.standardError = log }
    try job.run(); job.waitUntilExit()
    guard job.terminationStatus == 0 else { throw NSError(domain:"Silkwire.Tests", code:Int(job.terminationStatus), userInfo:[NSLocalizedDescriptionKey:"Test gate failed: \(arguments.first ?? "")"]) }
}
/// Do not inherit fixture storage under ~/Library/Application Support from the
/// app. Accept a canonical inherited TMPDIR only inside OS temporary storage;
/// otherwise use the canonical OS temporary parent. Never use the /tmp link as a path.
func fixtureDirectory() throws -> URL {
    // Do not use confstr here: it can echo the protected inherited TMPDIR.
    func canonical(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    let system = try canonical(URL(fileURLWithPath: "/private/tmp"))
    let inherited = try canonical(ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? files.temporaryDirectory)
    let path = inherited.path
    let parent = path == system.path || path.hasPrefix(system.path + "/") || path.hasPrefix("/private/var/folders/") ? inherited : system
    var template = Array(parent.appendingPathComponent("Silkwire-Test-Fixtures-XXXXXX").path.utf8CString)
    guard let made = mkdtemp(&template) else {
        throw NSError(domain: "Silkwire.Tests", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Cannot create an allowed fixture root outside protected app data. Update the workspace TMPDIR host or use a host permitted to create OS temporary fixtures."])
    }
    return try canonical(URL(fileURLWithPath: String(cString: made)))
}
do {
    let requested = Array(CommandLine.arguments.dropFirst()).filter { !["--reuse-core", "--native-acceptance"].contains($0) }
    guard !CommandLine.arguments.contains("--native-acceptance") || requested.isEmpty else { throw NSError(domain: "Silkwire.Tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use --native-acceptance without additional suite names."]) }
    let names = CommandLine.arguments.contains("--native-acceptance") ? nativeAcceptance : requested.isEmpty ? ["StorageTests","ProjectTests","RefinementTests","WorkroomTests","PerformanceTests","RoomTests"] : requested
    guard names.allSatisfy({ $0.range(of: "^[A-Za-z][A-Za-z0-9]*Tests$", options: .regularExpression) != nil }) else { throw CocoaError(.fileReadInvalidFileName) }
    let fixtures = try fixtureDirectory()
    testEnvironment["TMPDIR"] = fixtures.path + "/"
    testEnvironment["SILKWIRE_DEV_DATA"] = fixtures.appendingPathComponent("development-library").path
    testEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"; testEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"; testEnvironment["GIT_TERMINAL_PROMPT"] = "0"
    print("Canonical synthetic fixture root: " + fixtures.path)
    try files.createDirectory(at:output, withIntermediateDirectories:true)
    let resultDirectory = output.appendingPathComponent("results/" + UUID().uuidString)
    try files.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
    print("Per-suite results: " + resultDirectory.path)
    let source = root.appendingPathComponent("Sources/Silkwire")
    let sources = try files.contentsOfDirectory(at:source, includingPropertiesForKeys:nil).filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SilkwireApp.swift" }.map(\.path).sorted()
    let moduleCache = output.appendingPathComponent("ModuleCache")
    try files.createDirectory(at: moduleCache, withIntermediateDirectories: true)
    guard let toolchain = NativeSandboxState.appleToolchain else { throw NSError(domain: "Silkwire.Tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected Apple Swift compiler/SDK is unavailable. Nothing installed."]) }
    let compiler = [toolchain.compiler, "-sdk", toolchain.sdk, "-module-cache-path", moduleCache.path] + (NativeSandboxState.isSandboxed ? ["-disable-sandbox"] : [])
        // Test builds use a private per-process ownership registry (HostOwnershipDefault).
        + ["-D", "SILKWIRE_TEST_HARNESS"]
    var fingerprintInput = Data(compiler.joined(separator: "\n").utf8)
    for path in sources { fingerprintInput.append(Data(path.utf8)); fingerprintInput.append(try Data(contentsOf: URL(fileURLWithPath: path))) }
    let fingerprint = SHA256.hash(data: fingerprintInput).map { String(format: "%02x", $0) }.joined()
    let fingerprintFile = output.appendingPathComponent("core-source.sha256")
    let reuse = CommandLine.arguments.contains("--reuse-core")
    if reuse {
        guard (try? String(contentsOf: fingerprintFile, encoding: .utf8)) == fingerprint,
              files.fileExists(atPath: output.appendingPathComponent("libSilkwireCore.dylib").path) else {
            throw NSError(domain: "Silkwire.Tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cached test core does not match current sources/options. Run again without --reuse-core."])
        }
    } else {
        try run(compiler + ["-O","-parse-as-library","-swift-version","5","-enable-testing","-emit-library","-emit-module","-module-name","SilkwireCore","-emit-module-path",output.appendingPathComponent("SilkwireCore.swiftmodule").path] + sources + ["-o",output.appendingPathComponent("libSilkwireCore.dylib").path])
        try fingerprint.write(to: fingerprintFile, atomically: true, encoding: .utf8)
    }
    print("Test core SHA-256: " + fingerprint + (reuse ? " (verified cache)" : " (compiled)"))
    // Every requested suite runs after failures. Keep the complete compiler and
    // executable output for each suite, including a signal-derived exit code.
    var results: [[String: Any]] = []
    for name in names {
        let started = Date()
        let file = root.appendingPathComponent("Tests/\(name).swift")
        let fixture = output.appendingPathComponent("\(name).swift")
        let executable = output.appendingPathComponent(name).path
        let logURL = resultDirectory.appendingPathComponent(name + ".log")
        guard files.createFile(atPath: logURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let log = try FileHandle(forWritingTo: logURL)
        var status: Int32 = 0
        var executed = false
        do {
            try ("@testable import SilkwireCore\n" + String(contentsOf:file, encoding:.utf8)).write(to:fixture, atomically:true, encoding:.utf8)
            try run(compiler + ["-Onone","-parse-as-library","-swift-version","5","-I",output.path,"-L",output.path,"-lSilkwireCore","-Xlinker","-rpath","-Xlinker",output.path,fixture.path,"-o",executable], log: log)
            let test = Process(); test.executableURL = URL(fileURLWithPath:executable); test.currentDirectoryURL = root
            test.environment = testEnvironment; test.standardOutput = log; test.standardError = log
            try test.run(); executed = true
            let deadline = max(1, Double(testEnvironment["SILKWIRE_TEST_DEADLINE_SECONDS"] ?? "480") ?? 480)
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                if completed.wait(timeout: .now() + deadline) == .timedOut, test.isRunning {
                    try? log.write(contentsOf: Data("TEST DEADLINE EXPIRED after \(deadline)s; timeout is a failure.\n".utf8))
                    test.terminate()
                }
            }
            test.waitUntilExit(); completed.signal()
            status = test.terminationReason == .uncaughtSignal ? 128 + test.terminationStatus : test.terminationStatus
        } catch {
            try log.write(contentsOf: Data("\(name): \(error.localizedDescription)\n".utf8))
            status = -1
        }
        try log.close()
        let data = try Data(contentsOf: logURL)
        print(String(decoding: data, as: UTF8.self), terminator: "")
        results.append(["suite": name, "exitCode": status, "executed": executed, "seconds": Date().timeIntervalSince(started), "log": logURL.lastPathComponent, "logSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        let receipt: [String: Any] = ["coreSHA256": fingerprint, "fixtureRoot": fixtures.path, "results": results]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: resultDirectory.appendingPathComponent("results.json"), options: .atomic)
        print(status == 0 ? "SUITE PASS: \(name)" : "SUITE FAIL: \(name) (exit \(status))")
    }
    print("\nSuite summary:")
    for result in results { print("  \(result["exitCode"] as? Int32 == 0 ? "pass" : "FAIL") \(result["suite"]!) · exit \(result["exitCode"]!) · \(String(format: "%.1f", result["seconds"] as! Double))s") }
    let failed = results.filter { $0["exitCode"] as? Int32 != 0 }
    guard failed.isEmpty else { fputs("FAIL: \(failed.count) of \(results.count) native Swift suites failed: \(failed.compactMap { $0["suite"] as? String }.joined(separator: ", "))\n", stderr); exit(1) }
    print("PASS: \(names.count) native Swift suites")
} catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
