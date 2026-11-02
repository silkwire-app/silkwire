import Foundation
import Darwin

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

// Synthetic directories only. No live library, provider, UI driving or accounts.
private struct PersistenceDocument: Codable {
    let version: Int
    let projectID: UUID
    let conversationID: UUID
    let snapshot: BackgroundWorkSnapshot
}
private struct PersistenceFixture {
    let root: URL
    let project: UUID
    let room: UUID
    let item: BackgroundWorkItem
    init(_ parent: URL) throws {
        let project = UUID(), room = UUID()
        self.project = project; self.room = room
        root = parent.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let scope = BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: UUID(), agentID: "codex", sourceRevision: String(repeating: "a", count: 40))
        item = BackgroundWorkItem(id: UUID(), scope: scope, sessionID: UUID(), title: "Synthetic persistence work", limits: BackgroundWorkLimits(totalSteps: 5, stepsPerSlice: 5))
    }
    var primary: URL { root.appendingPathComponent("background-work.json") }
    var backup: URL { root.appendingPathComponent("background-work.previous.json") }
    func snapshot(_ text: String) -> BackgroundWorkSnapshot {
        var value = item; value.checkpoint = text
        return BackgroundWorkSnapshot(version: 1, items: [value])
    }
    func document(_ file: URL? = nil) throws -> PersistenceDocument {
        try JSONDecoder().decode(PersistenceDocument.self, from: Data(contentsOf: file ?? primary))
    }
    func seed(_ snapshot: BackgroundWorkSnapshot) throws {
        let bytes = try JSONEncoder().encode(PersistenceDocument(version: 1, projectID: project, conversationID: room, snapshot: snapshot))
        try bytes.write(to: primary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primary.path)
    }
    func open(fault: @escaping @Sendable (BackgroundWorkStorageBoundary) throws -> Void = { _ in }) async throws -> BackgroundWorkStorageSession {
        try await BackgroundWorkStorageSession.open(directory: root, projectID: project, conversationID: room, fault: fault)
    }
}

// @unchecked Sendable is confined to this test latch. Every mutable field is
// protected by the condition; it deliberately holds the physical worker, not UI.
private final class PersistenceDiskGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let boundary: BackgroundWorkStorageBoundary
    private var consumed = false
    private var waiting = false
    private var mainThread = false
    private var released = false
    init(_ boundary: BackgroundWorkStorageBoundary = .beforeFileSync) { self.boundary = boundary }
    var entered: Bool {
        condition.lock(); defer { condition.unlock() }
        return waiting
    }
    var ranOnMainThread: Bool {
        condition.lock(); defer { condition.unlock() }
        return mainThread
    }
    func hit(_ value: BackgroundWorkStorageBoundary) throws {
        guard value == boundary else { return }
        condition.lock(); defer { condition.unlock() }
        guard !consumed else { return }
        consumed = true; waiting = true; mainThread = Thread.isMainThread
        let deadline = Date().addingTimeInterval(15)
        while !released {
            guard condition.wait(until: deadline) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

@main struct BackgroundPersistenceResponsivenessTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Synthetic persistence gate timed out") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let parent = try canonicalFixtureTemporaryDirectory().appendingPathComponent("BackgroundPersistence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }

        // Hold real physical I/O, continue on the main actor, cancel the caller,
        // and reject a competing stale snapshot rather than assume actor FIFO.
        do {
            let fixture = try PersistenceFixture(parent), gate = PersistenceDiskGate()
            defer { gate.release() }
            let session = try await fixture.open { try gate.hit($0) }
            let fresh = await session.state()
            check(fresh.snapshot == nil && fresh.generation == 0 && !fresh.storageFailed, "opening a new off-main session creates no phantom task or checkpoint")
            let first = fixture.snapshot("first confirmed checkpoint")
            let second = fixture.snapshot("second confirmed checkpoint")
            var firstFinished = false
            let writer = Task { @MainActor in
                let value = try await session.save(first, basedOn: 0)
                firstFinished = true
                return value
            }
            try await wait { gate.entered }
            check(!gate.ranOnMainThread, "the physical checkpoint write does not run on the main thread")
            var heartbeat = 0
            await Task { @MainActor in heartbeat += 1 }.value
            check(heartbeat == 1 && !firstFinished, "the main actor remains available while checkpoint I/O is deliberately held")
            var staleFinished = false
            let stale = Task { @MainActor () -> Bool in
                do { _ = try await session.save(second, basedOn: 0); staleFinished = true; return false }
                catch BackgroundWorkStoreError.changed { staleFinished = true; return true }
                catch { staleFinished = true; return false }
            }
            writer.cancel()
            var excluded = false
            do { _ = try await fixture.open() }
            catch BackgroundWorkStoreError.alreadyOpen { excluded = true }
            catch {}
            check(excluded && !firstFinished, "caller cancellation does not release the writer lock during physical I/O")
            check(!staleFinished, "another snapshot cannot finish while the first physical write owns the session")
            gate.release()
            let firstGeneration = try await writer.value
            let rejectedStale = await stale.value
            check(firstGeneration == 1 && firstFinished, "cancellation during a physical commit reports its actual successful durability outcome")
            check(rejectedStale, "a stale concurrent snapshot is rejected instead of silently replacing newer progress")
            let state = await session.state()
            check(state.generation == 1 && state.snapshot == first && !state.storageFailed, "only the confirmed snapshot advances the session generation")
            check(try fixture.document().snapshot == first, "the confirmed checkpoint is the actual primary file")
            let nextGeneration = try await session.save(second, basedOn: state.generation)
            let secondOnDisk = try fixture.document().snapshot
            check(nextGeneration == 2 && secondOnDisk == second, "an explicit retry using the current generation can persist the next checkpoint")
            check(try fixture.document(fixture.backup).snapshot == first, "the previous confirmed checkpoint remains in the recovery file")

            let cancelled = Task { @MainActor () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try await session.save(fixture.snapshot("must not be written"), basedOn: 2); return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            check(await cancelled.value, "cancellation before physical I/O rejects the queued save")
            let afterCancel = await session.state()
            check(afterCancel.generation == 2 && afterCancel.snapshot == second && !afterCancel.storageFailed, "pre-write cancellation neither advances nor poisons the ledger")
            do {
                _ = try await session.save(BackgroundWorkSnapshot(version: 2, items: first.items), basedOn: 2)
                check(false, "invalid snapshot input is rejected before writing")
            } catch BackgroundWorkError.invalidSnapshot { check(true, "invalid snapshot input is rejected before writing") }
            let afterInvalid = await session.state()
            let afterInvalidOnDisk = try fixture.document().snapshot
            check(afterInvalid.generation == 2 && !afterInvalid.storageFailed && afterInvalidOnDisk == second, "invalid caller input leaves confirmed storage available and unchanged")
        }

        // Opening an existing ledger also performs recovery I/O away from UI.
        do {
            let fixture = try PersistenceFixture(parent), gate = PersistenceDiskGate()
            defer { gate.release() }
            var running = fixture.item
            running.state = .running; running.attempts = 1; running.pendingStepID = UUID()
            running.checkpoint = "last durable boundary"
            let original = BackgroundWorkSnapshot(version: 1, items: [running])
            try fixture.seed(original)
            var opened = false
            let opening = Task { @MainActor in
                let session = try await fixture.open { try gate.hit($0) }
                opened = true; return session
            }
            try await wait { gate.entered }
            var heartbeat = false
            await Task { @MainActor in heartbeat = true }.value
            check(heartbeat && !opened && !gate.ranOnMainThread, "opening and saving restart recovery cannot block the main actor")
            gate.release()
            let session = try await opening.value
            let restored = await session.state()
            let recovered = restored.snapshot?.items.first
            check(recovered?.state == .paused && recovered?.pause == .reconciliation && recovered?.pendingStepID == running.pendingStepID, "restart preserves the exact uncertain step and pauses for reconciliation")
            check(recovered?.attempts == 1 && recovered?.checkpoint == running.checkpoint, "restart does not reset attempts or discard the confirmed checkpoint")
            check(try fixture.document().snapshot == restored.snapshot, "recovery pauses are physically saved before open returns")
            check(try fixture.document(fixture.backup).snapshot == original, "restart preserves the pre-recovery evidence in the backup")
        }

        // Durable result identities survive open, and clean queued tasks pause.
        do {
            let fixture = try PersistenceFixture(parent)
            var completed = fixture.item
            completed.state = .completed; completed.resultID = UUID(); completed.resultAcknowledged = true
            try fixture.seed(BackgroundWorkSnapshot(version: 1, items: [completed]))
            let session = try await fixture.open()
            let state = await session.state()
            check(state.snapshot?.items.first == completed, "reopening completed work preserves its result identity and acknowledgement")
        }
        do {
            let fixture = try PersistenceFixture(parent)
            try fixture.seed(fixture.snapshot("queued before restart"))
            let session = try await fixture.open()
            let state = await session.state()
            check(state.snapshot?.items.first?.pause == .restart && state.snapshot?.items.first?.pendingStepID == nil, "clean queued work reopens paused rather than automatically running")
        }

        // A failed physical save is sticky. After-rename failure is uncertain,
        // not a successful publish, even if new bytes are visible on the disk.
        for boundary in [BackgroundWorkStorageBoundary.beforeReplace, .afterReplace] {
            let fixture = try PersistenceFixture(parent)
            let session = try await fixture.open { point in
                if point == boundary { throw CocoaError(.fileWriteOutOfSpace) }
            }
            let desired = fixture.snapshot("unacknowledged physical outcome")
            do { _ = try await session.save(desired, basedOn: 0); check(false, "physical failure at \(boundary) reaches the caller") }
            catch { check(true, "physical failure at \(boundary) reaches the caller") }
            let state = await session.state()
            check(state.storageFailed && state.generation == 0 && state.snapshot == nil, "physical failure at \(boundary) cannot publish unconfirmed progress")
            do { _ = try await session.save(fixture.snapshot("forbidden retry"), basedOn: 0); check(false, "failed session at \(boundary) refuses subsequent writes") }
            catch BackgroundWorkStoreError.unavailable { check(true, "failed session at \(boundary) refuses subsequent writes") }
            var excluded = false
            do { _ = try await fixture.open() }
            catch BackgroundWorkStoreError.alreadyOpen { excluded = true }
            catch {}
            check(excluded, "failed session at \(boundary) retains its single-writer lock")
            if boundary == .afterReplace {
                check(try fixture.document().snapshot == desired, "after-replace fault records visible but unacknowledged bytes for host reconciliation")
            } else {
                check(!FileManager.default.fileExists(atPath: fixture.primary.path), "before-replace fault does not create a successful primary ledger")
            }
        }

        print("BackgroundPersistenceResponsivenessTests: \(passed) passed, \(failed) failed")
        if failed > 0 { throw nativeFailure("Background persistence responsiveness regressions failed") }
    }
}
