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
    /// SwiftUI's macro plugin ships with Xcode, not the Command Line Tools. Say so
    /// plainly before anything is created, instead of a wall of compiler errors.
    static var xcodeProblem: String? {
        let plugin = "usr/lib/swift/host/plugins/libSwiftUIMacros.dylib", platform = "Platforms/MacOSX.platform/Developer/"
        let files = FileManager.default
        if let developer = appleToolchain?.developer, [platform + plugin, plugin].contains(where: { files.fileExists(atPath: developer + "/" + $0) }) { return nil }
        let xcode = "/Applications/Xcode.app/Contents/Developer"
        if files.fileExists(atPath: xcode + "/" + platform + plugin) {
            return "Xcode is installed but not selected. Run this once, then try again:\n  sudo xcode-select -s " + xcode + "\nNothing was built.\n"
        }
        return "Silkwire needs the full Xcode app, because the Command Line Tools leave out what SwiftUI needs. Install Xcode from the Mac App Store, open it once, then try again.\nNothing was built.\n"
    }
}


// Native Apple toolchain only. A verification bundle is separate from the app
// Jason opens and contains explicitly compiled-in synthetic acceptance fixtures.
if let problem = NativeSandboxState.xcodeProblem { fputs(problem, stderr); exit(1) }
let files = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let verification = CommandLine.arguments.contains("--verification")
let preview = CommandLine.arguments.contains("--preview")
let staging = CommandLine.arguments.contains("--staging")
guard [verification, preview, staging].filter({ $0 }).count <= 1 else {
    fputs("Choose only one of --verification, --preview, or --staging. Nothing built.\n", stderr); exit(1)
}
let output = root.appendingPathComponent(verification ? "output/verification" : staging ? "output/staging" : preview ? "output/preview" : "output/release")
let app = output.appendingPathComponent(verification ? "Silkwire Verification.app" : staging ? "Silkwire Staging.app" : preview ? "Silkwire Preview.app" : "Silkwire Dev.app")
let contents = app.appendingPathComponent("Contents"), resources = contents.appendingPathComponent("Resources")
func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, quiet: Bool = false) throws {
    let job = Process(); job.executableURL = URL(fileURLWithPath: executable); job.arguments = arguments; job.currentDirectoryURL = root
    if let environment { job.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
    if quiet { job.standardOutput = FileHandle.nullDevice }
    try job.run(); job.waitUntilExit()
    guard job.terminationStatus == 0 else { throw NSError(domain: "Silkwire.Build", code: Int(job.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Apple toolchain step failed: \(executable)"]) }
}
func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
do {
    let revisionJob = Process(), revisionPipe = Pipe()
    revisionJob.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    revisionJob.arguments = ["rev-parse", "--verify", "HEAD"]
    revisionJob.currentDirectoryURL = root; revisionJob.standardOutput = revisionPipe
    try revisionJob.run()
    let revision = String(data: revisionPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    revisionJob.waitUntilExit()
    guard revisionJob.terminationStatus == 0, revision.count == 40, revision.allSatisfy({ $0.isHexDigit }) else {
        throw NSError(domain: "Silkwire.Build", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not identify the source Git revision; nothing built."])
    }
    // Candidate identity for Jason's Staging install: a digest of every tracked and
    // untracked, non-ignored source file as built, so an app built from uncommitted
    // workspace edits can be matched to the commit that later records them. The same
    // algorithm is StagingInstaller.sourceDigest; keep both identical.
    func git(_ arguments: [String]) throws -> Data {
        let job = Process(), pipe = Pipe(); job.executableURL = URL(fileURLWithPath: "/usr/bin/git"); job.arguments = arguments
        job.currentDirectoryURL = root; job.standardOutput = pipe; job.standardError = FileHandle.nullDevice
        try job.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); job.waitUntilExit()
        guard job.terminationStatus == 0 else { throw NSError(domain: "Silkwire.Build", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not inventory source files; nothing built."]) }
        return data
    }
    let inventory = Set(try git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    var digestInput = Data()
    for path in inventory.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
        let url = root.appendingPathComponent(path)
        guard let kind = try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { continue }
        let content = kind == .typeSymbolicLink ? Data(("link:" + ((try? files.destinationOfSymbolicLink(atPath: url.path)) ?? "")).utf8) : kind == .typeRegular ? try Data(contentsOf: url) : Data("special".utf8)
        digestInput.append(Data(path.utf8)); digestInput.append(0); digestInput.append(Data(sha(content).utf8)); digestInput.append(10)
    }
    let sourceDigest = sha(digestInput)
    let sourceStatus = try git(["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty ? "clean" : "modified"
    if staging && sourceStatus != "clean" {
        throw NSError(domain: "Silkwire.Build", code: 5, userInfo: [NSLocalizedDescriptionKey: "Commit or checkpoint the Staging source before building. Installed Staging builds must retain their exact committed source."])
    }
    try files.createDirectory(at: output, withIntermediateDirectories: true)
    // Never overlay an older bundle: retain it outside the new package.
    if files.fileExists(atPath: app.path) {
        let retained = output.appendingPathComponent("previous-\(UUID().uuidString).app")
        try files.moveItem(at: app, to: retained)
    }
    try files.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try files.createDirectory(at: resources, withIntermediateDirectories: true)
    let assets = root.appendingPathComponent("Resources/Assets")
    let palette = root.appendingPathComponent("Resources/Compiled/macOS")
    let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:palette.appendingPathComponent("BrandAssets.json"))) as? [String:Any]
    let catalog = assets.appendingPathComponent("Colors.xcassets")
    guard let expected = manifest?["sourceFiles"] as? [String:String],
          let enumerator = files.enumerator(at:catalog,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { throw CocoaError(.fileReadCorruptFile) }
    var actual: [String:String] = [:]
    for case let file as URL in enumerator {
        let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        if values.isRegularFile == true { actual["Colors.xcassets/"+String(file.path.dropFirst(catalog.path.count+1))] = sha(try Data(contentsOf:file)) }
    }
    actual["SilkwireAppIcon-1024.png"] = sha(try Data(contentsOf:assets.appendingPathComponent("SilkwireAppIcon-1024.png")))
    let iconData = try Data(contentsOf:palette.appendingPathComponent("Silkwire.icns"))
    let compiled = manifest?["compiledFiles"] as? [String:String] ?? [:]
    let paletteData = try Data(contentsOf:palette.appendingPathComponent("Assets.car"))
    guard expected == actual, Set(compiled.keys) == Set(["Assets.car","Silkwire.icns"]), compiled["Assets.car"] == sha(paletteData), compiled["Silkwire.icns"] == sha(iconData), manifest?["minimumOS"] as? String == "14.0" else {
        throw NSError(domain:"Silkwire.Build",code:2,userInfo:[NSLocalizedDescriptionKey:"Native brand resource source/artifact mismatch. Run swift Scripts/regenerate-brand-assets.swift in the trusted asset-authoring workspace; review its source and generated resource diff."])
    }
    // Exercise release optimization in acceptance too: debug-only performance
    // numbers do not describe the app being delivered.
    #if arch(arm64)
    let architecture = "arm64"
    #else
    let architecture = "x86_64"
    #endif
    // There are no external Swift packages. Invoke the supported Apple compiler
    // directly with a local module cache: no package-manifest/global-cache or
    // shared build-service authority is needed inside the Builder sandbox.
    // Package.swift remains available for Xcode indexing/source navigation.
    let source = root.appendingPathComponent("Sources/Silkwire")
    let sources = try files.contentsOfDirectory(at:source, includingPropertiesForKeys:nil).filter { $0.pathExtension == "swift" }.map(\.path).sorted()
    let moduleCache = output.appendingPathComponent("ModuleCache")
    try files.createDirectory(at:moduleCache, withIntermediateDirectories:true)
    guard let toolchain = NativeSandboxState.appleToolchain else { throw NSError(domain: "Silkwire.Build", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected Apple Swift compiler/SDK is unavailable. Nothing installed."]) }
    var arguments = ["-sdk",toolchain.sdk,"-O","-whole-module-optimization","-parse-as-library","-swift-version","5","-target",architecture + "-apple-macosx14.0","-module-cache-path",moduleCache.path,
                     "-framework","SwiftUI","-framework","AppKit","-framework","UserNotifications","-framework","CryptoKit"]
    if verification { arguments += ["-D","SILKWIRE_TESTING"] }
    if staging { arguments += ["-D","SILKWIRE_STAGING"] }
    // macOS refuses nested sandbox_apply. Compiler macro subprocesses already
    // inherit Builder's outer no-network/private-write profile. Disable only
    // the compiler's redundant nested sandbox, never the host command boundary.
    if NativeSandboxState.isSandboxed { arguments += ["-disable-sandbox"] }
    try run(toolchain.compiler, arguments + sources + ["-o",contents.appendingPathComponent("MacOS/Silkwire").path])
    try paletteData.write(to:resources.appendingPathComponent("Assets.car"))
    try files.copyItem(at: assets.appendingPathComponent("silkwire-lockup-chrome.png"), to: resources.appendingPathComponent("silkwire-lockup.png"))
    try files.copyItem(at: assets.appendingPathComponent("Fonts"), to: resources.appendingPathComponent("Fonts"))
    try iconData.write(to:resources.appendingPathComponent("Silkwire.icns"))
    var info: [String: Any] = ["CFBundleExecutable":"Silkwire", "CFBundleIdentifier":verification ? "app.silkwire.verification" : staging ? "app.silkwire.staging" : preview ? "app.silkwire.native.contextaccess.preview" : "app.silkwire.native.ready.preview", "CFBundleName":verification ? "Silkwire Verification" : staging ? "Silkwire Staging" : preview ? "Silkwire Preview" : "Silkwire Dev", "CFBundleDisplayName":staging ? "Silkwire Staging" : "Silkwire", "CFBundleVersion":"1", "CFBundleShortVersionString":"0.1", "CFBundlePackageType":"APPL", "LSMinimumSystemVersion":"14.0", "CFBundleIconFile":"Silkwire.icns", "NSAccentColorName":"AccentColor", "NSHighResolutionCapable":true, "SilkwireGitRevision":revision, "SilkwireSourceDigest":sourceDigest, "SilkwireSourceStatus":sourceStatus]
    if staging { info["SilkwireEnvironment"] = "staging"; info["SilkwireAgentTestProtocol"] = 2 }
    // Date-based version (Jason's choice): the day it was built, plus the exact build time.
    let builtAt = Date(), day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy.MM.dd"
    info["CFBundleShortVersionString"] = day.string(from: builtAt); info["SilkwireBuiltAt"] = ISO8601DateFormatter().string(from: builtAt)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    if staging {
        let helpers = contents.appendingPathComponent("Helpers")
        try files.createDirectory(at: helpers, withIntermediateDirectories: true)
        let helper = helpers.appendingPathComponent("silkwire-staging-installer")
        try run(toolchain.compiler, ["-sdk", toolchain.sdk, "-O", "-parse-as-library", "-module-cache-path", moduleCache.path,
            root.appendingPathComponent("Sources/Silkwire/StagingInstaller.swift").path]
            // The helper installs only through the app's exclusive host lane.
            + ["StagingInstallLane", "StagingInstallWorkload", "HostExecutionCoordinator", "PhysicalWorkOwnership", "HostLocalExecutionEvidence", "HostPrivateExecutionCleanup"].map { root.appendingPathComponent("Sources/Silkwire/\($0).swift").path }
            + [root.appendingPathComponent("Tools/StagingInstallerMain.swift").path, "-o", helper.path])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", helper.path])
        let retained = resources.appendingPathComponent("Source")
        try files.createDirectory(at: retained, withIntermediateDirectories: true)
        let archive = retained.appendingPathComponent("source.bundle")
        try run("/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "bundle", "create", archive.path, "HEAD"])
        let manifest: [String: String] = ["revision": revision, "sourceDigest": sourceDigest, "bundleSHA256": sha(try Data(contentsOf: archive))]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: retained.appendingPathComponent("manifest.json"), options: .atomic)
        // Detect edits during compilation instead of attaching a misleading source archive.
        guard try git(["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty,
              String(decoding: try git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == revision else {
            throw NSError(domain: "Silkwire.Build", code: 6, userInfo: [NSLocalizedDescriptionKey: "Source changed during the build. Checkpoint and rebuild before review."])
        }
    }
    try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path])
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    print(app.path)
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
