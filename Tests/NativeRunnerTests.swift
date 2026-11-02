import Foundation
import Darwin

// Real host -> sandboxed test executable -> broker -> separately sandboxed
// workspace commands. Providers are synthetic; no installed app is launched.
@main struct NativeRunnerTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw nativeFailure("FAIL " + label) }
            print("PASS " + label)
        }
        func wait(_ label: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !predicate() {
                guard Date() < deadline else { throw nativeFailure("Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func repository(_ root: URL) async throws -> URL {
            let source = root.appendingPathComponent("source")
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("synthetic source\n".utf8).write(to: source.appendingPathComponent("note.txt"))
            let env = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
            for args in [["-c", "init.templateDir=", "init"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Synthetic native runner"]] {
                let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: args, directory: source, environment: env)
                guard result.exitCode == 0 else { throw nativeFailure(result.stderr) }
            }
            return source
        }
        let nested = CommandLine.arguments.contains("--nested") || CommandLine.arguments.contains("--hold")
        if nested {
            try check(NativeSandboxState.isSandboxed, "nested executable is inside a kernel sandbox")
            let fixture = try NativeTemporaryDirectory.createWorkspace()
            defer { try? fm.removeItem(at: fixture) }
            let source = try await repository(fixture)
            let engine = NativeBuilder(onReceipt: { _ in }, storageRoot: fixture.appendingPathComponent("runs"), ownership: HostOwnershipDefault.coordinator)
            let receipt = try await engine.beginTrusted(source: source, task: "Synthetic nested checks", owner: "codex")
            guard let path = receipt["worktreePath"] as? String else { throw nativeFailure("Missing nested worktree") }
            if CommandLine.arguments.contains("--hold") {
                let hostTMP = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
                try Data(path.utf8).write(to: hostTMP.appendingPathComponent("held-worktree"), options: .atomic)
                _ = try await engine.trustedOperation(["action": "run", "command": "mkdir -p output; printf '%s' $$ > output/parent.pid; sleep 90 & child=$!; printf '%s' \"$child\" > output/child.pid; touch output/started; wait; touch output/finished"])
                return
            }
            let command = try await engine.trustedOperation(["action": "run", "command": "printf nested-command-started"])
            try check(command["ok"] as? Bool == true && command["output"] as? String == "nested-command-started", "nested workspace starts a real shell command")
            for (label, target) in [("source", source.appendingPathComponent("note.txt")), ("sibling", fixture.appendingPathComponent("sibling.txt"))] {
                if label == "sibling" { try Data("private sibling".utf8).write(to: target) }
                let result = try await engine.trustedOperation(["action": "run", "command": "cat " + quote(target.path)])
                try check(result["ok"] as? Bool == false && (result["output"] as? String)?.contains("Operation not permitted") == true, "nested sandbox denies " + label + " reads")
            }
            let outside = fixture.appendingPathComponent("escape")
            setenv("SILKWIRE_COMMAND_SANDBOX", "0", 1)
            let denied = try await engine.trustedOperation(["action": "run", "command": "touch " + quote(outside.path)])
            try check(denied["ok"] as? Bool == false && !fm.fileExists(atPath: outside.path), "agent environment cannot disable write isolation")
            let metadata = try await engine.trustedOperation(["action": "run", "command": "git update-ref refs/heads/escape HEAD"])
            try check(metadata["ok"] as? Bool == false, "nested command cannot alter private Git metadata")
            let parentCanary = CommandLine.arguments.last!
            let read = try await engine.trustedOperation(["action": "run", "command": "cat " + quote(parentCanary)])
            try check(read["ok"] as? Bool == false && (read["output"] as? String)?.contains("Operation not permitted") == true, "protected home data stays inaccessible")
            let endpoint = ProcessInfo.processInfo.environment[NativeCommandBroker.environmentKey]!
            let responses = URL(fileURLWithPath: endpoint).appendingPathComponent("responses/forged")
            let tamper = try await engine.trustedOperation(["action": "run", "command": "touch " + quote(responses.path)])
            try check(tamper["ok"] as? Bool == false && !fm.fileExists(atPath: responses.path), "command cannot forge host broker responses")
            do {
                _ = try await NativeCommandBroker.Client(endpoint: endpoint).execute(.init(worktree: "/usr", temporary: "/private/tmp", repository: "/bin", executable: "/bin/sh", arguments: ["-c", "touch " + quote(outside.path)]))
                throw nativeFailure("FAIL escaped broker scope")
            } catch {
                try check(error.localizedDescription.contains("roots must stay inside"), "host rejects arbitrary roots instead of trusting the request")
            }
            setenv(NativeCommandBroker.environmentKey, "/dev/null", 1)
            let forged = try await engine.trustedOperation(["action": "run", "command": "touch " + quote(outside.path)])
            try check(forged["ok"] as? Bool == false && !fm.fileExists(atPath: outside.path), "forged broker endpoint fails closed")
            setenv(NativeCommandBroker.environmentKey, endpoint, 1)
            _ = try await engine.finishTrusted(summary: "Synthetic isolation checks complete")
            return
        }

        try check(!NativeSandboxState.isSandboxed, "outer native test owns the host launcher")
        setenv("SILKWIRE_COMMAND_SANDBOX", "1", 1)
        setenv(NativeCommandBroker.environmentKey, "/dev/null", 1)
        defer { unsetenv("SILKWIRE_COMMAND_SANDBOX"); unsetenv(NativeCommandBroker.environmentKey) }
        let root = try NativeTemporaryDirectory.createWorkspace()
        defer { try? fm.removeItem(at: root) }
        let source = try await repository(root)
        var receipts: [[String: Any]] = []
        let engine = NativeBuilder(onReceipt: { receipts.append($0) }, storageRoot: root.appendingPathComponent("runs"), ownership: HostOwnershipDefault.coordinator)
        let begin = try await engine.beginTrusted(source: source, task: "Run native tests through the actual host command sandbox", owner: "codex")
        let work = URL(fileURLWithPath: begin["worktreePath"] as! String)
        let output = work.appendingPathComponent("output")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let compiled = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for (from, to) in [("NativeRunnerTests", "runner"), ("BrokerRunningStopReviewTests", "stop"), ("libSilkwireCore.dylib", "libSilkwireCore.dylib")] {
            try fm.copyItem(at: compiled.appendingPathComponent(from), to: output.appendingPathComponent(to))
        }
        let canary = compiled.appendingPathComponent("protected-canary-" + UUID().uuidString)
        try Data("Synthetic protected home data\n".utf8).write(to: canary)
        defer { try? fm.removeItem(at: canary) }
        for command in ["DYLD_LIBRARY_PATH=\"$PWD/output\" ./output/runner --nested " + quote(canary.path), "DYLD_LIBRARY_PATH=\"$PWD/output\" ./output/stop"] {
            let result = try await engine.trustedOperation(["action": "run", "command": command])
            print(result["output"] as? String ?? "Missing nested output")
            try check(result["ok"] as? Bool == true, "native regression executable passes inside host isolation")
        }
        let operation = Task { try await engine.trustedOperation(["action": "run", "command": "DYLD_LIBRARY_PATH=\"$PWD/output\" ./output/runner --hold"]) }
        let temporary = URL(fileURLWithPath: begin["temporaryPath"] as! String)
        var held: URL?
        try await wait("nested long command started") {
            if let text = try? String(contentsOf: temporary.appendingPathComponent("held-worktree"), encoding: .utf8) { held = URL(fileURLWithPath: text) }
            return held.map { fm.fileExists(atPath: $0.appendingPathComponent("output/started").path) } == true
        }
        let parent = Int32(try String(contentsOf: held!.appendingPathComponent("output/parent.pid"), encoding: .utf8))!
        let child = Int32(try String(contentsOf: held!.appendingPathComponent("output/child.pid"), encoding: .utf8))!
        try check(kill(parent, 0) == 0 && kill(child, 0) == 0, "host observes live broker shell and child before outer Stop")
        engine.stop()
        do {
            _ = try await operation.value
            throw nativeFailure("FAIL outer Stop returned success")
        } catch { try check(error.localizedDescription.contains("Stopped"), "outer command returns a stopped outcome") }
        try await wait("all broker descendants stop with outer command") { kill(parent, 0) != 0 && kill(child, 0) != 0 }
        try check(!fm.fileExists(atPath: held!.appendingPathComponent("output/finished").path), "outer Stop also cancels commands launched outside its process group by the broker")
        try check(receipts.contains { !($0["nestedCommands"] as? [[String: Any]] ?? []).isEmpty }, "host receipts retain nested launch and exit evidence")
        if let final = receipts.last { try JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys]).write(to: compiled.appendingPathComponent("native-runner-host-receipt.json"), options: .atomic) }
        print("NativeRunnerTests passed: nested Stop fixture, separate confinement, scope rejection and broker lifetime")
    }
}
