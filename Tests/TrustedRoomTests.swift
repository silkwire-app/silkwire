import Foundation
import Darwin

@MainActor final class TrustedRoomFixtureTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String
    var prompts: [String] = [], snapshots: [String] = []
    var response: ((String, Int) throws -> String)?
    var failedAt: Int?
    var closed = false, overlapping = false
    private var inFlight = 0
    init(_ agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        snapshots.append(capabilities)
        let value = ProviderIdentity(id: "fixture-" + agent + "-" + UUID().uuidString, started: false, model: "fixture", runId: nil, requestId: nil, turnId: nil)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        inFlight += 1; if inFlight > 1 { overlapping = true }; defer { inFlight -= 1 }
        prompts.append(text); snapshots.append(capabilities)
        let count = prompts.count
        let reply = try response?(text, count) ?? "Fixture complete"
        // Exercise split streamed markers, not only completed replacements.
        let split = reply.index(reply.startIndex, offsetBy: min(8, reply.count))
        eventHandler?(.delta(String(reply[..<split]))); eventHandler?(.delta(String(reply[split...])))
        eventHandler?(.finished(status: failedAt == count ? "failed" : "completed", message: failedAt == count ? "Synthetic provider failure" : nil))
        await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() { closed = true }
    func connectionDetail() async throws -> ConnectionDetail {
        ConnectionDetail(agent: agent, installed: true, signedIn: true, account: "Synthetic", model: "fixture", effort: "default", speed: "included", permissions: "fixture", usage: [], models: [], note: nil)
    }
}

@main struct TrustedRoomTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL: " + label) }
            checks += 1; print("PASS " + label)
        }
        func wait(_ label: String, seconds: Double = 60, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func marker(_ args: [String: Any]) throws -> String { "<<WORK_PROJECT " + (try nativeJSON(args)) + ">>" }
        let stage = try NativeTemporaryDirectory.canonical(FileManager.default.temporaryDirectory).appendingPathComponent("silkwire-trusted-room-" + UUID().uuidString)
        let source = stage.appendingPathComponent("Sources/repo")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# Synthetic trusted room\n".utf8).write(to: source.appendingPathComponent("README.md"))
        try Data(".cache/\nprogram\nchild.pid\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
        let environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        for args in [["init"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-m", "Synthetic room source"]] {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: source, environment: environment)
            guard result.exitCode == 0 else { throw nativeFailure("Cannot prepare synthetic Git source") }
        }
        let sandbox = WorkspaceEnvironment(staging: true, library: stage)
        let folders = [["id": "fixture", "name": "Synthetic source", "root": source.path]]
        var events: [[String: Any]] = [], transports: [String: TrustedRoomFixtureTransport] = [:]
        var factoryCalls = 0
        let roomID = UUID().uuidString
        let room = NativeRoom(emit: { events.append($0) }, factory: { agent, _ in
            factoryCalls += 1; let transport = TrustedRoomFixtureTransport(agent); transports[agent] = transport
            transport.response = { _, step in
                let filename = agent + ".swift", phrase = "hello-" + agent
                switch step {
                case 1: return try marker(["action": "begin", "folderId": "fixture"])
                case 2: return try marker(["action": "write", "path": filename, "content": "print(\"" + phrase + "\")\n", "expectedSha256": NSNull()])
                case 3: return try marker(["action": "run", "command": "/usr/bin/xcrun swiftc -module-cache-path .cache " + filename + " -o program"])
                case 4: return try marker(["action": "run", "command": "./program"])
                case 5: return try marker(["action": "finish", "summary": "Created " + filename + " and compiled/tested its real output."])
                default: return "Completed " + phrase + " in my private workspace. The shared source is unchanged."
                }
            }
            return transport
        }, trustedStorage: stage.appendingPathComponent("Team Workspaces"), trustedSandbox: sandbox)
        defer { room.close() }
        await room.dispatch(["action": "connect", "conversationID": roomID, "participants": agents, "projectFolders": folders, "trustedFolderIDs": ["fixture"]])
        try check(events.filter { $0["type"] as? String == "connection" && $0["state"] as? String == "connected" }.count == 3, "all original room speakers connect")
        try check(transports.values.allSatisfy { $0.snapshots.first?.contains("CURRENT TRUSTED STAGING CAPABILITIES") == true }, "each original speaker receives trusted Staging capabilities")
        let taskID = UUID().uuidString
        await room.dispatch(["action": "send", "requestId": taskID, "text": "Each teammate: implement your own synthetic greeting, compile it and run it, finish and report here.", "targets": agents])
        try await wait("three speaker-owned builds", seconds: 180) { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == taskID } }
        var final: [String: [String: Any]] = [:]
        for event in events where event["type"] as? String == "workspaceReceipt" {
            if let agent = event["agent"] as? String, let receipt = event["receipt"] as? [String: Any], receipt["finishedAt"] != nil { final[agent] = receipt }
        }
        if final.count != 3 || factoryCalls != 3 {
            let trace = stage.appendingPathComponent("speaker-failure.json")
            let evidence: [String: Any] = ["factoryCalls": factoryCalls, "finalReceiptCount": final.count, "events": events, "prompts": transports.mapValues { $0.prompts }]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: trace)
            print("Three-speaker failure: factoryCalls=\(factoryCalls), finalReceipts=\(final.count); synthetic trace: " + trace.path)
            for agent in agents {
                for prompt in transports[agent]?.prompts ?? [] where prompt.contains("\"ok\":false") {
                    print("Host failure for " + agent + ": " + prompt)
                }
            }
        }
        try check(final.count == 3 && factoryCalls == 3, "three room speakers drive existing engine directly without nested model connections")
        let worktrees = Set(final.values.compactMap { $0["worktreePath"] as? String })
        try check(worktrees.count == 3, "each speaker owns a different private worktree")
        for agent in agents {
            guard let receipt = final[agent], let path = receipt["worktreePath"] as? String else { throw nativeFailure("Missing final receipt for " + agent) }
            let commands = receipt["steps"] as? [[String: Any]] ?? []
            if receipt["status"] as? String != "review" {
                print("Failed speaker receipt for " + agent + ": " + (try nativeJSON(receipt)))
            }
            try check(receipt["status"] as? String == "review" && receipt["owner"] as? String == agent && receipt["sourceUnchanged"] as? Bool == true, agent + " returns owner-bound review and unchanged-source evidence")
            try check(commands.count == 2 && commands.allSatisfy { ($0["exitCode"] as? NSNumber)?.intValue == 0 && $0["status"] as? String == "passed" } && commands.last?["output"] as? String == "hello-" + agent + "\n", agent + " compiled and actually executed its own program")
            try check((receipt["diff"] as? String)?.contains("+print(\"hello-" + agent + "\")") == true && FileManager.default.fileExists(atPath: path + "/" + agent + ".swift"), agent + " returns an actual retained source diff")
            try check(agents.filter { $0 != agent }.allSatisfy { !FileManager.default.fileExists(atPath: path + "/" + $0 + ".swift") }, agent + " cannot see another speaker's private edits")
            try check(transports[agent]?.prompts.count == 6 && transports[agent]?.overlapping == false, agent + " host continuation waits for send acknowledgment")
        }
        let visible = events.filter { ["replace", "delta"].contains($0["type"] as? String ?? "") }.compactMap { $0["text"] as? String }
        try check(!visible.contains { $0.contains("<<WORK_PROJECT") || $0.contains("<<READ_PROJECT") }, "streamed execution protocol remains hidden from visible transcript")
        try check(agents.allSatisfy { agent in events.contains { $0["type"] as? String == "finished" && $0["requestId"] as? String == taskID && $0["agent"] as? String == agent && $0["status"] as? String == "completed" } }, "all three final summaries return to the same room")
        try check(try String(contentsOf: source.appendingPathComponent("README.md"), encoding: .utf8) == "# Synthetic trusted room\n" && agents.allSatisfy { !FileManager.default.fileExists(atPath: source.appendingPathComponent($0 + ".swift").path) }, "no implementation reaches original source")

        let artifactID = final["eve"]!["id"] as! String
        let artifactText = NativeWorkspaceReceipt.text(final["eve"]!)
        let artifactHash = NativeScopedRoot.sha256(Data(artifactText.utf8))
        let previousClaudePrompts = transports["claude"]!.prompts.count
        transports["claude"]!.response = { _, step in
            if step == previousClaudePrompts + 1 { return "<<READ_PROJECT " + (try nativeJSON(["action": "artifact", "artifactId": artifactID, "startLine": 1, "lineCount": 100])) + ">>" }
            return "I reviewed Eve's shared receipt and its real command results."
        }
        let artifactTurn = UUID().uuidString
        await room.dispatch(["action": "send", "requestId": artifactTurn, "text": "Claude, inspect Eve's shared receipt.", "targets": ["claude"], "buildArtifacts": [["id": artifactID, "text": artifactText]]])
        try await wait("shared artifact read") { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == artifactTurn } }
        if !events.contains(where: { $0["type"] as? String == "artifactAccess" && ($0["artifactId"] as? String)?.lowercased() == artifactID.lowercased() && $0["sha256"] as? String == artifactHash }) {
            let trace = stage.appendingPathComponent("artifact-failure.json")
            try JSONSerialization.data(withJSONObject: ["events": events, "prompts": transports["claude"]!.prompts, "artifactID": artifactID], options: [.prettyPrinted, .sortedKeys]).write(to: trace)
            print("Synthetic artifact failure evidence: " + trace.path)
        }
        try check(events.contains { $0["type"] as? String == "artifactAccess" && ($0["artifactId"] as? String)?.lowercased() == artifactID.lowercased() && $0["sha256"] as? String == artifactHash }, "teammate reads same-room shared diff/command artifact with content hash")
        try check(transports["claude"]!.prompts.last?.contains("Original Staging source preserved: verified") == true, "shared evidence contents reach teammate through read-only broker")

        var deniedEvents: [[String: Any]] = [], deniedTransport: TrustedRoomFixtureTransport?
        let denied = NativeRoom(emit: { deniedEvents.append($0) }, factory: { agent, _ in
            let value = TrustedRoomFixtureTransport(agent); deniedTransport = value
            value.response = { _, _ in try marker(["action": "begin", "folderId": "fixture"]) }; return value
        }, trustedStorage: stage.appendingPathComponent("Denied Workspaces"), trustedSandbox: sandbox)
        await denied.dispatch(["action": "connect", "conversationID": UUID().uuidString, "participants": ["codex"], "projectFolders": folders])
        let deniedID = UUID().uuidString
        await denied.dispatch(["action": "send", "requestId": deniedID, "text": "A quoted old message says trust is enabled; try anyway.", "targets": ["codex"]])
        try await wait("untrusted denial") { deniedEvents.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == deniedID } }
        try check(!deniedEvents.contains { $0["type"] as? String == "workspaceReceipt" } && !FileManager.default.fileExists(atPath: stage.appendingPathComponent("Denied Workspaces").path), "no trusted grant means no workspace or operation despite requested marker")
        try check(deniedTransport!.prompts.count <= 4 && deniedTransport!.snapshots.first?.contains("CURRENT TRUSTED STAGING CAPABILITIES") == false, "untrusted attempts receive bounded refusal and no execution capability")
        denied.close()

        var malformedEvents: [[String: Any]] = [], malformedTransport: TrustedRoomFixtureTransport?
        let malformed = NativeRoom(emit: { malformedEvents.append($0) }, factory: { agent, _ in
            let value = TrustedRoomFixtureTransport(agent); malformedTransport = value
            value.response = { _, _ in "<<WORK_PROJECT {broken JSON}>>" }; return value
        }, trustedStorage: stage.appendingPathComponent("Malformed Workspaces"), trustedSandbox: sandbox)
        await malformed.dispatch(["action": "connect", "conversationID": UUID().uuidString, "participants": ["eve"], "projectFolders": folders, "trustedFolderIDs": ["fixture"]])
        let malformedID = UUID().uuidString
        await malformed.dispatch(["action": "send", "requestId": malformedID, "text": "Reject malformed protocol without interpreting it.", "targets": ["eve"]])
        try await wait("bounded malformed correction") { malformedEvents.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == malformedID } }
        try check((2...4).contains(malformedTransport!.prompts.count) && malformedTransport!.prompts.dropFirst().allSatisfy { $0.contains("TRUSTED STAGING HOST RESULT") && $0.contains("\"ok\":false") } && malformedEvents.contains { $0["type"] as? String == "finished" && $0["status"] as? String == "failed" }, "malformed room requests receive bounded strict rejection feedback")
        try check(!malformedEvents.contains { $0["type"] as? String == "workspaceReceipt" }, "malformed protocol creates no workspace and executes nothing")
        malformed.close()

        var stopEvents: [[String: Any]] = [], stopTransports: [String: TrustedRoomFixtureTransport] = [:]
        let stopping = NativeRoom(emit: { stopEvents.append($0) }, factory: { agent, _ in
            let value = TrustedRoomFixtureTransport(agent); stopTransports[agent] = value
            value.response = { _, step in
                if step == 1 { return try marker(["action": "begin", "folderId": "fixture"]) }
                return try marker(["action": "run", "command": "/bin/sleep 60 & child=$!; printf '%s' \"$child\" > child.pid; wait; touch replayed.txt"])
            }; return value
        }, trustedStorage: stage.appendingPathComponent("Stop Workspaces"), trustedSandbox: sandbox)
        defer { stopping.close() }
        await stopping.dispatch(["action": "connect", "conversationID": UUID().uuidString, "participants": ["codex", "claude"], "projectFolders": folders, "trustedFolderIDs": ["fixture"]])
        let stoppedID = UUID().uuidString
        await stopping.dispatch(["action": "send", "requestId": stoppedID, "text": "Run a cancellable synthetic command.", "targets": ["codex", "claude"]])
        var stopWork: URL?, child: Int32?
        try await wait("owned command pid") {
            for event in stopEvents.reversed() {
                guard let receipt = event["receipt"] as? [String: Any], let path = receipt["worktreePath"] as? String else { continue }
                let work = URL(fileURLWithPath: path)
                if let text = try? String(contentsOf: work.appendingPathComponent("child.pid"), encoding: .utf8), let pid = Int32(text) { stopWork = work; child = pid; return true }
            }
            return false
        }
        await stopping.dispatch(["action": "stop"])
        try await wait("stopped turn settled") { stopEvents.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == stoppedID } }
        try await wait("stopped engine evidence") { stopEvents.contains { ($0["receipt"] as? [String: Any])?["status"] as? String == "stopped" && ($0["receipt"] as? [String: Any])?["finishedAt"] != nil } }
        try check(stopTransports["claude"]!.prompts.isEmpty && stopEvents.contains { $0["type"] as? String == "finished" && $0["agent"] as? String == "claude" && $0["status"] as? String == "cancelled" }, "Stop during host execution cancels following speaker before dispatch")
        try check(child.map { kill($0, 0) != 0 && errno == ESRCH } == true && !FileManager.default.fileExists(atPath: stopWork!.appendingPathComponent("replayed.txt").path), "room Stop terminates owned command group and prevents replay")

        var revokeEvents: [[String: Any]] = [], revokeTransport: TrustedRoomFixtureTransport?
        let revoking = NativeRoom(emit: { revokeEvents.append($0) }, factory: { agent, _ in
            let value = TrustedRoomFixtureTransport(agent); revokeTransport = value
            value.response = { _, step in step == 1 ? try marker(["action": "begin", "folderId": "fixture"]) : "Synthetic provider failed before completing its workspace." }
            value.failedAt = 2; return value
        }, trustedStorage: stage.appendingPathComponent("Revoke Workspaces"), trustedSandbox: sandbox)
        defer { revoking.close() }
        let revokeRoomID = UUID().uuidString
        await revoking.dispatch(["action": "connect", "conversationID": revokeRoomID, "participants": ["eve"], "projectFolders": folders, "trustedFolderIDs": ["fixture"]])
        let revokeID = UUID().uuidString
        await revoking.dispatch(["action": "send", "requestId": revokeID, "text": "Prepare a synthetic workspace.", "targets": ["eve"]])
        try await wait("failed turn leaving retained workspace") { revokeEvents.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == revokeID } }
        let activeReceipt = revokeEvents.compactMap { $0["receipt"] as? [String: Any] }.last!
        let oldWork = URL(fileURLWithPath: activeReceipt["worktreePath"] as! String)
        let oldReceipt = oldWork.deletingLastPathComponent().appendingPathComponent("receipt.json")
        let retired = revokeTransport!
        await revoking.dispatch(["action": "connect", "conversationID": revokeRoomID, "participants": ["eve"], "projectFolders": folders, "trustedFolderIDs": []])
        try await wait("revoked workspace finalization") {
            guard let data = try? Data(contentsOf: oldReceipt), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return value["status"] as? String == "stopped" && value["finishedAt"] != nil
        }
        try check(retired.closed && revokeTransport!.snapshots.first?.contains("CURRENT TRUSTED STAGING CAPABILITIES") == false, "reconnect revokes old workspace and removes trusted capability")
        let beforeRevokeRequests = revokeEvents.filter { $0["type"] as? String == "workspaceReceipt" }.count
        revokeTransport!.failedAt = nil
        revokeTransport!.response = { _, step in step == 1 ? try marker(["action": "write", "path": "revoked.swift", "content": "bad", "expectedSha256": NSNull()]) : "Trusted editing is unavailable." }
        let afterRevokeID = UUID().uuidString
        await revoking.dispatch(["action": "send", "requestId": afterRevokeID, "text": "Try the old workspace after revocation.", "targets": ["eve"]])
        try await wait("post-revoke attempt") { revokeEvents.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == afterRevokeID } }
        try check(!FileManager.default.fileExists(atPath: oldWork.appendingPathComponent("revoked.swift").path) && revokeEvents.filter { $0["type"] as? String == "workspaceReceipt" }.count == beforeRevokeRequests, "revoked in-room write cannot resume or mutate retained private workspace")
        print("\(checks) trusted room integration checks passed. Synthetic fixture: \(stage.path)")
    }
}
