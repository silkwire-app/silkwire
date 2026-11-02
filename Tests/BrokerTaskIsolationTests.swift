import Foundation

/// Exercise the actual host broker and kernel sandbox, including a second
/// broker hop. A child tries to promote sibling and parent paths into authority.
@main struct BrokerTaskIsolationTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let files = FileManager.default
        if CommandLine.arguments.contains("--native-client") {
            let request = try JSONDecoder().decode(NativeCommandBroker.Request.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments.last!)))
            let reply = try await NativeCommandBroker.Client(endpoint: ProcessInfo.processInfo.environment[NativeCommandBroker.environmentKey]!).execute(request)
            guard reply.exitCode == 0, reply.error == nil else { throw nativeFailure("Native nested client failed: " + reply.stderr) }
            print("PASS native client reached its assigned descendant command")
            return
        }
        let root = try NativeTemporaryDirectory.createWorkspace()
        let work = root.appendingPathComponent("host-work"), scratch = root.appendingPathComponent("host-scratch")
        for dir in [work, scratch] { try files.createDirectory(at: dir, withIntermediateDirectories: true) }
        func task(_ base: URL) throws -> [URL] {
            let paths = [base.appendingPathComponent("work"), base.appendingPathComponent("scratch"), base.appendingPathComponent("repo")]
            for path in paths { try files.createDirectory(at: path, withIntermediateDirectories: true) }
            return paths
        }
        let a = try task(scratch.appendingPathComponent("task-a"))
        let sibling = try task(scratch.appendingPathComponent("task-b"))
        let nested = try task(a[1].appendingPathComponent("grandchild"))
        let canary = sibling[0].appendingPathComponent("canary.txt")
        let unrelated = try NativeTemporaryDirectory.createWorkspace().appendingPathComponent("private-canary")
        try Data("unrelated private task".utf8).write(to: unrelated)
        try Data("sibling intact".utf8).write(to: canary)
        let broker = try NativeCommandBroker(worktree: work, temporary: scratch)
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func request(_ paths: [URL], _ command: String) throws -> String {
            String(decoding: try JSONEncoder().encode(NativeCommandBroker.Request(worktree: paths[0].path, temporary: paths[1].path, repository: paths[2].path, executable: "/bin/bash", arguments: ["-c", command])), as: UTF8.self)
        }
        func submit(_ json: String) -> String {
            let id = UUID().uuidString
            return "printf '%s' " + quote(json) + " > \"$SILKWIRE_COMMAND_BROKER/requests/" + id + ".json\"; for i in {1..500}; do if test -f \"$SILKWIRE_COMMAND_BROKER/responses/" + id + ".json\"; then cat \"$SILKWIRE_COMMAND_BROKER/responses/" + id + ".json\"; break; fi; sleep 0.02; done"
        }
        let escape = try request(sibling, "printf CORRUPTED > " + quote(canary.path))
        let parent = try request([work, a[1], sibling[2]], "touch " + quote(work.appendingPathComponent("escape").path))
        let allowed = try request(nested, "printf assigned > owned.txt")
        // A deeper command must not regain task-a authority either.
        let grandchildEscape = try request([a[0], a[1], a[2]], "touch " + quote(a[0].appendingPathComponent("promoted").path))
        let deep = try request(nested, submit(grandchildEscape))
        let ancestorTamper = "printf x > " + quote(broker.root.appendingPathComponent("requests/" + UUID().uuidString + ".json").path)
        let script = submit(escape) + "; " + submit(parent) + "; " + submit(allowed) + "; " + submit(deep) + "; cat " + quote(unrelated.path) + "; " + ancestorTamper
        let result = try await NativeCommandBroker.Client(endpoint: broker.root.path).execute(.init(worktree: a[0].path, temporary: a[1].path, repository: a[2].path, executable: "/bin/bash", arguments: ["-c", script]))
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        try files.copyItem(at: executable, to: a[0].appendingPathComponent("native-client"))
        try files.copyItem(at: executable.deletingLastPathComponent().appendingPathComponent("libSilkwireCore.dylib"), to: a[0].appendingPathComponent("libSilkwireCore.dylib"))
        let nativeRequest = NativeCommandBroker.Request(worktree: nested[0].path, temporary: nested[1].path, repository: nested[2].path, executable: "/bin/sh", arguments: ["-c", "printf native > native-owned.txt"])
        try JSONEncoder().encode(nativeRequest).write(to: a[0].appendingPathComponent("native-request.json"))
        let native = try await NativeCommandBroker.Client(endpoint: broker.root.path).execute(.init(worktree: a[0].path, temporary: a[1].path, repository: a[2].path, executable: "/bin/bash", arguments: ["-c", "DYLD_LIBRARY_PATH=\"$PWD\" ./native-client --native-client native-request.json"]))
        await broker.close()
        func check(_ ok: Bool, _ message: String) throws { guard ok else { throw nativeFailure("FAIL: " + message + "\n" + result.stdout + result.stderr) }; print("PASS: " + message) }
        try check(try String(contentsOf: canary, encoding: .utf8) == "sibling intact", "a nested task cannot write into a sibling through the broker")
        try check(!files.fileExists(atPath: work.appendingPathComponent("escape").path), "a child cannot promote parent workspace roots")
        try check(!files.fileExists(atPath: a[0].appendingPathComponent("promoted").path), "a grandchild cannot recover ancestor authority")
        try check(try String(contentsOf: nested[0].appendingPathComponent("owned.txt"), encoding: .utf8) == "assigned", "a correctly scoped grandchild runs a real command")
        try check(result.stdout.components(separatedBy: "roots must stay inside").count >= 4, "host explicitly rejects sibling, parent and grandchild scope escalation")
        try check(result.exitCode != 0 && result.stderr.contains("Operation not permitted"), "kernel sandbox also prevents use of the ancestor endpoint")
        try check(!result.stdout.contains("unrelated private task") && result.stderr.contains("private-canary"), "unrelated temporary task files cannot be read")
        try check(native.exitCode == 0 && files.fileExists(atPath: nested[0].appendingPathComponent("native-owned.txt").path), "a native scoped reader can traverse its ancestors to use a child broker endpoint: " + native.stdout + native.stderr)
        print("PASS: BrokerTaskIsolationTests; two real broker hops and kernel denial")
    }
}
