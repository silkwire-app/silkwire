import Foundation

/// The D2 physical-ownership registry for every room, trusted workspace and Builder the
/// app creates without being handed one explicitly.
///
/// - The app uses the single application registry, the same one
///   `BackgroundJobHostInjection.application` registers background hosts against, so
///   foreground and background work share one slot.
/// - The test harness (`Scripts/test.swift`) compiles the core with
///   `SILKWIRE_TEST_HARNESS`. Each test process then gets its own private registry
///   under its temporary directory, and no test can reach
///   `~/Library/Application Support/Silkwire Host Ownership`.
///
/// Tests that build a NativeBuilder or NativeTrustedWorkspaces directly pass
/// `ownership: HostOwnershipDefault.coordinator` (or their own private coordinator).
@MainActor enum HostOwnershipDefault {
    static let coordinator: HostExecutionCoordinator = {
        #if SILKWIRE_TEST_HARNESS
        return HostExecutionCoordinator(directory: testRegistry)
        #else
        return .application
        #endif
    }()
    #if SILKWIRE_TEST_HARNESS
    /// One private registry per test process, removed when the process exits.
    nonisolated static let testRegistry: URL = {
        let root = try! NativeTemporaryDirectory.createWorkspace()
        testRegistryRoot = root.path
        atexit { if let path = HostOwnershipDefault.testRegistryRoot { try? FileManager.default.removeItem(atPath: path) } }
        return root.appendingPathComponent("host-ownership")
    }()
    nonisolated(unsafe) static var testRegistryRoot: String?
    #endif
}

/// Staging install/rollback share the app's registry, so they wait for, and block,
/// every room, workspace and background job (tests get the private registry).
extension StagingInstallLane {
    static let application = StagingInstallLane(coordinator: HostOwnershipDefault.coordinator)
}
