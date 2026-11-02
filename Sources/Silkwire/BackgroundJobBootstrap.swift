import Foundation

/// Application bootstrap for background jobs: the one object that switches the room's
/// background work on.
///
/// - **Hosts.** Each conversation that uses jobs gets one host, opened once per process
///   through `BackgroundJobHostInjection.openNativeBuilderHost` (the same injection, and so
///   the same D2 coordinator, as foreground Builder and the room's trusted workspaces).
/// - **Storage.** Each host's ledger opens in a private directory under the Staging library:
///   `<library>/Background Jobs/<staging|working>/<conversation>/ledger`. Its Builder
///   runs go beside it. That is never inside "Team Workspaces" (the agents' private
///   workspaces) or a source folder.
/// - **Callbacks.** Scope, authorize, resolve and plan come from `BackgroundJobCommandBridge`.
///   Exit and recovery evidence come only from `BackgroundJobExitVerification` (the one
///   replaceable adapter file).
///
/// `wiring` is what `ConversationStore(backgroundJobs:)` takes. The same scope resolver
/// backs the HostJobCommandRouter the store passes to NativeRoom.
@MainActor final class BackgroundJobBootstrap {
    /// Opens and registers one conversation's host. The app opens the real native Builder
    /// host; tests can supply the real host service over a stub executor.
    typealias Opener = (_ conversationID: UUID, _ storage: BackgroundWorkStorageSession, _ builderRoot: URL, _ bridge: BackgroundJobCommandBridge) async throws -> any BackgroundJobHost

    /// The app's bootstrap. The synthetic verification build runs without it, so its
    /// acceptance runs never touch the application ownership registry.
    static let application: BackgroundJobBootstrap? = Bundle.main.bundleIdentifier == "app.silkwire.verification" ? nil
        : BackgroundJobBootstrap(injection: .application, verification: .application)

    let injection: BackgroundJobHostInjection
    let verification: BackgroundJobExitVerification
    private let opener: Opener?
    private weak var store: ConversationStore?
    private var opening: [UUID: Task<Void, Error>] = [:]
    private(set) var openFailures: [UUID: String] = [:]

    init(injection: BackgroundJobHostInjection, verification: BackgroundJobExitVerification, opener: Opener? = nil) {
        self.injection = injection; self.verification = verification; self.opener = opener
    }

    private(set) lazy var bridge = BackgroundJobCommandBridge(
        library: { [weak self] id in self?.store?.backgroundJobRoom(id) },
        requested: { [weak self] job, conversationID in self?.store?.jobDesk?.requestedJob(job: job, conversationID: conversationID) },
        refused: { [weak self] job, conversationID, reason in self?.store?.jobDesk?.noteRefusal(job, conversationID: conversationID, reason: reason) })

    var wiring: BackgroundJobDesk.Wiring {
        BackgroundJobDesk.Wiring(
            host: { [injection] in try injection.host(for: $0) },
            scope: { [weak self] conversationID, workspaceID, agentID in
                guard let self else { throw BackgroundWorkError.unavailable }
                return try await self.bridge.scope(conversationID: conversationID, workspaceID: workspaceID, agentID: agentID)
            },
            open: { [weak self] in try await self?.open($0) },
            attach: { [weak self] store in await self?.attach(store) },
            ownership: injection.ownership,
            verifyForegroundExit: verification.verifyForegroundExit)
    }

    /// Library bootstrap: open the host of every conversation that uses jobs.
    func attach(_ store: ConversationStore) async {
        self.store = store
        for id in store.conversationsUsingBackgroundJobs { try? await open(id) }
    }

    /// Opens this conversation's host once per process; later calls return at once.
    func open(_ conversationID: UUID) async throws {
        if (try? injection.host(for: conversationID)) != nil { return }
        if let pending = opening[conversationID] { return try await pending.value }
        let task = Task { @MainActor in try await self.openHost(conversationID) }
        opening[conversationID] = task
        do { try await task.value; opening[conversationID] = nil; openFailures[conversationID] = nil }
        catch {
            opening[conversationID] = nil
            openFailures[conversationID] = BackgroundJobDesk.describe(error)
            throw error
        }
    }
    private func openHost(_ conversationID: UUID) async throws {
        guard let store, let projectID = store.backgroundJobProject(conversationID) else { throw BackgroundWorkError.unavailable }
        let planned = try store.backgroundJobStorage(conversationID)
        for name in ["ledger", "builder-runs"] where !FileManager.default.fileExists(atPath: planned.appendingPathComponent(name).path) {
            try FileManager.default.createDirectory(at: planned.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // The ledger refuses aliased paths (e.g. /var for /private/var): use the real path.
        guard let real = realpath(planned.path, nil) else { throw BackgroundWorkError.unavailable }
        let base = URL(fileURLWithPath: String(cString: real), isDirectory: true); free(real)
        let ledger = base.appendingPathComponent("ledger"), builderRoot = base.appendingPathComponent("builder-runs")
        let storage = try await BackgroundWorkStorageSession.open(directory: ledger, projectID: projectID, conversationID: conversationID)
        if let opener { _ = try await opener(conversationID, storage, builderRoot, bridge); return }
        let bridge = self.bridge
        _ = try await injection.openNativeBuilderHost(originatingConversationID: conversationID, storage: storage, builderStorageRoot: builderRoot,
            authorize: { await bridge.authorize($0) }, resolve: { try await bridge.resolve($0) }, plan: { try await bridge.plan($0) },
            verifyExit: verification.verifyExit, verifyRecovery: verification.verifyRecovery)
    }
}
