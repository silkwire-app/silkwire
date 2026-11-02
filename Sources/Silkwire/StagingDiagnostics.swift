#if SILKWIRE_STAGING
import AppKit
import Foundation

// Opt-in installed-bundle diagnostics. Data remains under Staging/Diagnostics;
// neither an arbitrary path nor the working library can be supplied.
extension ConversationStore {
    func runStagingCheck() async {
        guard environment.staging, (try? environment.validateLibrary(directory)) != nil, storageError == nil else { shutdown(); NSApp.terminate(nil); return }
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            return condition()
        }
        let reopening = ProcessInfo.processInfo.environment["SILKWIRE_STAGING_CHECK_REOPEN"] == "1"
        let fm = FileManager.default
        do {
            record("separate Staging identity and library", Bundle.main.bundleIdentifier == "app.silkwire.staging" && directory.path.hasPrefix(environment.library.path + "/Diagnostics/") && storageError == nil)
            let expectation = directory.appendingPathComponent("expected.json")
            if reopening {
                let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: expectation)) as! [String: Any]
                record("room and draft survive installed relaunch", conversation.id.uuidString == saved["room"] as? String && conversation.draft == "Preserved Staging diagnostic draft")
                record("provider sessions survive installed relaunch", conversation.identities.mapValues(\.id) == saved["identities"] as? [String: String])
                record("transcript survives installed relaunch", conversation.messages.count == saved["messages"] as? Int)
            } else {
                if ProcessInfo.processInfo.environment["SILKWIRE_STAGING_TRUST_CHECK"] == "1" {
                    try await runTrustedStagingCheck(record: record)
                } else {
                let fixture = environment.sources.appendingPathComponent("Acceptance-" + UUID().uuidString)
                guard environment.permits(fixture) else { throw nativeFailure("Staging diagnostic sources point outside the private workspace. No fixture created.") }
                try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
                let phrases = Dictionary(uniqueKeysWithValues: participants.map { ($0, "STAGING-" + UUID().uuidString) })
                for (agent, phrase) in phrases { try Data((phrase + "\n").utf8).write(to: fixture.appendingPathComponent("mission-" + agent + ".txt")) }
                var project = activeProject!
                project.name = "Staging isolation check"
                project.folders = [ProjectFolder(name: "Staging fixture", path: fixture.path, bookmark: try fixture.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil))]
                record("private fixture grant accepted", updateProject(project, reconnect: false))
                connect()
                record("connections settle", await wait(70) { !connecting })
                for agent in participants {
                    record("\(agent) connected in its own session", seats[agent]?.state == "connected")
                    guard seats[agent]?.state == "connected" else { continue }
                    conversation.recipient = agent
                    conversation.draft = "Synthetic Staging isolation check. Use the native READ_PROJECT plain-text protocol to request mission-\(agent).txt from Staging fixture. The host app supplies quoted text; you do not access files or invoke tools yourself. Return its exact phrase and say this is STAGING."
                    send()
                    record("\(agent) turn completes", await wait(180) { !busy })
                    let reply = conversation.messages.last { $0.author == names[agent] }
                    record("\(agent) read exact unpredictable fixture", reply?.state == "completed" && reply?.text.contains(phrases[agent]!) == true)
                    let key = agent + ":" + project.folders![0].id.uuidString.lowercased()
                    record("\(agent) host broker recorded a successful read", projectAccess[key]?.contains("Native broker read succeeded.") == true)
                }
                if let eve = conversation.identities["eve"]?.id { record("Eve has a Staging-only gateway namespace", eve.hasPrefix("agent:main:subagent:silkwire-staging-")) }
                }
                conversation.draft = "Preserved Staging diagnostic draft"; save()
                let saved: [String: Any] = ["room": conversation.id.uuidString, "identities": conversation.identities.mapValues(\.id), "messages": conversation.messages.count]
                try JSONSerialization.data(withJSONObject: saved, options: [.prettyPrinted, .sortedKeys]).write(to: expectation, options: .atomic)
            }
            try? await Task.sleep(for: .milliseconds(500))
            if let window = NSApp.windows.first(where: { $0.title.contains("Silkwire") && $0.contentView != nil }), let view = window.contentView?.superview {
                record("mounted window identifies STAGING", window.title.contains("STAGING"))
                let info: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber, "title": window.title, "width": view.bounds.width, "height": view.bounds.height]
                try JSONSerialization.data(withJSONObject: info, options: .prettyPrinted).write(to: directory.appendingPathComponent("window.json"))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("window.png"))
                }
            } else { record("mounted Staging window", false) }
        } catch { checks.append(["name": "diagnostic error", "passed": false, "error": error.localizedDescription]) }
        let receipt: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "bundle": Bundle.main.bundlePath, "revision": Bundle.main.object(forInfoDictionaryKey: "SilkwireGitRevision") as? String ?? "unknown", "recordedAt": ISO8601DateFormatter().string(from: Date())]
        try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(reopening ? "reopen-check.json" : "check.json"), options: .atomic)
        shutdown(); NSApp.terminate(nil)
    }
}
#endif
