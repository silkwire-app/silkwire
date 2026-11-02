#!/usr/bin/env swift
import Foundation

// Packages an already-built, committed candidate. Never installs or rebuilds it.
let files = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let candidate = root.appendingPathComponent("output/staging/Silkwire Staging.app")
let output = root.appendingPathComponent("output/candidate-" + UUID().uuidString)
let launcher = output.appendingPathComponent("Try This Build.app")
func run(_ command: [String], capture: Bool = false) throws -> Data {
    let job = Process(); let pipe = Pipe(); job.executableURL = URL(fileURLWithPath: command[0]); job.arguments = Array(command.dropFirst())
    if capture { job.standardOutput = pipe }
    try job.run(); let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data(); job.waitUntilExit()
    guard job.terminationStatus == 0 else { throw NSError(domain: "Silkwire.Package", code: 1, userInfo: [NSLocalizedDescriptionKey: "Packaging failed: " + command[0]]) }; return data
}
do {
    _ = try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", candidate.path])
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
    guard info?["SilkwireSourceStatus"] as? String == "clean", info?["CFBundleIdentifier"] as? String == "app.silkwire.staging" else { throw CocoaError(.fileReadCorruptFile) }
    let resources = launcher.appendingPathComponent("Contents/Resources"), macos = launcher.appendingPathComponent("Contents/MacOS")
    try files.createDirectory(at: resources, withIntermediateDirectories: true); try files.createDirectory(at: macos, withIntermediateDirectories: true)
    try files.copyItem(at: candidate, to: resources.appendingPathComponent("Silkwire Staging.app"))
    let cache = output.appendingPathComponent("ModuleCache"); try files.createDirectory(at: cache, withIntermediateDirectories: true)
    // Both installers run only through the app's exclusive host lane.
    let laneSources = ["StagingInstallLane", "StagingInstallWorkload", "HostExecutionCoordinator", "PhysicalWorkOwnership", "HostLocalExecutionEvidence", "HostPrivateExecutionCleanup"].map { root.appendingPathComponent("Sources/Silkwire/\($0).swift").path }
    let executable = macos.appendingPathComponent("TryThisBuild")
    _ = try run(["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", "-module-cache-path", cache.path, root.appendingPathComponent("Sources/Silkwire/StagingInstaller.swift").path] + laneSources + [root.appendingPathComponent("Tools/TryThisBuildMain.swift").path, "-o", executable.path])
    let helpers = launcher.appendingPathComponent("Contents/Helpers")
    try files.createDirectory(at: helpers, withIntermediateDirectories: true)
    let cli = helpers.appendingPathComponent("silkwire-staging-installer")
    _ = try run(["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", "-module-cache-path", cache.path, root.appendingPathComponent("Sources/Silkwire/StagingInstaller.swift").path] + laneSources + [root.appendingPathComponent("Tools/StagingInstallerMain.swift").path, "-o", cli.path])
    _ = try run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", cli.path])
    let helper = candidate.appendingPathComponent("Contents/Helpers/silkwire-staging-installer")
    let identity = try run([helper.path, "review", candidate.path], capture: true)
    try identity.write(to: resources.appendingPathComponent("candidate.json"))
    try identity.write(to: output.appendingPathComponent("candidate.json"))
    let installerRevision = String(decoding: try run(["/usr/bin/git", "-C", root.path, "rev-parse", "HEAD"], capture: true), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let status = try run(["/usr/bin/git", "-C", root.path, "status", "--porcelain=v1"], capture: true)
    guard status.isEmpty else { throw NSError(domain: "Silkwire.Package", code: 2, userInfo: [NSLocalizedDescriptionKey: "Commit installer sources before packaging; no installed app changed."]) }
    let plist: [String: Any] = ["CFBundleExecutable": "TryThisBuild", "CFBundleIdentifier": "app.silkwire.staging-candidate.v5", "CFBundleName": "Try This Build", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0", "CFBundleVersion": "5", "SilkwireInstallerRevision": installerRevision, "SilkwireCandidateRevision": info?["SilkwireGitRevision"] ?? ""]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: launcher.appendingPathComponent("Contents/Info.plist"))
    _ = try run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", launcher.path])
    _ = try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", launcher.path])
    print(output.path)
} catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
