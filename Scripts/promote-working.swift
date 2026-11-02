#!/usr/bin/env swift
import Foundation
import CryptoKit
import Darwin

// Local, explicitly authorized promotion. Never rebuilds, launches, sends,
// merges, deploys, or changes provider identities. Keep every recovery artifact.
let files = FileManager.default
func fail(_ text: String) -> NSError { NSError(domain: "Silkwire.PromoteWorking", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func canonical(_ path: String) throws -> URL {
    guard path.hasPrefix("/"), !path.contains("\0"), let resolved = realpath(path, nil) else { throw fail("Every supplied path must exist and resolve safely.") }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}
func inside(_ child: URL, _ parent: URL) -> Bool { child.path.hasPrefix(parent.path + "/") }
func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
func regular(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw fail("Required regular file is missing or linked.") }
}
func manifest(_ root: URL) throws -> [String: String] {
    var enumerationFailed = false
    guard let listing = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw fail("Cannot enumerate a required directory.") }
    var result: [String: String] = [:]
    for case let url as URL in listing {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw fail("Linked files are not supported by this promotion.") }
        let key = String(url.path.dropFirst(root.path.count + 1))
        if values.isRegularFile == true { result[key] = sha(try Data(contentsOf: url)) }
        else if values.isDirectory == true { result[key + "/"] = "directory" }
        else { throw fail("Special files are not supported by this promotion.") }
    }
    guard !enumerationFailed else { throw fail("Directory enumeration failed; promotion stopped.") }
    return result
}
func assertNoHardlinks(_ root: URL) throws {
    guard let listing = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw fail("Cannot inspect independent copy.") }
    for case let url as URL in listing where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        guard (try files.attributesOfItem(atPath: url.path)[.referenceCount] as? NSNumber)?.intValue == 1 else { throw fail("A private copy contains hardlinked files.") }
    }
}
func command(_ path: String, _ arguments: [String], at directory: URL? = nil) throws -> String {
    let job = Process(), out = Pipe()
    job.executableURL = URL(fileURLWithPath: path); job.arguments = arguments; job.currentDirectoryURL = directory
    job.standardOutput = out; job.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    job.environment = environment
    try job.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); job.waitUntilExit()
    guard job.terminationStatus == 0 else { throw fail("A local verification command failed; private diagnostics were withheld.") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func assertNotRunning(_ app: URL) throws {
    let processes = try command("/bin/ps", ["-axo", "command="])
    guard !processes.contains(app.appendingPathComponent("Contents/MacOS/").path) else { throw fail("The working app is open. Quit it normally before promotion; nothing was changed.") }
}
func readPlist(_ app: URL) throws -> [String: Any] {
    let path = app.appendingPathComponent("Contents/Info.plist"); try regular(path)
    guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any], value["CFBundleExecutable"] as? String == "Silkwire" else { throw fail("Unsupported application bundle.") }
    return value
}
func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) }
func uuid(_ value: Any?) -> String? { guard let text = value as? String, UUID(uuidString: text) != nil else { return nil }; return text.lowercased() }
func folders(_ project: [String: Any]) throws -> [[String: Any]] {
    let value: [[String: Any]]
    if let raw = project["folders"] { guard let array = raw as? [[String: Any]] else { throw fail("Corrupt folder grants.") }; value = array }
    else if let path = project["folderPath"], let bookmark = project["folderBookmark"], let id = project["id"] {
        value = [["id": id, "name": "Project files", "path": path, "bookmark": bookmark]]
    } else {
        guard project["folderPath"] == nil, project["folderBookmark"] == nil else { throw fail("Incomplete legacy folder grant.") }; value = []
    }
    guard value.count <= 8 else { throw fail("Project has more than eight folder grants.") }
    var ids = Set<String>(), paths = Set<String>()
    for folder in value {
        guard let id = uuid(folder["id"]), ids.insert(id).inserted,
              let path = folder["path"] as? String, path.hasPrefix("/"), path != "/", path.count <= 4096, paths.insert(path).inserted,
              let name = folder["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 80,
              let encoded = folder["bookmark"] as? String, let bookmark = Data(base64Encoded: encoded), !bookmark.isEmpty,
              folder["builderAllowed"] == nil || folder["builderAllowed"] is Bool else { throw fail("Corrupt Project folder grant.") }
    }
    return value
}
// Decode the supported v5 field types before preserving the original JSON tree.
// Do not re-encode these structs: that would discard unknown owner fields.
private struct OwnerAttachment: Decodable { let id: UUID; let name: String; let mimeType: String; let data: Data }
private struct OwnerMessage: Decodable {
    let id: UUID; let author: String; let text: String; let state: String
    let requestId: String?; let detail: String?; let createdAt: Date?; let attachments: [OwnerAttachment]?
}
private struct OwnerIdentity: Decodable {
    let id: String; let started: Bool?; let model: String?; let runId: String?; let requestId: String?; let turnId: String?
}
private struct OwnerHistory: Decodable {
    let supplied: Int; let total: Int; let shortened: Bool; let requestID: String; let recordedAt: Date
    let capabilityHash: String?; let folderCount: Int?
}
private struct OwnerConversation: Decodable {
    let id: UUID; let projectID: UUID?; let archived: Bool?; let draftAttachments: [OwnerAttachment]?; let unread: Bool?
    let title: String?; let createdAt: Date?; let updatedAt: Date?; let draft: String?; let recipient: String?
    let messages: [OwnerMessage]?; let identities: [String: OwnerIdentity]?; let historyContext: [String: OwnerHistory]?; let threadID: String?
}
private struct OwnerFolder: Decodable { let id: UUID; let name: String; let path: String; let bookmark: Data; let builderAllowed: Bool? }
private struct OwnerProject: Decodable {
    let id: UUID; let name: String; let icon: String; let color: String; let participants: [String]; let expanded: Bool
    let folderPath: String?; let folderBookmark: Data?; let folders: [OwnerFolder]?; let brief: String?; let trustedStaging: Bool?
}
private struct OwnerPreferences: Decodable {
    let completionChime: Bool?; let sidebarVisible: Bool?; let reduceMotion: Bool?; let autoScrollReplies: Bool?
    let textCompletion: Bool?; let automaticCorrection: Bool?
}
private struct OwnerWorkspace: Decodable {
    let version: Int; let environment: String?; let activeID: UUID; let conversations: [OwnerConversation]
    let projects: [OwnerProject]; let preferences: OwnerPreferences
}
func patchedWorkspace(_ original: Data, stagingSource: URL) throws -> Data {
    do { _ = try JSONDecoder().decode(OwnerWorkspace.self, from: original) }
    catch { throw fail("Unsupported or corrupt working library; no data was changed.") }
    guard var workspace = try JSONSerialization.jsonObject(with: original) as? [String: Any], workspace["version"] as? Int == 5,
          workspace["environment"] as? String != "staging", workspace["preferences"] is [String: Any],
          let active = uuid(workspace["activeID"]), let conversations = workspace["conversations"] as? [[String: Any]], !conversations.isEmpty,
          var projects = workspace["projects"] as? [[String: Any]], !projects.isEmpty else { throw fail("Unsupported or corrupt working library; version 5 is required.") }
    var projectIDs = Set<String>()
    for project in projects {
        guard let id = uuid(project["id"]), projectIDs.insert(id).inserted,
              let name = project["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let participants = project["participants"] as? [String], !participants.isEmpty, Set(participants).count == participants.count,
              participants.allSatisfy({ ["eve", "claude", "codex"].contains($0) }),
              (project["brief"] as? String ?? "").utf16.count <= 2000 else { throw fail("Corrupt working Project.") }
        _ = try folders(project)
    }
    var conversationIDs = Set<String>(), activeProject: String?
    for conversation in conversations {
        guard let id = uuid(conversation["id"]), conversationIDs.insert(id).inserted,
              let project = uuid(conversation["projectID"]), projectIDs.contains(project),
              let messages = conversation["messages"] as? [[String: Any]],
              conversation["identities"] == nil || conversation["identities"] is [String: Any] else { throw fail("Corrupt working conversation.") }
        for message in messages {
            guard uuid(message["id"]) != nil, message["text"] is String, message["author"] is String, message["state"] is String else { throw fail("Corrupt working message.") }
        }
        if id == active { activeProject = project }
    }
    guard let activeProject, let index = projects.firstIndex(where: { uuid($0["id"]) == activeProject }) else { throw fail("No valid active Project.") }
    var granted = try folders(projects[index])
    let matches = granted.indices.filter { (try? canonical(granted[$0]["path"] as! String)) == stagingSource }
    guard matches.count <= 1 else { throw fail("Duplicate grants resolve to the same Staging source.") }
    if let existing = matches.first { granted[existing]["builderAllowed"] = true; granted[existing]["name"] = "Staging Source" }
    else {
        guard granted.count < 8 else { throw fail("No slot available for a Staging source grant.") }
        let bookmark = try stagingSource.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        granted.append(["id": UUID().uuidString, "name": "Staging Source", "path": stagingSource.path, "bookmark": bookmark.base64EncodedString(), "builderAllowed": true])
    }
    projects[index]["trustedStaging"] = true; projects[index]["folders"] = granted
    workspace["projects"] = projects
    return try json(workspace)
}

var recovery: URL?, target: URL?, workspaceFile: URL?, originalWorkspace: Data?
var appMoved = false, workspaceChanged = false
var workspacePermissions: Any?
var lockFD: Int32 = -1
var receipt: [String: Any] = ["format": 1, "status": "incomplete", "rebuilt": false, "providersStarted": false]
defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
do {
    let flags = Set(["--source-app", "--target-app", "--library", "--staging-source"])
    var options: [String: String] = [:], verifyOnly = false, index = 1
    while index < CommandLine.arguments.count {
        let flag = CommandLine.arguments[index]
        if flag == "--verify-only", !verifyOnly { verifyOnly = true; index += 1; continue }
        guard flags.contains(flag), options[flag] == nil, index + 1 < CommandLine.arguments.count, !CommandLine.arguments[index + 1].hasPrefix("--") else { throw fail("Usage: swift Scripts/promote-working.swift --source-app PATH --target-app PATH --library PATH --staging-source PATH [--verify-only]") }
        options[flag] = CommandLine.arguments[index + 1]; index += 2
    }
    guard options.count == 4 else { throw fail("All four explicit path flags are required.") }
    let source = try canonical(options["--source-app"]!), app = try canonical(options["--target-app"]!), library = try canonical(options["--library"]!), clone = try canonical(options["--staging-source"]!)
    target = app
    let expectedTarget = files.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Silkwire Updated Preview.app").standardizedFileURL
    let stageRoot = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Silkwire Staging/Sources").standardizedFileURL
    guard app == expectedTarget, try canonical(stageRoot.path) == stageRoot, inside(clone, stageRoot), clone.path != files.homeDirectoryForCurrentUser.appendingPathComponent("Projects/silkwire").standardizedFileURL.path,
          app != source, !inside(source, app), !inside(app, source), !inside(library, app), !inside(app, library), !inside(library, stageRoot.deletingLastPathComponent()) else { throw fail("Promotion paths overlap or are outside the authorized working/Staging locations.") }
    let plist = try readPlist(source), oldPlist = try readPlist(app)
    let allowed = ["app.silkwire.native.recovery.preview", "app.silkwire.native.ready.preview", "app.silkwire.native.contextaccess.preview"]
    guard plist["CFBundleIdentifier"] as? String == "app.silkwire.staging", plist["SilkwireEnvironment"] as? String == "staging", let bundleID = oldPlist["CFBundleIdentifier"] as? String, allowed.contains(bundleID), oldPlist["SilkwireEnvironment"] as? String != "staging" else { throw fail("Unexpected source or working bundle identity.") }
    let gitDirectory = clone.appendingPathComponent(".git")
    let gitArguments = ["-c", "core.hooksPath=/dev/null"]
    let commonPath = try command("/usr/bin/git", gitArguments + ["rev-parse", "--git-common-dir"], at: clone)
    let commonDirectory = try canonical(commonPath.hasPrefix("/") ? commonPath : clone.appendingPathComponent(commonPath).path)
    guard try canonical(gitDirectory.path) == gitDirectory, try gitDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
          !exists(gitDirectory.appendingPathComponent("objects/info/alternates")), !exists(gitDirectory.appendingPathComponent("objects/info/http-alternates")), !exists(gitDirectory.appendingPathComponent("commondir")),
          try command("/usr/bin/git", gitArguments + ["remote"], at: clone).isEmpty,
          try canonical(command("/usr/bin/git", gitArguments + ["rev-parse", "--show-toplevel"], at: clone)) == clone,
          commonDirectory == gitDirectory else { throw fail("Staging source is not an independent local clone.") }
    _ = try manifest(clone); try assertNoHardlinks(clone)
    try assertNotRunning(app)
    let file = library.appendingPathComponent("workspace.json"); try regular(file); workspaceFile = file
    let lock = library.appendingPathComponent(".conversation.lock"); try regular(lock)
    lockFD = Darwin.open(lock.path, O_RDONLY | O_NOFOLLOW)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw fail("Working library is in use. Quit its app normally before promotion.") }
    let original = try Data(contentsOf: file); originalWorkspace = original
    workspacePermissions = try files.attributesOfItem(atPath: file.path)[.posixPermissions]
    let updated = try patchedWorkspace(original, stagingSource: clone)
    let expected = try manifest(source), oldAppHashes = try manifest(app), libraryHashes = try manifest(library)
    guard expected["Contents/MacOS/Silkwire"] != nil, expected.keys.contains(where: { $0.hasPrefix("Contents/Resources/") && !$0.hasSuffix("/") }) else { throw fail("Staging app is incomplete.") }
    _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
    if verifyOnly { print("Promotion preflight passed. No application or library data was changed."); exit(0) }
    let backup = app.deletingLastPathComponent().appendingPathComponent("Silkwire Working Recovery/\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
    try files.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); recovery = backup
    let oldApp = backup.appendingPathComponent("Previous.app"), oldLibrary = backup.appendingPathComponent("Library")
    try files.copyItem(at: app, to: oldApp); try files.copyItem(at: library, to: oldLibrary)
    guard try manifest(oldApp) == oldAppHashes, try manifest(oldLibrary) == libraryHashes else { throw fail("Matched app/library backup verification failed.") }
    try assertNoHardlinks(oldApp); try assertNoHardlinks(oldLibrary)
    receipt.merge(["sourceApp": source.path, "workingApp": app.path, "recoveryApp": oldApp.path, "recoveryLibrary": oldLibrary.path,
                   "sourceHashes": expected, "previousAppHashes": oldAppHashes, "previousLibraryHashes": libraryHashes,
                   "workspaceBeforeSHA256": sha(original), "workspaceAfterSHA256": sha(updated), "createdAt": ISO8601DateFormatter().string(from: Date())]) { _, value in value }
    try json(receipt).write(to: backup.appendingPathComponent("receipt.json"), options: .atomic)
    let prepared = backup.appendingPathComponent("Prepared.app")
    try files.copyItem(at: source, to: prepared)
    guard try manifest(prepared) == expected else { throw fail("Exact tested app copy verification failed.") }
    var promotedPlist = plist
    promotedPlist["CFBundleIdentifier"] = bundleID
    promotedPlist["CFBundleName"] = oldPlist["CFBundleName"] ?? "Silkwire"
    promotedPlist["CFBundleDisplayName"] = oldPlist["CFBundleDisplayName"] ?? "Silkwire"
    promotedPlist.removeValue(forKey: "SilkwireEnvironment")
    try PropertyListSerialization.data(fromPropertyList: promotedPlist, format: .xml, options: 0).write(to: prepared.appendingPathComponent("Contents/Info.plist"), options: .atomic)
    _ = try command("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", prepared.path])
    _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", prepared.path])
    let afterSigning = try manifest(prepared)
    let changed = Set(expected.keys).union(afterSigning.keys).filter { expected[$0] != afterSigning[$0] }
    guard changed.allSatisfy({ $0 == "Contents/Info.plist" || $0 == "Contents/MacOS/Silkwire" || $0.hasPrefix("Contents/_CodeSignature/") }),
          expected.filter({ $0.key.hasPrefix("Contents/Resources/") }) == afterSigning.filter({ $0.key.hasPrefix("Contents/Resources/") }) else { throw fail("Promotion changed tested resources or unexpected bundle files.") }
    let originalPayload = backup.appendingPathComponent("StagingPayload"), newPayload = backup.appendingPathComponent("WorkingPayload")
    try files.copyItem(at: source.appendingPathComponent("Contents/MacOS/Silkwire"), to: originalPayload)
    try files.copyItem(at: prepared.appendingPathComponent("Contents/MacOS/Silkwire"), to: newPayload)
    _ = try command("/usr/bin/codesign", ["--remove-signature", originalPayload.path])
    _ = try command("/usr/bin/codesign", ["--remove-signature", newPayload.path])
    let payloadHash = sha(try Data(contentsOf: originalPayload))
    guard payloadHash == sha(try Data(contentsOf: newPayload)), try manifest(source) == expected else { throw fail("Executable code changed beyond signing metadata, or the tested source app changed.") }
    receipt["unsignedExecutableSHA256"] = payloadHash; receipt["promotedHashes"] = afterSigning
    receipt["metadataAndSignatureExceptions"] = changed.sorted()
    try assertNotRunning(app)
    guard try manifest(app) == oldAppHashes, try manifest(library) == libraryHashes, try Data(contentsOf: file) == original else { throw fail("Working app/library changed during preparation; promotion stopped.") }
    try files.moveItem(at: app, to: backup.appendingPathComponent("Retired.app")); appMoved = true
    try files.copyItem(at: prepared, to: app)
    guard try manifest(app) == afterSigning else { throw fail("Installed app verification failed.") }
    workspaceChanged = true
    try updated.write(to: file, options: .atomic)
    if let workspacePermissions { try files.setAttributes([.posixPermissions: workspacePermissions], ofItemAtPath: file.path) }
    guard try Data(contentsOf: file) == updated else { throw fail("Working Project grant verification failed.") }
    var finalLibrary = try manifest(library); finalLibrary["workspace.json"] = libraryHashes["workspace.json"]
    guard finalLibrary == libraryHashes else { throw fail("An unexpected working library file changed.") }
    receipt["status"] = "complete"
    try json(receipt).write(to: backup.appendingPathComponent("receipt.json"), options: .atomic)
    print("Promoted tested code/resources with working identity preserved. Recovery: \(backup.path). No app was launched.")
} catch {
    var restored = true
    if let backup = recovery {
        if appMoved, let app = target {
            do {
                if exists(app) { try files.moveItem(at: app, to: backup.appendingPathComponent("Incomplete-\(UUID().uuidString).app")) }
                try files.copyItem(at: backup.appendingPathComponent("Previous.app"), to: app)
                if let expected = receipt["previousAppHashes"] as? [String: String] { guard try manifest(app) == expected else { throw fail("App restoration verification failed.") } }
            } catch { restored = false }
        }
        if workspaceChanged, let file = workspaceFile, let original = originalWorkspace {
            do {
                try original.write(to: file, options: .atomic)
                if let workspacePermissions { try files.setAttributes([.posixPermissions: workspacePermissions], ofItemAtPath: file.path) }
                guard try Data(contentsOf: file) == original else { throw fail("Workspace restoration verification failed.") }
            }
            catch { restored = false }
        }
        receipt["status"] = restored ? "failed-restored" : "failed-recovery-required"
        try? json(receipt).write(to: backup.appendingPathComponent("receipt.json"), options: .atomic)
        fputs("Recovery artifacts retained: \(backup.path). Restoration verified: \(restored).\n", stderr)
    }
    fputs("\(error.localizedDescription)\n", stderr); exit(1)
}
