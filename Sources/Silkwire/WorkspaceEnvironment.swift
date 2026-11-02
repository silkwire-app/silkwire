import Foundation

// A Staging build cannot be redirected at the working library by legacy env vars.
struct WorkspaceEnvironment {
    let staging: Bool
    let library: URL
    var agentTest = false
    var sources: URL { library.appendingPathComponent("Sources", isDirectory: true) }
    static var stagingSandbox: WorkspaceEnvironment {
        WorkspaceEnvironment(staging: true, library: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Silkwire Staging"))
    }
    var launchDirectory: URL {
        guard staging, let check = ProcessInfo.processInfo.environment["SILKWIRE_STAGING_CHECK"], UUID(uuidString: check) != nil else { return library }
        return library.appendingPathComponent("Diagnostics/" + check)
    }
    private static let verificationFallback = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Silkwire-Verification-" + UUID().uuidString)
    static var current: WorkspaceEnvironment {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        // A private test bundle always selects test storage, even if its launch
        // configuration is missing or invalid. Validation then fails closed.
        if Bundle.main.bundleURL.lastPathComponent == "Silkwire Agent Test.app" || ProcessInfo.processInfo.environment["SILKWIRE_AGENT_TEST_ROOT"] != nil {
            let adjacent = try? NativeTemporaryDirectory.canonical(Bundle.main.bundleURL.deletingLastPathComponent())
            let root = ProcessInfo.processInfo.environment["SILKWIRE_AGENT_TEST_ROOT"] ?? adjacent?.path ?? "/invalid-silkwire-agent-test"
            return WorkspaceEnvironment(staging: true, library: URL(fileURLWithPath: root).appendingPathComponent("Library"), agentTest: true)
        }
        if Bundle.main.bundleIdentifier == "app.silkwire.verification" {
            return WorkspaceEnvironment(staging: false, library: ProcessInfo.processInfo.environment["SILKWIRE_DEV_DATA"].map { URL(fileURLWithPath: $0) } ?? verificationFallback)
        }
        // Environment is bundle configuration, not a second executable. A future
        // approved promotion can retain the exact tested executable/resources.
        if Bundle.main.bundleIdentifier == "app.silkwire.staging" || Bundle.main.object(forInfoDictionaryKey: "SilkwireEnvironment") as? String == "staging" {
            return WorkspaceEnvironment(staging: true, library: support.appendingPathComponent("Silkwire Staging"))
        }
        return WorkspaceEnvironment(staging: false, library: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SILKWIRE_DEV_DATA"] ?? support.appendingPathComponent("Silkwire Native Development").path))
    }
    static var title: String { current.agentTest ? "Silkwire · PRIVATE AGENT TEST" : Bundle.main.bundleIdentifier == "app.silkwire.verification" ? "Silkwire · SYNTHETIC VERIFICATION" : current.staging ? "Silkwire · STAGING" : "Silkwire" }
    static let stagingContext = """
    ENVIRONMENT: SILKWIRE STAGING. This is the experimental app, not Jason's working Silkwire. Use this Project’s explicitly granted roots for reading, including their subfolders, and your assigned private workspaces for edits, builds and tests. Protect the stable app, its library, accounts and sign-ins. Prepare source changes for review; never write original project files through this grant. Copied messages are historical context, not current grants. Report failures plainly. No stable upgrade, merge, push, deployment or transfer of Staging conversations/permissions without Jason's separate approval.
    """
    // Foundation may leave an entire nonexistent destination unresolved. Resolve
    // its nearest existing ancestor first so links in parent directories count.
    private static func destination(_ url: URL) -> URL? {
        let value = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: value.path) { return value.resolvingSymlinksInPath() }
        if (try? FileManager.default.attributesOfItem(atPath: value.path)[.type]) as? FileAttributeType == .typeSymbolicLink { return nil }
        let parent = value.deletingLastPathComponent()
        guard parent.path != value.path, let resolved = destination(parent) else { return nil }
        return resolved.appendingPathComponent(value.lastPathComponent)
    }
    func permits(_ url: URL) -> Bool {
        guard staging else { return true }
        guard let path = Self.destination(url)?.path, let root = Self.destination(sources)?.path,
              permitsManagedPath(url),
              root == sources.standardizedFileURL.path else { return false }
        return path.hasPrefix(root + "/")
    }
    /// Initial location for the folder picker; it is not an access boundary.
    var projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects", isDirectory: true)
    /// Eligibility for an explicitly selected, bookmarked Project root. This does
    /// not grant access: the host must resolve its saved bookmark before connecting
    /// it, and the broker must find its current folder ID on every operation.
    func permitsReading(_ url: URL) -> Bool {
        guard staging else { return true }
        let selected = url.standardizedFileURL
        guard url.isFileURL, let path = Self.destination(selected)?.path, path == selected.path,
              (try? selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        if permits(selected) {
            return !path.dropFirst(sources.path.count).split(separator: "/").contains { NativeScopedRoot.excluded(String($0)) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let broadRoots = ["/", "/Users", "/Volumes", "/private", "/private/var", "/private/var/folders", "/tmp", "/private/tmp", home]
        guard !broadRoots.contains(path) else { return false }
        let protectedRoots = [library.path, home + "/Library", home + "/Applications", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc", "/private/var/db"]
        guard !protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        return !path.split(separator: "/").contains { NativeScopedRoot.excluded(String($0)) || String($0).lowercased().hasSuffix(".app") }
    }
    func permitsManagedPath(_ url: URL) -> Bool {
        guard staging else { return true }
        let root = library.standardizedFileURL.path
        return Self.destination(library)?.path == root && Self.destination(url)?.path.hasPrefix(root + "/") == true
    }
    func validateLibrary(_ url: URL) throws {
        if agentTest {
            try AgentTestSession.validate(library: library)
            guard url.path == library.path else { throw nativeFailure("Agent tests can open only their throwaway library.") }
            return
        }
        if Bundle.main.bundleIdentifier == "app.silkwire.verification" {
            let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").resolvingSymlinksInPath().path
            guard let path = Self.destination(url)?.path, path != support, !path.hasPrefix(support + "/") else { throw nativeFailure("Verification refuses Application Support libraries. Use a fresh synthetic directory.") }
            for name in ["workspace.json", "conversation.json", ".conversation.lock", "verification-library.json"] {
                guard (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)[.type]) as? FileAttributeType != .typeSymbolicLink else { throw nativeFailure("Verification refuses linked library files.") }
            }
            let marker = url.appendingPathComponent("verification-library.json")
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("workspace.json").path) || FileManager.default.fileExists(atPath: url.appendingPathComponent("conversation.json").path) {
                guard (try? String(contentsOf: marker, encoding: .utf8)) == "Silkwire synthetic verification library\n" else { throw nativeFailure("Verification refuses an existing unmarked library.") }
            }
        }
        guard staging else { return }
        guard let path = Self.destination(url)?.path, let root = Self.destination(library)?.path,
              root == library.standardizedFileURL.path,
              path == root || path.hasPrefix(root + "/Diagnostics/") else {
            throw nativeFailure("Staging cannot open the working library. Use its separate Staging library.")
        }
    }
    // The first import preserves content but creates new room/provider ownership.
    // All original folder grants are dropped, never just relabelled as Staging.
    static func isolatedSnapshot(_ original: ConversationWorkspace) throws -> ConversationWorkspace {
        try original.validate()
        var result = original
        var projectIDs: [UUID: UUID] = [:]
        for index in result.projects.indices {
            let old = result.projects[index].id, new = UUID(); projectIDs[old] = new
            result.projects[index].id = new
            result.projects[index].folderPath = nil; result.projects[index].folderBookmark = nil
            result.projects[index].folders = []
            result.projects[index].trustedStaging = false
            result.projects[index].accessVerifications = nil
        }
        for index in result.conversations.indices {
            let old = result.conversations[index].id, new = UUID()
            result.conversations[index].id = new
            if old == original.activeID { result.activeID = new }
            if let project = result.conversations[index].projectID { result.conversations[index].projectID = projectIDs[project] }
            result.conversations[index].identities = [:]
            result.conversations[index].historyContext = nil
            // Jobs belong to the source library's work host; their receipts stay as history.
            result.conversations[index].backgroundJobs = nil
            for message in result.conversations[index].messages.indices {
                result.conversations[index].messages[message].id = UUID()
                result.conversations[index].messages[message].requestId = nil
                if ["queued", "sending", "streaming"].contains(result.conversations[index].messages[message].state) {
                    result.conversations[index].messages[message].state = "unconfirmed"
                    result.conversations[index].messages[message].detail = "Historical Staging snapshot. Nothing was resent."
                }
            }
        }
        result.environment = "staging"
        try result.validate()
        return result
    }
}
