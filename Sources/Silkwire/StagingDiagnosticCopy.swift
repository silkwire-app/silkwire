import Foundation
import Darwin

enum StagingDiagnosticCopy {
    /// A single read sees one atomic saved snapshot. Only the copy is decoded or changed.
    static func create(library: URL, destination: URL, projectID: UUID, workspace: URL) throws -> [String: String] {
        try Task.checkCancellation()
        let source = library.appendingPathComponent("workspace.json")
        guard library.standardizedFileURL.resolvingSymlinksInPath() == library.standardizedFileURL,
              (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw nativeFailure("Diagnostic copy refused: the Staging library is linked.")
        }
        let directory = try privateDestination(workspace: workspace, destination: destination)
        defer { Darwin.close(directory) }
        let original = try Data(contentsOf: source)
        var workspace = try JSONDecoder().decode(ConversationWorkspace.self, from: original)
        workspace.projects = workspace.projects.filter { $0.id == projectID }
        workspace.conversations = workspace.conversations.filter { $0.projectID == projectID }
        guard workspace.projects.count == 1, let first = workspace.conversations.first else {
            throw nativeFailure("Diagnostic copy refused: the currently authorized Project has no saved Staging snapshot.")
        }
        if !workspace.conversations.contains(where: { $0.id == workspace.activeID }) { workspace.activeID = first.id }
        let isolated = try WorkspaceEnvironment.isolatedSnapshot(workspace)
        let copy = try JSONEncoder().encode(isolated)
        try Task.checkCancellation()
        try write(copy, named: "workspace.json", directory: directory)
        let receipt = ["sourceSnapshotSHA256": StagingInstaller.sha(original), "copySHA256": StagingInstaller.sha(copy), "path": destination.path,
                       "scope": "Selected Project Staging snapshot only; provider identities and folder permissions removed; original never written"]
        try write(JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), named: "diagnostic-copy.json", directory: directory)
        return receipt
    }
    /// Pin every directory without following links. Commands can create links inside
    /// their worktree; privileged diagnostic writes must never follow those links.
    private static func privateDestination(workspace: URL, destination: URL) throws -> Int32 {
        let root = workspace.standardizedFileURL.path, path = destination.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { throw nativeFailure("Diagnostic destination is outside the assigned workspace.") }
        let parts = path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "output", parts[1] == "diagnostics", !parts[2].isEmpty, ![".", ".."].contains(parts[2]) else {
            throw nativeFailure("Diagnostic destination must be a new output/diagnostics folder in the assigned workspace.")
        }
        var identity = stat()
        guard lstat(root, &identity) == 0, identity.st_mode & S_IFMT == S_IFDIR,
              let canonical = realpath(root, nil) else { throw nativeFailure("Diagnostic workspace is unavailable or linked.") }
        defer { free(canonical) }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw nativeFailure("Diagnostic workspace could not be opened.") }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        for component in String(cString: canonical).split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw nativeFailure("Diagnostic workspace contains a linked or unavailable directory.") }
            Darwin.close(fd); fd = next
        }
        var pinned = stat()
        guard fstat(fd, &pinned) == 0, pinned.st_dev == identity.st_dev, pinned.st_ino == identity.st_ino else {
            throw nativeFailure("Diagnostic workspace changed before copying; nothing written.")
        }
        for (index, component) in parts.enumerated() {
            let created = mkdirat(fd, component, S_IRWXU)
            guard created == 0 || (index < parts.count - 1 && errno == EEXIST) else {
                throw nativeFailure("Diagnostic destination already exists or cannot be created.")
            }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw nativeFailure("Diagnostic destination contains a link; no linked target was opened.") }
            Darwin.close(fd); fd = next
        }
        retained = true; return fd
    }
    private static func write(_ data: Data, named name: String, directory: Int32) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw nativeFailure("Diagnostic file could not be created safely; existing files were not changed.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
    }

}
