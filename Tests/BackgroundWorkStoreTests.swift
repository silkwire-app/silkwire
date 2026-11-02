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

// Real local file I/O in isolated synthetic fixtures; no live library or providers.
private struct StoreTestDocument: Codable {
    var version = 1
    var projectID: UUID
    var conversationID: UUID
    var snapshot: BackgroundWorkSnapshot
}
@MainActor private final class StoreFixture {
    let root: URL
    let project = UUID(), room = UUID(), workspace = UUID()
    let limits = BackgroundWorkLimits(totalSteps: 5, stepsPerSlice: 5)
    init(_ parent: URL) throws {
        root = parent.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var scope: BackgroundWorkScope { BackgroundWorkScope(projectID: project, conversationID: room, workspaceID: workspace, agentID: "codex", sourceRevision: String(repeating: "a", count: 40)) }
    var permit: BackgroundWorkPermit { BackgroundWorkPermit(scope: scope, limits: limits) }
    var primary: URL { root.appendingPathComponent(BackgroundWorkStore.ledgerName) }
    var backup: URL { root.appendingPathComponent(BackgroundWorkStore.backupName) }
    var lock: URL { root.appendingPathComponent(BackgroundWorkStore.lockName) }
    func store(fault: @escaping (BackgroundWorkStore.Boundary) throws -> Void = { _ in }) throws -> BackgroundWorkStore {
        try BackgroundWorkStore(directory: root, projectID: project, conversationID: room, fault: fault)
    }
    func engine(_ store: BackgroundWorkStore, execute: @escaping BackgroundWorkEngine.Execute = { _ in .completed(checkpoint: "synthetic", summary: "Synthetic result") }) throws -> BackgroundWorkEngine {
        try store.makeEngine(authorize: { [scope] in $0 == scope }, execute: execute)
    }
    func document(_ file: URL? = nil) throws -> StoreTestDocument {
        try JSONDecoder().decode(StoreTestDocument.self, from: Data(contentsOf: file ?? primary))
    }
    func write(_ bytes: Data, to file: URL? = nil) throws {
        let file = file ?? primary
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func emptyDocument() -> StoreTestDocument {
        StoreTestDocument(projectID: project, conversationID: room, snapshot: BackgroundWorkSnapshot(version: 1, items: []))
    }
    func item() -> BackgroundWorkItem {
        BackgroundWorkItem(id: UUID(), scope: scope, sessionID: UUID(), title: "Synthetic saved work", limits: limits)
    }
}
@MainActor private final class StoreStepGate {
    var context: BackgroundWorkContext?
    var continuation: CheckedContinuation<BackgroundWorkStep, Never>?
    func run(_ context: BackgroundWorkContext) async -> BackgroundWorkStep {
        self.context = context
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        let old = continuation; continuation = nil
        old?.resume(returning: .completed(checkpoint: "late synthetic completion", summary: "Synthetic result"))
    }
}

@main struct BackgroundWorkStoreTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1; print("PASS: " + label) }
            else { failed += 1; print("FAIL: " + label) }
        }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body(); check(false, label) } catch { check(true, label) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Synthetic background store checkpoint timed out") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let parent = try canonicalFixtureTemporaryDirectory().appendingPathComponent("BackgroundStore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }

        // Disk save-before-execute, real kernel writer exclusion, restart and outbox ack.
        do {
            let f = try StoreFixture(parent)
            var store: BackgroundWorkStore? = try f.store()
            var calls = 0
            var engine: BackgroundWorkEngine? = try f.engine(store!) { context in
                calls += 1
                let disk = try f.document().snapshot.items.first
                check(disk?.pendingStepID == context.stepID && disk?.attempts == 1, "the actual store saves the pending step before executor entry")
                return .completed(checkpoint: "saved output", summary: "Synthetic completion")
            }
            check(calls == 0 && !FileManager.default.fileExists(atPath: f.primary.path), "constructing a fresh store and engine executes no work")
            rejects("a second file descriptor cannot acquire the same writer lock") { _ = try f.store() }
            rejects("one store cannot attach a second engine") { _ = try f.engine(store!) }
            let id = try engine!.enqueue(scope: f.scope, title: "Synthetic persisted work", limits: f.limits)
            check(try engine!.start(id, permit: f.permit), "fresh host admission starts the stored task")
            try await wait { engine!.item(id)?.state == .completed && engine!.activeWorkerCount == 0 }
            let result = engine!.item(id)!.resultID!
            check(try f.document().snapshot.items.first?.resultID == result, "completion and result identity are saved on disk")
            check(try f.document(f.backup).snapshot.items.first?.pendingStepID != nil, "the previous durable step remains available as recovery evidence")
            let mode = try FileManager.default.attributesOfItem(atPath: f.primary.path)[.posixPermissions] as? NSNumber
            check(mode?.intValue == 0o600, "checkpoint files have owner-only permissions")
            store = nil
            rejects("an engine retains the writer lock after its caller releases the store") { _ = try f.store() }
            try engine!.shutdown(); engine = nil
            store = try f.store()
            var restoredCalls = 0
            engine = try f.engine(store!) { _ in restoredCalls += 1; return .completed(checkpoint: "unexpected", summary: "Unexpected") }
            check(engine!.pendingResults.first?.resultID == result && restoredCalls == 0, "reopen retains the undelivered result without replay")
            check(try engine!.acknowledgeResult(id, resultID: result), "the exact delivered result can be durably acknowledged")
            try engine!.shutdown(); engine = nil; store = nil
            store = try f.store(); engine = try f.engine(store!)
            check(engine!.pendingResults.isEmpty && engine!.item(id)?.resultAcknowledged == true, "result acknowledgement survives another disk reopen")
            try engine!.shutdown(); engine = nil; store = nil
            rejects("a ledger cannot be opened as a different Project") {
                let wrong = try BackgroundWorkStore(directory: f.root, projectID: UUID(), conversationID: f.room)
                _ = try f.engine(wrong)
            }
        }

        // An interrupted step remains uncertain; cancellation stays terminal after reopen.
        do {
            let f = try StoreFixture(parent), gate = StoreStepGate()
            defer { gate.release() }
            var store: BackgroundWorkStore? = try f.store()
            var engine: BackgroundWorkEngine? = try f.engine(store!) { await gate.run($0) }
            let id = try engine!.enqueue(scope: f.scope, title: "Synthetic uncertain step", limits: f.limits)
            _ = try engine!.start(id, permit: f.permit)
            try await wait { gate.continuation != nil }
            let step = gate.context!.stepID
            try engine!.shutdown()
            check(gate.context?.mayPerformOperation() == false, "shutdown fences the executor before storage ownership can move")
            rejects("a winding-down physical worker still retains its store lock") { _ = try f.store() }
            gate.release()
            try await wait { engine!.activeWorkerCount == 0 }
            engine = nil; store = nil
            store = try f.store(); engine = try f.engine(store!)
            check(engine!.item(id)?.pendingStepID == step && engine!.item(id)?.pause == .reconciliation, "disk recovery retains the exact uncertain step")
            rejects("an uncertain restored step cannot be automatically retried") { _ = try engine!.start(id, permit: f.permit) }
            check(try engine!.cancel(id), "host Stop can durably cancel recovered work")
            try engine!.shutdown(); engine = nil; store = nil
            store = try f.store(); engine = try f.engine(store!)
            check(try engine!.item(id)?.state == .cancelled && engine!.start(id, permit: f.permit) == false, "cancelled work is terminal after another disk reopen")
            try engine!.shutdown(); engine = nil; store = nil
        }

        // Inject faults before file sync, before replacement, and AFTER replacement.
        // Post-rename failure is intentionally uncertain, never claimed rolled back.
        for boundary in [BackgroundWorkStore.Boundary.beforeFileSync, .beforeReplace, .afterReplace] {
            let f = try StoreFixture(parent), gate = StoreStepGate()
            defer { gate.release() }
            var armed = false
            var store: BackgroundWorkStore? = try f.store { observed in
                if armed && observed == boundary { armed = false; throw CocoaError(.fileWriteOutOfSpace) }
            }
            var engine: BackgroundWorkEngine? = try f.engine(store!) { await gate.run($0) }
            let id = try engine!.enqueue(scope: f.scope, title: "Synthetic storage fault", limits: f.limits)
            _ = try engine!.start(id, permit: f.permit)
            try await wait { gate.continuation != nil }
            let old = try Data(contentsOf: f.primary)
            armed = true; gate.release()
            try await wait { engine!.storageFailed && engine!.activeWorkerCount == 0 }
            check(engine!.pendingResults.isEmpty && gate.context?.mayPerformOperation() == false, "fault \(boundary) fences execution and does not publish unsaved success")
            let current = try Data(contentsOf: f.primary)
            check(boundary == .afterReplace ? current != old : current == old, "fault \(boundary) preserves the expected old-or-new atomic boundary")
            engine = nil; store = nil
            store = try f.store()
            var calls = 0
            engine = try f.engine(store!) { _ in calls += 1; return .completed(checkpoint: "unexpected", summary: "Unexpected") }
            check(calls == 0 && (boundary == .afterReplace ? engine!.item(id)?.state == .completed : engine!.item(id)?.pause == .reconciliation), "fault \(boundary) reopens without dispatching or guessing a rollback")
            try engine!.shutdown(); engine = nil; store = nil
        }

        // Invalid files are preserved, not replaced with an empty ledger.
        for kind in 0..<8 {
            let f = try StoreFixture(parent)
            var document = f.emptyDocument(), item = f.item()
            switch kind {
            case 1: document.version = 99
            case 2: document.snapshot = BackgroundWorkSnapshot(version: 99, items: [])
            case 3: document.projectID = UUID()
            case 4: document.conversationID = UUID()
            case 5: item.attempts = -1; document.snapshot = BackgroundWorkSnapshot(version: 1, items: [item])
            case 6: document.snapshot = BackgroundWorkSnapshot(version: 1, items: [item, item])
            case 7:
                let wrong = BackgroundWorkScope(projectID: f.project, conversationID: UUID(), workspaceID: f.workspace, agentID: "codex", sourceRevision: String(repeating: "a", count: 40))
                item = BackgroundWorkItem(id: UUID(), scope: wrong, sessionID: UUID(), title: "Wrong room", limits: f.limits)
                document.snapshot = BackgroundWorkSnapshot(version: 1, items: [item])
            default: break
            }
            let bytes = kind == 0 ? Data("{broken JSON".utf8) : try JSONEncoder().encode(document)
            try f.write(bytes)
            let store = try f.store()
            rejects("invalid saved fixture \(kind) is refused") { _ = try f.engine(store) }
            check(try Data(contentsOf: f.primary) == bytes, "invalid saved fixture \(kind) is not overwritten")
        }
        do {
            let f = try StoreFixture(parent)
            let backup = try JSONEncoder().encode(f.emptyDocument())
            try f.write(backup, to: f.backup)
            let store = try f.store()
            rejects("a missing primary with a recovery copy is not treated as a new ledger") { _ = try f.engine(store) }
            check(try !FileManager.default.fileExists(atPath: f.primary.path) && Data(contentsOf: f.backup) == backup, "missing-primary recovery preserves evidence without automatic rollback")
        }
        do {
            let f = try StoreFixture(parent), bytes = try JSONEncoder().encode(f.emptyDocument())
            try f.write(bytes); try f.write(Data("broken backup".utf8), to: f.backup)
            let store = try f.store()
            rejects("an invalid recovery envelope requires host review") { _ = try f.engine(store) }
            check(try Data(contentsOf: f.primary) == bytes, "invalid backup handling preserves the valid primary")
        }

        // No-follow path traversal, special-file refusal and alias protections.
        for kind in 0..<7 {
            let f = try StoreFixture(parent)
            let canary = parent.appendingPathComponent("canary-" + UUID().uuidString)
            let bytes = Data("synthetic canary, never a live file".utf8)
            try f.write(bytes, to: canary)
            switch kind {
            case 0: try FileManager.default.createSymbolicLink(at: f.primary, withDestinationURL: canary)
            case 1: guard link(canary.path, f.primary.path) == 0 else { throw nativeFailure("Synthetic hard-link setup failed") }
            case 2: try FileManager.default.createDirectory(at: f.primary, withIntermediateDirectories: false)
            case 3: guard mkfifo(f.primary.path, mode_t(0o600)) == 0 else { throw nativeFailure("Synthetic FIFO setup failed") }
            case 4: try f.write(Data(count: BackgroundWorkStore.maximumBytes + 1))
            case 5:
                try f.write(try JSONEncoder().encode(f.emptyDocument()))
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.primary.path)
            default: try FileManager.default.createSymbolicLink(at: f.lock, withDestinationURL: canary)
            }
            rejects("unsafe file fixture \(kind) is refused without following or blocking") {
                let store = try f.store(); _ = try f.engine(store)
            }
            check(try Data(contentsOf: canary) == bytes, "unsafe file fixture \(kind) leaves its synthetic canary unchanged")
        }
        do {
            let f = try StoreFixture(parent), alias = parent.appendingPathComponent("root-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
            rejects("a symlinked storage directory is rejected") { _ = try BackgroundWorkStore(directory: alias, projectID: f.project, conversationID: f.room) }
            let ancestor = parent.appendingPathComponent("ancestor-alias")
            try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: parent)
            rejects("a symlinked ancestor is rejected") { _ = try BackgroundWorkStore(directory: ancestor.appendingPathComponent(f.root.lastPathComponent), projectID: f.project, conversationID: f.room) }
        }
        do {
            let f = try StoreFixture(parent)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
            rejects("a shared-readable storage directory is rejected") { _ = try f.store() }
        }
        do {
            let f = try StoreFixture(parent), store = try f.store(), engine = try f.engine(store)
            _ = try engine.enqueue(scope: f.scope, title: "Original checkpoint", limits: f.limits)
            let before = try Data(contentsOf: f.primary), changed = Data("external synthetic modification".utf8)
            try f.write(changed)
            rejects("an external checkpoint modification fences subsequent writes") { _ = try engine.enqueue(scope: f.scope, title: "Must not overwrite", limits: f.limits) }
            check(try engine.storageFailed && Data(contentsOf: f.primary) == changed && changed != before, "external modification is preserved and execution is blocked")
        }
        do {
            let f = try StoreFixture(parent), store = try f.store(), engine = try f.engine(store)
            _ = try engine.enqueue(scope: f.scope, title: "Original checkpoint", limits: f.limits)
            let before = try Data(contentsOf: f.primary), moved = parent.appendingPathComponent("moved-" + UUID().uuidString)
            try FileManager.default.moveItem(at: f.root, to: moved)
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            rejects("replacing the named storage directory fences the old store") { _ = try engine.enqueue(scope: f.scope, title: "Must not write elsewhere", limits: f.limits) }
            check(try engine.storageFailed && Data(contentsOf: moved.appendingPathComponent(BackgroundWorkStore.ledgerName)) == before && !FileManager.default.fileExists(atPath: f.primary.path), "directory replacement cannot redirect checkpoint writes")
        }
        do {
            let f = try StoreFixture(parent), store = try f.store(), engine = try f.engine(store)
            _ = try engine.enqueue(scope: f.scope, title: "Original checkpoint", limits: f.limits)
            let before = try Data(contentsOf: f.primary)
            try FileManager.default.removeItem(at: f.lock); try f.write(Data(), to: f.lock)
            rejects("replacing the writer-lock inode fences the old store") { _ = try engine.enqueue(scope: f.scope, title: "Must not bypass lock", limits: f.limits) }
            check(try engine.storageFailed && Data(contentsOf: f.primary) == before, "lock replacement cannot overwrite the saved checkpoint")
        }
        do {
            let f = try StoreFixture(parent), store = try f.store(), engine = try f.engine(store)
            let wrong = BackgroundWorkScope(projectID: f.project, conversationID: UUID(), workspaceID: f.workspace, agentID: "codex", sourceRevision: String(repeating: "a", count: 40))
            rejects("a task cannot be committed into another conversation's ledger") { _ = try engine.enqueue(scope: wrong, title: "Wrong room", limits: f.limits) }
            check(engine.storageFailed && !FileManager.default.fileExists(atPath: f.primary.path), "scope mismatch cannot create a phantom checkpoint")
        }
        // Crash-leftover maintenance under the writer lock. Only exact, private,
        // single-link temporary files are removed; protected files and look-alikes stay.
        func temporary(_ f: StoreFixture, _ suffix: String = UUID().uuidString.lowercased()) -> URL {
            f.root.appendingPathComponent("background-work-" + suffix + ".tmp")
        }
        func inode(_ url: URL) -> ino_t? { var info = stat(); return lstat(url.path, &info) == 0 ? info.st_ino : nil }
        do {
            let f = try StoreFixture(parent)
            var store: BackgroundWorkStore? = try f.store()
            var engine: BackgroundWorkEngine? = try f.engine(store!)
            _ = try engine!.enqueue(scope: f.scope, title: "First", limits: f.limits)
            _ = try engine!.enqueue(scope: f.scope, title: "Second", limits: f.limits)
            engine = nil; store = nil
            let primary = try Data(contentsOf: f.primary), lockInode = inode(f.lock)
            // Leftovers an interrupted write leaves: a torn ledger and a complete copy.
            let torn = temporary(f), whole = temporary(f)
            try f.write(primary.prefix(primary.count / 2), to: torn)
            try f.write(primary, to: whole)
            // Look-alikes: a symlink, a directory, a non-private file, a hard link, and
            // names outside the exact pattern.
            let sentinel = parent.appendingPathComponent("store-sentinel-" + UUID().uuidString)
            try Data("sentinel".utf8).write(to: sentinel)
            let symlink = temporary(f), folder = temporary(f), wide = temporary(f), shared = temporary(f), linked = temporary(f)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sentinel)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("wide".utf8).write(to: wide)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wide.path)
            try f.write(Data("shared".utf8), to: shared)
            try FileManager.default.linkItem(at: shared, to: linked)
            let upper = temporary(f, UUID().uuidString), loose = f.root.appendingPathComponent("background-work.json.tmp")
            try f.write(Data("keep".utf8), to: upper); try f.write(Data("keep".utf8), to: loose)
            store = try f.store()
            check(store!.maintenance == BackgroundWorkStorageMaintenance(), "maintenance does not run before the store claims its ledger")
            engine = try f.engine(store!)
            check(store!.maintenance == BackgroundWorkStorageMaintenance(removedTemporaries: 2, retainedEntries: 5),
                  "the legacy facade removes exactly the two abandoned temporaries and counts five look-alikes")
            check(!FileManager.default.fileExists(atPath: torn.path) && !FileManager.default.fileExists(atPath: whole.path), "abandoned temporary writes are removed")
            // Restoring saves restart pauses, so the old primary becomes the recovery copy.
            check(try Data(contentsOf: f.backup) == primary && f.document().snapshot.items.count == 2 && inode(f.lock) == lockInode,
                  "the primary survives as the recovery copy, the ledger is intact and the permanent lock inode is unchanged")
            var link = stat()
            let target = try String(contentsOf: sentinel, encoding: .utf8)
            check(lstat(symlink.path, &link) == 0 && (link.st_mode & S_IFMT) == S_IFLNK && target == "sentinel",
                  "a symlink with a temporary name and its target are untouched")
            check([folder, wide, shared, linked, upper, loose].allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                  "directories, non-private, hard-linked and non-matching files are untouched")
            check(engine!.snapshot.items.count == 2, "the ledger loads normally after maintenance")
            engine = nil; store = nil
            // The awaited session reports the same maintenance; nothing is left to remove.
            let again = temporary(f)
            try f.write(Data("{".utf8), to: again)
            let session = try await BackgroundWorkStorageSession.open(directory: f.root, projectID: f.project, conversationID: f.room)
            check(session.maintenance == BackgroundWorkStorageMaintenance(removedTemporaries: 1, retainedEntries: 5) && !FileManager.default.fileExists(atPath: again.path),
                  "the awaited storage session runs the same maintenance under its writer lock")
        }
        do {
            // A directory too large to scan within the bound is refused, not half-cleaned.
            let f = try StoreFixture(parent)
            var store: BackgroundWorkStore? = try f.store()
            var engine: BackgroundWorkEngine? = try f.engine(store!)
            _ = try engine!.enqueue(scope: f.scope, title: "Kept", limits: f.limits)
            engine = nil; store = nil
            let primary = try Data(contentsOf: f.primary), leftover = temporary(f)
            try f.write(Data("torn".utf8), to: leftover)
            for index in 0..<1_100 { try f.write(Data(), to: f.root.appendingPathComponent("junk-\(index)")) }
            store = try f.store()
            var refused = false
            do { _ = try f.engine(store!) } catch BackgroundWorkStoreError.maintenanceRequired { refused = true }
            let unchanged = try Data(contentsOf: f.primary) == primary
            check(refused && FileManager.default.fileExists(atPath: leftover.path) && unchanged,
                  "an over-large directory is refused with maintenanceRequired and nothing is removed or rewritten")
            store = nil
            for index in 0..<1_100 { try FileManager.default.removeItem(at: f.root.appendingPathComponent("junk-\(index)")) }
            store = try f.store()
            engine = try f.engine(store!)
            check(store!.maintenance.removedTemporaries == 1 && engine!.snapshot.items.count == 1, "once the directory is within bound, maintenance proceeds")
        }

        print("Background checkpoint store: \(passed) passed, \(failed) failed; isolated synthetic files only")
        if failed > 0 { exit(1) }
    }
}
