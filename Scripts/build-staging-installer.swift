#!/usr/bin/env swift
import Foundation

// Builds only; does not install or run the helper.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("output/installer")
do {
    try FileManager.default.createDirectory(at: output.appendingPathComponent("ModuleCache"), withIntermediateDirectories: true)
    let executable = output.appendingPathComponent("silkwire-staging-installer")
    let job = Process(); job.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    job.arguments = ["swiftc", "-O", "-parse-as-library", "-module-cache-path", output.appendingPathComponent("ModuleCache").path,
                     root.appendingPathComponent("Sources/Silkwire/StagingInstaller.swift").path]
        + ["StagingInstallLane", "StagingInstallWorkload", "HostExecutionCoordinator", "PhysicalWorkOwnership", "HostLocalExecutionEvidence", "HostPrivateExecutionCleanup"].map { root.appendingPathComponent("Sources/Silkwire/\($0).swift").path }
        + [root.appendingPathComponent("Tools/StagingInstallerMain.swift").path, "-o", executable.path]
    try job.run(); job.waitUntilExit()
    guard job.terminationStatus == 0 else { exit(job.terminationStatus) }
    let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", "--timestamp=none", executable.path]
    try sign.run(); sign.waitUntilExit()
    guard sign.terminationStatus == 0 else { exit(sign.terminationStatus) }
    print(executable.path)
} catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
