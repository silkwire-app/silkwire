#!/usr/bin/env swift
import Foundation

// Compile the actual complete application core through the shared test runner.
// The former hand-maintained dependency list became stale when Models gained Alexandria pages.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let allowed: Set<String> = ["--live", "--reuse-core"]
guard CommandLine.arguments.dropFirst().allSatisfy({ allowed.contains($0) }) else {
    fputs("Usage: swift Tests/run-transports.swift [--reuse-core] [--live]\n", stderr); exit(1)
}
var suites = ["NativeTransportTests"]
if CommandLine.arguments.contains("--live") { suites.append("NativeProviderLiveTests") }
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [root.appendingPathComponent("Scripts/test.swift").path] + (CommandLine.arguments.contains("--reuse-core") ? ["--reuse-core"] : []) + suites
process.currentDirectoryURL = root
try process.run(); process.waitUntilExit()
exit(process.terminationStatus)
