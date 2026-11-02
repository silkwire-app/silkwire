import Foundation
import Darwin

private func hostExitFailure(_ text: String) -> NSError {
    NSError(domain: "Silkwire.PhysicalExit", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}

/// Immutable identity from the durable reservation, including its unrepeatable lease
/// generation. Paths and operation UUIDs alone cannot identify an execution attempt.
struct HostExecutionIdentity: Codable, Equatable, Sendable {
    let operationID: UUID
    let attemptID: UUID
    let owner: PhysicalWorkOwnership.Owner
    let workspace: PhysicalWorkOwnership.Workspace
    let createdAt: Date
    init(_ record: PhysicalWorkOwnership.Record) {
        operationID = record.operationID; attemptID = record.executionAttemptID
        owner = record.owner; workspace = record.workspace; createdAt = record.createdAt
    }
}

typealias HostExitVerifier = @MainActor (HostExitRequest) async -> HostPhysicalExit

/// Runtime-only capability: the actual Builder run UUID, optional job UUID, and
/// exact durable attempt. Never decoded from agent input or a Builder receipt.
@MainActor struct HostExitRequest {
    let workspaceID: UUID
    let jobID: UUID?
    let evidence: HostLocalExecutionEvidence
    var inherited = false
    var identity: HostExecutionIdentity { evidence.identity }
    var operationID: UUID { identity.operationID }
    var kind: PhysicalWorkOwnership.Kind { identity.owner.kind }
    var conversationID: UUID { identity.owner.conversationID }
    var executionRoot: URL { evidence.executionRoot }
    var conflictRoot: URL { URL(fileURLWithPath: identity.workspace.path) }
    var builderRunID: UUID? { workspaceID }
}

/// Kernel observation starts while the child is suspended, before any user code.
/// NOTE_FORK is sticky: macOS cannot automatically track every descendant, so a
/// fork permanently makes this scope ambiguous, even after its leader exits.
final class HostProcessExitObservation {
    private let queue: Int32
    private var exited = false
    private var forked = false
    private var failure: String?
    init(pid: pid_t) throws {
        queue = kqueue()
        guard queue >= 0 else { throw hostExitFailure("Cannot create the kernel exit observer.") }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
        var change = kevent64_s()
        change.ident = UInt64(pid); change.filter = Int16(EVFILT_PROC)
        change.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
        change.fflags = UInt32(NOTE_EXIT) | UInt32(NOTE_FORK)
        guard Darwin.kevent64(queue, &change, 1, nil, 0, 0, nil) == 0 else {
            Darwin.close(queue); throw hostExitFailure("Kernel exit observation was refused (errno \(errno)).")
        }
    }
    func verdict() -> HostPhysicalExit {
        if let failure { return .unconfirmed(reason: failure) }
        // Coalesced flags retain NOTE_FORK even if fork and exit precede this poll.
        while !exited {
            var event = kevent64_s(), timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let count = Darwin.kevent64(queue, nil, 0, &event, 1, 0, &timeout)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                let message = "Kernel exit observer failed (errno \(errno))."; failure = message
                return .unconfirmed(reason: message)
            }
            if count == 0 { break }
            guard event.flags & UInt16(EV_ERROR) == 0 else {
                failure = "Kernel exit observation became unavailable."
                return .unconfirmed(reason: failure!)
            }
            if event.fflags & UInt32(NOTE_FORK) != 0 { forked = true }
            if event.fflags & UInt32(NOTE_EXIT) != 0 { exited = true }
        }
        if forked { return .unconfirmed(reason: "A managed process forked; detached or reparented child workers cannot be ruled out. Ownership stays held.") }
        guard exited else { return .unconfirmed(reason: "The exact managed process has not been observed exited by the kernel.") }
        return .verified(evidence: "Kernel observed exact-process exit with no fork since suspended spawn.")
    }
    deinit { Darwin.close(queue) }
}

/// Lives with admission, independently of UI, executor completion and cancellation.
/// Only the native local executor opts into complete launch coverage. Any provider,
/// delegated/unobserved launch or lost coverage makes the scope unconfirmed. Forks
/// require strict proof unless all launches qualify for approved private cleanup.
@MainActor final class HostLocalExecutionEvidence {
    let identity: HostExecutionIdentity
    let executionRoot: URL
    private let storage: HostExitProofStorage
    private var tracking = false
    private var binding: (UUID, UUID?)?
    private var sealed: (UUID, UUID?)?
    private var observations: [HostProcessExitObservation] = []
    private var reason: String?
    private var privateManifest: HostPrivateCleanupManifest?
    private let privateStore: HostPrivateCleanupStore
    private var hadUnsandboxedLaunch = false
    private var lineageSampler: Task<Void, Never>?
    init(identity: HostExecutionIdentity, directory: URL, executionRoot: URL? = nil) {
        self.executionRoot = executionRoot ?? URL(fileURLWithPath: identity.workspace.path)
        privateStore = HostPrivateCleanupStore(directory: directory)
        self.identity = identity; storage = HostExitProofStorage(directory: directory)
    }
    func bind(workspaceID: UUID, jobID: UUID?) throws {
        if let binding, binding.0 != workspaceID || binding.1 != jobID {
            try invalidateExternalWork("Execution attempt was assigned conflicting workspace or job identities.")
            throw hostExitFailure("Physical-exit witness already belongs to a different workspace or job.")
        }
        binding = (workspaceID, jobID)
    }
    func enableLocalTracking() { tracking = true }
    func invalidate(_ message: String) { if reason == nil { reason = message } }
    /// External/delegated work must durably disable restart's private exception
    /// BEFORE dispatch. If evidence cannot be changed, do not dispatch it.
    func invalidateExternalWork(_ message: String) throws {
        invalidate(message)
        if var manifest = privateManifest {
            manifest.disabledReason = message
            try privateStore.save(manifest); privateManifest = manifest
        }
    }
    /// The fixed offline renderer may use an ALREADY witnessed sandboxed private
    /// attempt. It supplies no whole-worker witness to strict or unsandboxed work,
    /// and cannot create private eligibility or clear a prior coverage failure.
    func recordOfflinePreview() throws {
        guard tracking, !identity.owner.kind.isExclusive, !hadUnsandboxedLaunch,
              let manifest = privateManifest, manifest.disabledReason == nil, reason == nil else {
            try invalidateExternalWork("Offline preview has no strict child-worker exit witness; only an existing sandboxed private attempt may use practical cleanup.")
            return
        }
    }
    func launchEnvironment(_ original: [String: String], sandboxedPrivate: Bool) throws -> [String: String] {
        guard sealed == nil else { throw hostExitFailure("Execution attempt is sealed; no further worker may launch.") }
        guard sandboxedPrivate else {
            hadUnsandboxedLaunch = true
            if privateManifest != nil { try invalidateExternalWork("Unsandboxed launch is ineligible for private practical cleanup.") }
            return original
        }
        guard tracking, !identity.owner.kind.isExclusive, !hadUnsandboxedLaunch, let binding else { return original }
        if privateManifest == nil {
            let manifest = HostPrivateCleanupManifest(identity: identity, workspaceID: binding.0, jobID: binding.1,
                tag: UUID(), owner: try HostProcessToken.read(getpid()), lineage: try StagingInstallWorkload.lineage(), roots: [], observed: [], disabledReason: reason)
            try privateStore.save(manifest); privateManifest = manifest
        }
        var result = original
        result[HostPrivateProcessInspector.tagKey] = privateManifest!.tag.uuidString
        return result
    }
    func observeSuspended(pid: pid_t) throws {
        guard sealed == nil else { throw hostExitFailure("Execution attempt is sealed; no further worker may launch.") }
        guard tracking, observations.count < 4096 else {
            invalidate("Complete local launch coverage is unavailable or its observation limit was reached.")
            throw hostExitFailure("Cannot safely observe another managed worker.")
        }
        do {
            let observation = try HostProcessExitObservation(pid: pid)
            if var manifest = privateManifest {
                guard case .live(let root) = try StagingInstallWorkload.identity(pid), manifest.roots != nil else {
                    throw hostExitFailure("Cannot establish suspended worker lineage.")
                }
                manifest.roots!.append(root)
                manifest.tracked.append(try HostProcessToken.read(pid))
                try privateStore.save(manifest); privateManifest = manifest
            }
            observations.append(observation)
            startLineageSampling()
        }
        catch { invalidate("A managed worker could not be observed before execution."); throw error }
    }
    private struct Sample: Sendable {
        var identities: [StagingInstallWorkload.Identity] = []
        var complete = false
    }
    /// The SAME scanner supplies positive descendant observations during execution.
    /// Unknown orphans are never promoted to roots without a matching tag.
    private nonisolated static func sampleLineage(_ scope: StagingInstallWorkload.Scope) -> Sample {
        guard let pass = try? StagingInstallWorkload.pass(scope) else { return Sample() }
        var sample = Sample(complete: pass.incomplete == nil)
        for found in pass.survivors where found.signalSafe {
            if case .live(let id)? = try? StagingInstallWorkload.identity(found.pid), id.unique == found.unique {
                sample.identities.append(id)
            } else { sample.complete = false }
        }
        return sample
    }
    private func startLineageSampling() {
        guard privateManifest != nil, lineageSampler == nil else { return }
        lineageSampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.sealed == nil, let before = self.privateManifest,
                      let lineage = before.lineage, let roots = before.roots else { break }
                let scope = StagingInstallWorkload.Scope(host: before.owner, lineage: lineage,
                    tag: before.tag.uuidString, hostAlive: true, roots: roots + (before.observed ?? []),
                    environmentKey: HostPrivateProcessInspector.tagKey)
                let sample = await Task.detached { Self.sampleLineage(scope) }.value
                guard !Task.isCancelled, self.sealed == nil, var current = self.privateManifest else { break }
                var known = Set((current.roots ?? []).map(\.unique) + (current.observed ?? []).map(\.unique))
                let added = sample.identities.filter { known.insert($0.unique).inserted }
                if !added.isEmpty {
                    current.observed = (current.observed ?? []) + added
                    do { try self.privateStore.save(current); self.privateManifest = current }
                    catch { self.invalidate("Cannot persist observed process lineage: " + error.localizedDescription); break }
                }
                // No known worker remains. A later launch restarts sampling. A
                // root added during the scan prevents this early stop.
                if sample.complete, sample.identities.isEmpty, current.tracked.count == before.tracked.count { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.lineageSampler = nil
        }
    }
    /// A leader can exit while a detached tagged helper keeps its pipes open.
    /// Sweep the same private attempt before waiting for those pipes, without
    /// sealing it: the Builder may still need to collect final Git evidence.
    func sweepAfterLeaderExit() async {
        guard let manifest = privateManifest, reason == nil, manifest.disabledReason == nil else { return }
        do {
            guard let durable = try privateStore.load(identity), durable.binding == manifest.binding,
                  durable.tracked == manifest.tracked, durable.lineage == manifest.lineage, durable.roots == manifest.roots, durable.observed == manifest.observed else { throw hostExitFailure("Missing or mismatched pre-drain cleanup evidence.") }
            let answer = await Task.detached { await HostPrivateExecutionCleanup().sweep(manifest) }.value
            if case .unconfirmed(let message) = answer { invalidate(message) }
        } catch { invalidate("Pre-drain private cleanup failed: " + error.localizedDescription) }
    }
    func verify(_ request: HostExitRequest) async -> HostPhysicalExit {
        guard request.evidence === self else { return .unconfirmed(reason: "Exit evidence belongs to a different execution attempt.") }
        guard let binding, binding.0 == request.workspaceID, binding.1 == request.jobID else {
            return .unconfirmed(reason: "Missing or mismatched host job/workspace binding for this execution attempt.")
        }
        if let sealed, sealed.0 != request.workspaceID || sealed.1 != request.jobID {
            return .unconfirmed(reason: "Exit evidence is bound to a different job or workspace.")
        }
        sealed = (request.workspaceID, request.jobID)
        // Join the sampler before comparing/sealing durable evidence. It cannot
        // race a final snapshot or write after the launch boundary is sealed.
        lineageSampler?.cancel()
        await lineageSampler?.value
        lineageSampler = nil
        guard tracking else { return .unconfirmed(reason: "No complete local executor witness exists for this execution attempt.") }
        if var manifest = privateManifest {
            do {
                guard let durable = try privateStore.load(identity), durable.workspaceID == request.workspaceID,
                      durable.jobID == request.jobID, durable.tag == manifest.tag, durable.tracked == manifest.tracked,
                      durable.disabledReason == manifest.disabledReason, durable.lineage == manifest.lineage,
                      durable.roots == manifest.roots, durable.observed == manifest.observed else { return .unconfirmed(reason: "Missing or mismatched durable private cleanup evidence.") }
                manifest.sealed = true; try privateStore.save(manifest); privateManifest = manifest
                if let reason { return .unconfirmed(reason: reason) }
                let snapshot = manifest
                return await Task.detached { await HostPrivateExecutionCleanup().sweep(snapshot) }.value
            } catch { return .unconfirmed(reason: "Private cleanup evidence unavailable; ownership stays held: " + error.localizedDescription) }
        }
        if let reason { return .unconfirmed(reason: reason) }
        for observation in observations {
            if case .unconfirmed(let reason) = observation.verdict() { return .unconfirmed(reason: reason) }
        }
        let proof = HostExitProof(identity: identity, workspaceID: request.workspaceID, jobID: request.jobID,
                                  observedProcesses: observations.count)
        do {
            try await storage.save(proof)
            return .verified(evidence: proof.summary)
        } catch { return .unconfirmed(reason: "Exit was observed, but its durable proof could not be saved: \(error.localizedDescription)") }
    }
}

/// Only sealed, complete kernel observations become certificates. A crash before
/// seal leaves no certificate; recovery must retain ownership, never infer PID exit.
struct HostExitProof: Codable, Equatable, Sendable {
    let identity: HostExecutionIdentity
    let workspaceID: UUID
    let jobID: UUID?
    let observedProcesses: Int
    var summary: String { "Local exit verified for operation \(identity.operationID), exact durable attempt, workspace \(workspaceID): \(observedProcesses) exact kernel exits, no forks or unobserved work." }
}

actor HostExitProofStorage {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private func openDirectory() throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw hostExitFailure("Exit-proof directory is unavailable.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(fd); throw hostExitFailure("Exit-proof directory ownership or permissions are unsafe.")
        }
        return fd
    }
    private func name(_ identity: HostExecutionIdentity) -> String { "physical-exit-" + identity.attemptID.uuidString + ".json" }
    func save(_ proof: HostExitProof) throws {
        let dir = try openDirectory(); defer { close(dir) }
        let data = try JSONEncoder().encode(proof)
        guard data.count <= 65536 else { throw hostExitFailure("Exit proof exceeds its bound.") }
        let temporary = ".physical-exit-" + UUID().uuidString
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw hostExitFailure("Cannot create durable exit proof.") }
        defer { close(fd); unlinkat(dir, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw hostExitFailure("Cannot write durable exit proof.") }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(dir, temporary, dir, name(proof.identity)) == 0, fsync(dir) == 0 else {
            throw hostExitFailure("Cannot commit durable exit proof.")
        }
    }
    func verify(_ record: PhysicalWorkOwnership.Record) -> HostPhysicalExit {
        do {
            let identity = HostExecutionIdentity(record)
            let dir = try openDirectory(); defer { close(dir) }
            let fd = openat(dir, name(identity), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == ENOENT { return .unconfirmed(reason: "No sealed physical-exit proof exists for this exact execution attempt; workers may still be alive after restart.") }
                return .unconfirmed(reason: "Physical-exit proof cannot be opened (errno \(errno)); permission or path validation failed. Ownership stays held.")
            }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_mode & 0o777 == 0o600, info.st_nlink == 1, (1...65536).contains(info.st_size) else {
                return .unconfirmed(reason: "Physical-exit proof has unsafe metadata or ambiguous contents.")
            }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
            let total = bytes.count
            while offset < total {
                let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), total - offset) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw hostExitFailure("Cannot read complete physical-exit proof.") }
                offset += count
            }
            let proof = try JSONDecoder().decode(HostExitProof.self, from: Data(bytes))
            guard proof.identity == identity, (0...4096).contains(proof.observedProcesses) else {
                return .unconfirmed(reason: "Physical-exit proof is stale or belongs to another owner, workspace or execution attempt.")
            }
            return .verified(evidence: proof.summary)
        } catch { return .unconfirmed(reason: "Physical-exit proof could not be revalidated: \(error.localizedDescription)") }
    }
}
