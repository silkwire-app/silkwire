#!/usr/bin/env swift
import Foundation
import CryptoKit

// Reversible local installation, never an overlay; no library path is mutated.
let files = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let preview = CommandLine.arguments.contains("--preview")
let staging = CommandLine.arguments.contains("--staging")
let verification = CommandLine.arguments.contains("--verification")
guard [verification, preview, staging].filter({ $0 }).count <= 1, !verification else {
    fputs("Choose only one of --preview or --staging; verification bundles are not installable. Nothing installed.\n", stderr); exit(1)
}
let name = staging ? "Silkwire Staging" : preview ? "Silkwire Preview" : "Silkwire Dev"
let source = root.appendingPathComponent(staging ? "output/staging/Silkwire Staging.app" : preview ? "output/preview/Silkwire Preview.app" : "output/release/Silkwire Dev.app")
let target = staging ? URL(fileURLWithPath: "/Applications/Silkwire Staging.app") : files.homeDirectoryForCurrentUser.appendingPathComponent("Applications/" + name + ".app")
func digest(_ bundle: URL) throws -> [String: String] {
    guard let listing = files.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { throw CocoaError(.fileReadUnknown) }
    var result: [String: String] = [:]
    for case let path as URL in listing where try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[String(path.path.dropFirst(bundle.path.count + 1))] = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
    }
    return result
}
do {
    if staging {
        // Keep the legacy entry point on the same locked, app-and-library backup
        // implementation as the one-click UI. Old candidates fail closed.
        let helper = source.appendingPathComponent("Contents/Helpers/silkwire-staging-installer")
        let review = Process(), pipe = Pipe(); review.executableURL = helper; review.arguments = ["review", source.path]; review.standardOutput = pipe
        try review.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); review.waitUntilExit()
        guard review.terminationStatus == 0,
              let identity = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let manifest = identity["manifestSHA256"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        let install = Process(); install.executableURL = helper; install.arguments = ["install", source.path, manifest]
        try install.run(); install.waitUntilExit(); exit(install.terminationStatus)
    }
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
    guard plist?["CFBundleIdentifier"] as? String == (staging ? "app.silkwire.staging" : preview ? "app.silkwire.native.contextaccess.preview" : "app.silkwire.native.ready.preview"), plist?["CFBundleExecutable"] as? String == "Silkwire",
          !staging || plist?["SilkwireEnvironment"] as? String == "staging" else { throw NSError(domain: "Silkwire.Install", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected bundle identity; nothing installed."]) }
    let pipe = Pipe(), job = Process(); job.executableURL = URL(fileURLWithPath: "/bin/ps"); job.arguments = ["-axo", "command="]; job.standardOutput = pipe
    try job.run(); let processes = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; job.waitUntilExit()
    guard !processes.contains(target.appendingPathComponent("Contents/MacOS/").path) else { throw NSError(domain: "Silkwire.Install", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name) is open. Quit it before replacing the installation; your library will remain unchanged."]) }
    let expected = try digest(source)
    guard expected["Contents/MacOS/Silkwire"] != nil, expected["Contents/Resources/Fonts/Archivo-Italic-Variable-latin.woff2"] != nil,
          !expected.keys.contains(where: { [".mjs", ".js", ".cjs", ".node"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased().withDot) }) else { throw CocoaError(.fileReadCorruptFile) }
    try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    var backup: URL?
    if files.fileExists(atPath: target.path) {
        let path = target.deletingLastPathComponent().appendingPathComponent("\(name) Backups/\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)/\(name).app")
        try files.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: target, to: path); backup = path
    }
    do {
        try files.copyItem(at: source, to: target)
        guard try digest(target) == expected else { throw CocoaError(.fileReadCorruptFile) }
    } catch {
        if files.fileExists(atPath: target.path) { try? files.moveItem(at: target, to: target.deletingLastPathComponent().appendingPathComponent("Silkwire Incomplete \(UUID().uuidString).app")) }
        if let backup { try? files.moveItem(at: backup, to: target) }; throw error
    }
    let receipt: [String: Any] = ["installed": target.path, "backup": backup?.path ?? "", "filesVerified":expected.count, "hashes":expected, "libraryModified":false, "installedAt":ISO8601DateFormatter().string(from:Date())]
    try JSONSerialization.data(withJSONObject: receipt, options:[.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent(staging ? "output/installed-staging.json" : preview ? "output/installed-preview.json" : "output/installed-dev.json"), options:.atomic)
    print("Installed and verified \(expected.count) files: \(target.path). Library unchanged.")
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
private extension String { var withDot: String { "." + self } }
