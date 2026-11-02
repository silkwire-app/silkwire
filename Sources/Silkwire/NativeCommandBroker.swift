import Foundation
import Darwin

/// A command cannot apply another Seatbelt profile from inside Seatbelt. Keep
/// the launcher in the host, and accept only narrower, canonical workspace roots.
/// The endpoint is a routing hint, never permission to execute without a sandbox.
@MainActor final class NativeCommandBroker {
    nonisolated static let environmentKey = "SILKWIRE_COMMAND_BROKER"
    struct Request: Codable {
        let worktree: String, temporary: String, repository: String
        let executable: String
        let arguments: [String]
    }
    struct Reply: Codable {
        var exitCode: Int32 = -1
        var stdout = "", stderr = ""
        var truncated = false
        var error: String?
    }
    let root: URL
    private let worktree: URL, temporary: URL
    private var listener: Task<Void, Never>?
    private var jobs: [String: Task<Void, Never>] = [:]
    private var accepted = Set<String>()
    private(set) var records: [[String: Any]] = []
    private var stopped = false
    private let admission: HostExecutionAdmission?

    init(worktree: URL, temporary: URL, admission: HostExecutionAdmission? = nil) throws {
        self.admission = admission
        self.worktree = worktree; self.temporary = temporary
        root = temporary.appendingPathComponent("command-broker-" + UUID().uuidString)
        for path in [root, root.appendingPathComponent("requests"), root.appendingPathComponent("responses")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        listener = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                self.poll()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    private func poll() {
        let requests = root.appendingPathComponent("requests")
        guard let files = try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            if file.pathExtension == "cancel" { jobs[id]?.cancel(); continue }
            guard file.pathExtension == "json", !accepted.contains(id), jobs.count < 8, accepted.count < 128 else { continue }
            accepted.insert(id)
            jobs[id] = Task { [weak self] in
                guard let self else { return }
                var reply = Reply()
                do {
                    try self.admission?.check()
                    guard !self.stopped else { throw CancellationError() }
                    let input = try NativeScopedRoot(requests).readData(file.lastPathComponent, limit: 65536)
                    let request = try JSONDecoder().decode(Request.self, from: input)
                    let roots = try [request.worktree, request.temporary, request.repository].map { path -> URL in
                        let url = URL(fileURLWithPath: path, isDirectory: true)
                        let canonical = try NativeTemporaryDirectory.canonical(url)
                        guard canonical.path == path,
                              [self.worktree, self.temporary].contains(where: { path.hasPrefix($0.path + "/") }),
                              path != self.root.path, !path.hasPrefix(self.root.path + "/"),
                              (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                            throw nativeFailure("Nested command roots must stay inside the host workspace and scratch directory.")
                        }
                        return canonical
                    }
                    guard Set(roots.map(\.path)).count == 3,
                          ["/bin/bash", "/bin/sh", "/usr/bin/true"].contains(request.executable),
                          request.arguments.joined().utf8.count <= 32768,
                          !request.arguments.contains(where: { $0.contains("\0") }) else { throw nativeFailure("Invalid nested command configuration.") }
                    try Task.checkCancellation()
                    try self.admission?.check()
                    guard !self.stopped else { throw CancellationError() }
                    // An endpoint is a capability. Passing our endpoint down would
                    // let this child ask the host to execute in a sibling task's
                    // roots. Give it a new capability bounded to its own roots;
                    // Seatbelt makes the ancestor endpoint inaccessible as well.
                    let child = try NativeCommandBroker(worktree: roots[0], temporary: roots[1], admission: self.admission)
                    var environment = NativeBuilder.commandEnvironment(temporary: roots[1])
                    environment[Self.environmentKey] = child.root.path
                    let profile = NativeBuilder.commandSandbox(worktree: roots[0], temporary: roots[1], repository: roots[2], broker: child.root, enclosing: [self.worktree, self.temporary])
                    let result: NativeProcessResult
                    do {
                        result = try await NativeProcess.run(executable: "/usr/bin/sandbox-exec", arguments: ["-p", profile, request.executable] + request.arguments, directory: roots[0], environment: environment, timeoutSeconds: 900, outputLimit: 65536, standardSignals: true, returnInterruptedResult: true, physicalEvidence: self.admission?.physicalEvidence, sandboxedPrivate: true)
                        await child.close()
                    } catch {
                        await child.close()
                        throw error
                    }
                    reply.exitCode = result.exitCode; reply.stdout = NativeBuilder.scrub(result.stdout); reply.stderr = NativeBuilder.scrub(result.stderr); reply.truncated = result.truncated
                    self.records.append(["id": id, "worktree": roots[0].path, "temporary": roots[1].path, "repository": roots[2].path, "executable": request.executable, "exitCode": result.exitCode, "isolation": "host-seatbelt", "nestedCommands": child.records])
                } catch {
                    reply.error = NativeBuilder.scrub(error.localizedDescription)
                    self.records.append(["id": id, "error": reply.error ?? "Nested command rejected", "isolation": "rejected-or-cancelled"])
                }
                // responses/ and its ancestors cannot be replaced by the command.
                if let data = try? JSONEncoder().encode(reply) { try? data.write(to: self.root.appendingPathComponent("responses/" + id + ".json"), options: .atomic) }
                self.jobs.removeValue(forKey: id)
            }
        }
    }
    func stop() {
        stopped = true; listener?.cancel(); listener = nil
        for job in jobs.values { job.cancel() }
    }
    func close() async {
        stop()
        let pending = Array(jobs.values)
        for job in pending { await job.value }
    }

    @MainActor final class Client {
        private let root: URL
        private let id = UUID().uuidString
        private var cancelled = false
        init(endpoint: String) { root = URL(fileURLWithPath: endpoint, isDirectory: true) }
        func stop() {
            cancelled = true
            try? Data().write(to: root.appendingPathComponent("requests/" + id + ".cancel"), options: .atomic)
        }
        func execute(_ request: Request) async throws -> Reply {
            guard !cancelled else { throw CancellationError() }
            // Verify the response channel before launching anything. A sandbox
            // traversal denial must fail immediately, not look like a 905s wait.
            let responses: NativeScopedRoot
            do { responses = try NativeScopedRoot(root.appendingPathComponent("responses")) }
            catch { throw nativeFailure("Nested command broker response channel is inaccessible inside the assigned roots. No command started. " + error.localizedDescription) }
            try JSONEncoder().encode(request).write(to: root.appendingPathComponent("requests/" + id + ".json"), options: .atomic)
            let response = root.appendingPathComponent("responses/" + id + ".json")
            let deadline = Date().addingTimeInterval(905)
            // Room Stop cancels its reader Task too. Keep this receipt waiter
            // independent of that cancellation, and wait for the real host exit.
            let waiter = Task { @MainActor in
                while Date() < deadline {
                    try responses.verifyRoot()
                    if let data = try? responses.readData(response.lastPathComponent, limit: 524288), let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                        if let error = reply.error { throw nativeFailure(error) }
                        return reply
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                stop(); throw nativeFailure("Nested command host did not respond; no unsandboxed fallback was used.")
            }
            return try await withTaskCancellationHandler(operation: { try await waiter.value }, onCancel: { Task { @MainActor in self.stop() } })
        }
    }
}
