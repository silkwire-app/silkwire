import Foundation

/// All callbacks receive exact runtime identity. Foreground finish includes the
/// Builder workspace UUID; background finish also includes the job UUID and the
/// runner's durable operation/attempt. Recovery rereads evidence on every check.
/// Sandboxed private work uses its distinct practical cleanup result. Exclusive
/// and unsandboxed work still requires strict physical-exit proof. Provider or
/// unobserved work and inspection/cleanup failures retain ownership.
@MainActor struct BackgroundJobExitVerification {
    static let unconfirmedReason = "No sealed physical-exit proof exists for this exact execution attempt; workers may still be alive after restart."
    let verifyExit: HostNativeBuilderJobs.VerifyExit
    let verifyRecovery: BackgroundJobHostRecovery.Verify
    let verifyForegroundExit: HostExitVerifier

    init(verifyExit: @escaping HostNativeBuilderJobs.VerifyExit,
         verifyRecovery: @escaping BackgroundJobHostRecovery.Verify,
         verifyForegroundExit: @escaping HostExitVerifier) {
        self.verifyExit = verifyExit; self.verifyRecovery = verifyRecovery
        self.verifyForegroundExit = verifyForegroundExit
    }
    init(coordinator: HostExecutionCoordinator) {
        let proofs = HostExitProofStorage(directory: coordinator.storage.directory)
        verifyExit = { await $0.evidence.verify($0) }
        verifyForegroundExit = { await $0.evidence.verify($0) }
        verifyRecovery = { record in
            if let result = await Task.detached(operation: { await HostPrivateExecutionCleanup().recover(record, directory: coordinator.storage.directory) }).value { return result }
            return await proofs.verify(record)
        }
    }
    // The test harness resolves this to its private registry, never the app ledger.
    static let application = BackgroundJobExitVerification(coordinator: HostOwnershipDefault.coordinator)
}
