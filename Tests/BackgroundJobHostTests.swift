import Foundation

// BackgroundJobHost contract v1 as the room relies on it, checked against the shipped
// FakeBackgroundJobHost (whose Release path is the host's real recovery code over a
// private D2 registry), plus the saved card model. Nothing runs.
@main struct BackgroundJobHostTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        let root = try NativeTemporaryDirectory.createWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let ownership = root.appendingPathComponent("registry"), workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let room = UUID()
        func request(_ agent: String, id: UUID = UUID()) -> HostJobRequest {
            HostJobRequest(operationID: id, scope: BackgroundWorkScope(projectID: UUID(), conversationID: room, workspaceID: UUID(), agentID: agent, sourceRevision: String(repeating: "a", count: 40)),
                           workDescription: "Run build check", limits: .init(totalSteps: 1, stepsPerSlice: 1))
        }

        // Plain-English titles from the teammate's own request (also the host workDescription).
        check(BackgroundJobText.title(["action": "run", "checks": [["name": "build", "command": "x"], ["name": "test", "command": "y"]]]) == "Run build and test checks", "two named checks read as plain English")
        check(BackgroundJobText.title(["action": "run", "checks": [["name": "build", "command": "x"], ["name": "lint", "command": "y"], ["name": "test", "command": "z"]]]) == "Run build, lint and test checks", "three named checks are listed")
        check(BackgroundJobText.title(["action": "run", "checks": [["command": "x"]]]) == "Run 1 workspace check", "unnamed checks are counted, not invented")
        check(BackgroundJobText.title(["action": "run", "command": "swift Scripts/test.swift RoomTests\nrm -rf x"]) == "Run `swift Scripts/test.swift RoomTests`", "a command shows its first line only")
        check(BackgroundJobText.title(["action": "run", "checks": [["name": String(repeating: "é", count: 200), "command": "x"]]]).utf8.count <= 240, "a title always fits the host's 240-byte workDescription")
        check(BackgroundJobText.isLongWork(["action": "run"]) && !BackgroundJobText.isLongWork(["action": "write"]) && !BackgroundJobText.isLongWork(["action": "begin"]), "only run steps leave the turn")
        check(!BackgroundJobText.acknowledgement("Run build check").contains("\n"), "the acknowledgement is one line")

        // Acceptance by operationID, one slot, monotonic revisions.
        let host = FakeBackgroundJobHost(ownership: ownership, workspace: workspace)
        var stream = host.events().makeAsyncIterator()
        let firstRequest = request("codex")
        let first = try await host.submit(firstRequest)
        check(first == firstRequest.operationID, "the job ID is the room's operationID")
        let second = try await host.submit(request("claude"))
        check(host.state(first) == .running && host.state(second) == .queued, "a second job queues behind the one slot")
        check(try await host.submit(firstRequest) == first && host.order.count == 2, "a repeated submission of the same identity never replays")
        var changed = request("codex", id: first); changed = HostJobRequest(operationID: first, scope: changed.scope, workDescription: "Different work", limits: changed.limits)
        check((try? await host.submit(changed)) == nil, "a reused identity with different work is refused")
        let opened = await stream.next()
        check(opened?.jobID == first && opened?.state == .queued, "events start with the job's earliest published state")
        let r1 = host.snapshot(first)?.revision ?? 0
        host.progress(first, "build 1 of 2")
        check((host.snapshot(first)?.revision ?? 0) > r1 && host.snapshot(first)?.progress == "build 1 of 2", "progress raises the revision and is not a result")

        // Stop: an immediate fence, a separate durable acknowledgement, no result.
        host.requestStop(first)
        check(host.state(first) == .stopping && host.pendingResults.isEmpty, "requestStop fences at once; work isn't over yet")
        let acknowledgement = try await host.stop(first)
        check(acknowledgement.stopRequested && host.jobs[first]?.stopRecorded == true, "stop() reports the durable Stop intent")
        check(host.state(second) == .queued, "the slot stays taken while stopped work is still ending")
        await host.end(first, note: "Stopped by the host.")
        check(host.state(first) == .failed && host.snapshot(first)?.completionID != nil && host.pendingResults.isEmpty, "a stopped job ends as failed with no result")
        check(host.state(second) == .running, "the queued job starts once the slot frees")

        // Results only through pendingResults, until acknowledged.
        await host.complete(second, summary: "build passed (exit 0)")
        let pending = host.pendingResults.first
        check(pending?.id == second && pending?.resultID != nil && pending?.note == "build passed (exit 0)", "a completed job's result waits in pendingResults")
        check(host.pendingResults.first?.resultID == pending?.resultID, "repeated polls return the same resultID")
        host.acknowledgementFailure = BackgroundWorkError.storage
        check((try? await host.acknowledgeResult(second, resultID: pending?.resultID ?? UUID())) == nil && host.pendingResults.count == 1, "a failed acknowledgement leaves the result pending")
        host.acknowledgementFailure = nil
        check(try await host.acknowledgeResult(second, resultID: pending?.resultID ?? UUID()) && host.pendingResults.isEmpty, "an acknowledged result leaves the outbox")
        let third = try await host.submit(request("codex"))
        let queuedStop = try await host.submit(request("eve"))
        check(host.state(third) == .running && host.state(queuedStop) == .queued, "the next job runs and another queues")
        host.requestStop(queuedStop)
        check(host.state(queuedStop) == .failed && host.pendingResults.isEmpty, "a job stopped before dispatch ends as failed: nothing ran")

        // Physical hold and verification-only Release (the host's real recovery code).
        try await host.holdPhysically(third)
        await host.end(third, note: "Executor returned; exit not proved.", uncertain: true)
        let held = try await host.heldPhysicalOperations()
        check(held.count == 1 && held.first?.operationID == host.snapshot(third)?.pendingOperationID && held.first?.originatingConversationID == room, "an unproved exit stays held for that job's step")
        let blocked = try await host.submit(request("claude"))
        check(host.state(blocked) == .queued, "a physical hold keeps the slot")
        let ticket = try await host.checkPhysicalExit(operationID: held.first!.operationID)
        let refused = try await host.reconcilePhysicalExit(ticket)
        if case .retained(_, let reason) = refused { check(!reason.isEmpty, "Release without exit evidence is retained, with a reason") } else { check(false, "Release without exit evidence is retained, with a reason") }
        check(try await host.heldPhysicalOperations().count == 1, "a retained Release keeps the hold")

        // Reopen: unfinished work needs review; nothing restarts on its own.
        let reopened = FakeBackgroundJobHost(ownership: ownership, workspace: workspace, restoring: host.saved)
        check(reopened.state(blocked) == .needsReview && reopened.state(third) == .needsReview, "reopened unfinished work is needsReview, never done")
        check(try await reopened.heldPhysicalOperations().count == 1, "the physical hold survives the restart")
        reopened.verifier = { _ in .verified(evidence: "fixture: exact executor exit observed") }
        let second2 = try await reopened.checkPhysicalExit(operationID: held.first!.operationID)
        let released = try await reopened.reconcilePhysicalExit(second2)
        check(released == .released(operationID: held.first!.operationID, evidence: "fixture: exact executor exit observed"), "Release with fresh evidence frees the slot")
        check(try await reopened.heldPhysicalOperations().isEmpty && reopened.state(third) == .needsReview, "release frees the slot but never resolves the job's outcome")
        reopened.refuseSubmissions = BackgroundWorkError.busy
        check((try? await reopened.submit(request("eve"))) == nil, "a refused submission creates no job")

        // Saved cards: labels and tolerant decoding.
        var card = BackgroundJobCard(id: UUID(), agent: "codex", title: "Run build check", originRequestID: "r", work: "{}", workspaceID: UUID())
        check(card.stateLabel == "Handing off…" && card.holdsWorkspace, "a card is saved before the host accepts")
        card.phase = .running
        check(card.stateLabel == "Running" && card.mayStop, "running label")
        card.stopRequested = true
        check(card.stateLabel == "Stopping…", "Stop requested shows Stopping…")
        card.phase = .failed
        check(card.stateLabel == "Stopping…", "a recorded end isn't Stopped until the physical hold is checked")
        card.physicalChecked = true; card.physicalHold = "Physical executor may still be running."
        check(card.stateLabel == "Stopping…" && card.mayRelease && card.holdsWorkspace, "a physical hold keeps Stopping… and offers Release")
        card.physicalHold = nil
        check(card.stateLabel == "Stopped" && !card.holdsWorkspace, "Stopped once the host recorded the end and nothing is held")
        card.stopRequested = false
        check(card.stateLabel == "Failed", "a failure that wasn't a Stop says Failed")
        card.phase = .needsReview
        check(card.stateLabel == "Needs review" && !card.holdsWorkspace, "uncertain work needs review; with no physical hold, the workspace is free again")
        card.startedAt = Date(timeIntervalSince1970: 100); card.endedAt = Date(timeIntervalSince1970: 172)
        check(card.elapsed() == 72, "elapsed time runs from start to end")
        check((try? JSONDecoder().decode(BackgroundJobCard.Phase.self, from: Data(#""finishedSomehow""#.utf8))) == .unknown, "a phase from a newer build decodes as unknown")
        var conversation = Conversation(); conversation.backgroundJobs = [card]
        let encoded = try JSONEncoder().encode(conversation)
        check(try JSONDecoder().decode(Conversation.self, from: encoded).backgroundJobs == [card], "cards round-trip with their conversation")
        var raw = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        raw["backgroundJobs"] = [["id": "not-a-uuid"]]
        let damaged = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: raw))
        check(damaged.id == conversation.id && damaged.backgroundJobs == nil, "an unreadable card list never stops a conversation from opening")
        raw.removeValue(forKey: "backgroundJobs")
        check(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: raw)).backgroundJobs == nil, "older conversations without cards still open")
        let isolated = try WorkspaceEnvironment.isolatedSnapshot({ () -> ConversationWorkspace in
            let project = Project(); var room = Conversation(); room.projectID = project.id; room.backgroundJobs = [card]
            return ConversationWorkspace(activeID: room.id, conversations: [room], projects: [project])
        }())
        check(isolated.conversations.allSatisfy { $0.backgroundJobs == nil }, "a Staging snapshot drops another library's job cards")

        print("BackgroundJobHostTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
