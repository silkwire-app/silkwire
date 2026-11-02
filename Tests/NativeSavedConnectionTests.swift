import Foundation

// Explicit read-only diagnostic: reconnect the actual saved provider identities
// without opening a ConversationStore, copying history, dispatching a message,
// changing sign-in or saving anything to the owner's library.
@main struct NativeSavedConnectionTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard ProcessInfo.processInfo.environment["SILKWIRE_CHECK_SAVED_SESSIONS"] == "1" else { throw nativeFailure("Saved-session diagnostic must be explicitly selected.") }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Silkwire Native Development/workspace.json")
        let original = try Data(contentsOf: file)
        let workspace = try JSONDecoder().decode(ConversationWorkspace.self, from: original)
        guard let conversation = workspace.conversations.first(where: { $0.id == workspace.activeID }),
              let project = workspace.projects.first(where: { $0.id == conversation.projectID }) else { throw nativeFailure("Active Project unavailable.") }
        var folders: [[String: String]] = []
        for folder in project.connectedFolders {
            let url = try nativeResolveProjectFolder(folder)
            folders.append(["id": folder.id.uuidString.lowercased(), "name": folder.name, "root": url.path])
        }
        let start = Date()
        var connected = Set<String>(), worstGap = 0.0
        let room = NativeRoom(emit: { event in
            guard event["type"] as? String == "connection", let agent = event["agent"] as? String, let state = event["state"] as? String else { return }
            print(String(format: "%.3fs %@ %@", Date().timeIntervalSince(start), agent, state))
            if state == "connected" { connected.insert(agent) }
            if state == "disconnected" { print(event["message"] as? String ?? "Connection failed") }
        })
        let heartbeat = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                worstGap = max(worstGap, Date().timeIntervalSince(last)); last = Date()
            }
        }
        defer { heartbeat.cancel(); room.close(); NativeProcess.shutdownOwnedGroups() }
        let identities = try JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation.identities))
        await room.dispatch(["action": "connect", "conversationID": conversation.id.uuidString.lowercased(), "identities": identities, "participants": project.participants, "projectFolders": folders, "projectBrief": project.brief ?? ""])
        let unchanged = try Data(contentsOf: file) == original
        print(String(format: "Saved-session connect %.3fs; worst UI heartbeat gap %.3fs; owner library unchanged: %@", Date().timeIntervalSince(start), worstGap, unchanged.description))
        guard connected == Set(project.participants), unchanged, worstGap < 0.5 else { throw nativeFailure("Saved-session connection diagnostic did not pass.") }
        print("PASS: actual saved identities reconnect without replay, history copy, library writes or UI stall")
    }
}
