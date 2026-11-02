import Foundation
import Darwin

// Regressions for the background-work follow-ups after 9cea7e0: unresolved stop
// evidence lost to archive retention, host calls starved by worker-first
// queueing, archive/ledger crash ordering, and abandoned temporary files after
// forced exits. Crash cases re-run this executable as a child process that
// blocks at a real storage boundary until the parent kills it with SIGKILL.
// Uses only APIs present at 9cea7e0 so the same file runs against that revision.
// Synthetic executors and private temporary files only.

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
private struct DurabilityLedger: Codable {
    let version: Int
    let projectID: UUID
    let conversationID: UUID
    let snapshot: BackgroundWorkSnapshot
}
private struct DurabilityArchive: Codable {
    let version: Int
    let projectID: UUID
    let conversationID: UUID
    let entries: [BackgroundWorkArchiveEntry]
}
/// The exact temporary names the store creates: background-work-<lowercase UUID>.tmp.
private func isStoreTemporaryName(_ name: String) -> Bool {
    guard name.hasPrefix("background-work-"), name.hasSuffix(".tmp") else { return false }
    let middle = String(name.dropFirst("background-work-".count).dropLast(".tmp".count))
    return middle.utf8.count == 36 && UUID(uuidString: middle)?.uuidString.lowercased() == middle
}
private func inode(_ url: URL) -> (dev_t, ino_t)? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return (info.st_dev, info.st_ino)
}

// MARK: Child process: blocks at one storage boundary until it is killed.

/// Parses "<boundary>:<occurrence>[:afterArchive]". Counting `afterArchive` starts
/// only once the archive temporary file has been prepared in this process.
private final class KillPoint: @unchecked Sendable {
    private let lock = NSLock()
    private let boundary: BackgroundWorkStorageBoundary
    private let occurrence: Int
    private let afterArchive: Bool
    private var count = 0, archiveSeen = false
    init?(_ spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        let names: [String: BackgroundWorkStorageBoundary] = ["beforeFileSync": .beforeFileSync, "beforeReplace": .beforeReplace,
                                                              "afterReplace": .afterReplace, "archiveBeforeReplace": .archiveBeforeReplace]
        guard parts.count >= 2, let boundary = names[parts[0]], let occurrence = Int(parts[1]), occurrence > 0 else { return nil }
        self.boundary = boundary; self.occurrence = occurrence; afterArchive = parts.count > 2 && parts[2] == "afterArchive"
    }
    func hit(_ value: BackgroundWorkStorageBoundary) {
        lock.lock()
        if value == .archiveBeforeReplace && boundary != .archiveBeforeReplace { archiveSeen = true; lock.unlock(); return }
        guard value == boundary, !afterArchive || archiveSeen else { lock.unlock(); return }
        count += 1
        guard count == occurrence else { lock.unlock(); return }
        lock.unlock()
        let line = "READY \(value)\n"
        _ = line.withCString { Darwin.write(STDOUT_FILENO, $0, strlen($0)) }
        // Hold this physical write open until the parent sends SIGKILL.
        while true { sleep(60) }
    }
}
@MainActor private func childMain(_ env: [String: String]) async -> Never {
    func fail(_ message: String) -> Never { print("CHILD ERROR: " + message); exit(5) }
    guard let mode = env["SILKWIRE_BG_CHILD_MODE"], let path = env["SILKWIRE_BG_CHILD_DIR"],
          let project = env["SILKWIRE_BG_CHILD_PROJECT"].flatMap(UUID.init(uuidString:)),
          let room = env["SILKWIRE_BG_CHILD_ROOM"].flatMap(UUID.init(uuidString:)),
          let kill = env["SILKWIRE_BG_CHILD_KILL"].flatMap(KillPoint.init) else { fail("bad child environment") }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let marker = env["SILKWIRE_BG_CHILD_MARKER"]
    let scope = { BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: UUID(), agentID: "codex", sourceRevision: String(repeating: "a", count: 40)) }
    let oneStep = BackgroundWorkLimits(totalSteps: 1, stepsPerSlice: 1)
    do {
        var opened: BackgroundWorkStorageSession?
        let deadline = Date().addingTimeInterval(10)
        while opened == nil {
            do { opened = try await BackgroundWorkStorageSession.open(directory: root, projectID: project, conversationID: room) { kill.hit($0) } }
            catch BackgroundWorkStoreError.alreadyOpen where Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }
        let runner = try await BackgroundWorkRunner.open(storage: opened!, authorize: { _ in true }, execute: { context in
            // Durable evidence that the executor was really entered, and for which step.
            if let marker {
                let fd = Darwin.open(marker, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
                let line = "EXEC \(context.stepID.uuidString)\n"
                _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
                fsync(fd); Darwin.close(fd)
            }
            return .completed(checkpoint: "child checkpoint", summary: "child result")
        })
        switch mode {
        case "archive":
            _ = try await runner.archiveSettledItems()
        case "cycle":
            let first = try await runner.enqueue(scope: scope(), title: "Cycle cancelled", limits: oneStep)
            _ = try await runner.cancel(first)
            _ = try await runner.enqueue(scope: scope(), title: "Cycle queued", limits: oneStep)
            _ = try await runner.archiveSettledItems()
            try await runner.shutdown()
        case "step":
            let job = scope()
            let id = try await runner.enqueue(scope: job, title: "Child step", limits: oneStep)
            _ = try await runner.start(id, permit: BackgroundWorkPermit(scope: job, limits: oneStep))
            try await Task.sleep(for: .seconds(10))
        default: fail("unknown mode " + mode)
        }
    } catch { fail("\(error)") }
    print("CHILD DONE: the kill point was never reached")
    exit(4)
}

// MARK: Parent side.

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
/// Holds workers in authorization (outside the runner's mutex) until opened.
/// Only this latch is unchecked Sendable; its state is locked.
private final class StartLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.lock(); open = true; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
}
private struct ChildResult {
    let killed: Bool
    let output: String
}
/// Runs one child to its kill point, then terminates it with SIGKILL.
@MainActor private func crashChild(mode: String, root: URL, project: UUID, room: UUID, kill: String, marker: URL? = nil) async throws -> ChildResult {
    let child = Process()
    child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    var environment = ProcessInfo.processInfo.environment
    environment["SILKWIRE_BG_CHILD_MODE"] = mode
    environment["SILKWIRE_BG_CHILD_DIR"] = root.path
    environment["SILKWIRE_BG_CHILD_PROJECT"] = project.uuidString
    environment["SILKWIRE_BG_CHILD_ROOM"] = room.uuidString
    environment["SILKWIRE_BG_CHILD_KILL"] = kill
    environment["SILKWIRE_BG_CHILD_MARKER"] = marker?.path
    child.environment = environment
    let pipe = Pipe(), buffer = OutputBuffer()
    child.standardOutput = pipe; child.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
    try child.run()
    let deadline = Date().addingTimeInterval(30)
    while child.isRunning && !buffer.text.contains("READY") && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let ready = buffer.text.contains("READY")
    if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
    while child.isRunning { try await Task.sleep(for: .milliseconds(5)) }
    pipe.fileHandleForReading.readabilityHandler = nil
    let killed = ready && child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL
    return ChildResult(killed: killed, output: buffer.text.trimmingCharacters(in: .whitespacesAndNewlines))
}

@main struct BackgroundWorkDurabilityRegressionTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if ProcessInfo.processInfo.environment["SILKWIRE_BG_CHILD_MODE"] != nil { await childMain(ProcessInfo.processInfo.environment) }
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
        let parent = try canonicalFixtureTemporaryDirectory().appendingPathComponent("BackgroundDurability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        func directory() throws -> URL {
            let root = parent.appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return root
        }
        func ledger(_ root: URL) throws -> DurabilityLedger {
            try JSONDecoder().decode(DurabilityLedger.self, from: Data(contentsOf: root.appendingPathComponent("background-work.json")))
        }
        func archive(_ root: URL) throws -> DurabilityArchive? {
            let url = root.appendingPathComponent("background-work.archive.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(DurabilityArchive.self, from: Data(contentsOf: url))
        }
        func leftovers(_ root: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { name in
                var info = stat()
                return isStoreTemporaryName(name) && lstat(root.appendingPathComponent(name).path, &info) == 0 &&
                    (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 && (info.st_mode & 0o077) == 0
            }
        }
        func open(_ root: URL, _ project: UUID, _ room: UUID,
                  fault: @escaping @Sendable (BackgroundWorkStorageBoundary) throws -> Void = { _ in }) async throws -> BackgroundWorkStorageSession {
            // An old session keeps its writer lock until it is deallocated.
            let deadline = Date().addingTimeInterval(10)
            while true {
                do { return try await BackgroundWorkStorageSession.open(directory: root, projectID: project, conversationID: room, fault: fault) }
                catch BackgroundWorkStoreError.alreadyOpen where Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            }
        }
        let revision = String(repeating: "a", count: 40)
        let oneStep = BackgroundWorkLimits(totalSteps: 1, stepsPerSlice: 1)

        // 1. Unresolved stop evidence must survive archive retention. A job stopped
        //    while its step was uncertain is followed by more than 256 settled jobs.
        do {
            let project = UUID(), room = UUID(), root = try directory()
            func scope() -> BackgroundWorkScope { BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: UUID(), agentID: "codex", sourceRevision: revision) }
            var storage: BackgroundWorkStorageSession? = try await open(root, project, room)
            var held: CheckedContinuation<BackgroundWorkStep, Never>?, step: UUID?, calls = 0
            let execute: BackgroundWorkRunner.Execute = { context in
                calls += 1; step = context.stepID
                return await withCheckedContinuation { held = $0 }
            }
            var runner: BackgroundWorkRunner? = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: execute)
            let job = scope()
            let stopped = try await runner!.enqueue(scope: job, title: "Stopped mid-step", limits: oneStep)
            _ = try await runner!.start(stopped, permit: BackgroundWorkPermit(scope: job, limits: oneStep))
            _ = await wait { held != nil }
            _ = try await runner!.cancel(stopped)
            held?.resume(returning: .completed(checkpoint: "late", summary: "late"))
            _ = await wait { runner!.activeWorkerCount == 0 }
            check(runner!.item(stopped)?.state == .cancelled && runner!.item(stopped)?.pendingStepID == step,
                  "a job stopped mid-step keeps its uncertain step identity")
            _ = try await runner!.archiveSettledItems()
            for index in 0..<300 {
                let id = try await runner!.enqueue(scope: scope(), title: "Settled history \(index)", limits: oneStep)
                _ = try await runner!.cancel(id)
            }
            _ = try await runner!.archiveSettledItems()
            check(runner!.item(stopped)?.pendingStepID == step, "the uncertain step is still visible after 300 later jobs and archive retention")
            let onDisk = try ledger(root).snapshot.items.contains { $0.id == stopped && $0.pendingStepID == step } ||
                (try archive(root)?.entries.contains { $0.item.id == stopped && $0.item.pendingStepID == step } ?? false)
            check(onDisk, "the uncertain step is still physically on disk after archive retention")
            let archivedUnresolved = try archive(root)?.entries.contains { $0.item.pendingStepID != nil } ?? false
            check(!archivedUnresolved, "no entry with an uncertain step was moved into the trimmable archive")
            try await runner!.shutdown(); runner = nil; storage = nil
            storage = try await open(root, project, room)
            runner = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: execute)
            check(runner!.item(stopped)?.pendingStepID == step && calls == 1, "after reopening the evidence remains and nothing replayed")
            try await runner!.shutdown()
        }

        // 2. Worker-first queueing must not starve host calls. Eight workers step
        //    continuously with slow saves; a host admission and a durable Stop wait.
        do {
            let project = UUID(), room = UUID(), root = try directory()
            func scope() -> BackgroundWorkScope { BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: UUID(), agentID: "codex", sourceRevision: revision) }
            let storage = try await open(root, project, room) { if $0 == .beforeFileSync { usleep(1_000) } }
            var steps = 0
            // Admit all eight before any steps; at 9cea7e0 later admissions would
            // otherwise starve behind the first workers.
            let latch = StartLatch()
            let runner = try await BackgroundWorkRunner.open(storage: storage, maxConcurrent: 8, authorize: { _ in
                while !latch.isOpen { try? await Task.sleep(for: .milliseconds(1)) }
                return true
            }, execute: { _ in
                steps += 1; return .checkpoint("fair step")
            })
            let long = BackgroundWorkLimits(totalSteps: 10_000, stepsPerSlice: 10_000)
            var jobs: [UUID] = []
            for _ in 0..<8 {
                let job = scope()
                let id = try await runner.enqueue(scope: job, title: "Continuous worker", limits: long)
                if try await runner.start(id, permit: BackgroundWorkPermit(scope: job, limits: long)) { jobs.append(id) }
            }
            latch.release()
            let flowing = await wait { steps >= 40 }
            check(jobs.count == 8 && flowing, "eight workers are stepping continuously")
            var admitted = false, admitError: Error?, admitSteps = -1
            var issued = steps
            let admission = Task { @MainActor in
                do { _ = try await runner.enqueue(scope: scope(), title: "Host admission", limits: oneStep) } catch { admitError = error }
                admitted = true; admitSteps = steps - issued
            }
            _ = await wait(20) { admitted || steps - issued >= 80 }
            check(admitted && admitError == nil, "a host admission completes while workers keep stepping (after \(admitSteps) worker steps)")
            check(admitted && admitSteps <= 12, "the host admission waits a bounded number of worker steps (\(admitSteps), bound 12)")
            var stopped = false, stopError: Error?, stopSteps = -1
            issued = steps
            let stop = Task { @MainActor in
                do { stopped = try await runner.cancel(jobs[0]) } catch { stopError = error }
                stopSteps = steps - issued
            }
            _ = await wait(20) { stopSteps >= 0 || steps - issued >= 80 }
            check(stopped && stopError == nil && stopSteps <= 12, "a durable Stop waits a bounded number of worker steps (\(stopSteps), bound 12)")
            let before = steps
            let continued = await wait { steps >= before + 20 }
            check(continued && !runner.storageFailed, "the remaining workers keep their transition capacity throughout")
            for id in jobs { runner.requestCancel(id) }
            await admission.value; await stop.value
            _ = await wait { runner.activeWorkerCount == 0 }
            try? await runner.shutdown()
        }

        // 3. Archive/ledger crash ordering with a real child-process kill between
        //    the writes, then reopen: evidence kept, nothing duplicated or replayed.
        struct Seeded { let acknowledged, cancelled, stopped, uncertain, undelivered: UUID; let stoppedStep, uncertainStep: UUID }
        func seed(_ root: URL, _ project: UUID, _ room: UUID) async throws -> Seeded {
            var storage: BackgroundWorkStorageSession? = try await open(root, project, room)
            var held: CheckedContinuation<BackgroundWorkStep, Never>?, steps: [String: UUID] = [:]
            var runner: BackgroundWorkRunner? = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { context in
                steps[context.item.title] = context.stepID
                switch context.item.title {
                case "Stopped mid-step": return await withCheckedContinuation { held = $0 }
                case "Uncertain": throw CocoaError(.fileWriteUnknown)
                default: return .completed(checkpoint: "seed checkpoint", summary: "seed result")
                }
            })
            func run(_ title: String) async throws -> UUID {
                let job = BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: UUID(), agentID: "codex", sourceRevision: revision)
                let id = try await runner!.enqueue(scope: job, title: title, limits: oneStep)
                _ = try await runner!.start(id, permit: BackgroundWorkPermit(scope: job, limits: oneStep))
                return id
            }
            let acknowledged = try await run("Acknowledged")
            _ = await wait { runner!.activeWorkerCount == 0 }
            _ = try await runner!.acknowledgeResult(acknowledged, resultID: runner!.item(acknowledged)!.resultID!)
            let cancelled = try await runner!.enqueue(scope: BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: UUID(), agentID: "codex", sourceRevision: revision), title: "Cancelled", limits: oneStep)
            _ = try await runner!.cancel(cancelled)
            let stopped = try await run("Stopped mid-step")
            _ = await wait { held != nil }
            _ = try await runner!.cancel(stopped)
            held?.resume(returning: .completed(checkpoint: "late", summary: "late"))
            _ = await wait { runner!.activeWorkerCount == 0 }
            let uncertain = try await run("Uncertain")
            _ = await wait { runner!.activeWorkerCount == 0 }
            let undelivered = try await run("Undelivered")
            _ = await wait { runner!.activeWorkerCount == 0 }
            try await runner!.shutdown(); runner = nil; storage = nil
            return Seeded(acknowledged: acknowledged, cancelled: cancelled, stopped: stopped, uncertain: uncertain, undelivered: undelivered,
                          stoppedStep: steps["Stopped mid-step"]!, uncertainStep: steps["Uncertain"]!)
        }
        for (kill, label, archived, ledgerMoved) in [("archiveBeforeReplace:1", "before the archive replacement", false, false),
                                                       ("beforeFileSync:1:afterArchive", "after the archive, while the ledger temporary is written", true, false),
                                                       ("beforeReplace:1:afterArchive", "after the archive, before the ledger replacement", true, false),
                                                       ("afterReplace:1:afterArchive", "after both replacements, before the directory sync", true, true)] {
            let project = UUID(), room = UUID(), root = try directory()
            let s = try await seed(root, project, room)
            let lockBefore = inode(root.appendingPathComponent("background-work.lock"))
            let child = try await crashChild(mode: "archive", root: root, project: project, room: room, kill: kill)
            check(child.killed, "archive child was killed by SIGKILL \(label) [\(child.output)]")
            let ledgerIDs = Set(try ledger(root).snapshot.items.map(\.id)), archiveIDs = Set(try archive(root)?.entries.map(\.item.id) ?? [])
            let settled: Set<UUID> = [s.acknowledged, s.cancelled]
            check(archiveIDs == (archived ? settled : []), "on disk the archive holds exactly the settled, resolved items \(label)")
            check(ledgerIDs == (ledgerMoved ? [s.stopped, s.uncertain, s.undelivered] : settled.union([s.stopped, s.uncertain, s.undelivered])),
                  "on disk the ledger still holds every item it has not durably handed over \(label)")
            check(!archiveIDs.contains(s.stopped), "a stopped job's uncertain step never enters the archive \(label)")
            let lockAfter = inode(root.appendingPathComponent("background-work.lock"))
            check(lockBefore != nil && lockAfter?.0 == lockBefore?.0 && lockAfter?.1 == lockBefore?.1, "the permanent lock inode survives the kill \(label)")
            // Reopen after the crash.
            var calls = 0
            let storage = try await open(root, project, room)
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not run") })
            check(leftovers(root).isEmpty, "reopening leaves no abandoned temporary file \(label)")
            let stopped = runner.item(s.stopped), uncertain = runner.item(s.uncertain)
            check(stopped?.state == .cancelled && stopped?.pendingStepID == s.stoppedStep, "the stopped job's uncertain step survives the crash \(label)")
            check(uncertain?.pause == .reconciliation && uncertain?.pendingStepID == s.uncertainStep, "the uncertain paused step survives the crash \(label)")
            check(runner.pendingResults.map(\.id) == [s.undelivered], "the undelivered result is listed exactly once \(label)")
            let visible = Set(runner.snapshot.items.map(\.id)), history = Set(runner.archivedItems.map(\.id))
            check(visible.isDisjoint(with: history) && settled.allSatisfy { runner.item($0) != nil }, "settled items are visible once, never twice \(label)")
            var refused = false
            do { _ = try await runner.start(s.uncertain, permit: BackgroundWorkPermit(scope: uncertain!.scope, limits: oneStep)) }
            catch BackgroundWorkError.reconciliationRequired { refused = true }
            let restarted = try await runner.start(s.stopped, permit: BackgroundWorkPermit(scope: stopped!.scope, limits: oneStep))
            check(refused && !restarted && calls == 0, "nothing replays after the crash \(label)")
            _ = try await runner.archiveSettledItems()
            let entries = try archive(root)?.entries.map(\.item.id) ?? []
            check(Set(entries) == settled && entries.count == settled.count, "the next archive pass completes the move without duplicates \(label)")
            check(Set(try ledger(root).snapshot.items.map(\.id)) == [s.stopped, s.uncertain, s.undelivered], "only unresolved and undelivered work stays in the ledger \(label)")
            try await runner.shutdown()
        }

        // 4. A worker's step under real process death: save-before-execute holds and
        //    a step that may have run is never replayed after reopening.
        for (kill, label, executed) in [("beforeReplace:3", "during the pending-step save", false),
                                        ("afterReplace:3", "after the pending-step rename, before executor entry", false),
                                        ("beforeReplace:4", "during the finished-step save", true)] {
            let project = UUID(), room = UUID(), root = try directory(), marker = parent.appendingPathComponent(UUID().uuidString + ".marker")
            let child = try await crashChild(mode: "step", root: root, project: project, room: room, kill: kill, marker: marker)
            check(child.killed, "step child was killed by SIGKILL \(label) [\(child.output)]")
            let ran = ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { UUID(uuidString: String($0.dropFirst(5))) }
            check(ran.count == (executed ? 1 : 0), "the executor ran \(executed ? "exactly once" : "never") \(label)")
            var calls = 0
            let storage = try await open(root, project, room)
            let runner = try await BackgroundWorkRunner.open(storage: storage, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not run") })
            guard let item = runner.snapshot.items.first else { check(false, "the job is on disk \(label)"); continue }
            if executed {
                check(item.pause == .reconciliation && item.pendingStepID == ran.first, "the executed but unsaved step reopens for reconciliation with its exact identity \(label)")
            } else if kill.hasPrefix("afterReplace") {
                check(item.pause == .reconciliation && item.pendingStepID != nil, "a committed pending step reopens as uncertain even though the executor never ran \(label)")
            } else {
                check(item.pause == .restart && item.pendingStepID == nil && item.attempts == 0, "an uncommitted pending step reopens as a clean restart \(label)")
            }
            var refused = !executed && !kill.hasPrefix("afterReplace")
            if !refused {
                do { _ = try await runner.start(item.id, permit: BackgroundWorkPermit(scope: item.scope, limits: oneStep)) }
                catch BackgroundWorkError.reconciliationRequired { refused = true }
            }
            check(refused && calls == 0 && runner.pendingResults.isEmpty, "nothing replays or publishes after the kill \(label)")
            check(leftovers(root).isEmpty, "reopening leaves no abandoned temporary file \(label)")
            try await runner.shutdown()
        }

        // 5. Repeated forced exits. Each child is killed at a different storage
        //    boundary. Leftovers stay bounded, protected files and decoys survive.
        do {
            let project = UUID(), room = UUID(), root = try directory()
            let sentinel = parent.appendingPathComponent("sentinel-" + UUID().uuidString)
            try Data("sentinel".utf8).write(to: sentinel)
            func decoy(_ suffix: String = UUID().uuidString.lowercased()) -> URL { root.appendingPathComponent("background-work-" + suffix + ".tmp") }
            let symlink = decoy(), folder = decoy(), shared = decoy(), wide = decoy(), linked = decoy()
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sentinel)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("readable by others".utf8).write(to: wide)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wide.path)
            try Data("hard-linked".utf8).write(to: shared)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shared.path)
            try FileManager.default.linkItem(at: shared, to: linked)
            let unmatched = ["background-work-not-a-uuid.tmp", "background-work-" + UUID().uuidString + ".tmp", "background-work.json.tmp", "notes.tmp"].map { root.appendingPathComponent($0) }
            for url in unmatched {
                try Data("keep".utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            var storage: BackgroundWorkStorageSession? = try await open(root, project, room)
            var runner: BackgroundWorkRunner? = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in .checkpoint("must not run") })
            _ = try await runner!.enqueue(scope: BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: UUID(), agentID: "codex", sourceRevision: revision), title: "Seed", limits: oneStep)
            try await runner!.shutdown(); runner = nil; storage = nil
            let lock = inode(root.appendingPathComponent("background-work.lock"))
            // Ledger writes per cycle: 1 open, 2 enqueue, 3 cancel, 4 enqueue, then the
            // archive write, 5 the archive pass's ledger write, 6 shutdown.
            let kills = ["beforeFileSync:2", "beforeReplace:3", "archiveBeforeReplace:1", "beforeFileSync:1:afterArchive", "afterReplace:4"]
            var allKilled = true, worst = 0, protectedIntact = true, largest = 0
            for cycle in 0..<15 {
                let child = try await crashChild(mode: "cycle", root: root, project: project, room: room, kill: kills[cycle % kills.count])
                if !child.killed { allKilled = false; print("cycle \(cycle) output: \(child.output)") }
                worst = max(worst, leftovers(root).count)
                let now = inode(root.appendingPathComponent("background-work.lock"))
                let ledgerOK = (try? ledger(root)) != nil
                let backupOK = (try? JSONDecoder().decode(DurabilityLedger.self, from: Data(contentsOf: root.appendingPathComponent("background-work.previous.json")))) != nil
                let archiveOK: Bool = { do { _ = try archive(root); return true } catch { return false } }()
                if !(now?.0 == lock?.0 && now?.1 == lock?.1 && ledgerOK && backupOK && archiveOK) { protectedIntact = false }
                let bytes = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).reduce(0) { total, name in
                    var info = stat()
                    return lstat(root.appendingPathComponent(name).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG ? total + Int(info.st_size) : total
                }
                largest = max(largest, bytes)
            }
            check(allKilled, "15 children were each killed by SIGKILL at their storage boundary")
            check(worst <= 2, "abandoned temporary files stay bounded across repeated forced exits (worst \(worst), bound 2)")
            check(protectedIntact, "primary, recovery copy, archive and the permanent lock inode survive every forced exit")
            check(largest <= 4 * 2_097_152, "directory storage stays bounded (largest \(largest) bytes)")
            var calls = 0
            storage = try await open(root, project, room)
            runner = try await BackgroundWorkRunner.open(storage: storage!, authorize: { _ in true }, execute: { _ in calls += 1; return .checkpoint("must not run") })
            check(leftovers(root).isEmpty, "a clean open after the forced exits leaves no abandoned temporary file")
            check(runner!.snapshot.items.allSatisfy { $0.state != .running && $0.state != .queued } && calls == 0 && !runner!.storageFailed,
                  "recovery after the forced exits dispatches nothing and the runner is healthy")
            var link = stat()
            let symlinkKept = lstat(symlink.path, &link) == 0 && (link.st_mode & S_IFMT) == S_IFLNK &&
                (try? FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)) == sentinel.path &&
                (try? String(contentsOf: sentinel, encoding: .utf8)) == "sentinel"
            var sharedInfo = stat()
            let sharedKept = lstat(linked.path, &sharedInfo) == 0 && sharedInfo.st_nlink == 2 && FileManager.default.fileExists(atPath: shared.path)
            var isFolder: ObjCBool = false
            let folderKept = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
            check(symlinkKept && sharedKept && folderKept && FileManager.default.fileExists(atPath: wide.path),
                  "matching names that are links, directories, shared or non-private files are never deleted")
            check(unmatched.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "files outside the exact temporary-name pattern are never deleted")
            try await runner!.shutdown()
        }

        print("BackgroundWorkDurabilityRegressionTests: \(passed) passed, \(failed) failed; synthetic executors, real child-process kills and isolated files only")
        if failed > 0 { exit(1) }
    }
}
