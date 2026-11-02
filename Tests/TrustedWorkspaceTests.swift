import Foundation
import Darwin

@MainActor final class CorrectingBuilderTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var sends = 0
    var correctionSeen = false
    let alwaysMalformed: Bool
    init(alwaysMalformed: Bool = false) { self.alwaysMalformed = alwaysMalformed }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = ProviderIdentity(id: "format-fixture", started: false, model: "fixture", runId: nil, requestId: nil, turnId: nil)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        sends += 1
        if text.contains("FORMAT REJECTED. No operation executed.") { correctionSeen = true }
        let response: String
        if alwaysMalformed || sends == 1 { response = "```\n<<BUILDER_WRITE {\"path\":\"greeting.txt\",\"content\":\"WRONG\",\"expectedSha256\":null}>>\n```" }
        else if sends == 2 { response = "<<BUILDER_READ {\"path\":\"greeting.txt\"}>>" }
        else if sends == 3 {
            let data = Data(text[text.index(after: text.firstIndex(of: "\n")!)...].utf8)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let hash = (object["result"] as! [String: Any])["sha256"] as! String
            response = "<<BUILDER_WRITE " + (try nativeJSON(["path": "greeting.txt", "content": "hello team\n", "expectedSha256": hash])) + ">>"
        } else { response = "Updated the greeting; commands have not yet run." }
        eventHandler?(.replace(response)); eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws {}
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture") }
}

@main struct TrustedWorkspaceTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0
        func check(_ valid: Bool, _ name: String) throws {
            guard valid else { throw nativeFailure("FAIL " + name) }
            passed += 1; print("PASS " + name)
        }
        let fixture = try NativeTemporaryDirectory.canonical(FileManager.default.temporaryDirectory).appendingPathComponent("silkwire-trusted-" + UUID().uuidString)
        let source = fixture.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: source.appendingPathComponent("greeting.txt"))
        let env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        for args in [["init"], ["add", "greeting.txt"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid.local", "commit", "-m", "Fixture"]] {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: source, environment: env)
            guard result.exitCode == 0 else { throw nativeFailure("Cannot prepare synthetic Git fixture.") }
        }
        var latest: [String: Any] = [:]
        let eve = NativeBuilder(onReceipt: { latest = $0 }, storageRoot: fixture.appendingPathComponent("eve-runs"), ownership: HostOwnershipDefault.coordinator)
        let claude = NativeBuilder(onReceipt: { _ in }, storageRoot: fixture.appendingPathComponent("claude-runs"), ownership: HostOwnershipDefault.coordinator)
        let first = try await eve.beginTrusted(source: source, task: "Update greeting, build and test", owner: "eve")
        let second = try await claude.beginTrusted(source: source, task: "Independent review", owner: "claude")
        try check(eve.trustedActive && claude.trustedActive && first["worktreePath"] as? String != second["worktreePath"] as? String, "agents get separate private workspaces")
        let listing = try await eve.trustedOperation(["action": "list", "path": ""])
        try check(listing["ok"] as? Bool == true && listing["owner"] as? String == "eve", "scoped listing includes owner identity")
        let read = try await eve.trustedOperation(["action": "read", "path": "greeting.txt"])
        let written = try await eve.trustedOperation(["action": "write", "path": "greeting.txt", "content": "hello team\n", "expectedSha256": read["sha256"]!])
        try check(written["ok"] as? Bool == true, "hash-checked private edit")
        let stale = try await eve.trustedOperation(["action": "write", "path": "greeting.txt", "content": "stale", "expectedSha256": read["sha256"]!])
        try check(stale["ok"] as? Bool == false, "stale edit rejected without replacing file")
        let other = try await claude.trustedOperation(["action": "read", "path": "greeting.txt"])
        try check(other["content"] as? String == "hello\n", "one agent cannot alter another agent's workspace")
        let code = try await eve.trustedOperation(["action": "write", "path": "greeting.swift", "content": "print(\"hello team\")\n", "expectedSha256": NSNull()])
        guard code["ok"] as? Bool == true else { throw nativeFailure("Cannot prepare synthetic Swift code") }
        let checkpoint = try await eve.trustedOperation(["action": "checkpoint", "summary": "Commit greeting before building"])
        try check(checkpoint["ok"] as? Bool == true && checkpoint["headCommit"] as? String != first["baseCommit"] as? String && eve.trustedActive, "checkpoint records a private head while leaving checks available")
        let script = try await eve.trustedOperation(["action": "run", "command": "/usr/bin/swift greeting.swift"])
        try check(script["ok"] as? Bool == true && script["output"] as? String == "hello team\n", "Swift script interpreter uses private module cache without extra flags")
        let buildCommand = "/usr/bin/swiftc -module-cache-path \"$TMPDIR/modules\" greeting.swift -o greeting"
        let built = try await eve.trustedOperation(["action": "run", "command": buildCommand])
        let testCommand = "./greeting > greeting.actual && /usr/bin/printf 'hello team\\n' > greeting.expected && /usr/bin/cmp greeting.expected greeting.actual"
        let tested = try await eve.trustedOperation(["action": "run", "command": testCommand])
        try check(built["ok"] as? Bool == true && tested["ok"] as? Bool == true && tested["status"] as? String == "passed" && built["command"] as? String == buildCommand && tested["command"] as? String == testCommand, "actual local build/test commands run with exact receipts without command substitution")
        let failed = try await eve.trustedOperation(["action": "run", "command": "printf 'expected failure'; exit 17"])
        try check(failed["ok"] as? Bool == false && (failed["exitCode"] as? Int32) == 17 && failed["output"] as? String == "expected failure", "failed command retains exit and output")
        let outside = fixture.appendingPathComponent("outside.txt")
        let blocked = try await eve.trustedOperation(["action": "run", "command": "/usr/bin/touch '" + outside.path + "'"])
        try check(blocked["ok"] as? Bool == false && !FileManager.default.fileExists(atPath: outside.path), "sandbox denies outside writes")
        let sourceWrite = try await eve.trustedOperation(["action": "run", "command": "printf bad > '" + source.appendingPathComponent("greeting.txt").path + "'"])
        try check(sourceWrite["ok"] as? Bool == false, "sandbox denies source writes")
        let homeRead = try await eve.trustedOperation(["action": "run", "command": "/bin/cat '" + source.appendingPathComponent("greeting.txt").path + "'"])
        // Temporary fixtures can live outside HOME, so verify a known home file
        // only when the checkout itself is inside home.
        if FileManager.default.currentDirectoryPath.hasPrefix(NSHomeDirectory() + "/") {
            let secretRead = try await eve.trustedOperation(["action": "run", "command": "/bin/cat '" + FileManager.default.currentDirectoryPath + "/README.md'"])
            try check(secretRead["ok"] as? Bool == false, "sandbox denies unrelated home reads")
        }
        _ = homeRead
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw nativeFailure("Cannot create local network fixture") }
        defer { close(listener) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw nativeFailure("Cannot bind local network fixture") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else { throw nativeFailure("Cannot inspect local network fixture") }
        let port = UInt16(bigEndian: address.sin_port)
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        let reachable = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, length) }
        }
        close(probe)
        guard reachable == 0 else { throw nativeFailure("Local fixture is not reachable outside sandbox") }
        let network = try await eve.trustedOperation(["action": "run", "command": "/usr/bin/curl --max-time 2 --noproxy '*' http://127.0.0.1:\(port)"])
        // An available listener would accept the TCP connection and time out
        // waiting for HTTP (28). Sandbox denial fails immediately to connect (7).
        try check(network["ok"] as? Bool == false && network["exitCode"] as? Int32 == 7, "sandbox denies connection to independently reachable local listener")
        let gitWrite = try await eve.trustedOperation(["action": "run", "command": "/usr/bin/git update-ref refs/heads/escape HEAD"])
        try check(gitWrite["ok"] as? Bool == false, "Git command metadata remains immutable")
        let traversal = try await eve.trustedOperation(["action": "write", "path": "../escape", "content": "bad", "expectedSha256": NSNull()])
        try check(traversal["ok"] as? Bool == false, "file broker rejects traversal")
        let oversized = try await eve.trustedOperation(["action": "write", "path": "huge.txt", "content": String(repeating: "x", count: 262145), "expectedSha256": NSNull()])
        try check(oversized["ok"] as? Bool == false, "file size bound enforced before write")
        let output = try await eve.trustedOperation(["action": "run", "command": "/usr/bin/yes x | /usr/bin/head -c 100000"])
        try check(output["outputTruncated"] as? Bool == true && (output["output"] as? String)?.utf8.count == 65536, "command output capped with honest truncation")
        let done = try await eve.finishTrusted(summary: "Greeting changed and local command evidence returned")
        try check(!eve.trustedActive && done["sourceUnchanged"] as? Bool == true && done["status"] as? String == "review", "finish verifies unchanged source and ends capability")
        try check((done["diff"] as? String)?.contains("hello team") == true && done["editingVerified"] as? Bool == true, "finish returns actual diff evidence")
        try check(try String(contentsOf: source.appendingPathComponent("greeting.txt"), encoding: .utf8) == "hello\n", "original file bytes untouched")
        let receipt = URL(fileURLWithPath: done["worktreePath"] as! String).deletingLastPathComponent().appendingPathComponent("receipt.json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
        let savedSteps = saved["steps"] as? [[String: Any]] ?? []
        try check(savedSteps.first?["command"] as? String == "/usr/bin/swift greeting.swift" && savedSteps.filter { $0["command"] as? String == buildCommand }.count == 1 && saved["owner"] as? String == "eve", "durable exact command and owner receipt")
        let big = String(repeating: "b", count: 262144)
        _ = try await claude.trustedOperation(["action": "write", "path": "budget.txt", "content": big, "expectedSha256": NSNull()])
        for _ in 0..<30 {
            let chunk = try await claude.trustedOperation(["action": "read", "path": "budget.txt"])
            guard chunk["ok"] as? Bool == true else { throw nativeFailure("Budget fixture rejected an in-budget read") }
        }
        let exhaustedData = try await claude.trustedOperation(["action": "read", "path": "budget.txt"])
        try check(exhaustedData["ok"] as? Bool == false && (exhaustedData["error"] as? String)?.contains("8 MB") == true, "8 MB file-data budget enforced across operations")
        _ = try await claude.finishTrusted(summary: "Independent budget check complete")
        let budgetOwner = NativeBuilder(onReceipt: { latest = $0 }, storageRoot: fixture.appendingPathComponent("budget-runs"), ownership: HostOwnershipDefault.coordinator)
        _ = try await budgetOwner.beginTrusted(source: source, task: "Check operation bound", owner: "budget")
        for _ in 0..<128 { _ = try await budgetOwner.trustedOperation(["action": "list", "path": ""]) }
        var exhaustedOps = false
        do { _ = try await budgetOwner.trustedOperation(["action": "list", "path": ""]) } catch { exhaustedOps = true }
        try check(exhaustedOps, "128 operation bound prevents further execution")
        budgetOwner.stop()
        let idleStop = try await budgetOwner.finishTrusted(summary: "Stopped idle budget fixture")
        try check(idleStop["status"] as? String == "stopped", "idle Stop and finish join one final receipt")

        let stopper = NativeBuilder(onReceipt: { latest = $0 }, storageRoot: fixture.appendingPathComponent("stop-runs"), ownership: HostOwnershipDefault.coordinator)
        let stopStart = try await stopper.beginTrusted(source: source, task: "Cancellation check", owner: "codex")
        let work = URL(fileURLWithPath: stopStart["worktreePath"] as! String)
        let pending = Task { @MainActor in
            try await stopper.trustedOperation(["action": "run", "command": "/bin/sleep 60 & child=$!; printf '%s' \"$child\" > child.pid; wait; touch replayed.txt"])
        }
        var child: Int32?
        for _ in 0..<200 {
            if let text = try? String(contentsOf: work.appendingPathComponent("child.pid"), encoding: .utf8), let pid = Int32(text) { child = pid; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(child != nil, "owned command descendant actually started")
        var concurrentRejected = false
        do { _ = try await stopper.trustedOperation(["action": "write", "path": "concurrent.txt", "content": "bad", "expectedSha256": NSNull()]) } catch { concurrentRejected = true }
        try check(concurrentRejected && !FileManager.default.fileExists(atPath: work.appendingPathComponent("concurrent.txt").path), "concurrent operation is rejected rather than queued")
        stopper.stop()
        let stopFinish = Task { @MainActor in try await stopper.finishTrusted(summary: "Stopped") }
        var stoppedRejected = false
        do { _ = try await pending.value } catch { stoppedRejected = true }
        try check(stoppedRejected, "stopped in-flight operation cannot report success")
        let stoppedReceipt = try await stopFinish.value
        try check(stoppedReceipt["status"] as? String == "stopped", "finish joins stopped evidence rather than replaying")
        try check(!stopper.trustedActive && latest["status"] as? String == "stopped" && latest["sourceUnchanged"] as? Bool == true, "Stop produces stopped evidence without replay")
        if let child { try check(kill(child, 0) != 0 && errno == ESRCH, "Stop terminates descendant process group") }
        try check(!FileManager.default.fileExists(atPath: work.appendingPathComponent("replayed.txt").path), "no command continuation after Stop")
        var followupRejected = false
        do { _ = try await stopper.trustedOperation(["action": "run", "command": "touch replayed.txt"]) } catch { followupRejected = true }
        try check(followupRejected && !FileManager.default.fileExists(atPath: work.appendingPathComponent("replayed.txt").path), "stopped workspace rejects follow-up execution")

        let corrective = CorrectingBuilderTransport()
        let legacy = NativeBuilder(onReceipt: { latest = $0 }, storageRoot: fixture.appendingPathComponent("legacy"), makeTransport: { corrective }, ownership: HostOwnershipDefault.coordinator)
        await legacy.start(source: source, task: "Update greeting", build: "/usr/bin/true", test: "", edit: true)
        try check(latest["status"] as? String == "review" && latest["formatFailures"] as? Int == 1 && corrective.correctionSeen, "malformed legacy request gets bounded corrective feedback")
        try check((latest["fileOperations"] as? [[String: Any]])?.count == 2, "malformed request executes no operation")
        let invalid = CorrectingBuilderTransport(alwaysMalformed: true)
        let failing = NativeBuilder(onReceipt: { latest = $0 }, storageRoot: fixture.appendingPathComponent("invalid"), makeTransport: { invalid }, ownership: HostOwnershipDefault.coordinator)
        await failing.start(source: source, task: "Reject malformed requests", build: "/usr/bin/true", test: "", edit: true)
        try check(latest["status"] as? String == "failed" && invalid.sends == 3 && latest["formatFailures"] as? Int == 3 && (latest["fileOperations"] as? [[String: Any]])?.isEmpty == true, "malformed retries bounded to two with no relaxed validation")
        try Data("pending local work\n".utf8).write(to: source.appendingPathComponent("pending.txt"))
        let dirty = NativeBuilder(onReceipt: { latest = $0 }, storageRoot: fixture.appendingPathComponent("dirty"), ownership: HostOwnershipDefault.coordinator)
        var dirtyRejected = false
        do { _ = try await dirty.beginTrusted(source: source, task: "Reject dirty source", owner: "dirty") } catch { dirtyRejected = true }
        try check(dirtyRejected && !dirty.trustedActive && latest["status"] as? String == "failed" && (latest["message"] as? String)?.contains("uncommitted") == true, "shared clean-source preflight rejects pending local work")
        print("\(passed) trusted workspace checks passed. Synthetic fixture: \(fixture.path)")
    }
}
