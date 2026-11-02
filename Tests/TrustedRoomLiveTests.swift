import Foundation
import Darwin

// Explicit real-provider acceptance: the original room seats use their existing
// included accounts. All files, conversations and workspaces are synthetic.
@main struct TrustedRoomLiveTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard ProcessInfo.processInfo.environment["SILKWIRE_TRUSTED_ROOM_LIVE"] == "1" else {
            throw nativeFailure("Opt in with SILKWIRE_TRUSTED_ROOM_LIVE=1; this gate uses fresh synthetic provider conversations and existing included accounts.")
        }
        let requested = Set(CommandLine.arguments.dropFirst())
        let participants = agents.filter { requested.isEmpty || requested.contains($0) }
        guard !participants.isEmpty else { throw nativeFailure("Choose eve, claude and/or codex, or omit arguments for all three.") }
        let stage = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-trusted-room-live-" + UUID().uuidString)
        let source = stage.appendingPathComponent("Sources/repo")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let token = UUID().uuidString.lowercased()
        let original = "# Synthetic trusted Staging acceptance\nThis is a disposable fixture, not Jason's app or conversation library.\n"
        try Data(original.utf8).write(to: source.appendingPathComponent("README.md"))
        try Data(".cache/\nprogram-*\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
        let environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        for args in [["init"], ["add", "."], ["-c", "user.name=Synthetic Acceptance", "-c", "user.email=fixture@invalid.local", "commit", "-m", "Synthetic trusted room fixture"]] {
            let value = try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: source, environment: environment)
            guard value.exitCode == 0 else { throw nativeFailure("Cannot prepare synthetic trusted-room Git source.") }
        }
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/trusted-room-live/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let eventFile = artifacts.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: eventFile.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw nativeFailure("Cannot create synthetic event evidence.") }
        let eventHandle = try FileHandle(forWritingTo: eventFile)
        defer { try? eventHandle.close() }
        var events: [[String: Any]] = [], final: [String: [String: Any]] = [:], progress: [String: String] = [:]
        var evidenceWriteFailed = false
        // Default factory deliberately exercises the exact room connector path;
        // no substitute Builder model, model override or alternate API account.
        let room = NativeRoom(emit: { event in
            events.append(event)
            do {
                let text = NativeBuilder.scrub(try nativeJSON(event)) + "\n"
                try eventHandle.write(contentsOf: Data(text.utf8))
            } catch { evidenceWriteFailed = true }
            if event["type"] as? String == "connection", let agent = event["agent"] as? String, let state = event["state"] as? String {
                print("\(agent): \(state)")
            }
            if event["type"] as? String == "workspaceReceipt", let agent = event["agent"] as? String, let receipt = event["receipt"] as? [String: Any] {
                let state = "\(receipt["status"] ?? "unknown") · \((receipt["fileOperations"] as? [[String: Any]])?.count ?? 0) operations · \((receipt["steps"] as? [[String: Any]])?.count ?? 0) commands"
                if progress[agent] != state { progress[agent] = state; print("\(agent): \(state)") }
                if receipt["finishedAt"] != nil { final[agent] = receipt }
            }
        }, trustedStorage: stage.appendingPathComponent("Team Workspaces"), trustedSandbox: WorkspaceEnvironment(staging: true, library: stage))
        defer { room.close() }
        let roomID = UUID().uuidString
        print("Fresh synthetic room: " + roomID)
        print("Synthetic source: " + source.path)
        print("Evidence: " + artifacts.path)
        await room.dispatch(["action": "connect", "conversationID": roomID, "participants": participants,
                             "projectBrief": "Synthetic Staging capability test. The current human task authorizes changes/builds/tests only in each speaker's independent private copy. Do not hand off to Builder or change the source folder.",
                             "projectFolders": [["id": "fixture", "name": "Synthetic test source", "root": source.path]], "trustedFolderIDs": ["fixture"]])
        guard participants.allSatisfy({ agent in events.contains { $0["type"] as? String == "connection" && $0["agent"] as? String == agent && $0["state"] as? String == "connected" } }) else {
            throw nativeFailure("Not all requested original room seats connected; inspect synthetic events at " + artifacts.path)
        }
        let task = """
        This is an authorized synthetic Staging acceptance, not a planning discussion. Each teammate must IMPLEMENT, BUILD and TEST directly from this room using the offered WORK_PROJECT response-text protocol. No per-edit approval or Send to Builder handoff is needed.
        For your own agent name (eve, claude or codex), begin your independent workspace from folderId fixture. Create ONLY a new file named YOURNAME.swift containing exactly print("silkwire-YOURNAME-\(token)") followed by a newline, replacing YOURNAME with your actual lowercase agent name. A new file uses expectedSha256:null.
        Run the real compiler command /usr/bin/xcrun swiftc -module-cache-path .cache YOURNAME.swift -o program-YOURNAME, replacing YOURNAME. Inspect the actual exit code; fix any failure instead of claiming success. Then run ./program-YOURNAME and verify the exact output silkwire-YOURNAME-\(token). These commands are approved inside your private workspace. Do not install, merge, publish or touch the shared source.
        Finish your workspace with an accurate summary, then give Jason one short plain-English result stating whether compilation and execution actually passed. Each speaker must perform their own work even if a prior teammate completed their own file. Use exactly one offered marker per response and wait for the host result. If the host denies an operation, report it accurately. This fixture phrase is non-secret test data, not a credential.
        """
        let requestID = UUID().uuidString
        await room.dispatch(["action": "send", "requestId": requestID, "text": task, "targets": participants, "history": [], "attachments": []])
        let deadline = Date().addingTimeInterval(900)
        while !events.contains(where: { $0["type"] as? String == "settled" && $0["requestId"] as? String == requestID }) {
            guard Date() < deadline else {
                await room.dispatch(["action": "stop"])
                throw nativeFailure("Trusted-room real-provider gate exceeded 900 seconds; owned work stopped. Evidence: " + artifacts.path)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try eventHandle.synchronize()
        guard !evidenceWriteFailed else { throw nativeFailure("Synthetic event capture was incomplete; no complete evidence claim.") }
        var validation: [[String: Any]] = []
        for agent in participants {
            guard let receipt = final[agent], let worktree = receipt["worktreePath"] as? String,
                  receipt["owner"] as? String == agent, receipt["status"] as? String == "review", receipt["sourceUnchanged"] as? Bool == true,
                  receipt["editingVerified"] as? Bool == true else { throw nativeFailure(agent + " did not return a completed private-workspace receipt. Evidence: " + artifacts.path) }
            let phrase = "silkwire-" + agent + "-" + token
            let filename = agent + ".swift", code = "print(\"" + phrase + "\")\n"
            let steps = receipt["steps"] as? [[String: Any]] ?? []
            let compile = steps.contains { step in
                let command = step["command"] as? String ?? ""
                return command.contains("swiftc") && command.contains(filename) && (step["exitCode"] as? NSNumber)?.intValue == 0 && step["status"] as? String == "passed" && step["outputTruncated"] as? Bool != true
            }
            let executed = steps.contains { step in
                let command = step["command"] as? String ?? ""
                return command.contains("./program-" + agent) && (step["exitCode"] as? NSNumber)?.intValue == 0 && step["status"] as? String == "passed" && step["output"] as? String == phrase + "\n" && step["outputTruncated"] as? Bool != true
            }
            guard compile, executed,
                  try String(contentsOf: URL(fileURLWithPath: worktree).appendingPathComponent(filename), encoding: .utf8) == code,
                  (receipt["diff"] as? String)?.contains("+print(\"" + phrase + "\")") == true,
                  !FileManager.default.fileExists(atPath: source.appendingPathComponent(filename).path),
                  events.contains(where: { $0["type"] as? String == "finished" && $0["agent"] as? String == agent && $0["requestId"] as? String == requestID && $0["status"] as? String == "completed" }) else {
                throw nativeFailure(agent + " lacked exact compile/run/file/diff evidence. Inspect " + artifacts.path)
            }
            let visible = events.filter { $0["agent"] as? String == agent && ["delta", "replace"].contains($0["type"] as? String ?? "") }.compactMap { $0["text"] as? String }
            guard !visible.contains(where: { $0.contains("<<WORK_PROJECT") }) else { throw nativeFailure(agent + " execution marker leaked into visible transcript.") }
            validation.append(["agent": agent, "workspace": worktree, "receiptID": receipt["id"] ?? "", "compilePassed": true, "programOutput": phrase, "sourceUnchanged": true])
            print("PASS \(agent): original room speaker created, compiled, executed and returned real private diff without handoff")
        }
        guard Set(final.values.compactMap { $0["worktreePath"] as? String }).count == participants.count,
              try String(contentsOf: source.appendingPathComponent("README.md"), encoding: .utf8) == original else { throw nativeFailure("Workspace/source isolation evidence failed.") }
        let result = ["roomID": roomID, "source": source.path, "participants": participants, "checks": validation, "receipts": final] as [String: Any]
        let data = Data(NativeBuilder.scrub(try nativeJSON(result)).utf8)
        let summary = artifacts.appendingPathComponent("validated-results.json")
        try data.write(to: summary, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summary.path)
        print("PASS real trusted-room acceptance for \(participants.count) original speakers. Evidence: \(summary.path)")
    }
}
