import Foundation
import Darwin

// Safe parallel work in the D2 ownership registry (docs/safe-parallel-ownership.md):
// independent private workspaces side by side, exclusive operations that wait for and
// block everything else, exit/finish tied to one admission, and capacity migration.
// Three layers: the registry itself, the host coordinator with Builder ownership, and
// real trusted workspaces (three teammates on one granted source). Synthetic work only:
// private registries under the fixture root, /usr/bin/true, no provider or network.
private typealias Ownership = PhysicalWorkOwnership
private let files = FileManager.default

@main struct SafeParallelOwnershipTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func failure(_ body: () throws -> Void) -> Ownership.Failure? {
            do { try body(); return nil } catch let error as Ownership.Failure { return error } catch { return .unavailable }
        }
        let fixture = try NativeTemporaryDirectory.canonical(files.temporaryDirectory).appendingPathComponent("silkwire-safe-parallel-" + UUID().uuidString)
        try files.createDirectory(at: fixture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: fixture) }
        func directory(_ name: String = UUID().uuidString) throws -> URL {
            let url = fixture.appendingPathComponent(name)
            try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return url
        }
        func ledger(_ root: URL) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ownership.json")))) as? [String: Any] ?? [:]
        }
        let foreground = { Ownership.Owner(conversationID: UUID(), kind: .foregroundBuild) }
        let background = { Ownership.Owner(conversationID: UUID(), kind: .backgroundJob) }
        let exclusive = { Ownership.Owner(conversationID: UUID(), kind: .exclusiveOperation) }

        // MARK: 1. Registry: independent workspaces, same-workspace exclusion, exclusive work.
        let root = try directory("registry")
        let registry = try Ownership(directory: root, capacity: 4)
        let other = try Ownership(directory: root, capacity: 4) // a second participant
        let ws = try (0..<3).map { try directory("workspace-\($0)") }
        let results = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 3) { index in
            var outcome: Any = "failed"
            for _ in 0..<5000 {
                do { outcome = try registry.reserve(workspace: ws[index], owner: index == 2 ? background() : foreground(), operationID: UUID()); break }
                catch Ownership.Failure.registryBusy { usleep(1000) } catch { outcome = String(describing: error); break }
            }
            lock.lock(); results.add(outcome); lock.unlock()
        }
        let leases = results.compactMap { $0 as? Ownership.Lease }
        check(leases.count == 3, "three independent workspaces are admitted together (two teammates' builds and a background job)")
        check(try registry.snapshot().filter(\.holdsResources).count == 3, "all three hold their places at once")
        for lease in leases { try registry.beginExecution(lease) }
        func record(_ lease: Ownership.Lease) throws -> Ownership.Record { try registry.snapshot().first { $0.operationID == lease.operationID }! }
        let byWorkspace = try Dictionary(uniqueKeysWithValues: leases.map { (try record($0).workspace.path, $0) })
        let lease0 = byWorkspace[try Ownership.Workspace.canonical(ws[0]).path]!, lease1 = byWorkspace[try Ownership.Workspace.canonical(ws[1]).path]!, lease2 = byWorkspace[try Ownership.Workspace.canonical(ws[2]).path]!

        check(failure { _ = try other.reserve(workspace: ws[0], owner: background(), operationID: UUID()) } == .workspaceBusy,
              "same-workspace exclusion still holds: a job on a held workspace is refused")
        let link = fixture.appendingPathComponent("workspace-1-link")
        try files.createSymbolicLink(at: link, withDestinationURL: ws[1])
        check(failure { _ = try other.reserve(workspace: link, owner: foreground(), operationID: UUID()) } == .workspaceBusy,
              "a symlink alias of a held workspace is the same workspace")
        let inner = try directory("workspace-2/private/worktree")
        try registry.registerHostAlias(fixture.appendingPathComponent("workspace-2/private"), conflictRoot: ws[2])
        check(failure { _ = try other.reserve(workspace: inner, owner: background(), operationID: UUID()) } == .workspaceBusy,
              "an overlapping (registered descendant) workspace is excluded")

        let installer = try directory("applications")
        let exclusiveID = UUID(), exclusiveOwner = exclusive()
        if case .waiting(let holders, let ahead) = try registry.reserveExclusive(resource: installer, owner: exclusiveOwner, operationID: exclusiveID) {
            check(holders == 3 && ahead == 0, "an exclusive operation waits for the three running workspaces (holders \(holders))")
        } else { check(false, "an exclusive operation waits for the three running workspaces") }
        let fresh = try directory("workspace-fresh")
        check(failure { _ = try other.reserve(workspace: fresh, owner: foreground(), operationID: UUID()) } == .exclusivePending,
              "while it waits, a NEW independent workspace is refused (exclusivePending), even with a free place")
        check(failure { _ = try registry.reserve(workspace: fresh, owner: exclusiveOwner, operationID: UUID()) } == .invalidInput,
              "exclusive work cannot enter through the private-workspace reserve")
        check((ledger(root)["version"] as? Int) == 3, "a queued exclusive request writes a v3 ledger, which every older (v1/v2) binary refuses")
        let secondExclusive = UUID(), secondOwner = exclusive()
        if case .waiting(_, let ahead) = try other.reserveExclusive(resource: installer, owner: secondOwner, operationID: secondExclusive) {
            check(ahead == 1, "a second exclusive request queues behind the first")
        } else { check(false, "a second exclusive request queues behind the first") }
        try other.withdrawExclusive(operationID: secondExclusive)

        try registry.finishAfterPhysicalExit(lease0, evidence: "fixture: workspace 0 exited")
        let afterFinish = try registry.snapshot()
        let finished0 = afterFinish.first { $0.operationID == lease0.operationID }?.phase == .finished
        let othersHeld = [lease1, lease2].allSatisfy { lease in afterFinish.first { $0.operationID == lease.operationID }?.holdsResources == true }
        check(finished0 && othersHeld, "finishing one workspace leaves the other two held")
        if case .waiting(let holders, _) = try registry.reserveExclusive(resource: installer, owner: exclusiveOwner, operationID: exclusiveID) {
            check(holders == 2, "the exclusive operation still waits for the remaining two")
        } else { check(false, "the exclusive operation still waits for the remaining two") }
        check(failure { _ = try other.reserve(workspace: ws[0], owner: foreground(), operationID: UUID()) } == .exclusivePending,
              "the finished workspace's place is not handed to new work while the exclusive request waits")

        try registry.markUncertain(lease1, evidence: "fixture: workspace 1 exit not proved")
        try registry.reconcileAfterPhysicalExit(try record(lease1), evidence: "fixture: host verified workspace 1 exited")
        let last = try record(lease2)
        check(last.holdsResources && last.phase == .executing, "releasing one uncertain workspace leaves the last one held")
        try registry.markUncertain(lease2, evidence: "fixture: workspace 2 exit not proved")
        if case .waiting(let holders, _) = try registry.reserveExclusive(resource: installer, owner: exclusiveOwner, operationID: exclusiveID) {
            check(holders == 1, "uncertain work still blocks the exclusive operation")
        } else { check(false, "uncertain work still blocks the exclusive operation") }
        try registry.reconcileAfterPhysicalExit(try record(lease2), evidence: "fixture: host verified workspace 2 exited")
        guard case .admitted(let exclusiveLease) = try registry.reserveExclusive(resource: installer, owner: exclusiveOwner, operationID: exclusiveID) else {
            check(false, "the exclusive operation is admitted once nothing else holds resources"); exit(1)
        }
        check(true, "the exclusive operation is admitted once nothing else holds resources")
        try registry.beginExecution(exclusiveLease)
        check(failure { _ = try other.reserve(workspace: fresh, owner: background(), operationID: UUID()) } == .exclusiveHeld,
              "while it runs, every new workspace is refused (exclusiveHeld)")
        if case .waiting(let holders, _) = try other.reserveExclusive(resource: installer, owner: secondOwner, operationID: UUID()) {
            check(holders == 1, "and a second exclusive operation waits for it")
        } else { check(false, "and a second exclusive operation waits for it") }
        let queued = try other.admissionState().exclusiveWaiters.map(\.operationID)
        for id in queued { try other.withdrawExclusive(operationID: id) }
        try registry.finishAfterPhysicalExit(exclusiveLease, evidence: "fixture: exclusive operation returned")
        let afterExclusive = try other.reserve(workspace: fresh, owner: foreground(), operationID: UUID())
        check(true, "after it finishes, independent work is admitted again")
        try other.abandonBeforeExecution(afterExclusive)

        // A queue entry whose waiter died (stopped refreshing) is pruned; it held no work.
        let staleRoot = try directory("stale-registry")
        let stale = try Ownership(directory: staleRoot, capacity: 4)
        let staleHolder = try stale.reserve(workspace: ws[0], owner: foreground(), operationID: UUID())
        _ = try stale.reserveExclusive(resource: installer, owner: exclusive(), operationID: UUID())
        check(failure { _ = try stale.reserve(workspace: ws[1], owner: foreground(), operationID: UUID()) } == .exclusivePending, "a fresh queue entry fences new work")
        var staleLedger = ledger(staleRoot)
        var waiters = staleLedger["exclusiveWaiters"] as? [[String: Any]] ?? []
        if !waiters.isEmpty { waiters[0]["refreshedAt"] = Date().addingTimeInterval(-Ownership.waiterLifetime - 60).timeIntervalSinceReferenceDate }
        staleLedger["exclusiveWaiters"] = waiters
        let staleFile = staleRoot.appendingPathComponent("ownership.json")
        try JSONSerialization.data(withJSONObject: staleLedger, options: [.sortedKeys]).write(to: staleFile)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staleFile.path)
        let unfenced = try stale.reserve(workspace: ws[1], owner: foreground(), operationID: UUID())
        check(try stale.admissionState().exclusiveWaiters.isEmpty, "a queue entry not refreshed within its lifetime is pruned, and new work is admitted again")
        try stale.abandonBeforeExecution(unfenced); try stale.abandonBeforeExecution(staleHolder)

        // MARK: 2. Capacity migration from the old single-slot registry.
        let idleRoot = try directory("old-idle")
        let oldIdle = try Ownership(directory: idleRoot, capacity: 1)
        let past = try oldIdle.reserve(workspace: ws[0], owner: foreground(), operationID: UUID())
        try oldIdle.beginExecution(past); try oldIdle.finishAfterPhysicalExit(past, evidence: "fixture: old work exited")
        check((ledger(idleRoot)["capacity"] as? Int) == 1 && (ledger(idleRoot)["version"] as? Int) == 1, "fixture: an old capacity-1 v1 ledger with only finished history")
        let migrated = try? Ownership(directory: idleRoot, capacity: 4)
        check(migrated != nil && (ledger(idleRoot)["capacity"] as? Int) == 4 && (ledger(idleRoot)["version"] as? Int) == 3,
              "an idle old registry (capacity 1) migrates to capacity 4 and becomes v3")
        check(try migrated?.snapshot().first?.operationID == past.operationID, "migration keeps the registry's history (operation tombstones)")
        if let migrated {
            let two = try (0..<2).map { try migrated.reserve(workspace: ws[$0], owner: foreground(), operationID: UUID()) }
            check(two.count == 2, "the migrated registry admits independent workspaces side by side")
            for lease in two { try migrated.abandonBeforeExecution(lease) }
        }

        for (label, uncertain) in [("reserved/executing", false), ("uncertain", true)] {
            let busyRoot = try directory("old-busy-" + label.replacingOccurrences(of: "/", with: "-"))
            let oldBusy = try Ownership(directory: busyRoot, capacity: 1)
            let held = try oldBusy.reserve(workspace: ws[0], owner: background(), operationID: UUID())
            try oldBusy.beginExecution(held)
            if uncertain { try oldBusy.markUncertain(held, evidence: "fixture: old job exit not proved") }
            let before = try Data(contentsOf: busyRoot.appendingPathComponent("ownership.json"))
            var refusal: Ownership.Failure?
            do { _ = try Ownership(directory: busyRoot, capacity: 4) } catch let error as Ownership.Failure { refusal = error }
            check(refusal == .configurationMismatch, "a busy old registry (\(label) work) is refused, not migrated")
            check(try Data(contentsOf: busyRoot.appendingPathComponent("ownership.json")) == before && (try oldBusy.snapshot().first?.holdsResources == true),
                  "the refused migration leaves the old ledger and its held work untouched (\(label))")
            if uncertain {
                try oldBusy.reconcileAfterPhysicalExit(try oldBusy.snapshot().first!, evidence: "fixture: host verified old job exited")
                check((try? Ownership(directory: busyRoot, capacity: 4)) != nil, "once its held work is reconciled, the old registry migrates")
            }
        }

        // MARK: 3. Host coordinator and Builder ownership: identity-bound finish.
        let coordinator = HostExecutionCoordinator(directory: fixture.appendingPathComponent("host-registry"))
        let sources = try (0..<4).map { try directory("host-workspace-\($0)") }
        func admit(_ source: URL, kind: Ownership.Kind = .foregroundBuild) async throws -> HostExecutionAdmission {
            try await coordinator.admit(operationID: UUID(), conversationID: UUID(), kind: kind,
                authorize: { .init(executionRoot: source, conflictRoot: source) }, mayOperate: { true }, wait: false)
        }
        var subjects: [HostExitSubject] = []
        var answers: [UUID: HostPhysicalExit] = [:]
        let verifier: HostExitVerifier = { subject in
            subjects.append(subject)
            return answers[subject.operationID] ?? .unconfirmed(reason: "fixture: no answer for this subject")
        }
        let owners = (0..<3).map { _ in HostBuilderOwnership(coordinator: coordinator, conversationID: UUID(), authorize: nil, verifyExit: verifier) }
        let operations = (0..<3).map { _ in UUID() }
        async let begin0: Void = owners[0].begin(operationID: operations[0], source: sources[0], mayOperate: { true })
        async let begin1: Void = owners[1].begin(operationID: operations[1], source: sources[1], mayOperate: { true })
        async let begin2: Void = owners[2].begin(operationID: operations[2], source: sources[2], mayOperate: { true })
        _ = try await (begin0, begin1, begin2)
        check(Set(coordinator.activeOperationIDs) == Set(operations), "the coordinator admits three independent Builder workspaces together")
        var sameWorkspace: Error?
        do { _ = try await admit(sources[0], kind: .backgroundJob) } catch { sameWorkspace = error }
        check((sameWorkspace as? Ownership.Failure) == .workspaceBusy, "a background job on a held workspace is refused at once (wait: false), not admitted")

        var exclusiveAdmission: HostExecutionAdmission?
        let exclusiveTask = Task { @MainActor in
            exclusiveAdmission = try await coordinator.admitExclusive(operationID: UUID(), requester: UUID(), resource: installer, mayOperate: { true })
        }
        func waitFor(_ condition: () async -> Bool) async -> Bool {
            for _ in 0..<400 { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
            return false
        }
        check(await waitFor { (try? await coordinator.admissionState().exclusiveWaiters.count) == 1 }, "the exclusive operation queues behind three running workspaces")
        var blocked: Error?
        do { _ = try await admit(sources[3]) } catch { blocked = error }
        check((blocked as? Ownership.Failure) == .exclusivePending, "while it waits, new work is refused (exclusivePending)")
        let waitingMessage = (try? await coordinator.admissionState()).flatMap(HostExecutionCoordinator.privateAdmissionRefusal) ?? ""
        check(waitingMessage.contains("exclusive host operation") && waitingMessage.contains("waiting"), "the refusal says why in plain words: " + waitingMessage)

        answers[operations[0]] = .verified(evidence: "fixture: workspace 0's executor exited")
        let run0 = UUID()
        try await owners[0].finish(workspaceID: run0)
        let subject0 = subjects.last
        check(subject0?.operationID == operations[0] && subject0?.builderRunID == run0 && subject0?.inherited == false
              && subject0?.executionRoot == sources[0] && subject0?.kind == .foregroundBuild && subject0?.conversationID == owners[0].conversationID,
              "finish hands the verifier exactly this workspace's identity (operation, Builder run, root, kind, conversation)")
        var state = try await coordinator.admissionState()
        check(state.records.first { $0.operationID == operations[0] }?.phase == .finished
              && [operations[1], operations[2]].allSatisfy { id in state.held.contains { $0.operationID == id } },
              "finishing workspace 0 releases only workspace 0; the other two stay held")

        // A verifier keyed to identity: proof for workspace 0 does not apply to workspace 1.
        var unconfirmed = false
        do { try await owners[1].finish(workspaceID: UUID()) } catch HostExecutionCoordinator.Failure.physicalExitUnconfirmed { unconfirmed = true }
        state = try await coordinator.admissionState()
        check(unconfirmed && subjects.last?.operationID == operations[1] && state.records.first { $0.operationID == operations[1] }?.phase == .uncertain,
              "workspace 1's own unproved exit keeps it held (uncertain); workspace 0's proof is not reused")
        check(state.held.contains { $0.operationID == operations[2] } && exclusiveAdmission == nil, "workspace 2 stays held and the exclusive operation still waits")
        let record1 = state.records.first { $0.operationID == operations[1] }!
        try await coordinator.reconcileAfterPhysicalExit(record1, evidence: "fixture: host verified workspace 1 exited")
        state = try await coordinator.admissionState()
        check(state.held.map(\.operationID) == [operations[2]], "releasing workspace 1 leaves exactly workspace 2 held")

        answers[operations[2]] = .verified(evidence: "fixture: workspace 2's executor exited")
        try await owners[2].finish(workspaceID: UUID())
        check(await waitFor { exclusiveAdmission != nil }, "the exclusive operation is admitted once the last workspace finishes")
        try await exclusiveTask.value
        var whileExclusive: Error?
        do { _ = try await admit(sources[3]) } catch { whileExclusive = error }
        check((whileExclusive as? Ownership.Failure) == .exclusiveHeld, "while it runs, new work is refused (exclusiveHeld)")
        state = try await coordinator.admissionState()
        check(HostExecutionCoordinator.privateAdmissionRefusal(state)?.contains("is running") == true, "and the room's begin check reports it")
        if let exclusiveAdmission {
            try await coordinator.finish(exclusiveAdmission, exit: .verified(evidence: "fixture: in-process exclusive operation returned"))
        }
        let afterwards = try await admit(sources[3])
        check(afterwards.kind == .foregroundBuild, "after the exclusive operation finishes, independent work is admitted again")
        // A waiter that gives up withdraws its queue entry, so new work is not fenced by it.
        let giveUp = Task { @MainActor in
            try await coordinator.admitExclusive(operationID: UUID(), requester: UUID(), resource: installer, mayOperate: { true })
        }
        check(await waitFor { (try? await coordinator.admissionState().exclusiveWaiters.count) == 1 }, "a second exclusive operation queues behind running work")
        giveUp.cancel()
        _ = try? await giveUp.value
        check((try await coordinator.admissionState()).exclusiveWaiters.isEmpty, "cancelling a waiting exclusive operation withdraws it")
        let unblocked = try await admit(sources[0])
        check(unblocked.kind == .foregroundBuild, "and new independent work is admitted again")
        try await coordinator.finish(afterwards, exit: .verified(evidence: "fixture: never dispatched"))
        try await coordinator.finish(unblocked, exit: .verified(evidence: "fixture: never dispatched"))

        // MARK: 4. Real trusted workspaces: three teammates on ONE granted source.
        let projects = try directory("Projects"), source = try directory("Projects/Example")
        let library = try directory("Staging")
        try Data("synthetic\n".utf8).write(to: source.appendingPathComponent("README.md"))
        let env = ["PATH": "/usr/bin:/bin", "HOME": fixture.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        func git(_ args: [String], in directory: URL = source) async throws -> String {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null"] + args, directory: directory, environment: env)
            guard result.exitCode == 0 else { throw nativeFailure(result.stderr) }; return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q"]); _ = try await git(["add", "."])
        _ = try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-qm", "Example"])
        let room = UUID()
        let teamRegistry = HostExecutionCoordinator(directory: fixture.appendingPathComponent("team-registry"))
        let storage = library.appendingPathComponent("Team Workspaces/staging/" + room.uuidString.lowercased())
        let grant = NativeProjectFolderGrant(id: "projects", name: "Projects", root: projects)
        var teamSubjects: [HostExitSubject] = []
        var unprovedAgent: String?
        let workspaces = NativeTrustedWorkspaces(storage: storage, sandbox: WorkspaceEnvironment(staging: true, library: library), ownership: teamRegistry, conversationID: room,
            verifyPhysicalExit: { subject in
                teamSubjects.append(subject)
                if let agent = unprovedAgent, subject.executionRoot.path.contains("/" + agent + "/") { return .unconfirmed(reason: "fixture: this teammate's exit not proved") }
                return .verified(evidence: "fixture: this workspace ran no commands; its host Git operations were awaited")
            }, receipt: { _, _ in })
        try workspaces.configure(grants: [grant], trustedIDs: [grant.id])
        let team = ["codex", "claude", "eve"]
        // Separate task paths: the room's task board refuses overlapping claims (a logical
        // layer above physical ownership, which this suite is about).
        func begin(_ agent: String, area: String? = nil) async -> [String: Any]? {
            let request: [String: Any] = ["action": "begin", "folderId": grant.id, "path": "Example", "taskTitle": "Candidate for " + agent, "paths": [area ?? agent + "-area"]]
            do { return try await workspaces.perform(request, agent: agent, task: "Prepare a candidate") }
            catch { print("  begin \(agent): \(error.localizedDescription)"); return nil }
        }
        async let codexBegin = begin("codex"), claudeBegin = begin("claude"), eveBegin = begin("eve")
        let begun = await [codexBegin, claudeBegin, eveBegin]
        check(begun.allSatisfy { $0?["status"] as? String == "active" } && team.allSatisfy(workspaces.active),
              "three teammates begin private workspaces on the SAME granted source together")
        state = try await teamRegistry.admissionState()
        let keys = state.held.map(\.workspace.path)
        check(state.held.count == 3 && Set(keys).count == 3 && team.allSatisfy { agent in keys.contains { $0.contains("/" + agent + "/") } },
              "each holds its own key (its private run root), not the shared source")
        let worktrees = begun.compactMap { $0?["worktreePath"] as? String }.map { URL(fileURLWithPath: $0) }
        if worktrees.count == 3 {
            var jobOnOpenWorkspace: Error?
            do {
                _ = try await teamRegistry.admit(operationID: UUID(), conversationID: room, kind: .backgroundJob,
                    authorize: { .init(executionRoot: worktrees[0], conflictRoot: worktrees[0]) }, mayOperate: { true }, wait: false)
            } catch { jobOnOpenWorkspace = error }
            check((jobOnOpenWorkspace as? Ownership.Failure) == .workspaceBusy, "a background job on a teammate's OPEN worktree maps to that workspace and is refused")
        } else { check(false, "a background job on a teammate's OPEN worktree maps to that workspace and is refused") }

        let codexFinished = try await workspaces.perform(["action": "finish", "summary": "Candidate"], agent: "codex", task: "Finish")
        let codexSubject = teamSubjects.last
        check(codexFinished["status"] as? String == "review" && codexSubject?.builderRunID?.uuidString == codexFinished["id"] as? String
              && codexSubject?.executionRoot.path.hasSuffix("/codex/" + (codexFinished["id"] as? String ?? "?")) == true,
              "Codex's finish verifies Codex's own run (receipt \(codexFinished["id"] as? String ?? "?"))")
        state = try await teamRegistry.admissionState()
        check(!workspaces.active("codex") && workspaces.active("claude") && workspaces.active("eve") && state.held.count == 2
              && state.held.allSatisfy { !$0.workspace.path.contains("/codex/") },
              "finishing Codex's workspace leaves Claude's and Eve's held and active")
        unprovedAgent = "claude"
        let claudeFinished = try await workspaces.perform(["action": "finish", "summary": "Candidate"], agent: "claude", task: "Finish")
        state = try await teamRegistry.admissionState()
        check(claudeFinished["physicalExitUnconfirmed"] as? Bool == true && state.held.count == 2
              && state.held.contains { $0.phase == .uncertain && $0.workspace.path.contains("/claude/") } && workspaces.active("eve"),
              "Claude's unproved exit keeps only Claude's workspace held; Eve's is unaffected")
        let codexAgain = await begin("codex", area: "codex-second-area")
        check(codexAgain?["status"] as? String == "active", "Codex can begin a new workspace while Claude's earlier one is held")
        unprovedAgent = nil
        for agent in ["eve", "codex"] { _ = try await workspaces.perform(["action": "finish", "summary": "Done"], agent: agent, task: "Finish") }
        state = try await teamRegistry.admissionState()
        check(state.held.count == 1 && state.held.first?.workspace.path.contains("/claude/") == true, "only Claude's unproved workspace remains held at the end")

        print((failures == 0 ? "PASS" : "FAIL") + ": SafeParallelOwnershipTests, \(checks - failures)/\(checks) checks; synthetic work only")
        exit(failures == 0 ? 0 : 1)
    }
}
