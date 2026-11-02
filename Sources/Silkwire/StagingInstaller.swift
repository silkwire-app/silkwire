import Foundation
import CryptoKit
import Darwin
import Security

/// Set while Staging install/recovery runs inside the exclusive lane
/// (StagingInstallLane). The lane's strict exit proof relies on the installer
/// launching no child process there, so every launch site refuses while it is set.
enum StagingInstallScope {
    @TaskLocal static var exclusiveOperation: UUID?
    static func refuseChildLaunch(_ what: String) throws {
        if exclusiveOperation != nil {
            throw NSError(domain: "Silkwire.StagingInstaller", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(what) would launch a child process inside the exclusive install lane. Nothing was launched."])
        }
    }
}

/// Jason-operated installation of an exact Silkwire Staging candidate. Agents have no
/// route here (no WORK_PROJECT action exists for it). A closed Staging library
/// and its app are retained together before installation or recovery. The stable
/// app, stable library and provider sign-ins have no target in this installer.
struct StagingInstaller {
    struct Identity: Equatable {
        var path: String
        var bundleID: String
        var environment: String
        var revision: String
        var sourceStatus: String
        var sourceDigest: String
        var executableSHA256: String
        /// SHA-256 over every file's relative path and content hash.
        var manifestSHA256: String
        var fileCount: Int
        var signatureValid: Bool
        /// When the bundle was built (newer builds record it), for date-based version labels.
        var builtAt: Date? = nil
        var shortRevision: String { String(revision.prefix(12)) }
        var asJSON: [String: Any] {
            ["path": path, "bundleID": bundleID, "environment": environment, "revision": revision, "sourceStatus": sourceStatus, "sourceDigest": sourceDigest,
             "executableSHA256": executableSHA256, "manifestSHA256": manifestSHA256, "fileCount": fileCount, "signatureValid": signatureValid]
        }
    }
    struct Backup: Identifiable {
        var id: String { path.path }; let path: URL; let identity: Identity?; let savedAt: Date?
        var hasRecoveryPoint: Bool { FileManager.default.fileExists(atPath: path.deletingLastPathComponent().appendingPathComponent("RecoveryPoint.json").path) }
    }
    /// Where a candidate came from, when it was built inside a private team workspace.
    struct Provenance {
        var receiptID: String
        var owner: String
        var status: String
        var headCommit: String?
        /// The worktree's current files match what was built, and it is clean at its
        /// committed head: the candidate is exactly that commit.
        var builtFromHead: Bool?
        var detail: String
    }

    static let installApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let applications: URL
    let library: URL
    /// Executable paths of running processes, or nil when the listing failed
    /// (treated as "Staging may be open"). In-process: no child is launched.
    private let processPaths: () -> [String]?
    private let progress: (String) -> Void
    init(applications: URL = StagingInstaller.installApplications, library: URL? = nil, processPaths: @escaping () -> [String]? = StagingInstaller.runningExecutablePaths, progress: @escaping (String) -> Void = { _ in }) {
        self.applications = applications; self.processPaths = processPaths
        self.progress = progress
        let home = FileManager.default.homeDirectoryForCurrentUser
        // An injected Applications directory must never implicitly select owner data.
        self.library = library ?? (applications.standardizedFileURL == Self.installApplications.standardizedFileURL
            ? home.appendingPathComponent("Library/Application Support/Silkwire Staging")
            : applications.deletingLastPathComponent().appendingPathComponent("Library"))
    }
    var target: URL { applications.appendingPathComponent("Silkwire Staging.app") }
    var backups: URL { applications.appendingPathComponent("Silkwire Staging Backups") }
    var receipts: URL { backups.appendingPathComponent("Install Receipts") }
    var operationLock: URL { backups.appendingPathComponent(".installer.lock") }
    /// Durable record of an install or rollback that has started changing the target.
    /// A crash leaves it behind; the next install or rollback first repairs from it.
    var interruptedMarker: URL { backups.appendingPathComponent(".operation-in-progress.json") }
    var hasInterruptedOperation: Bool { FileManager.default.fileExists(atPath: interruptedMarker.path) }

    /// A shared startup lock closes the interval when rollback swaps library
    /// directories. The app takes it before acquiring its normal library lock.
    static func startupLock() throws -> Int32 {
        let path = StagingInstaller().operationLock.path
        guard FileManager.default.fileExists(atPath: path) else { return -1 }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure("Cannot check the Staging update lock.") }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { Darwin.close(fd); throw failure("Staging is being updated or rolled back. Reopen it when that finishes.") }
        return fd
    }
    private func lockOperation() throws -> Int32 {
        for path in [applications, backups] where FileManager.default.fileExists(atPath: path.path) {
            guard path.standardizedFileURL.resolvingSymlinksInPath() == path.standardizedFileURL else { throw Self.failure("Installer directories must not be symbolic links.") }
        }
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(operationLock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Self.failure("Cannot lock the Staging installer.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw Self.failure("Another Staging install or rollback is in progress.") }
        return fd
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Silkwire.StagingInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func identify(_ app: URL) throws -> Identity {
        var info = stat()
        guard lstat(app.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw failure("Choose an existing Silkwire Staging app bundle (not a link).") }
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any] else { throw failure("The bundle has no readable Info.plist.") }
        guard plist["CFBundleIdentifier"] as? String == "app.silkwire.staging", plist["SilkwireEnvironment"] as? String == "staging", plist["CFBundleExecutable"] as? String == "Silkwire" else {
            throw failure("Only a Silkwire Staging bundle (app.silkwire.staging, environment staging) can be installed here. Nothing changed.")
        }
        let revision = plist["SilkwireGitRevision"] as? String ?? ""
        guard revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else { throw failure("The bundle does not identify its source revision. Rebuild it with Scripts/build.swift --staging.") }
        let manifest = try manifest(app)
        guard let executable = manifest["Contents/MacOS/Silkwire"] else { throw failure("The bundle has no Silkwire executable.") }
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Silkwire").path) else { throw failure("The Silkwire executable is not executable. Nothing was changed.") }
        let entries = try manifest.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { path in
            let permissions = try FileManager.default.attributesOfItem(atPath: app.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber
            return path + "\u{0}" + manifest[path]! + "\u{0}" + (permissions?.stringValue ?? "unknown") + "\n"
        }.joined()
        return Identity(path: app.path, bundleID: "app.silkwire.staging", environment: "staging", revision: revision,
                        sourceStatus: plist["SilkwireSourceStatus"] as? String ?? "not recorded", sourceDigest: plist["SilkwireSourceDigest"] as? String ?? "",
                        executableSHA256: executable, manifestSHA256: sha(Data(entries.utf8)), fileCount: manifest.count, signatureValid: signatureValid(app), builtAt: (plist["SilkwireBuiltAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
    }
    static func manifest(_ bundle: URL, progress: ((Int, Int64) -> Void)? = nil) throws -> [String: String] {
        var failed = false
        guard let listing = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, _ in failed = true; return false }) else { throw failure("Cannot read the app bundle.") }
        var result: [String: String] = [:]
        var bytes: Int64 = 0, lastReport = Date.distantPast
        for case let url as URL in listing {
            try autoreleasepool {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                let key = String(url.standardizedFileURL.path.dropFirst(bundle.standardizedFileURL.path.count + 1))
                if values.isSymbolicLink == true { result[key] = "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "") }
                else if values.isRegularFile == true {
                    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                    var digest = SHA256()
                    while true {
                        // Foundation's NSData buffers are autoreleased. A GCD work
                        // item can otherwise retain every chunk until the whole
                        // library scan ends, despite the small per-read bound.
                        let count = try autoreleasepool { () throws -> Int in
                            guard let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty else { return 0 }
                            digest.update(data: chunk); return chunk.count
                        }
                        guard count > 0 else { break }
                        bytes += Int64(count)
                        if Date().timeIntervalSince(lastReport) >= 0.2 { progress?(result.count, bytes); lastReport = Date() }
                    }
                    result[key] = digest.finalize().map { String(format: "%02x", $0) }.joined()
                }
                else if values.isDirectory != true { throw failure("The bundle contains a special file; refusing it.") }
            }
        }
        guard !failed else { throw failure("The app bundle could not be read completely.") }
        progress?(result.count, bytes)
        return result
    }
    /// In-process equivalent of `codesign --verify --deep --strict`: static validity of
    /// the bundle and all nested code, strict validation, and the code's own designated
    /// requirement. No child process, so the install lane can prove its own exit.
    static func signatureValid(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }
    /// Executable paths of this user's visible processes (libproc, in-process), or nil.
    static func runningExecutablePaths() -> [String]? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var paths: [String] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { paths.append(String(cString: buffer)) }
        }
        return paths
    }
    /// Same algorithm as Scripts/build.swift: per-file SHA-256 over tracked and
    /// untracked, non-ignored files as they are on disk.
    static func sourceDigest(_ root: URL) throws -> (digest: String, clean: Bool, headCommit: String) {
        func git(_ arguments: [String]) throws -> Data {
            try StagingInstallScope.refuseChildLaunch("Reading workspace source")
            let job = Process(), pipe = Pipe(); job.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            job.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments; job.currentDirectoryURL = root
            job.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0"]
            job.standardOutput = pipe; job.standardError = FileHandle.nullDevice
            try job.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); job.waitUntilExit()
            guard job.terminationStatus == 0 else { throw failure("Cannot inventory workspace source files.") }
            return data
        }
        let files = FileManager.default
        let inventory = Set(try git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        var input = Data()
        for path in inventory.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let url = root.appendingPathComponent(path)
            guard let kind = try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { continue }
            let content = kind == .typeSymbolicLink ? Data(("link:" + ((try? files.destinationOfSymbolicLink(atPath: url.path)) ?? "")).utf8) : kind == .typeRegular ? try Data(contentsOf: url) : Data("special".utf8)
            input.append(Data(path.utf8)); input.append(0); input.append(Data(sha(content).utf8)); input.append(10)
        }
        return (sha(input), try git(["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty,
                String(decoding: try git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// Matches a candidate built inside a private workspace to that workspace's receipt.
    static func provenance(of candidate: Identity, receipt: [String: Any], worktree: URL) -> Provenance {
        let id = receipt["id"] as? String ?? "", owner = receipt["owner"] as? String ?? "", status = receipt["status"] as? String ?? "unknown"
        let head = (receipt["transfer"] as? [String: Any])?["headCommit"] as? String
        guard !candidate.sourceDigest.isEmpty else { return Provenance(receiptID: id, owner: owner, status: status, headCommit: head, builtFromHead: nil, detail: "This build did not record a source digest; its exact source cannot be matched.") }
        guard let current = try? sourceDigest(worktree) else { return Provenance(receiptID: id, owner: owner, status: status, headCommit: head, builtFromHead: nil, detail: "The workspace source could not be read.") }
        if current.digest == candidate.sourceDigest, current.clean, current.headCommit == head, status == "review" {
            return Provenance(receiptID: id, owner: owner, status: status, headCommit: head, builtFromHead: true, detail: "Built from exactly the finished workspace's committed head.")
        }
        if current.digest == candidate.sourceDigest { return Provenance(receiptID: id, owner: owner, status: status, headCommit: head, builtFromHead: false, detail: "Built from the workspace's current files, which are not a finished committed head.") }
        return Provenance(receiptID: id, owner: owner, status: status, headCommit: head, builtFromHead: false, detail: "The workspace changed after this build; the candidate does not match its final source.")
    }

    func installed() -> Identity? { FileManager.default.fileExists(atPath: target.path) ? try? Self.identify(target) : nil }
    /// A fixed filename alone is not proof that an existing app is Staging.
    /// Refuse a renamed stable app or a link before moving any existing bundle.
    private func checkedInstalled() throws -> Identity? {
        var status = stat()
        guard lstat(target.path, &status) == 0 else {
            guard errno == ENOENT else { throw Self.failure("Cannot inspect the existing Staging destination. Nothing replaced.") }
            return nil
        }
        return try Self.identify(target)
    }
    func isRunning() -> Bool {
        guard let paths = processPaths() else { return true }
        var prefixes = [target.appendingPathComponent("Contents/MacOS/").path]
        if let real = realpath(applications.path, nil) {
            prefixes.append(URL(fileURLWithPath: String(cString: real)).appendingPathComponent("Silkwire Staging.app/Contents/MacOS/").path); free(real)
        }
        return paths.contains { path in prefixes.contains { path.hasPrefix($0) } }
    }
    func listBackups() -> [Backup] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return folders.filter { $0.lastPathComponent != "Install Receipts" && !$0.lastPathComponent.hasPrefix(".") }.compactMap { folder in
            let app = folder.appendingPathComponent("Silkwire Staging.app")
            guard FileManager.default.fileExists(atPath: app.path) else { return nil }
            return Backup(path: app, identity: try? Self.identify(app), savedAt: (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate)
        }.sorted { ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
    }
    private func recoveryFolder(label: String) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = backups.appendingPathComponent("\(stamp)-\(label)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let exists = FileManager.default.fileExists(atPath: library.path)
        var point: [String: Any] = ["version": 1, "libraryExisted": exists, "libraryPath": library.path]
        if exists {
            let snapshot = folder.appendingPathComponent("Library")
            func inventory(_ url: URL, label: String) throws -> [String: String] {
                progress(label)
                return try Self.manifest(url) { count, bytes in
                    progress(label + " · \(count) files · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
            }
            let before = try inventory(library, label: "Checking Staging library before backup")
            progress("Copying the complete Staging library to its recovery point…")
            try FileManager.default.copyItem(at: library, to: snapshot)
            guard try inventory(snapshot, label: "Verifying the library backup") == before,
                  try inventory(library, label: "Confirming the original library is unchanged") == before else { throw Self.failure("Library changed during backup. Nothing installed.") }
            point["libraryManifest"] = before
        }
        try JSONSerialization.data(withJSONObject: point, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("RecoveryPoint.json"), options: .atomic)
        return folder
    }
    private func retain(_ app: URL, label: String, beforeMove: (URL) throws -> Void = { _ in }) throws -> URL {
        let folder = try recoveryFolder(label: label)
        let destination = folder.appendingPathComponent("Silkwire Staging.app")
        try beforeMove(destination)
        try FileManager.default.moveItem(at: app, to: destination)
        return destination
    }
    /// Same exclusive lock as ConversationStore. Keep the inode in place while
    /// copying; a running app cannot race its final save against our snapshot.
    private func lockLibrary() throws -> Int32 {
        for path in [applications, backups, library] {
            if FileManager.default.fileExists(atPath: path.path), path.standardizedFileURL.resolvingSymlinksInPath() != path.standardizedFileURL {
                throw Self.failure("Installer destinations must not be symbolic links. Nothing changed.")
            }
        }
        guard FileManager.default.fileExists(atPath: library.path) else { return -1 }
        let fd = Darwin.open(library.appendingPathComponent(".conversation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Self.failure("Cannot lock the Staging library. Nothing changed.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw Self.failure("Silkwire Staging still has its library open. Quit it before installing or rolling back.") }
        return fd
    }
    private func plannedReceipt() -> URL {
        receipts.appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8) + ".json")
    }
    private func writeReceipt(_ value: [String: Any], to url: URL? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        let url = url ?? plannedReceipt()
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        return url
    }

    /// What an install or rollback had done when it was interrupted. Every path is
    /// saved BEFORE the move it describes, so a crash at any point can be undone.
    struct InterruptedOperation: Codable, Equatable {
        var version = 1
        var attempt = UUID()
        var action: String
        /// Whether a Staging app was installed when the operation began.
        var hadPrevious: Bool
        /// Where the previously installed app is (being) retained.
        var retainedPrevious: String?
        /// Restore only: where the later library is (being) moved aside.
        var laterLibrary: String?
        var libraryReplacementBegan = false
        /// Planned receipt; once it exists the operation committed.
        var receipt: String?
    }
    func interruptedOperation() -> InterruptedOperation? {
        var status = stat()
        guard lstat(interruptedMarker.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              let data = try? Data(contentsOf: interruptedMarker) else { return nil }
        return try? JSONDecoder().decode(InterruptedOperation.self, from: data)
    }
    private func saveInterrupted(_ value: InterruptedOperation) throws {
        let data = try JSONEncoder().encode(value)
        let temporary = backups.appendingPathComponent(".operation-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Self.failure("Cannot record the operation's progress. Nothing more was changed.") }
        defer { Darwin.close(fd); unlink(temporary.path) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0, rename(temporary.path, interruptedMarker.path) == 0 else {
            throw Self.failure("Cannot record the operation's progress. Nothing more was changed.")
        }
        let directory = Darwin.open(backups.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if directory >= 0 { _ = fsync(directory); Darwin.close(directory) }
    }
    private func clearInterrupted() { unlink(interruptedMarker.path) }
    /// Undoes an install or rollback that a crash or kill interrupted before its receipt
    /// was saved, putting back the app (and, for rollback, the library) that was in place
    /// when it began. Incomplete copies are retained, never deleted. Call with both locks held.
    private func repairInterrupted() throws -> String? {
        guard hasInterruptedOperation else { return nil }
        guard let marker = interruptedOperation() else { throw Self.failure("An interrupted Staging operation left unreadable progress at \(interruptedMarker.path). Nothing was changed; inspect it before installing.") }
        let files = FileManager.default
        if let receipt = marker.receipt, files.fileExists(atPath: receipt) {
            clearInterrupted(); return "The interrupted \(marker.action) had already saved its receipt; nothing needed repair."
        }
        progress("Repairing an interrupted Staging \(marker.action) before continuing…")
        var notes: [String] = []
        if let later = marker.laterLibrary, files.fileExists(atPath: later) {
            if files.fileExists(atPath: library.path) {
                let incomplete = URL(fileURLWithPath: later).deletingLastPathComponent().appendingPathComponent("Incomplete Restored Library \(UUID().uuidString.prefix(8))")
                try files.moveItem(at: library, to: incomplete); notes.append("The partly restored library was kept at \(incomplete.path).")
            }
            try files.moveItem(at: URL(fileURLWithPath: later), to: library); notes.append("The library in place before the rollback was put back.")
        } else if marker.libraryReplacementBegan, marker.laterLibrary == nil, files.fileExists(atPath: library.path) {
            let incomplete = backups.appendingPathComponent("Incomplete Restored Library \(UUID().uuidString.prefix(8))")
            try files.moveItem(at: library, to: incomplete); notes.append("A partly restored library (none existed before) was kept at \(incomplete.path).")
        }
        if let previous = marker.retainedPrevious.map(URL.init(fileURLWithPath:)), files.fileExists(atPath: previous.path) {
            let outcome = rollback(previous: previous)
            guard outcome.restored else { throw Self.failure("Repairing the interrupted \(marker.action) could not finish. " + outcome.text) }
            notes.append(outcome.text)
        } else if !marker.hadPrevious, files.fileExists(atPath: target.path) {
            let outcome = rollback(previous: nil)
            guard outcome.restored else { throw Self.failure("Repairing the interrupted \(marker.action) could not finish. " + outcome.text) }
            notes.append(outcome.text)
        } else {
            notes.append("The installed Staging app had not been replaced yet.")
        }
        clearInterrupted()
        let text = "Repaired an interrupted Staging \(marker.action): " + notes.joined(separator: " ")
        progress(text)
        return text
    }
    /// Real-world actions cannot be rolled back with a conversation snapshot.
    /// Keep the newest control rules/audit/task history, then pause running tasks
    /// so an older library cannot automatically repeat already-performed work.
    private func preserveComputerControl(from laterLibrary: URL?, retained: URL) throws -> [String: Any] {
        let files = FileManager.default, name = "Computer Control"
        let target = library.appendingPathComponent(name)
        var latestPreserved = false
        if let latest = laterLibrary?.appendingPathComponent(name) {
            var status = stat()
            if lstat(latest.path, &status) == 0 {
                guard (status.st_mode & S_IFMT) == S_IFDIR else { throw Self.failure("The newer computer-control history is not a real directory. Nothing was discarded.") }
                let expected = try Self.manifest(latest)
                try files.createDirectory(at: library, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var old = stat()
                if lstat(target.path, &old) == 0 { try files.moveItem(at: target, to: retained.appendingPathComponent("Snapshot Computer Control")) }
                try files.copyItem(at: latest, to: target)
                guard try Self.manifest(target) == expected else { throw Self.failure("The newer computer-control history did not copy exactly.") }
                latestPreserved = true
            } else if errno != ENOENT { throw Self.failure("Cannot inspect the newer computer-control history.") }
        }
        var paused = 0, status = stat()
        if lstat(target.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR else { throw Self.failure("Computer-control history must be a real directory.") }
            let tasks = target.appendingPathComponent("tasks.json")
            if lstat(tasks.path, &status) == 0 {
                guard (status.st_mode & S_IFMT) == S_IFREG,
                      var values = try JSONSerialization.jsonObject(with: Data(contentsOf: tasks)) as? [[String: Any]] else { throw Self.failure("Cannot safely pause the saved agent tasks. The previous library is retained.") }
                for index in values.indices where values[index]["state"] as? String == "running" {
                    paused += 1
                    values[index]["state"] = "blocked"
                    values[index]["resumeAfterRestart"] = false
                    values[index]["updatedAt"] = ISO8601DateFormatter().string(from: Date())
                    let reason = "Paused after Staging rollback. Check the current state before resuming."
                    let oldNote = values[index]["note"] as? String ?? ""
                    values[index]["note"] = oldNote.isEmpty ? reason : oldNote + "\n" + reason
                    values[index]["progress"] = (values[index]["progress"] as? String ?? "") + " · paused after rollback"
                }
                if paused > 0 { try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted]).write(to: tasks, options: .atomic) }
            } else if errno != ENOENT { throw Self.failure("Cannot inspect saved agent tasks before rollback.") }
        } else if errno != ENOENT { throw Self.failure("Cannot inspect restored computer-control history.") }
        return ["latestHistoryPreserved": latestPreserved, "runningTasksPaused": paused]
    }
    /// Report rollback only after each move succeeds. Never hide a retained app's
    /// location or promise restoration when a filesystem failure prevented it.
    private func rollback(previous: URL?) -> (text: String, restored: Bool) {
        do {
            if FileManager.default.fileExists(atPath: target.path) { _ = try retain(target, label: "incomplete") }
            if let previous {
                try FileManager.default.moveItem(at: previous, to: target)
                return ("The previously installed Staging app was put back.", true)
            }
            return ("No previous Staging app was installed; the incomplete copy was retained in \(backups.path).", true)
        } catch {
            return ("Automatic restoration could not finish: \(error.localizedDescription). Previous app retained at \(previous?.path ?? "none"); inspect \(target.path) before opening Staging.", false)
        }
    }
    /// Replaces the installed Staging app with `candidate`, which must still be byte-for-
    /// byte what Jason reviewed. The previous bundle is moved aside, never deleted; any
    /// failure restores it. Returns the receipt, including the installed identity.
    /// True when `running` is the installed Staging app, so it may update itself.
    func isInstalledCopy(_ running: URL) -> Bool {
        running.standardizedFileURL.resolvingSymlinksInPath().path == target.standardizedFileURL.resolvingSymlinksInPath().path
    }
    /// Kept as a fail-closed boundary for callers of older versions. Self updates
    /// now use the bundled helper after exit, never a live library snapshot.
    func installReplacingRunning(candidate: URL, reviewed: Identity, running: URL) throws -> [String: Any] {
        guard isInstalledCopy(running) else { throw Self.failure("This Staging app is not the copy installed in Applications, so it cannot update itself. Nothing was changed.") }
        throw Self.failure("Finish saving and quit Staging first. Use the bundled installer helper to install after exit, with a matched library backup.")
    }
    /// Reopens `app` once process `pid` has exited, so two copies never share the library.
    static func relaunchAfterExit(_ app: URL, pid: Int32 = getpid()) throws {
        try StagingInstallScope.refuseChildLaunch("Relaunching Staging")
        let job = Process(); job.executableURL = URL(fileURLWithPath: "/bin/sh")
        job.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.3; done; /usr/bin/open \"$2\"", "silkwire-relaunch", String(pid), app.path]
        try job.run()
    }
    func install(candidate: URL, reviewed: Identity, replacingRunning: Bool = false) throws -> [String: Any] {
        progress("Rechecking the candidate bytes and signature…")
        let current = try Self.identify(candidate)
        guard current.manifestSHA256 == reviewed.manifestSHA256, current.executableSHA256 == reviewed.executableSHA256 else { throw Self.failure("The candidate changed after you reviewed it. Nothing was installed.") }
        guard current.signatureValid else { throw Self.failure("The candidate's code signature does not verify. Nothing was installed.") }
        if !hasInterruptedOperation, let installed = try checkedInstalled(), installed.signatureValid, installed.manifestSHA256 == current.manifestSHA256 {
            progress("This exact build is already installed and verified. No backup or replacement is needed.")
            return ["action": "already-installed", "installed": installed.asJSON, "target": target.path, "libraryModified": false, "backup": NSNull(), "receiptPath": NSNull()]
        }
        guard candidate.standardizedFileURL.path != target.standardizedFileURL.path else { throw Self.failure("That bundle is already the installed Staging app.") }
        guard !replacingRunning, !isRunning() else { throw Self.failure("Silkwire Staging is open. Quit it first; nothing was changed.") }
        progress("Acquiring the Staging installer and library locks…")
        let operation = try lockOperation(); defer { Darwin.close(operation) }
        let lock = try lockLibrary(); defer { if lock >= 0 { Darwin.close(lock) } }
        let repaired = try repairInterrupted()
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        progress("Checking the installed Staging app…")
        let previous = try checkedInstalled()
        var backup: URL?
        var marker = InterruptedOperation(action: "install", hadPrevious: FileManager.default.fileExists(atPath: target.path))
        try saveInterrupted(marker)
        let point: URL
        do {
            if marker.hadPrevious { backup = try retain(target, label: "before-install") { marker.retainedPrevious = $0.path; try saveInterrupted(marker) } }
            point = try backup?.deletingLastPathComponent() ?? recoveryFolder(label: "before-first-install")
        } catch {
            // Nothing replaced yet; put back anything already moved aside.
            if let backup, !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.moveItem(at: backup, to: target) }
            if !FileManager.default.fileExists(atPath: marker.retainedPrevious ?? "/nonexistent") { clearInterrupted() }
            throw error
        }
        do {
            progress("Installing the verified candidate after its matched backup…")
            try FileManager.default.copyItem(at: candidate, to: target)
            progress("Verifying the installed app bytes and signature…")
            let result = try Self.identify(target)
            guard result.manifestSHA256 == reviewed.manifestSHA256, result.signatureValid else { throw Self.failure("Installed bytes did not match the reviewed candidate.") }
            var receipt: [String: Any] = ["action": "install", "candidate": reviewed.asJSON, "installed": result.asJSON, "target": target.path, "libraryModified": false, "at": ISO8601DateFormatter().string(from: Date())]
            receipt["previous"] = previous?.asJSON ?? NSNull(); receipt["backup"] = backup?.path ?? NSNull()
            receipt["recoveryPoint"] = point.path; receipt["libraryBackup"] = point.appendingPathComponent("Library").path
            receipt["attempt"] = marker.attempt.uuidString
            if let repaired { receipt["repairedInterrupted"] = repaired }
            progress("Saving the install receipt…")
            let planned = plannedReceipt(); marker.receipt = planned.path; try saveInterrupted(marker)
            receipt["receiptPath"] = planned.path
            _ = try writeReceipt(receipt, to: planned)
            clearInterrupted()
            return receipt
        } catch {
            let outcome = rollback(previous: backup)
            if outcome.restored { clearInterrupted() }
            throw Self.failure("Installation failed. " + outcome.text + " " + error.localizedDescription)
        }
    }
    /// Restores a retained backup. The currently installed bundle is retained too, and
    /// the backup itself is copied, not consumed, so recovery can be repeated.
    func recover(backup: Backup, reviewed: Identity) throws -> [String: Any] {
        progress("Checking the selected rollback app and matched library…")
        let folder = backups.standardizedFileURL.resolvingSymlinksInPath().path
        guard backup.path.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(folder + "/") else { throw Self.failure("Choose a backup from the Silkwire Staging Backups folder.") }
        let current = try Self.identify(backup.path)
        guard current.manifestSHA256 == reviewed.manifestSHA256 else { throw Self.failure("The backup changed after you reviewed it. Nothing was restored.") }
        guard current.signatureValid else { throw Self.failure("The backup's code signature does not verify. Nothing was restored.") }
        guard !isRunning() else { throw Self.failure("Silkwire Staging is open. Quit it first; nothing was changed.") }
        let operation = try lockOperation(); defer { Darwin.close(operation) }
        let lock = try lockLibrary(); defer { if lock >= 0 { Darwin.close(lock) } }
        let repaired = try repairInterrupted()
        guard FileManager.default.fileExists(atPath: backup.path.path) else { throw Self.failure("The selected backup was used to repair an interrupted operation and is now installed. Nothing more was restored. " + (repaired ?? "")) }
        let pointURL = backup.path.deletingLastPathComponent().appendingPathComponent("RecoveryPoint.json")
        var restoreLibrary = false, libraryExisted = false
        var libraryManifest: [String: String]?
        var pointStatus = stat()
        if lstat(pointURL.path, &pointStatus) == 0 {
            guard (pointStatus.st_mode & S_IFMT) == S_IFREG else { throw Self.failure("Recovery point metadata must be a regular file. Nothing restored.") }
            guard let point = try JSONSerialization.jsonObject(with: Data(contentsOf: pointURL)) as? [String: Any],
                  point["version"] as? Int == 1, point["libraryPath"] as? String == library.path,
                  let existed = point["libraryExisted"] as? Bool else { throw Self.failure("The recovery point does not match this Staging library.") }
            libraryExisted = existed; restoreLibrary = true
            if existed {
                var snapshotStatus = stat()
                let snapshot = backup.path.deletingLastPathComponent().appendingPathComponent("Library")
                guard lstat(snapshot.path, &snapshotStatus) == 0, (snapshotStatus.st_mode & S_IFMT) == S_IFDIR else { throw Self.failure("The library backup must be a real directory, not a link. Nothing restored.") }
                guard let expected = point["libraryManifest"] as? [String: String],
                      try Self.manifest(snapshot) == expected else { throw Self.failure("The library backup changed. Nothing restored.") }
                libraryManifest = expected
            }
        } else if errno != ENOENT { throw Self.failure("Cannot inspect recovery point metadata. Nothing restored.")
        }
        let previous = try checkedInstalled()
        var retained: URL?
        var marker = InterruptedOperation(action: "rollback", hadPrevious: FileManager.default.fileExists(atPath: target.path))
        try saveInterrupted(marker)
        let retainedFolder: URL
        do {
            if marker.hadPrevious { retained = try retain(target, label: "before-recovery") { marker.retainedPrevious = $0.path; try saveInterrupted(marker) } }
            retainedFolder = try retained?.deletingLastPathComponent() ?? recoveryFolder(label: "before-recovery")
        } catch {
            if let retained, !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.moveItem(at: retained, to: target) }
            if !FileManager.default.fileExists(atPath: marker.retainedPrevious ?? "/nonexistent") { clearInterrupted() }
            throw error
        }
        var displacedLibrary: URL?
        var libraryReplacementBegan = false
        var control: [String: Any] = ["latestHistoryPreserved": false, "runningTasksPaused": 0]
        do {
            progress("Restoring the matched Staging app and library…")
            try FileManager.default.copyItem(at: backup.path, to: target)
            let result = try Self.identify(target)
            guard result.manifestSHA256 == reviewed.manifestSHA256, result.signatureValid else { throw Self.failure("Restored bytes or signature did not match the backup.") }
            if restoreLibrary {
                if FileManager.default.fileExists(atPath: library.path) {
                    let saved = retainedFolder.appendingPathComponent("Later Library")
                    marker.laterLibrary = saved.path; try saveInterrupted(marker)
                    try FileManager.default.moveItem(at: library, to: saved); displacedLibrary = saved
                }
                marker.libraryReplacementBegan = true; try saveInterrupted(marker)
                libraryReplacementBegan = true
                if libraryExisted {
                    try FileManager.default.copyItem(at: backup.path.deletingLastPathComponent().appendingPathComponent("Library"), to: library)
                    guard try Self.manifest(library) == libraryManifest else { throw Self.failure("Restored library bytes did not match the recovery point.") }
                }
                control = try preserveComputerControl(from: displacedLibrary, retained: retainedFolder)
            }
            var receipt: [String: Any] = ["action": "recover", "restoredFrom": backup.path.path, "installed": result.asJSON, "target": target.path, "libraryModified": restoreLibrary && (displacedLibrary != nil || libraryExisted), "laterLibraryRetained": displacedLibrary?.path ?? "", "at": ISO8601DateFormatter().string(from: Date())]
            receipt["previous"] = previous?.asJSON ?? NSNull(); receipt["retainedPrevious"] = retained?.path ?? NSNull()
            receipt["computerControl"] = control
            receipt["attempt"] = marker.attempt.uuidString
            if let repaired { receipt["repairedInterrupted"] = repaired }
            let planned = plannedReceipt(); marker.receipt = planned.path; try saveInterrupted(marker)
            receipt["receiptPath"] = planned.path
            _ = try writeReceipt(receipt, to: planned)
            clearInterrupted()
            return receipt
        } catch {
            var libraryOutcome = ""
            if libraryReplacementBegan {
                do {
                    if FileManager.default.fileExists(atPath: library.path) { try FileManager.default.moveItem(at: library, to: retainedFolder.appendingPathComponent("Incomplete Restored Library")) }
                    if let displacedLibrary { try FileManager.default.moveItem(at: displacedLibrary, to: library) }
                } catch { libraryOutcome = " The preceding library could not be put back; its verified recovery point is at \(retainedFolder.path). \(error.localizedDescription)" }
            }
            let outcome = rollback(previous: retained)
            if outcome.restored && libraryOutcome.isEmpty { clearInterrupted() }
            throw Self.failure("Recovery failed. " + outcome.text + libraryOutcome + " " + error.localizedDescription)
        }
    }
}
