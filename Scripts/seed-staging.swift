#!/usr/bin/env swift
import Foundation
import CryptoKit
import Darwin

// One-time, read-only import from the working library. This script never starts
// an app/provider, writes the original, or reuses a provider conversation/grant.
let files = FileManager.default
func failure(_ text: String) -> NSError { NSError(domain: "Silkwire.SeedStaging", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func canonical(_ path: String) throws -> URL {
    guard !path.isEmpty, !path.contains("\0") else { throw failure("A supplied path is invalid.") }
    var ancestor = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    var missing: [String] = []
    var attributes = stat()
    // Foundation can leave a nonexistent full path unresolved. Find an existing
    // ancestor using lstat (including dangling links), resolve it, then append
    // only the missing components. This catches links above future directories.
    while lstat(ancestor.path, &attributes) != 0 {
        guard errno == ENOENT else { throw failure("A supplied path cannot be safely inspected.") }
        let parent = ancestor.deletingLastPathComponent()
        guard parent.path != ancestor.path else { throw failure("A supplied path cannot be resolved.") }
        missing.append(ancestor.lastPathComponent); ancestor = parent
    }
    guard let resolved = realpath(ancestor.path, nil) else { throw failure("A supplied path contains an unresolved or dangling link.") }
    defer { free(resolved) }
    var result = URL(fileURLWithPath: String(cString: resolved))
    for component in missing.reversed() { result.appendPathComponent(component) }
    return result
}
func contains(_ parent: URL, _ child: URL) -> Bool { child.path == parent.path || child.path.hasPrefix(parent.path + "/") }
func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
func readSnapshot(_ url: URL) throws -> Data {
    // Open once, then read that descriptor: a concurrent atomic save/rename
    // cannot splice two versions into this snapshot.
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    return try handle.readToEnd() ?? Data()
}
func git(_ arguments: [String], at directory: URL) throws -> String {
    let job = Process(), out = Pipe(), err = Pipe()
    job.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    job.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
    job.currentDirectoryURL = directory; job.standardOutput = out
    // Avoid leaking configuration, URLs, or credential-bearing diagnostics.
    job.standardError = err
    try job.run()
    let output = out.fileHandleForReading.readDataToEndOfFile()
    _ = err.fileHandleForReading.readDataToEndOfFile()
    job.waitUntilExit()
    guard job.terminationStatus == 0 else { throw failure("Git preparation failed; no original files were changed.") }
    return String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

var destinationCreated: URL?
var receipt: [String: Any] = ["format": 1, "status": "incomplete", "sourceModified": false, "providersStarted": false]
do {
    var options: [String: String] = [:]
    let allowed: Set<String> = ["--source-library", "--source-repo", "--destination", "--original-source"]
    var index = 1
    while index < CommandLine.arguments.count {
        let flag = CommandLine.arguments[index]
        guard allowed.contains(flag), options[flag] == nil, index + 1 < CommandLine.arguments.count,
              !CommandLine.arguments[index + 1].hasPrefix("--") else {
            throw failure("Usage: swift Scripts/seed-staging.swift --source-library PATH --source-repo PATH [--destination PATH] [--original-source PATH]")
        }
        options[flag] = CommandLine.arguments[index + 1]; index += 2
    }
    guard let libraryPath = options["--source-library"], let repositoryPath = options["--source-repo"] else {
        throw failure("Both --source-library and --source-repo are required.")
    }
    let library = try canonical(libraryPath), repository = try canonical(repositoryPath)
    let originalSource = try canonical(options["--original-source"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/silkwire").path)
    let defaultDestination = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Silkwire Staging").path
    let rawDestination = URL(fileURLWithPath: ((options["--destination"] ?? defaultDestination) as NSString).expandingTildeInPath).standardizedFileURL
    let destination = try canonical(rawDestination.path)
    // lstat also refuses an existing dangling symlink. Resolve all existing
    // ancestors before checking overlap, so a symlink cannot hide source writes.
    guard !exists(rawDestination), !exists(destination), destination.path != "/",
          [library, repository, originalSource].allSatisfy({ !contains($0, destination) && !contains(destination, $0) }) else {
        throw failure("Destination must be new and separate from the source library and repositories. Nothing overwritten.")
    }
    let sourceFile = library.appendingPathComponent("workspace.json")
    let snapshot = try readSnapshot(sourceFile)
    let snapshotHash = sha(snapshot)
    guard var workspace = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
          let version = workspace["version"] as? Int, (1...5).contains(version),
          var conversations = workspace["conversations"] as? [[String: Any]], !conversations.isEmpty,
          let active = workspace["activeID"] as? String else { throw failure("Source workspace is invalid or unsupported; nothing imported.") }
    var projects = workspace["projects"] as? [[String: Any]] ?? []
    if version == 1 && projects.isEmpty {
        projects = [["id": UUID().uuidString, "name": "Silkwire", "icon": "spider", "color": "violet", "participants": ["eve", "claude", "codex"], "expanded": true]]
        for i in conversations.indices { conversations[i]["projectID"] = projects[0]["id"] }
        workspace["version"] = 5
        if workspace["preferences"] == nil { workspace["preferences"] = [String: Any]() }
    }
    guard !projects.isEmpty else { throw failure("Source workspace has no Projects; nothing imported.") }
    var projectIDs: [String: String] = [:], conversationIDs: [String: String] = [:]
    var matchingProjectIndices: [Int] = []
    for i in projects.indices {
        guard let old = projects[i]["id"] as? String, UUID(uuidString: old) != nil, projectIDs[old] == nil else { throw failure("Source Project identifiers are invalid.") }
        projectIDs[old] = UUID().uuidString
        var sourcePaths = (projects[i]["folders"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        if let legacy = projects[i]["folderPath"] as? String { sourcePaths.append(legacy) }
        if try sourcePaths.contains(where: { try canonical($0).path == originalSource.path }) { matchingProjectIndices.append(i) }
        projects[i]["id"] = projectIDs[old]
        projects[i].removeValue(forKey: "folderPath"); projects[i].removeValue(forKey: "folderBookmark")
        projects[i]["folders"] = [[String: Any]]()
        projects[i]["trustedStaging"] = false
        projects[i].removeValue(forKey: "accessVerifications")
    }
    var messageCount = 0, unconfirmed = 0
    for i in conversations.indices {
        guard let old = conversations[i]["id"] as? String, UUID(uuidString: old) != nil, conversationIDs[old] == nil,
              let project = conversations[i]["projectID"] as? String, let newProject = projectIDs[project],
              var messages = conversations[i]["messages"] as? [[String: Any]] else { throw failure("Source conversation ownership is invalid.") }
        let newID = UUID().uuidString; conversationIDs[old] = newID
        conversations[i]["id"] = newID; conversations[i]["projectID"] = newProject
        conversations[i]["identities"] = [String: Any]()
        for key in ["historyContext", "threadID", "providerIdentity", "providerIdentities", "requestId", "requestID", "runId", "turnId"] { conversations[i].removeValue(forKey: key) }
        for m in messages.indices {
            messages[m]["id"] = UUID().uuidString
            for key in ["requestId", "requestID", "runId", "turnId", "threadID", "providerIdentity", "providerIdentities", "historyContext"] { messages[m].removeValue(forKey: key) }
            if let state = messages[m]["state"] as? String, ["queued", "sending", "streaming"].contains(state) {
                messages[m]["state"] = "unconfirmed"
                messages[m]["detail"] = "Historical Staging snapshot. Nothing was resent."
                unconfirmed += 1
            }
        }
        messageCount += messages.count; conversations[i]["messages"] = messages
    }
    guard let newActive = conversationIDs[active] else { throw failure("Source active conversation is invalid.") }
    let revision = try git(["rev-parse", "--verify", "HEAD"], at: repository)
    guard revision.count == 40, revision.allSatisfy({ $0.isHexDigit }) else { throw failure("Source repository revision is invalid.") }
    receipt.merge(["snapshotSHA256": snapshotHash, "projects": projects.count, "conversations": conversations.count, "messages": messageCount,
                   "unconfirmedHistoricalMessages": unconfirmed, "sourceRevision": revision, "createdAt": ISO8601DateFormatter().string(from: Date())]) { _, new in new }
    try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Exclusive creation protects against races with a second importer.
    guard mkdir(destination.path, 0o700) == 0 else { throw failure("Destination appeared during preparation; nothing overwritten.") }
    destinationCreated = destination
    try writeJSON(receipt, to: destination.appendingPathComponent("staging-seed-receipt.json"))
    let sources = destination.appendingPathComponent("Sources", isDirectory: true)
    try files.createDirectory(at: sources, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let clone = sources.appendingPathComponent("Silkwire", isDirectory: true)
    _ = try git(["clone", "--quiet", "--no-hardlinks", "--no-local", "--template=", "--", repository.path, clone.path], at: destination)
    _ = try git(["remote", "remove", "origin"], at: clone)
    guard try git(["remote"], at: clone).isEmpty, try git(["rev-parse", "--verify", "HEAD"], at: clone) == revision,
          !exists(clone.appendingPathComponent(".git/objects/info/alternates")),
          try clone.appendingPathComponent(".git").resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
          try clone.appendingPathComponent(".git").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw failure("Private source clone verification failed.") }
    if let listing = files.enumerator(at: clone, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
        for case let path as URL in listing {
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true {
                let attributes = try files.attributesOfItem(atPath: path.path)
                guard (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw failure("Private source clone contains a hardlinked file.") }
            }
        }
    } else { throw failure("Private source clone could not be inspected.") }
    // Only Projects that had the exact original source folder get a new grant.
    // Similar names, ancestors, and unrelated folders never inherit access.
    if !matchingProjectIndices.isEmpty {
        let bookmark = try clone.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        for i in matchingProjectIndices {
            projects[i]["folders"] = [["id": UUID().uuidString, "name": "Project files", "path": clone.path, "bookmark": bookmark.base64EncodedString(), "builderAllowed": true]]
        }
        receipt["newGrantPath"] = clone.path
    }
    workspace["projects"] = projects; workspace["conversations"] = conversations
    workspace["activeID"] = newActive; workspace["environment"] = "staging"
    let imported = try JSONSerialization.data(withJSONObject: workspace, options: [.prettyPrinted, .sortedKeys])
    try imported.write(to: destination.appendingPathComponent("workspace.json"), options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.appendingPathComponent("workspace.json").path)
    let importedReadback = try readSnapshot(destination.appendingPathComponent("workspace.json"))
    guard sha(importedReadback) == sha(imported) else { throw failure("Imported workspace verification failed.") }
    receipt["importedSHA256"] = sha(importedReadback)
    receipt["snapshotSHA256AfterImport"] = sha(snapshot)
    // This is observation, not a requirement: the real app may legitimately
    // save newer work while we seed its point-in-time Staging copy.
    if let currentSource = try? readSnapshot(sourceFile) {
        receipt["sourceObservedAfterSHA256"] = sha(currentSource)
        receipt["sourceChangedDuringImport"] = sha(currentSource) != snapshotHash
    }
    receipt["newGrantCount"] = matchingProjectIndices.count
    receipt["status"] = "complete"
    try writeJSON(receipt, to: destination.appendingPathComponent("staging-seed-receipt.json"))
    print("Staging snapshot prepared and verified: \(destination.path). Originals unchanged; no providers started.")
} catch {
    if let destination = destinationCreated {
        receipt["status"] = "incomplete"
        try? writeJSON(receipt, to: destination.appendingPathComponent("staging-seed-receipt.json"))
        fputs("Import incomplete; retained for inspection at \(destination.path). No original files were changed.\n", stderr)
    }
    fputs("\(error.localizedDescription)\n", stderr); exit(1)
}
