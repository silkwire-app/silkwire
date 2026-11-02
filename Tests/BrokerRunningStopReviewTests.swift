import Foundation
import Darwin

// Independent review of the executing workspace-command Stop branch, not merely
// a parsed marker awaiting acknowledgement. Only a newly committed synthetic
// repository, private fixture storage and injected provider transports are used.
// This does not exercise a live provider, network inspection or mounted app UI.
@MainActor final class BrokerRunningStopTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var response: ((String, Int) throws -> String?)?
    var prompts: [String] = []
    var held: [CheckedContinuation<Void, Never>] = []
    var stopCalls = 0
    let agent: String
    init(_ agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = ProviderIdentity(id: "running-stop-fixture-" + agent, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text)
        if let reply = try response?(text, prompts.count) {
            eventHandler?(.delta(reply)); eventHandler?(.finished(status: "completed", message: nil))
        } else {
            eventHandler?(.delta("Synthetic teammate still working"))
            await withCheckedContinuation { held.append($0) }
        }
    }
    func release() { let values = held; held.removeAll(); for value in values { value.resume() } }
    func stop() async throws {
        stopCalls += 1
        eventHandler?(.finished(status: "interrupted", message: "Stopped synthetic transport"))
        release()
    }
    func stopPrevious() async throws {}
    func close() { release() }
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic fixture only") }
}

@main struct BrokerRunningStopReviewTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let files = FileManager.default
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL: " + label) }
            checks += 1; print("PASS: " + label)
        }
        func wait(_ label: String, seconds: Double = 20, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func marker(_ args: [String: Any]) throws -> String { "<<WORK_PROJECT " + (try nativeJSON(args)) + ">>" }
        func pid(_ file: URL) -> Int32? {
            (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let root = try NativeTemporaryDirectory.canonical(files.temporaryDirectory).appendingPathComponent("BrokerRunningStopReview-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        for openFloor in [true, false] {
            let label = openFloor ? "open floor" : "turn taking"
            let stage = root.appendingPathComponent(openFloor ? "open" : "sequential")
            let source = stage.appendingPathComponent("Sources/fixture")
            let home = stage.appendingPathComponent("fixture-home")
            try files.createDirectory(at: source, withIntermediateDirectories: true)
            try files.createDirectory(at: home, withIntermediateDirectories: true)
            let original = Data("# Private synthetic Stop fixture\n".utf8)
            try original.write(to: source.appendingPathComponent("README.md"))
            try Data("output/\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
            let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
            for args in [["init"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "-c", "commit.gpgsign=false", "commit", "-m", "Synthetic Stop source"]] {
                let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: source, environment: environment)
                guard result.exitCode == 0 else { throw nativeFailure("Synthetic Git preparation failed") }
            }
            var events: [[String: Any]] = []
            var transports: [String: BrokerRunningStopTransport] = [:]
            var worktree: URL?
            var normalReplies = false
            var factoryCalls = 0
            let command = "mkdir -p output; printf '%s' $$ > output/parent.pid; /bin/sleep 30 & child=$!; printf '%s' \"$child\" > output/child.pid; printf started > output/command.started; wait \"$child\"; printf finished > output/command.finished"
            let room = NativeRoom(emit: { event in
                events.append(event)
                if event["type"] as? String == "workspaceReceipt", let receipt = event["receipt"] as? [String: Any], receipt["status"] as? String == "active", let path = receipt["worktreePath"] as? String { worktree = URL(fileURLWithPath: path) }
            }, factory: { agent, _ in
                factoryCalls += 1
                let transport = BrokerRunningStopTransport(agent); transports[agent] = transport
                transport.response = { prompt, step in
                    if normalReplies { return agent + " answered the next Send" }
                    guard agent == "eve" else { return nil }
                    if step == 1 { return try marker(["action": "begin", "folderId": "fixture", "paths": ["fixture.txt"], "taskTitle": "Synthetic executing-command Stop fixture"]) }
                    if step == 2 {
                        guard worktree != nil else { throw nativeFailure("Synthetic nested workspace did not become active: " + String(prompt.suffix(2500))) }
                        return try marker(["action": "run", "command": command])
                    }
                    throw nativeFailure("Stopped command unexpectedly resumed its original provider turn: " + String(prompt.suffix(1500)))
                }
                return transport
            }, trustedStorage: stage.appendingPathComponent("Team Workspaces"), trustedSandbox: WorkspaceEnvironment(staging: true, library: stage), webPolicy: .init(hosts: []))
            defer { room.close() }
            await room.dispatch(["action": "connect", "conversationID": UUID().uuidString, "participants": agents, "projectFolders": [["id": "fixture", "name": "Synthetic source", "root": source.path]], "trustedFolderIDs": ["fixture"]])
            try check(factoryCalls == 3 && transports.count == 3, label + ": only three injected providers connect")
            let first = UUID().uuidString
            await room.dispatch(["action": "send", "requestId": first, "text": "Run only the synthetic slow check, then stop it.", "targets": agents, "openFloor": openFloor])
            do {
                try await wait(label + " actual command start", seconds: 25) {
                    guard let worktree else { return false }
                    return files.fileExists(atPath: worktree.appendingPathComponent("output/command.started").path)
                }
            } catch {
                for event in events where event["type"] as? String == "workspaceReceipt" || event["type"] as? String == "finished" {
                    print("Fixture evidence: " + ((try? nativeJSON(event)) ?? "unencodable event"))
                }
                for prompt in transports["eve"]?.prompts.dropFirst() ?? [] { print("Fixture host follow-up: " + String(prompt.suffix(3500))) }
                throw error
            }
            guard let worktree, worktree.path.hasPrefix(stage.path + "/Team Workspaces/"), let parent = pid(worktree.appendingPathComponent("output/parent.pid")), let child = pid(worktree.appendingPathComponent("output/child.pid")) else { throw nativeFailure("Missing real private command process evidence") }
            let output = worktree.appendingPathComponent("output")
            try check(kill(parent, 0) == 0 && kill(child, 0) == 0, label + ": both the actual shell and sleeping child are running")
            try check(!files.fileExists(atPath: output.appendingPathComponent("command.finished").path), label + ": command has not already finished before Stop")
            try check(events.contains { event in
                guard event["type"] as? String == "workspaceReceipt", let receipt = event["receipt"] as? [String: Any], let steps = receipt["steps"] as? [[String: Any]] else { return false }
                return steps.contains { $0["command"] as? String == command && $0["status"] as? String == "running" }
            }, label + ": host receipt independently records the executing command")
            try check(transports["eve"]?.prompts.count == 2, label + ": no command result or false completion arrived before Stop")
            if openFloor { try await wait("other synthetic streams") { transports["claude"]?.held.count == 1 && transports["codex"]?.held.count == 1 } }
            let stopTime = Date()
            await room.dispatch(["action": "stop"])
            try await wait(label + " room settles after Stop", seconds: 5) { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == first } }
            let firstEnds = events.filter { $0["type"] as? String == "finished" && $0["requestId"] as? String == first }
            try check(firstEnds.count == 3 && Set(firstEnds.compactMap { $0["agent"] as? String }).count == 3, label + ": Stop ends each requested teammate exactly once")
            try check(firstEnds.filter { $0["status"] as? String == "interrupted" }.count == (openFloor ? 3 : 1), label + ": every started teammate is interrupted")
            try check(firstEnds.filter { $0["status"] as? String == "cancelled" }.count == (openFloor ? 0 : 2), label + ": only unstarted sequential teammates are cancelled")
            try check(Date().timeIntervalSince(stopTime) < 5, label + ": room settles without waiting for the thirty-second command")
            normalReplies = true
            let second = UUID().uuidString
            await room.dispatch(["action": "send", "requestId": second, "text": "Next synthetic message", "targets": agents, "openFloor": openFloor])
            try await wait(label + " next message", seconds: 5) { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == second } }
            let nextEnds = events.filter { $0["type"] as? String == "finished" && $0["requestId"] as? String == second }
            try check(nextEnds.count == 3 && nextEnds.allSatisfy { $0["status"] as? String == "completed" }, label + ": all three teammates answer the next Send")
            try await wait(label + " actual process group termination", seconds: 10) { kill(parent, 0) != 0 && kill(child, 0) != 0 }
            try check(!files.fileExists(atPath: output.appendingPathComponent("command.finished").path), label + ": terminated child never reaches the late completion write")
            try await wait(label + " final stopped receipt", seconds: 20) {
                events.contains { event in
                    guard event["type"] as? String == "workspaceReceipt", let receipt = event["receipt"] as? [String: Any] else { return false }
                    return receipt["status"] as? String == "stopped" && receipt["finishedAt"] != nil
                }
            }
            guard let stopped = events.compactMap({ $0["receipt"] as? [String: Any] }).last(where: { $0["status"] as? String == "stopped" && $0["finishedAt"] != nil }), let step = (stopped["steps"] as? [[String: Any]])?.last else { throw nativeFailure("Missing stopped command receipt") }
            print("Stopped command evidence (" + label + "): " + ((try? nativeJSON(step)) ?? "unencodable step"))
            try check(step["command"] as? String == command && step["status"] as? String == "stopped" && (step["exitCode"] as? NSNumber).map { $0.int32Value != 0 } == true, label + ": interrupted command is recorded as stopped with a nonzero exit, never passed")
            try check(stopped["sourceUnchanged"] as? Bool == true && (try Data(contentsOf: source.appendingPathComponent("README.md"))) == original, label + ": original synthetic repository is unchanged")
            try await Task.sleep(for: .milliseconds(250))
            for request in [first, second] {
                try check(events.filter { $0["type"] as? String == "finished" && $0["requestId"] as? String == request }.count == 3 && events.filter { $0["type"] as? String == "settled" && $0["requestId"] as? String == request }.count == 1, label + ": late broker completion cannot duplicate replies or settlement for " + (request == first ? "stopped turn" : "next turn"))
            }
            try check(transports["eve"]?.stopCalls == 0, label + ": executing broker Stop does not masquerade as a provider stop")
            room.close()
        }
        print("BrokerRunningStopReviewTests: \(checks) checks passed; real private synthetic command execution, not live providers, web inspection or mounted UI")
    }
}
