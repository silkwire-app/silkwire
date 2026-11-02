import Foundation
import Darwin

@main struct NativeTransportTests {
    static func json(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); print(String(decoding: data, as: UTF8.self)); fflush(stdout) }
    static func codexFixture() {
        let directory = FileManager.default.currentDirectoryPath
        var started = FileManager.default.fileExists(atPath: directory + "/saved-completed-mode"), serial = 0
        var injectedPolicy: String?
        let activeMode = FileManager.default.fileExists(atPath: directory + "/active-mode")
        let noRolloutMode = FileManager.default.fileExists(atPath: directory + "/no-rollout-mode")
        while let line = readLine() {
            guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { exit(20) }
            guard let method = request["method"] as? String else { if request["id"] as? Int == 999 { try? Data("denied".utf8).write(to: URL(fileURLWithPath: directory + "/tool-denied")) }; continue }
            guard let id = request["id"] else { continue }
            var result: [String: Any] = [:]
            switch method {
            case "initialize":
                guard (request["params"] as? [String:Any])?["capabilities"] as? [String:Bool] == ["experimentalApi":true] else { exit(24) }
            case "config/read": result = ["config": ["model_provider": "openai", "web_search": "disabled", "features": Dictionary(uniqueKeysWithValues: ["view_image", "image_generation", "shell_tool", "multi_agent", "multi_agent_v2", "apps", "plugins", "hooks", "code_mode", "code_mode_host", "skill_search", "memories", "goals", "remote_plugin", "enable_mcp_apps", "skill_mcp_dependency_install"].map { ($0, false) })]]
            case "account/read": result = ["account": ["type": FileManager.default.fileExists(atPath: directory + "/api-mode") ? "apiKey" : "chatgpt", "email": "fixture@example.invalid"]]
            case "account/rateLimits/read": result = ["ordinaryUsageAllowed": !FileManager.default.fileExists(atPath: directory + "/blocked-usage-mode"), "rateLimits": ["primary": ["usedPercent": 12, "windowDurationMins": 300]]]
            case "model/list": result = ["data": [["isDefault": true, "model": "fixture-model", "displayName": "Fixture", "supportedReasoningEfforts": []]]]
            case "thread/start", "thread/resume":
                let params = request["params"] as? [String:Any] ?? [:]
                guard let base = params["baseInstructions"] as? String, let developer = params["developerInstructions"] as? String, developer == base, !developer.contains("CURRENT PROJECT CAPABILITIES") else { exit(27) }
                if method == "thread/resume", params["excludeTurns"] as? Bool != true { exit(41) }
                if method == "thread/resume", !started, noRolloutMode, !activeMode { json(["id": id, "error": ["message": "no rollout found"]]); continue }
                if method == "thread/resume", !started, !activeMode { exit(21) } // A fresh unstarted thread must NEVER be resumed.
                result = ["thread": ["id": "fixture-thread", "status": activeMode ? "active" : "idle"], "sandbox": ["type": "readOnly", "networkAccess": false], "approvalPolicy": "on-request", "approvalsReviewer": "user", "cwd": directory, "instructionSources": [], "modelProvider": "openai", "model":"fixture-model", "reasoningEffort":"medium"]
            case "thread/read":
                guard (request["params"] as? [String: Any])?["includeTurns"] as? Bool == false else { exit(42) }
                result = ["thread": ["id": "fixture-thread", "status": activeMode ? "active" : "idle"]]
            case "thread/turns/list":
                let params = request["params"] as? [String: Any] ?? [:]
                guard params["itemsView"] as? String == "notLoaded", params["limit"] as? Int == 50 else { exit(43) }
                if FileManager.default.fileExists(atPath: directory + "/cursor-loop-mode") {
                    result = ["data": [], "nextCursor": "loop"]
                } else if FileManager.default.fileExists(atPath: directory + "/paged-turn-mode"), params["cursor"] == nil {
                    result = ["data": [["id": "newer-turn", "status": "completed"]], "nextCursor": "older"]
                } else {
                    result = ["data": activeMode ? [["id": "old-turn", "status": "inProgress"]] : started ? [["id": "previous", "status": "completed"]] : []]
                }
            case "thread/items/list":
                let params = request["params"] as? [String: Any] ?? [:]
                guard params["turnId"] as? String == "previous", params["limit"] as? Int == 1, params["sortDirection"] as? String == "asc" else { exit(44) }
                let foreign = FileManager.default.fileExists(atPath: directory + "/foreign-item-mode")
                if params["cursor"] == nil {
                    result = ["data": [["turnId": "previous", "item": ["type": "userMessage", "content": []]]], "nextCursor": "reply"]
                } else {
                    result = ["data": [["turnId": foreign ? "foreign" : "previous", "item": ["type": "agentMessage", "text": "Recovered fixture"]]]]
                }
            case "mcpServerStatus/list": result = ["data": []]
            case "experimentalFeature/list": result = ["data": ["view_image", "image_generation", "shell_tool", "multi_agent", "multi_agent_v2", "apps", "plugins", "hooks", "code_mode", "code_mode_host", "skill_search", "memories", "goals", "remote_plugin", "enable_mcp_apps", "skill_mcp_dependency_install"].map { ["name": $0, "enabled": false] as [String: Any] }]
            case "thread/inject_items":
                let params = request["params"] as? [String: Any] ?? [:]
                guard params["threadId"] as? String == "fixture-thread", let items = params["items"] as? [[String: Any]], items.count == 2,
                      items[0]["role"] as? String == "system", items[1]["role"] as? String == "developer",
                      let base = (items[0]["content"] as? [[String: Any]])?.first?["text"] as? String,
                      let policy = (items[1]["content"] as? [[String: Any]])?.first?["text"] as? String,
                      policy.hasPrefix(base + "\n\n"), base.contains("READ_PROJECT"), base.contains("WORK_PROJECT"), base.contains("CURRENT TRUSTED STAGING"), base.contains("host-produced receipts"), base.contains("Native runtime filesystem tools") else { exit(28) }
                if FileManager.default.fileExists(atPath: directory + "/reject-policy-mode") { json(["id": id, "error": ["message": "synthetic policy update rejected"]]); continue }
                injectedPolicy = policy
            case "turn/start":
                try? Data().write(to: URL(fileURLWithPath: directory + "/turn-dispatched"))
                let params = request["params"] as? [String:Any] ?? [:]
                let mode = params["collaborationMode"] as? [String:Any] ?? [:]
                let settings = mode["settings"] as? [String:Any] ?? [:]
                guard mode["mode"] as? String == "default", settings["model"] as? String == "fixture-model", settings["reasoning_effort"] as? String == "medium", let policy = settings["developer_instructions"] as? String, policy.contains("READ_PROJECT") else { exit(25) }
                guard injectedPolicy == policy else { exit(29) }
                if let expected = try? String(contentsOfFile:directory + "/expected-policy",encoding:.utf8), !policy.hasSuffix(expected) { exit(26) }
                started = true; serial += 1; let turn = "turn-\(serial)"
                let imageMode = FileManager.default.fileExists(atPath: directory + "/early-image-mode")
                let imageEcho = String(repeating: "x", count: 750_000)
                if imageMode {
                    for method in ["item/started", "item/completed"] {
                        json(["method": method, "params": ["threadId": "fixture-thread", "turnId": turn, "item": ["type": "userMessage", "content": [["type": "image", "url": imageEcho]]]]])
                    }
                    for _ in 0..<1100 {
                        json(["method": "item/reasoning/summaryTextDelta", "params": ["threadId": "fixture-thread", "turnId": turn, "delta": "unused status"]])
                    }
                }
                if FileManager.default.fileExists(atPath: directory + "/early-output-overflow-mode") {
                    json(["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": turn, "delta": String(repeating: "x", count: 1024 * 1024)]])
                }
                if FileManager.default.fileExists(atPath: directory + "/early-count-overflow-mode") {
                    for _ in 0..<1025 { json(["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": turn, "delta": "x"]]) }
                }
                json(["method": "item/agentMessage/delta", "params": ["threadId": "wrong-thread", "turnId": turn, "delta": "BAD"]])
                json(["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": "wrong-turn", "delta": "BAD"]])
                // Output before acknowledgment tests the bounded early event buffer.
                json(["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": turn, "delta": "Fixture reply"]])
                json(["id": 999, "method": "unknown/runtimeTool", "params": ["threadId": "fixture-thread", "turnId": turn]])
                var terminal: [String: Any] = ["id": turn, "status": "completed"]
                if imageMode { terminal["items"] = [["type": "userMessage", "content": [["type": "image", "url": imageEcho + imageEcho]]]] }
                json(["method": "turn/completed", "params": ["threadId": "fixture-thread", "turn": terminal]])
                result = ["turn": ["id": turn]]
            case "turn/interrupt": break
            default: exit(22)
            }
            if ["thread/resume", "thread/read"].contains(method), FileManager.default.fileExists(atPath: directory + "/large-thread-mode") {
                // A legacy full-history request would exceed the 36 MiB frame bound.
                let params = request["params"] as? [String: Any] ?? [:]
                if params["excludeTurns"] as? Bool != true && params["includeTurns"] as? Bool != false {
                    result["syntheticPadding"] = String(repeating: "x", count: 40 * 1024 * 1024)
                }
            }
            json(["id": id, "result": result])
        }
    }
    static func claudeFixture() {
        if CommandLine.arguments.dropFirst().first == "auth" { json(["loggedIn": true, "authMethod": "claude.ai", "email": "fixture@example.invalid"]); return }
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--session-id") ?? args.firstIndex(of: "--resume"), args.contains("--restricted"), args.contains("--strict-mcp-config"), args.contains("--no-chrome"), let tools = args.firstIndex(of: "--tools"), args[tools + 1].isEmpty else { exit(23) }
        let id = args[index + 1]
        guard let systemIndex = args.firstIndex(of: "--system-prompt") else { exit(30) }
        let policy = args[systemIndex + 1]
        guard policy.contains("READ_PROJECT"), policy.contains("WORK_PROJECT"), policy.contains("CURRENT TRUSTED STAGING"), policy.contains("host-produced receipts"), policy.contains("no general tools") else { exit(31) }
        if let expected = try? String(contentsOfFile: FileManager.default.currentDirectoryPath + "/expected-claude-policy", encoding: .utf8), !policy.hasSuffix(expected) { exit(32) }
        _ = readLine()
        json(["type": "system", "subtype": "init", "session_id": id, "tools": FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/claude-tool-mode") ? ["Shell"] : []])
        json(["type": "stream_event", "event": ["delta": ["type": "text_delta", "text": "Fixture reply"]]])
        json(["type": "result", "subtype": "success", "is_error": false, "result": "Fixture reply"])
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("app-server") { codexFixture(); return }
        if CommandLine.arguments.contains("auth") || CommandLine.arguments.contains("-p") { claudeFixture(); return }
        if CommandLine.arguments.contains("--fixture-output") {
            for n in 0..<2000 { print("stdout-\(n)"); fputs("stderr-\(n)\n", stderr) }; return
        }
        if CommandLine.arguments.contains("--fixture-sleep") { sleep(20); return }
        if CommandLine.arguments.contains("--fixture-eof") { _ = readLine(); print("EOF"); return }
        if CommandLine.arguments.contains("--fixture-group") { print(getpid() == getpgrp() ? "isolated" : "shared"); return }
        if CommandLine.arguments.contains("--fixture-descendant") {
            let arguments: [String] = ["/bin/sh", "-c", "sleep 1; : > orphan-wrote"]
            let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            var child: pid_t = 0
            _ = argv.withUnsafeBufferPointer { posix_spawn(&child, "/bin/sh", nil, nil, UnsafeMutablePointer(mutating: $0.baseAddress!), environ) }
            for value in argv { if let value { free(value) } }
            return
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let cwd = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-transports-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        var count = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw nativeFailure("TEST: " + message) }; count += 1; print("PASS " + message) }
        let capture = try await NativeProcess.run(executable: executable, arguments: ["--fixture-output"], directory: cwd, environment: nativeProviderEnvironment())
        try check(capture.exitCode == 0 && capture.stdout.contains("stdout-1999") && capture.stderr.contains("stderr-1999") && !capture.truncated, "stdout/stderr fully drained before exit")
        let limited = try await NativeProcess.run(executable: executable, arguments: ["--fixture-output"], directory: cwd, environment: nativeProviderEnvironment(), outputLimit: 64)
        try check(limited.truncated && limited.stdout.utf8.count + limited.stderr.utf8.count <= 64, "capture output bounded")
        let start = Date()
        do { _ = try await NativeProcess.run(executable: executable, arguments: ["--fixture-sleep"], directory: cwd, environment: nativeProviderEnvironment(), timeoutSeconds: 0.05); throw nativeFailure("TEST timeout did not fail") } catch { try check(Date().timeIntervalSince(start) < 4, "process timeout stops group") }
        let group = try await NativeProcess.run(executable: executable, arguments: ["--fixture-group"], directory: cwd, environment: nativeProviderEnvironment())
        try check(group.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "isolated", "process group established atomically at spawn")
        let cancellationStart = Date()
        let cancelled = Task { try await NativeProcess.run(executable: executable, arguments: ["--fixture-sleep"], directory: cwd, environment: nativeProviderEnvironment()) }
        try await Task.sleep(nanoseconds: 30_000_000); cancelled.cancel()
        do { _ = try await cancelled.value; throw nativeFailure("TEST cancellation accepted") }
        catch is CancellationError { try check(Date().timeIntervalSince(cancellationStart) < 4, "structured task cancellation stops process group") }
        var stalled: NativeProcess?, stalledExited = false
        stalled = try NativeProcess(executable: executable, arguments: ["--fixture-sleep"], directory: cwd, environment: nativeProviderEnvironment(), stdout: { _ in }, stderr: { _ in }, onExit: { _ in stalledExited = true })
        let writeStart = Date(); try stalled!.write(Data(repeating: 65, count: 2 * 1024 * 1024))
        let unrelated = try await NativeProcess.run(executable: executable, arguments: ["--fixture-eof"], directory: cwd, environment: nativeProviderEnvironment())
        try check(unrelated.exitCode == 0 && unrelated.stdout.contains("EOF") && Date().timeIntervalSince(writeStart) < 0.8, "stalled writer does not block another process or the UI actor")
        for _ in 0..<80 where !stalledExited { try await Task.sleep(nanoseconds: 50_000_000) }
        try check(stalledExited && stalled?.isRunning == false, "incomplete pipe frame terminates owned process fail-closed")
        _ = try await NativeProcess.run(executable: executable, arguments: ["--fixture-descendant"], directory: cwd, environment: nativeProviderEnvironment())
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try check(!FileManager.default.fileExists(atPath: cwd.appendingPathComponent("orphan-wrote").path), "leader exit stops descendants before output drain completion")
        let codex = NativeCodexTransport(directory: cwd, executable: executable)
        var codexText = "", codexStatus = "", identityEvents = 0
        codex.eventHandler = { event in switch event { case .delta(let text): codexText += text; case .finished(let status, _): codexStatus = status; case .identity: identityEvents += 1; default: break } }
        let fresh = try await codex.connect(nil, capabilities: "No Project folders granted.")
        try check(fresh.id == "fixture-thread" && fresh.started == false, "Codex fresh identity confirmed")
        try await codex.send(text: "Synthetic fixture only", requestID: "test-request", attachments: [], capabilities: "No Project folders granted.")
        try check(codexStatus == "completed" && codexText == "Fixture reply" && identityEvents >= 2, "Codex early events gated by acknowledged thread and turn")
        try Data("Updated capabilities.".utf8).write(to:cwd.appendingPathComponent("expected-policy"))
        try await codex.send(text: "Synthetic second fixture only", requestID: "test-request-2", attachments: [], capabilities: "Updated capabilities.")
        try check(codexStatus == "completed" && codexText == "Fixture replyFixture reply", "Codex applies current per-turn instructions while preserving model and effort")
        let trustedCapabilities = "CURRENT TRUSTED STAGING CAPABILITIES: WORK_PROJECT begin|list|read|write|run|finish; private fixture workspace only."
        let trustedIdentity = codex.identity!.id
        try Data(trustedCapabilities.utf8).write(to: cwd.appendingPathComponent("expected-policy"))
        try await codex.send(text: "Synthetic trusted Staging request", requestID: "trusted-project", attachments: [], capabilities: trustedCapabilities)
        try check(codexStatus == "completed" && codex.identity?.id == trustedIdentity, "Codex authoritative trusted Staging broker policy reaches an existing session without replacing identity")
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("tool-denied").path), "unknown runtime tool request denied")
        let detail = try await codex.connectionDetail()
        try check(detail.signedIn && detail.models.count == 1 && detail.usage.first?.remainingPercent == 88, "connection catalog uses included account and usage")
        codex.close()
        let imageDirectory = cwd.appendingPathComponent("image-events")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try Data().write(to: imageDirectory.appendingPathComponent("early-image-mode"))
        let imageCodex = NativeCodexTransport(directory: imageDirectory, executable: executable)
        var imageText = "", imageStatus = "", imageDisconnected = false
        imageCodex.eventHandler = { event in
            switch event {
            case .delta(let text): imageText += text
            case .finished(let status, _): imageStatus = status
            case .disconnected: imageDisconnected = true
            default: break
            }
        }
        _ = try await imageCodex.connect(nil, capabilities: "Synthetic screenshot notification check")
        try await imageCodex.send(text: "Synthetic image echoes", requestID: "image-echoes", attachments: [], capabilities: "Synthetic screenshot notification check")
        try check(imageStatus == "completed" && imageText == "Fixture reply" && !imageDisconnected, "large image echoes, unused notification bursts and full terminal items do not exhaust the early reply buffer")
        imageCodex.close()
        for flag in ["early-output-overflow-mode", "early-count-overflow-mode"] {
            let boundedDirectory = cwd.appendingPathComponent("bounded-" + flag)
            try FileManager.default.createDirectory(at: boundedDirectory, withIntermediateDirectories: true)
            try Data().write(to: boundedDirectory.appendingPathComponent(flag))
            let bounded = NativeCodexTransport(directory: boundedDirectory, executable: executable)
            var uncertain = false, completed = false, failed = false
            bounded.eventHandler = { event in
                if case .disconnected(_, let value) = event { uncertain = value }
                if case .finished(let status, _) = event { completed = status == "completed" }
            }
            _ = try await bounded.connect(nil, capabilities: "Synthetic bound check")
            do { try await bounded.send(text: "Synthetic overflow", requestID: "overflow", attachments: [], capabilities: "Synthetic bound check") }
            catch { failed = true }
            try check(failed && uncertain && !completed && bounded.identity?.requestId == "overflow", "\(flag) still fails closed with unresolved identity preserved")
            bounded.close()
        }
        let freshChanged = NativeCodexTransport(directory: cwd, executable: executable)
        _ = try await freshChanged.connect(nil, capabilities: "Original")
        try Data("Changed".utf8).write(to:cwd.appendingPathComponent("expected-policy"))
        try await freshChanged.send(text: "Synthetic", requestID: "changed", attachments: [], capabilities: "Changed")
        try check(freshChanged.identity?.started == true, "fresh per-turn capabilities are applied without resume or replay"); freshChanged.close()
        try Data("No Project folders granted.".utf8).write(to:cwd.appendingPathComponent("expected-policy"))
        let revoked = NativeCodexTransport(directory:cwd,executable:executable)
        _ = try await revoked.connect(nil,capabilities:"Previously granted")
        try Data("Previously granted".utf8).write(to:cwd.appendingPathComponent("expected-policy"))
        try await revoked.send(text:"Synthetic grant",requestID:"granted",attachments:[],capabilities:"Previously granted")
        try Data("No Project folders granted.".utf8).write(to:cwd.appendingPathComponent("expected-policy"))
        try await revoked.send(text:"Synthetic revocation",requestID:"revoked",attachments:[],capabilities:"No Project folders granted.")
        try check(revoked.identity?.id == "fixture-thread", "revoked reader policy replaces prior permissions without replacing the saved identity"); revoked.close()
        var rejected = false
        try Data().write(to: cwd.appendingPathComponent("no-rollout-mode"))
        let noRollout = NativeCodexTransport(directory: cwd, executable: executable)
        let replacement = try await noRollout.connect(ProviderIdentity(id: "fixture-thread", started: false), capabilities: "Original")
        try check(replacement.started == false, "only known unstarted missing rollout may be replaced"); noRollout.close()
        try Data().write(to: cwd.appendingPathComponent("active-mode"))
        let active = NativeCodexTransport(directory: cwd, executable: executable)
        do { _ = try await active.connect(ProviderIdentity(id: "fixture-thread", started: true), capabilities: "Original"); throw nativeFailure("TEST accepted active saved thread") }
        catch { try check((error as NSError).userInfo["needsStop"] as? Bool == true, "active saved thread blocked with needsStop"); active.close() }
        let claude = NativeClaudeTransport(directory: cwd, executable: executable)
        var claudeText = "", claudeStatus = ""
        claude.eventHandler = { event in switch event { case .replace(let text): claudeText = text; case .finished(let status, _): claudeStatus = status; default: break } }
        let claudeID = try await claude.connect(nil, capabilities: "No folders")
        try await claude.send(text: "Synthetic fixture\n", requestID: "claude-request", attachments: [], capabilities: "No folders")
        for _ in 0..<100 where claudeStatus.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(claudeStatus == "completed" && claudeText == "Fixture reply" && claude.identity?.id == claudeID.id && claude.identity?.started == true, "Claude restricted stream and durable identity verified")
        claudeStatus = ""
        try Data(trustedCapabilities.utf8).write(to: cwd.appendingPathComponent("expected-claude-policy"))
        try await claude.send(text: "Synthetic trusted Staging request", requestID: "claude-trusted", attachments: [], capabilities: trustedCapabilities)
        for _ in 0..<100 where claudeStatus.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(claudeStatus == "completed" && claude.identity?.id == claudeID.id, "Claude resumes the same restricted session with current trusted Staging broker policy")
        try Data("No tools".utf8).write(to: cwd.appendingPathComponent("expected-claude-policy"))
        let claudeDetails = try await claude.connectionDetail()
        try check(claudeDetails.signedIn, "Claude existing-plan auth checked without API fallback"); claude.close()
        try Data().write(to: cwd.appendingPathComponent("claude-tool-mode"))
        let unsafeClaude = NativeClaudeTransport(directory: cwd, executable: executable)
        var unsafeClaudeStatus = ""
        unsafeClaude.eventHandler = { if case .finished(let status, _) = $0 { unsafeClaudeStatus = status } }
        _ = try await unsafeClaude.connect(nil, capabilities: "No tools")
        try await unsafeClaude.send(text: "Synthetic fixture\n", requestID: "unsafe-claude", attachments: [], capabilities: "No tools")
        for _ in 0..<100 where unsafeClaudeStatus.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(unsafeClaudeStatus == "failed", "Claude fails closed when init exposes a runtime tool"); unsafeClaude.close()
        let blockedDirectory = cwd.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        let blocked = NativeCodexTransport(directory: blockedDirectory, executable: executable)
        _ = try await blocked.connect(nil, capabilities: "No folders")
        try Data().write(to: blockedDirectory.appendingPathComponent("blocked-usage-mode"))
        rejected = false
        do { try await blocked.send(text: "Synthetic", requestID: "usage-blocked", attachments: [], capabilities: "No folders") } catch { rejected = true }
        try check(rejected && blocked.identity?.started == false, "Codex does not start a turn when included usage is unconfirmed"); blocked.close()
        let policyDirectory = cwd.appendingPathComponent("rejected-policy")
        try FileManager.default.createDirectory(at: policyDirectory, withIntermediateDirectories: true)
        try Data().write(to: policyDirectory.appendingPathComponent("reject-policy-mode"))
        let policyRejected = NativeCodexTransport(directory: policyDirectory, executable: executable)
        _ = try await policyRejected.connect(nil, capabilities: "Original")
        rejected = false
        do { try await policyRejected.send(text: "Synthetic user message", requestID: "policy-rejected", attachments: [], capabilities: trustedCapabilities) } catch { rejected = true }
        try check(rejected && policyRejected.identity?.started == false && policyRejected.identity?.requestId == nil && !FileManager.default.fileExists(atPath: policyDirectory.appendingPathComponent("turn-dispatched").path), "rejected authoritative trusted policy update prevents user-turn dispatch")
        policyRejected.close()
        try Data().write(to: blockedDirectory.appendingPathComponent("api-mode"))
        let api = NativeCodexTransport(directory: blockedDirectory, executable: executable)
        rejected = false
        do { _ = try await api.connect(nil, capabilities: "No folders") } catch { rejected = true }
        try check(rejected, "Codex API-key account rejected without fallback"); api.close()
        let recoveredDirectory = cwd.appendingPathComponent("recovered")
        try FileManager.default.createDirectory(at: recoveredDirectory, withIntermediateDirectories: true)
        try Data().write(to: recoveredDirectory.appendingPathComponent("saved-completed-mode"))
        let recovering = NativeCodexTransport(directory: recoveredDirectory, executable: executable)
        var recoveredRequest = "", recoveredText = "", recoveredStatus = ""
        recovering.eventHandler = { if case .recovery(let requestID, let status, let text) = $0 { recoveredRequest = requestID; recoveredStatus = status; recoveredText = text ?? "" } }
        let recoveredIdentity = try await recovering.connect(ProviderIdentity(id: "fixture-thread", started: true, requestId: "saved-request", turnId: "previous"), capabilities: "Current")
        try check(recoveredRequest == "saved-request" && recoveredStatus == "completed" && recoveredText == "Recovered fixture" && recoveredIdentity.turnId == nil && recoveredIdentity.requestId == nil, "exact saved turn recovered without replay; in-flight IDs cleared only after terminal evidence")
        try await recovering.stopPrevious()
        try check(recoveredText == "Recovered fixture" && recoveredStatus == "completed", "Stop Previous recovers a completed saved reply through bounded history, without interruption or replay")
        recovering.close()
        try Data().write(to: recoveredDirectory.appendingPathComponent("large-thread-mode"))
        let large = NativeCodexTransport(directory: recoveredDirectory, executable: executable)
        let largeStart = Date()
        let largeIdentity = try await large.connect(ProviderIdentity(id: "fixture-thread", started: true), capabilities: "Current")
        try check(largeIdentity.id == "fixture-thread" && Date().timeIntervalSince(largeStart) < 5, "history larger than frame bound reconnects with metadata only, without replay")
        large.close()
        try Data().write(to: recoveredDirectory.appendingPathComponent("paged-turn-mode"))
        let paged = NativeCodexTransport(directory: recoveredDirectory, executable: executable)
        var pagedText = ""
        paged.eventHandler = { if case .recovery(_, _, let text) = $0 { pagedText = text ?? "" } }
        _ = try await paged.connect(ProviderIdentity(id: "fixture-thread", started: true, requestId: "saved-request", turnId: "previous"), capabilities: "Current")
        try check(pagedText == "Recovered fixture", "exact older turn and reply recovered across metadata and item pages without full history")
        paged.close()
        for flag in ["cursor-loop-mode", "foreign-item-mode"] {
            try Data().write(to: recoveredDirectory.appendingPathComponent(flag))
            let invalidHistory = NativeCodexTransport(directory: recoveredDirectory, executable: executable)
            var failed = false
            do { _ = try await invalidHistory.connect(ProviderIdentity(id: "fixture-thread", started: true, requestId: "saved-request", turnId: "previous"), capabilities: "Current") } catch { failed = true }
            try check(failed && invalidHistory.identity?.turnId == "previous", "\(flag) fails closed preserving unresolved turn identity")
            invalidHistory.close()
            try FileManager.default.removeItem(at: recoveredDirectory.appendingPathComponent(flag))
        }
        let mismatched = NativeCodexTransport(directory: recoveredDirectory, executable: executable)
        rejected = false
        do { _ = try await mismatched.connect(ProviderIdentity(id: "fixture-thread", started: true, requestId: "saved-request", turnId: "wrong-turn"), capabilities: "Current") } catch { rejected = true }
        try check(rejected, "missing exact saved turn fails closed instead of recovering another reply"); mismatched.close()
        let hostShutdown = Task { @MainActor in
            try await NativeProcess.run(executable:"/bin/sh", arguments:["-c", "trap '' TERM; (: > shutdown-ready; /bin/sleep 1; : > shutdown-orphan-wrote) & wait"], directory:cwd, environment:nativeProviderEnvironment())
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath:cwd.appendingPathComponent("shutdown-ready").path) { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        NativeProcess.shutdownOwnedGroups()
        let shutdown = try await hostShutdown.value
        try await Task.sleep(for:.milliseconds(1200))
        try check(shutdown.exitCode >= 128 && !FileManager.default.fileExists(atPath:cwd.appendingPathComponent("shutdown-orphan-wrote").path), "host shutdown synchronously kills owned TERM-ignoring process groups")
        print("\(count) transport/process checks passed.")
    }
}
