import Foundation

/// The command bridge for background Builder jobs.
///
/// HostJobRequest carries no commands. So the host's Plan callback
/// (HostNativeBuilderJobs.Plan) reads the teammate's exact WORK_PROJECT JSON from the
/// job card (BackgroundJobDesk.requestedWork) and validates it here, every time it is
/// asked. That JSON is untrusted request data. It never supplies a path, and nothing in
/// it is a grant. The only commands that pass are a single `command`, or checks named
/// `build` and/or `test`: the two slots HostNativeBuildPlan has. Everything else is
/// refused with a plain reason.
///
/// The source is always the requesting teammate's own private workspace in this
/// conversation, found from the host's saved receipt (never from the JSON). It must
/// be committed and clean, and at exactly the revision the host authorized. The job
/// builds that revision in its own isolated Builder copy.
///
/// The same lookups back the host's scope resolver (also given to
/// HostJobCommandRouter), authorize and resolve callbacks, so every check is
/// repeated fresh before any physical effect.
@MainActor final class BackgroundJobCommandBridge {
    /// What the library says about a conversation right now: its Project, and that
    /// conversation's private trusted-workspace storage. nil if the conversation is gone,
    /// archived, or its Project no longer allows trusted work.
    struct Room: Equatable { let projectID: UUID; let storage: URL }
    struct Workspace: Equatable { let worktree: URL; let head: String }
    struct Refusal: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }
    typealias Library = (_ conversationID: UUID) -> Room?
    /// The job card's requester and exact request: (agent, workspaceID, WORK_PROJECT JSON).
    typealias Requested = (_ job: UUID, _ conversationID: UUID) -> (agent: String, workspaceID: UUID, work: String)?
    /// Called with the plain reason whenever the Plan refuses, so the card can show it.
    typealias Refused = (_ job: UUID, _ conversationID: UUID, _ reason: String) -> Void

    let library: Library
    private let requested: Requested
    private let refused: Refused
    init(library: @escaping Library, requested: @escaping Requested, refused: @escaping Refused = { _, _, _ in }) {
        self.library = library; self.requested = requested; self.refused = refused
    }

    // MARK: Host callbacks

    /// HostJobCommandRouter.Scope: the host-authorized scope for a teammate's workspace.
    func scope(conversationID: UUID, workspaceID: UUID, agentID: String) async throws -> BackgroundWorkScope {
        guard agents.contains(agentID) else { throw Refusal(reason: "Only a teammate in this room can request background work.") }
        guard let room = library(conversationID) else { throw Refusal(reason: "This conversation's Project doesn't allow trusted background work right now.") }
        let workspace = try await Self.workspace(storage: room.storage, id: workspaceID, agent: agentID)
        return BackgroundWorkScope(projectID: room.projectID, conversationID: conversationID, workspaceID: workspaceID, agentID: agentID, sourceRevision: workspace.head)
    }
    /// BackgroundWorkEngine.Authorize: the scope still resolves to exactly the same thing.
    func authorize(_ scope: BackgroundWorkScope) async -> Bool {
        (try? await self.scope(conversationID: scope.conversationID, workspaceID: scope.workspaceID, agentID: scope.agentID)) == scope
    }
    /// HostBackgroundExecution.Resolve: the workspace the job's admission reserves.
    func resolve(_ scope: BackgroundWorkScope) async throws -> HostAuthorizedWorkspace {
        guard let room = library(scope.conversationID) else { throw HostExecutionCoordinator.Failure.permissionChanged }
        let workspace = try await Self.workspace(storage: room.storage, id: scope.workspaceID, agent: scope.agentID)
        guard workspace.head == scope.sourceRevision else { throw HostExecutionCoordinator.Failure.permissionChanged }
        return HostAuthorizedWorkspace(executionRoot: workspace.worktree, conflictRoot: workspace.worktree)
    }
    /// HostNativeBuilderJobs.Plan. Called before the Builder starts and again when it
    /// re-authorizes its source; both answers must match.
    func plan(_ context: BackgroundWorkContext) async throws -> HostNativeBuildPlan {
        let scope = context.item.scope
        do {
            guard let job = requested(context.item.id, scope.conversationID) else {
                throw Refusal(reason: "This job's request isn't on its card in this conversation, so nothing ran.")
            }
            guard job.agent == scope.agentID, job.workspaceID == scope.workspaceID else {
                throw Refusal(reason: "This job's card names a different teammate or workspace than the host authorized, so nothing ran.")
            }
            guard job.work.utf8.count <= 64 * 1024, let args = try? JSONSerialization.jsonObject(with: Data(job.work.utf8)) as? [String: Any] else {
                throw Refusal(reason: "The requested run isn't readable WORK_PROJECT JSON, so nothing ran.")
            }
            let commands = try Self.commands(args)
            guard let room = library(scope.conversationID) else { throw Refusal(reason: "This conversation's Project doesn't allow trusted background work right now, so nothing ran.") }
            let workspace = try await Self.workspace(storage: room.storage, id: scope.workspaceID, agent: scope.agentID)
            guard workspace.head == scope.sourceRevision else {
                throw Refusal(reason: "The workspace is at a different revision than when the run was requested, so nothing ran. Run again to build the new revision.")
            }
            return HostNativeBuildPlan(source: workspace.worktree, build: commands.build, test: commands.test, edit: false)
        } catch {
            refused(context.item.id, scope.conversationID, (error as? Refusal)?.reason ?? BackgroundJobDesk.describe(error))
            throw error
        }
    }

    // MARK: Validation (also used by the room to decide what to hand off)

    /// The build and test commands in a WORK_PROJECT run step, or a plain refusal.
    static func commands(_ args: [String: Any]) throws -> (build: String, test: String) {
        guard args["action"] as? String == "run" else { throw Refusal(reason: "Background jobs only take WORK_PROJECT run steps.") }
        guard Set(args.keys).isSubset(of: ["action", "command", "checks"]) else { throw Refusal(reason: "The run step has fields Silkwire doesn't accept.") }
        var build = "", test = ""
        if let command = args["command"] as? String, args["checks"] == nil {
            build = command
        } else if args["command"] == nil, let checks = args["checks"] as? [[String: Any]], (1...2).contains(checks.count) {
            for check in checks {
                guard Set(check.keys).isSubset(of: ["name", "command"]), let name = check["name"] as? String, let command = check["command"] as? String else {
                    throw Refusal(reason: "Each check needs a name and a command.")
                }
                if name == "build", build.isEmpty { build = command }
                else if name == "test", test.isEmpty { test = command }
                else { throw Refusal(reason: "Background jobs run one check named build and one named test. \"\(limitedUTF16(name, to: 60))\" isn't one of them.") }
            }
        } else {
            throw Refusal(reason: "Background jobs run one command, or checks named build and test (at most two).")
        }
        for command in [build, test] where !command.isEmpty {
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, command.count <= 4000, !command.contains("\0") else {
                throw Refusal(reason: "Each command must be 1–4,000 characters.")
            }
            guard NativeBuilder.scrub(command) == command else { throw Refusal(reason: "Commands can't include credentials.") }
        }
        guard !(build + test).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal(reason: "The run step has no command.") }
        return (build, test)
    }
    static func eligible(_ args: [String: Any]) -> Bool { (try? commands(args)) != nil }

    /// The teammate's own private workspace in this conversation's storage: its retained
    /// worktree, which must be a clean Git top level with a 40-character HEAD.
    static func workspace(storage: URL, id: UUID, agent: String) async throws -> Workspace {
        guard let saved = NativeTrustedWorkspaces.savedReceipt(storage: storage, id: id.uuidString), saved.agent == agent else {
            throw Refusal(reason: "That workspace isn't one of this teammate's in this conversation.")
        }
        let root = saved.root.resolvingSymlinksInPath()
        let worktree = root.appendingPathComponent("worktree")
        let files = FileManager.default
        guard (try? files.attributesOfItem(atPath: worktree.path)[.type]) as? FileAttributeType == .typeDirectory,
              worktree.resolvingSymlinksInPath().path == worktree.path,
              (saved.receipt["worktreePath"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == worktree.path else {
            throw Refusal(reason: "That workspace's private copy isn't available any more.")
        }
        let env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
        let safe = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
        func git(_ arguments: [String]) async throws -> String {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: safe + arguments, directory: worktree, environment: env, timeoutSeconds: 30, outputLimit: 65536)
            guard result.exitCode == 0, !result.truncated else { throw Refusal(reason: "Silkwire couldn't read that workspace's Git state.") }
            return result.stdout
        }
        let top = try await git(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == worktree.path else { throw Refusal(reason: "That workspace's private copy isn't a Git checkout.") }
        let head = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else { throw Refusal(reason: "That workspace has no usable commit.") }
        guard try await git(["status", "--porcelain=v1", "--untracked-files=all"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Refusal(reason: "That workspace has uncommitted changes. Use WORK_PROJECT checkpoint first: a background job builds an exact committed revision.")
        }
        return Workspace(worktree: worktree, head: head)
    }
}
