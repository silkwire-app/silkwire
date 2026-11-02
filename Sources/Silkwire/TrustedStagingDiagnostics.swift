#if SILKWIRE_STAGING
import Foundation

extension ConversationStore {
    func runTrustedStagingCheck(record: (String, Bool) -> Void) async throws {
        func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            return condition()
        }
        let fixture = environment.sources.appendingPathComponent("Trusted-Acceptance-" + UUID().uuidString)
        guard environment.permits(fixture) else { throw nativeFailure("Trusted acceptance requires private Staging sources.") }
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("print(\"Initial source remains unchanged\")\n".utf8).write(to: fixture.appendingPathComponent("seed.swift"))
        try Data(".module-cache/\nprogram-*\n".utf8).write(to: fixture.appendingPathComponent(".gitignore"))
        var env = nativeProviderEnvironment(); env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        for args in [["init"], ["add", "."], ["-c", "user.name=Silkwire Acceptance", "-c", "user.email=acceptance@localhost", "commit", "-m", "Synthetic source"]] {
            let result = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null"] + args, directory: fixture, environment: env)
            guard result.exitCode == 0 else { throw nativeFailure("Synthetic trusted source preparation failed.") }
        }
        var project = activeProject!; project.name = "Trusted Staging proof"; project.trustedStaging = true
        project.folders = [ProjectFolder(name: "Trusted source", path: fixture.path, bookmark: try fixture.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil), builderAllowed: true)]
        record("trusted Project source configured", updateProject(project, reconnect: false))
        record("trusted workspace capability visible in the room", trustedStagingAvailable)
        connect(); record("trusted room connections settle", await wait(70) { !connecting })
        var worktrees: Set<String> = []
        for agent in participants {
            record("\(agent) connected", seats[agent]?.state == "connected")
            guard seats[agent]?.state == "connected" else { continue }
            let phrase = "BUILT-" + agent.uppercased() + "-" + UUID().uuidString
            conversation.recipient = agent
            conversation.draft = "Synthetic authorized trusted Staging task. Implement it yourself here using the offered WORK_PROJECT text broker, not a Builder form or native tools: begin a private workspace from Trusted source; create \(agent).swift with a Swift print of exactly \(phrase); compile using /usr/bin/xcrun swiftc -module-cache-path .module-cache \(agent).swift -o program-\(agent); run ./program-\(agent); finish with actual evidence. Do not ask for permission; this isolated edit/build/test is approved. Keep original source unchanged. Give Jason a short plain-English result."
            send(); record("\(agent) trusted task settles", await wait(600) { !busy })
            let receipt = trustedReceipts.values.first { $0["owner"] as? String == agent && $0["status"] as? String == "review" }
            record("\(agent) produced a real private task receipt", receipt != nil)
            guard let receipt else { continue }
            let commands = receipt["steps"] as? [[String: Any]] ?? []
            record("\(agent) really compiled", commands.contains { ($0["command"] as? String ?? "").contains("swiftc") && ($0["exitCode"] as? NSNumber)?.intValue == 0 && $0["timedOut"] as? Bool != true })
            record("\(agent) really ran its generated program", commands.contains { ($0["output"] as? String ?? "").contains(phrase) && ($0["exitCode"] as? NSNumber)?.intValue == 0 && $0["timedOut"] as? Bool != true })
            record("\(agent) actual diff includes its new source", (receipt["diff"] as? String ?? "").contains("\(agent).swift"))
            record("\(agent) preserved original source", receipt["sourceUnchanged"] as? Bool == true)
            record("\(agent) result returned to this conversation", conversation.messages.contains { $0.author == "Builder" && $0.requestId == receipt["id"] as? String && $0.state == "completed" })
            if let path = receipt["worktreePath"] as? String {
                worktrees.insert(path)
                let binary = URL(fileURLWithPath: path).appendingPathComponent("program-" + agent)
                let bytes = (try? Data(contentsOf: binary)) ?? Data()
                record("\(agent) produced a native executable", FileManager.default.isExecutableFile(atPath: binary.path) && bytes.starts(with: [0xcf, 0xfa, 0xed, 0xfe]))
            }
        }
        record("teammates have independent workspaces", worktrees.count == participants.count)
        record("protocol requests remain hidden from visible replies", !conversation.messages.filter { ["Eve", "Claude", "Codex"].contains($0.author) }.contains { $0.text.contains("<<WORK_PROJECT") })
        let unchanged = try await NativeProcess.run(executable: "/usr/bin/git", arguments: ["status", "--porcelain"], directory: fixture, environment: env)
        record("synthetic Staging source remains clean", unchanged.exitCode == 0 && unchanged.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
#endif
