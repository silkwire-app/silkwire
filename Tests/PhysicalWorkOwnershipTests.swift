import Foundation
import Darwin

private typealias Ownership = PhysicalWorkOwnership
private let files = FileManager.default

private func directory(_ parent: URL, _ name: String = UUID().uuidString) throws -> URL {
    let url = parent.appendingPathComponent(name)
    try files.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}
private func retryBusy<T>(_ body: () throws -> T) throws -> T {
    let deadline = Date().addingTimeInterval(10)
    while true {
        do { return try body() }
        catch Ownership.Failure.registryBusy {
            guard Date() < deadline else { throw Ownership.Failure.registryBusy }
            usleep(2000)
        }
    }
}
private func waitForFile(_ path: URL) throws {
    let deadline = Date().addingTimeInterval(15)
    while !files.fileExists(atPath: path.path) {
        guard Date() < deadline else { throw Ownership.Failure.unavailable }
        usleep(2000)
    }
}
private actor PhysicalGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func run() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func exit() { continuation?.resume(); continuation = nil }
}
private final class AdmissionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@main struct PhysicalWorkOwnershipTests {
    static func child(_ args: [String]) throws {
        // Self-exec, not fork: independent descriptors and address space.
        let root = URL(fileURLWithPath: args[0]), workspace = URL(fileURLWithPath: args[2])
        let ready = URL(fileURLWithPath: args[3]), release = URL(fileURLWithPath: args[4])
        let start = URL(fileURLWithPath: args[5]), operationID = UUID(uuidString: args[6])!
        try waitForFile(start)
        let result: String
        do {
            let registry = try retryBusy { try Ownership(directory: root, capacity: Int(args[1])!) }
            let lease = try retryBusy { try registry.reserve(workspace: workspace,
                owner: .init(conversationID: UUID(), kind: .backgroundJob), operationID: operationID) }
            if args[7] != "reserved" { try retryBusy { try registry.beginExecution(lease) } }
            if args[7] == "stopped" { try retryBusy { try registry.requestStop(lease) } }
            var survivingWorker: Process?
            if args[7] == "surviving-worker" {
                let worker = Process()
                worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                worker.arguments = ["--physical-fixture", ready.appendingPathExtension("physical-ready").path,
                    release.path, ready.appendingPathExtension("physical-exited").path]
                try worker.run(); survivingWorker = worker
                try Data(String(worker.processIdentifier).utf8).write(to: ready.appendingPathExtension("pid"))
                try waitForFile(ready.appendingPathExtension("physical-ready"))
            }
            try Data("admitted".utf8).write(to: ready, options: .atomic)
            try waitForFile(release)
            survivingWorker?.waitUntilExit()
            if args[7] == "reserved" { try retryBusy { try registry.abandonBeforeExecution(lease) } }
            else { try retryBusy { try registry.finishAfterPhysicalExit(lease, evidence: "Synthetic child operation joined; no descendants or remote work") } }
            return
        } catch { result = String(describing: error) }
        try Data(result.utf8).write(to: ready, options: .atomic)
    }
    static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.dropFirst().first == "--physical-fixture" {
            let args = Array(CommandLine.arguments.dropFirst(2))
            try Data().write(to: URL(fileURLWithPath: args[0]))
            try waitForFile(URL(fileURLWithPath: args[1]))
            try Data().write(to: URL(fileURLWithPath: args[2]))
            return
        }
        if CommandLine.arguments.dropFirst().first == "--ownership-child" {
            try child(Array(CommandLine.arguments.dropFirst(2))); return
        }
        let parent = try directory(files.temporaryDirectory, "physical-ownership-" + UUID().uuidString)
        defer { try? files.removeItem(at: parent) }
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { print("FAIL: " + message); throw Ownership.Failure.unavailable }
            checks += 1; print("PASS: " + message)
        }
        func denied(_ expected: Ownership.Failure, _ label: String, _ body: () throws -> Void) throws {
            do { try body() } catch let error as Ownership.Failure {
                try check(error == expected, label + " [\(error)]"); return
            }
            try check(false, label + " unexpectedly admitted")
        }
        let roomA = Ownership.Owner(conversationID: UUID(), kind: .backgroundJob)
        let roomB = Ownership.Owner(conversationID: UUID(), kind: .foregroundBuild)
        let root = try directory(parent), workspace = try directory(parent), other = try directory(parent)
        let registry = try Ownership(directory: root, capacity: 2)
        let competitor = try Ownership(directory: root, capacity: 2)
        let operation = UUID()
        let lease = try registry.reserve(workspace: workspace, owner: roomA, operationID: operation)
        try denied(.workspaceBusy, "different conversations exclude the same workspace") {
            _ = try competitor.reserve(workspace: workspace, owner: roomB, operationID: UUID())
        }
        let link = parent.appendingPathComponent("workspace-alias")
        try files.createSymbolicLink(at: link, withDestinationURL: workspace)
        for alias in [link, workspace.appendingPathComponent("."), workspace.appendingPathComponent("../" + workspace.lastPathComponent)] {
            try denied(.workspaceBusy, "canonical alias excludes competing foreground build: " + alias.lastPathComponent) {
                _ = try competitor.reserve(workspace: alias, owner: roomB, operationID: UUID())
            }
        }
        let caseAlias = URL(fileURLWithPath: workspace.path.uppercased())
        if files.fileExists(atPath: caseAlias.path) {
            try denied(.workspaceBusy, "case-insensitive volume alias uses directory identity") {
                _ = try competitor.reserve(workspace: caseAlias, owner: roomB, operationID: UUID())
            }
        }
        let second = try competitor.reserve(workspace: other, owner: roomB, operationID: UUID())
        let thirdWorkspace = try directory(parent)
        try denied(.limitReached, "foreground and background share one physical-worker limit") {
            _ = try registry.reserve(workspace: thirdWorkspace, owner: roomA, operationID: UUID())
        }
        try denied(.configurationMismatch, "another conversation cannot raise the shared limit") { _ = try Ownership(directory: root, capacity: 3) }
        try registry.beginExecution(lease)
        try denied(.invalidTransition, "executing work cannot use the pre-dispatch release") { try registry.abandonBeforeExecution(lease) }
        try registry.requestStop(lease)
        try check(try competitor.snapshot().filter(\.holdsResources).count == 2, "Stop acknowledgement retains both reservations")
        try denied(.workspaceBusy, "Stop acknowledgement does not authorize overlapping work") {
            _ = try competitor.reserve(workspace: workspace, owner: roomB, operationID: UUID())
        }
        try competitor.abandonBeforeExecution(second)
        try check(try competitor.snapshot().filter(\.holdsResources).count == 1, "never-dispatched work releases its slot")
        try registry.markUncertain(lease, evidence: "Synthetic physical join timed out")
        try denied(.invalidTransition, "uncertain operation requires explicit host reconciliation") {
            try registry.finishAfterPhysicalExit(lease, evidence: "Invalid ordinary completion")
        }
        let old = try registry.snapshot().first { $0.operationID == operation }!
        try registry.reconcileAfterPhysicalExit(old, evidence: "Host verified synthetic physical exit and reconciled outcome")
        try denied(.invalidTransition, "stale recovery snapshot cannot release twice") {
            try registry.reconcileAfterPhysicalExit(old, evidence: "stale")
        }
        try denied(.operationAlreadyKnown, "completed operation UUID cannot replay") {
            _ = try competitor.reserve(workspace: workspace, owner: roomB, operationID: operation)
        }
        let after = try competitor.reserve(workspace: workspace, owner: roomB, operationID: UUID())
        try competitor.abandonBeforeExecution(after)

        // Cancellation acknowledgement precedes an independently delayed physical
        // join. The detached worker deliberately ignores logical cancellation.
        let delayedRoot = try directory(parent), delayedWorkspace = try directory(parent)
        let delayed = try Ownership(directory: delayedRoot, capacity: 1)
        let delayedLease = try delayed.reserve(workspace: delayedWorkspace, owner: roomA, operationID: UUID())
        try delayed.beginExecution(delayedLease)
        let gate = PhysicalGate()
        let physical = Task.detached {
            await gate.run()
            try delayed.finishAfterPhysicalExit(delayedLease, evidence: "Synthetic physical continuation completed after cancellation")
        }
        while !(await gate.entered) { await Task.yield() }
        physical.cancel()
        try delayed.requestStop(delayedLease)
        try check(try delayed.snapshot().first!.holdsResources, "logical cancellation retains delayed physical execution")
        try denied(.limitReached, "delayed physical completion consumes global capacity after Stop") {
            _ = try delayed.reserve(workspace: thirdWorkspace, owner: roomB, operationID: UUID())
        }
        try denied(.workspaceBusy, "delayed physical completion keeps workspace excluded") {
            _ = try delayed.reserve(workspace: delayedWorkspace, owner: roomB, operationID: UUID())
        }
        await gate.exit(); try await physical.value
        try check(try delayed.snapshot().filter(\.holdsResources).isEmpty, "physical exit releases even when the worker Task is cancelled")
        let cancelled = Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try delayed.reserve(workspace: delayedWorkspace, owner: roomA, operationID: UUID()); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        try check(await cancelled.value, "cancellation before admission dispatches no worker")
        try check(try delayed.snapshot().filter(\.holdsResources).isEmpty, "cancelled admission leaks no slot")
        let prestart = try delayed.reserve(workspace: delayedWorkspace, owner: roomA, operationID: UUID())
        let beforeStop = try delayed.snapshot().first { $0.operationID == prestart.operationID }!
        try delayed.requestStop(prestart)
        try denied(.invalidTransition, "recovery snapshot predating a concurrent Stop cannot release") {
            try delayed.reconcileAfterPhysicalExit(beforeStop, evidence: "stale pre-Stop observation")
        }
        try denied(.invalidTransition, "Stop before dispatch prevents beginExecution") { try delayed.beginExecution(prestart) }
        try delayed.abandonBeforeExecution(prestart)

        let threadedRoot = try directory(parent)
        let threaded = try Ownership(directory: threadedRoot, capacity: 3)
        let threadedWorkspaces = try (0..<12).map { _ in try directory(parent) }
        let admissions = AdmissionResults()
        DispatchQueue.concurrentPerform(iterations: threadedWorkspaces.count) { index in
            do {
                _ = try retryBusy { try threaded.reserve(workspace: threadedWorkspaces[index],
                    owner: .init(conversationID: UUID(), kind: index % 2 == 0 ? .foregroundBuild : .backgroundJob), operationID: UUID()) }
                admissions.append("admitted")
            } catch { admissions.append(String(describing: error)) }
        }
        let threadAnswers = admissions.snapshot()
        try check(threadAnswers.filter { $0 == "admitted" }.count == 3 && threadAnswers.filter { $0 == "limitReached" }.count == 9,
            "twelve simultaneous same-process conversations share exactly three slots")
        for record in try threaded.snapshot() where record.holdsResources {
            try threaded.reconcileAfterPhysicalExit(record, evidence: "Fixture never dispatched any physical worker")
        }

        // Independent processes race on a shared start barrier and hold admitted
        // slots until the parent opens a second barrier. No timing-based release.
        var children: [Process] = []
        defer {
            for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
        }
        func launch(_ shared: URL, _ capacity: Int, _ ws: URL, _ start: URL, _ release: URL,
                    mode: String = "executing", operation: UUID = UUID()) throws -> (Process, URL) {
            let ready = parent.appendingPathComponent(UUID().uuidString + ".ready")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--ownership-child", shared.path, String(capacity), ws.path, ready.path, release.path, start.path, operation.uuidString, mode]
            try process.run(); children.append(process)
            return (process, ready)
        }
        let raceRoot = try directory(parent), raceWorkspace = try directory(parent)
        _ = try Ownership(directory: raceRoot, capacity: 8)
        let start = parent.appendingPathComponent("race-start"), release = parent.appendingPathComponent("race-release")
        var racers: [(Process, URL)] = []
        let raceAlias = parent.appendingPathComponent("child-workspace-alias")
        let registryAlias = parent.appendingPathComponent("registry-alias")
        try files.createSymbolicLink(at: raceAlias, withDestinationURL: raceWorkspace)
        try files.createSymbolicLink(at: registryAlias, withDestinationURL: raceRoot)
        for index in 0..<8 {
            racers.append(try launch(index % 2 == 0 ? raceRoot : registryAlias, 8,
                index % 2 == 0 ? raceWorkspace : raceAlias, start, release))
        }
        try Data().write(to: start)
        for (_, ready) in racers { try waitForFile(ready) }
        let answers = try racers.map { try String(contentsOf: $0.1, encoding: .utf8) }
        try check(answers.filter { $0 == "admitted" }.count == 1 && answers.filter { $0 == "workspaceBusy" }.count == 7,
            "eight separate child processes: exactly one canonical-workspace owner")
        try Data().write(to: release)
        for (process, _) in racers { process.waitUntilExit(); try check(process.terminationStatus == 0, "workspace-race child exited cleanly") }

        let capRoot = try directory(parent)
        let capRegistry = try Ownership(directory: capRoot, capacity: 2)
        let capStart = parent.appendingPathComponent("cap-start"), capRelease = parent.appendingPathComponent("cap-release")
        var capped: [(Process, URL)] = []
        for _ in 0..<7 { capped.append(try launch(capRoot, 2, directory(parent), capStart, capRelease)) }
        try Data().write(to: capStart)
        for (_, ready) in capped { try waitForFile(ready) }
        let capAnswers = try capped.map { try String(contentsOf: $0.1, encoding: .utf8) }
        try check(capAnswers.filter { $0 == "admitted" }.count == 2 && capAnswers.filter { $0 == "limitReached" }.count == 5,
            "seven separate processes and conversations share exactly two physical slots")
        try check(try capRegistry.snapshot().filter(\.holdsResources).count == 2, "disk ledger agrees with physical admission count")
        try Data().write(to: capRelease)
        for (process, _) in capped { process.waitUntilExit(); try check(process.terminationStatus == 0, "capacity-race child exited cleanly") }

        for mode in ["reserved", "executing", "stopped"] {
            let crashRoot = try directory(parent), crashWS = try directory(parent)
            _ = try Ownership(directory: crashRoot, capacity: 1)
            let go = parent.appendingPathComponent(UUID().uuidString), never = parent.appendingPathComponent(UUID().uuidString)
            let crashedID = UUID()
            let (process, ready) = try launch(crashRoot, 1, crashWS, go, never, mode: mode, operation: crashedID)
            try Data().write(to: go); try waitForFile(ready)
            try check(try String(contentsOf: ready, encoding: .utf8) == "admitted", "crash fixture admitted in \(mode) phase")
            kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            try check(process.terminationReason == .uncaughtSignal, "owner actually died by signal in \(mode) phase")
            let reopened = try Ownership(directory: crashRoot, capacity: 1)
            try denied(.workspaceBusy, "vanished \(mode) owner does not release workspace") {
                _ = try reopened.reserve(workspace: crashWS, owner: roomB, operationID: UUID())
            }
            try denied(.limitReached, "vanished \(mode) owner continues consuming capacity") {
                _ = try reopened.reserve(workspace: thirdWorkspace, owner: roomB, operationID: UUID())
            }
            try denied(.operationAlreadyKnown, "vanished \(mode) owner cannot authorize replay") {
                _ = try reopened.reserve(workspace: crashWS, owner: roomB, operationID: crashedID)
            }
            let expected = try reopened.snapshot().first!
            try reopened.reconcileAfterPhysicalExit(expected, evidence: "Fixture verified SIGKILL and absence of descendants/remote work")
            try check(try reopened.snapshot().filter(\.holdsResources).isEmpty, "explicit physical verification recovers \(mode) slot")
            try denied(.operationAlreadyKnown, "reconciliation retains \(mode) operation replay fence") {
                _ = try reopened.reserve(workspace: crashWS, owner: roomB, operationID: crashedID)
            }
        }

        let orphanRoot = try directory(parent), orphanWS = try directory(parent)
        let orphanRegistry = try Ownership(directory: orphanRoot, capacity: 1)
        let orphanStart = parent.appendingPathComponent("orphan-start"), orphanExit = parent.appendingPathComponent("orphan-exit")
        let (ownerProcess, orphanReady) = try launch(orphanRoot, 1, orphanWS, orphanStart, orphanExit, mode: "surviving-worker")
        try Data().write(to: orphanStart); try waitForFile(orphanReady)
        try check(try String(contentsOf: orphanReady, encoding: .utf8) == "admitted", "owner spawned a separate physical fixture")
        let physicalPID = Int32(try String(contentsOf: orphanReady.appendingPathExtension("pid"), encoding: .utf8))!
        var physicalExited = false
        defer { if !physicalExited { kill(physicalPID, SIGKILL) } }
        kill(ownerProcess.processIdentifier, SIGKILL); ownerProcess.waitUntilExit()
        try check(kill(physicalPID, 0) == 0, "physical process remains alive after its owner crashes")
        try denied(.workspaceBusy, "owner death cannot authorize work over surviving physical process") {
            _ = try orphanRegistry.reserve(workspace: orphanWS, owner: roomB, operationID: UUID())
        }
        try denied(.limitReached, "surviving physical process retains the global slot") {
            _ = try orphanRegistry.reserve(workspace: thirdWorkspace, owner: roomB, operationID: UUID())
        }
        try Data().write(to: orphanExit)
        try waitForFile(orphanReady.appendingPathExtension("physical-exited"))
        let exitDeadline = Date().addingTimeInterval(10)
        while kill(physicalPID, 0) == 0 {
            guard Date() < exitDeadline else { throw Ownership.Failure.unavailable }
            usleep(2000)
        }
        try check(errno == ESRCH, "independent physical fixture actually exited after owner death")
        physicalExited = true
        try check(try orphanRegistry.snapshot().first!.holdsResources, "even physical exit requires explicit reviewed crash recovery")
        try orphanRegistry.reconcileAfterPhysicalExit(orphanRegistry.snapshot().first!, evidence: "Synthetic fixture completed and independent PID was confirmed absent; no descendants or remote work")
        try check(try orphanRegistry.snapshot().filter(\.holdsResources).isEmpty, "reviewed recovery releases the surviving-worker reservation")

        // Fail closed rather than interpreting storage damage as empty ownership.
        let damagedRoot = try directory(parent)
        let damaged = try Ownership(directory: damagedRoot, capacity: 1)
        _ = try damaged.reserve(workspace: workspace, owner: roomA, operationID: UUID())
        let state = damagedRoot.appendingPathComponent("ownership.json")
        let saved = try Data(contentsOf: state)
        try Data("corrupt".utf8).write(to: state)
        try denied(.unavailable, "corrupt registry never admits work") { _ = try damaged.snapshot() }
        try saved.write(to: state)
        try files.removeItem(at: state)
        try denied(.unavailable, "missing state behind existing lock never resets ownership") { _ = try Ownership(directory: damagedRoot, capacity: 1) }
        let unsafeRoot = try directory(parent)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unsafeRoot.path)
        try denied(.unsafeRegistry, "shared-writable/readable registry is rejected") { _ = try Ownership(directory: unsafeRoot, capacity: 1) }
        try denied(.invalidInput, "missing workspace is not admitted by a lexical path") {
            _ = try registry.reserve(workspace: parent.appendingPathComponent("missing"), owner: roomA, operationID: UUID())
        }
        let partialRoot = try directory(parent)
        let partialLock = partialRoot.appendingPathComponent("ownership.lock")
        try Data().write(to: partialLock)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partialLock.path)
        try denied(.unavailable, "interrupted first bootstrap cannot initialize an empty replacement ledger") {
            _ = try Ownership(directory: partialRoot, capacity: 1)
        }
        let linkedRoot = try directory(parent)
        _ = try Ownership(directory: linkedRoot, capacity: 1)
        let linkedState = linkedRoot.appendingPathComponent("ownership.json")
        let outsideState = parent.appendingPathComponent("outside-fixture.json")
        try files.moveItem(at: linkedState, to: outsideState)
        try files.createSymbolicLink(at: linkedState, withDestinationURL: outsideState)
        try denied(.unavailable, "symlink ledger cannot redirect ownership outside its registry") {
            _ = try Ownership(directory: linkedRoot, capacity: 1)
        }
        print("PASS: PhysicalWorkOwnershipTests, \(checks) checks; synthetic work only")
    }
}
