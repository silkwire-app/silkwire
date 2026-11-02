import Foundation
import Darwin

// Regressions for review REVIEW-16fac7f findings D3 (host-call saturation latched
// the whole runner as storage-failed) and D4 (an unbounded ledger failed closed
// mid-work). Uses only APIs present at 16fac7f so the same file can be run
// against that revision, where it fails. Synthetic executors and private files only.

/// Fixture parent for the store's descriptor-relative, no-follow path checks.
/// `resolvingSymlinksInPath()` rewrites /private/var and /private/tmp to their
/// /var and /tmp symlinks, which the store correctly refuses. realpath returns
/// the true canonical directory. Prefer the harness-assigned TMPDIR fixture root.
private func canonicalFixtureTemporaryDirectory() throws -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
    guard let path = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
// Holds the next physical replacement once armed. Only this latch is unchecked
// Sendable; all of its mutable state is locked.
private final class ReplaceGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false, held = false, released = false
    func arm() { condition.lock(); armed = true; condition.unlock() }
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return held }
    func hit(_ boundary: BackgroundWorkStorageBoundary) throws {
        guard boundary == .beforeReplace else { return }
        condition.lock(); defer { condition.unlock() }
        guard armed else { return }
        armed = false; held = true
        let deadline = Date().addingTimeInterval(20)
        while !released {
            guard condition.wait(until: deadline) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
private struct RegressionDocument: Codable {
    let version: Int
    let projectID: UUID
    let conversationID: UUID
    let snapshot: BackgroundWorkSnapshot
}

@main struct BackgroundWorkCapacityRegressionTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        func wait(_ seconds: Double = 10, _ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                guard Date() < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }
        let parent = try canonicalFixtureTemporaryDirectory().appendingPathComponent("BackgroundCapacity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        func directory() throws -> URL {
            let root = parent.appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return root
        }
        func document(_ root: URL) throws -> RegressionDocument {
            try JSONDecoder().decode(RegressionDocument.self, from: Data(contentsOf: root.appendingPathComponent("background-work.json")))
        }
        let revision = String(repeating: "a", count: 40)

        // D3 (review probe P6): a worker's completion save meets a saturated host queue.
        do {
            let project = UUID(), room = UUID(), root = try directory(), gate = ReplaceGate()
            defer { gate.release() }
            let storage = try await BackgroundWorkStorageSession.open(directory: root, projectID: project, conversationID: room) { try gate.hit($0) }
            var held: CheckedContinuation<Void, Never>?
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in
                await withCheckedContinuation { held = $0 }
                return .completed(checkpoint: "verified checkpoint", summary: "real synthetic result")
            })
            let limits = BackgroundWorkLimits(totalSteps: 2, stepsPerSlice: 2)
            func scope() -> BackgroundWorkScope {
                BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: UUID(), agentID: "codex", sourceRevision: revision)
            }
            let job = scope()
            let id = try await runner.enqueue(scope: job, title: "Worker under host saturation", limits: limits)
            _ = try await runner.start(id, permit: BackgroundWorkPermit(scope: job, limits: limits))
            _ = await wait { held != nil }
            // One host admission holds the mutex inside a physical save; the
            // bounded host queue then fills completely behind it.
            gate.arm()
            var hostErrors: [Error] = []
            var host: [Task<Void, Never>] = [Task { @MainActor in
                do { _ = try await runner.enqueue(scope: scope(), title: "Holder", limits: limits) } catch { hostErrors.append(error) }
            }]
            _ = await wait { gate.entered }
            for index in 0..<BackgroundWorkRunner.maximumQueuedMutations {
                host.append(Task { @MainActor in
                    do { _ = try await runner.enqueue(scope: scope(), title: "Burst \(index)", limits: limits) } catch { hostErrors.append(error) }
                })
            }
            _ = await wait { runner.queuedMutationCount >= BackgroundWorkRunner.maximumQueuedMutations }
            // The executor finishes while every host slot is taken.
            held?.resume()
            _ = await wait { runner.storageFailed || runner.queuedMutationCount > BackgroundWorkRunner.maximumQueuedMutations }
            check(!runner.storageFailed, "a full host queue never latches the runner as storage-failed (D3)")
            gate.release()
            for task in host { await task.value }
            _ = await wait { runner.activeWorkerCount == 0 }
            let item = runner.item(id)
            check(item?.state == .completed && item?.pendingStepID == nil && item?.resultID != nil,
                  "the finished step is saved as completed instead of being left for reconciliation (D3)")
            check(runner.pendingResults.contains { $0.id == id }, "the saved result is published to the host outbox (D3)")
            let saved = try document(root).snapshot.items.first { $0.id == id }
            check(saved?.state == .completed && saved?.resultID == item?.resultID, "the completion is physically on disk with its result identity (D3)")
            check(!hostErrors.contains { ($0 as? BackgroundWorkError) == .storage }, "no host caller is told storage failed because of queue pressure (D3)")
            var usable = false
            do { _ = try await runner.enqueue(scope: scope(), title: "After the burst", limits: limits); usable = true } catch {}
            check(usable && !runner.storageFailed, "the runner stays usable after the burst drains (D3)")
            try? await runner.shutdown()
        }

        // D4 (review probe P7): large checkpoints, each result acknowledged. At
        // 16fac7f nothing ever left the ledger, so roughly the 74th completion save
        // exceeded the 2 MiB document and latched the runner as storage-failed.
        do {
            let project = UUID(), room = UUID(), root = try directory()
            // JSONEncoder escapes "/" as "\/", so this checkpoint encodes to ~24 KB.
            let checkpoint = String(repeating: "/", count: 8_000) + String(repeating: "x", count: 8_000)
            let summary = String(repeating: "s", count: 4_000)
            let limits = BackgroundWorkLimits(totalSteps: 1, stepsPerSlice: 1)
            func scope() -> BackgroundWorkScope {
                BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: UUID(), agentID: "codex", sourceRevision: revision)
            }
            func run(_ runner: BackgroundWorkRunner) async -> (Bool, String) {
                let job = scope()
                do {
                    let id = try await runner.enqueue(scope: job, title: "Large synthetic result", limits: limits)
                    guard try await runner.start(id, permit: BackgroundWorkPermit(scope: job, limits: limits)) else { return (false, "start refused") }
                    _ = await wait { runner.activeWorkerCount == 0 }
                    guard let item = runner.item(id), item.state == .completed, let result = item.resultID else {
                        return (false, "state \(String(describing: runner.item(id)?.state)), storageFailed \(runner.storageFailed)")
                    }
                    guard try await runner.acknowledgeResult(id, resultID: result) else { return (false, "acknowledgement refused") }
                    return (true, "")
                } catch { return (false, "\(error)") }
            }
            var storage: BackgroundWorkStorageSession? = try await BackgroundWorkStorageSession.open(directory: root, projectID: project, conversationID: room)
            var runner: BackgroundWorkRunner? = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in
                .completed(checkpoint: checkpoint, summary: summary)
            })
            let jobs = 100
            var completed = 0, firstFailure = ""
            for _ in 0..<jobs {
                let (ok, why) = await run(runner!)
                if ok { completed += 1 } else { firstFailure = why; break }
            }
            check(completed == jobs, "\(jobs) large results complete and acknowledge without the ledger filling (D4); stopped at \(completed): \(firstFailure)")
            check(!runner!.storageFailed, "a growing history never latches the runner as storage-failed (D4)")
            let size = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("background-work.json").path)[.size] as? Int) ?? Int.max
            check(size <= 2_097_152, "the ledger document stays within its 2 MiB bound (\(size) bytes) (D4)")
            try? await runner?.shutdown(); runner = nil; storage = nil
            // The old session releases its writer lock once it is deallocated.
            let deadline = Date().addingTimeInterval(5)
            while storage == nil {
                do { storage = try await BackgroundWorkStorageSession.open(directory: root, projectID: project, conversationID: room) }
                catch BackgroundWorkStoreError.alreadyOpen where Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            }
            runner = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in
                .completed(checkpoint: checkpoint, summary: summary)
            })
            let (reopened, why) = await run(runner!)
            check(reopened && !runner!.storageFailed, "after reopening, another large job still completes (D4) \(why)")
            try? await runner?.shutdown()
        }

        print("BackgroundWorkCapacityRegressionTests: \(passed) passed, \(failed) failed; synthetic executors and isolated checkpoint files only")
        if failed > 0 { exit(1) }
    }
}
