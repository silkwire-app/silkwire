import Foundation

@main struct AccessStatusTests {
    @MainActor static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name); print("PASS: \(name)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-access-status-\(UUID())")
        let folder = ProjectFolder(name: "Synthetic source", path: root.appendingPathComponent("source").path, bookmark: Data([1]))
        var projectID = UUID()
        do {
            let store = ConversationStore(directory: root)
            var project = store.activeProject!; project.folders = [folder]; projectID = project.id
            check(store.updateProject(project, reconnect: false), "synthetic grant configured")
            for agent in agents {
                store.recordProjectAccess(["folderId": folder.id.uuidString, "state": "verified", "operation": "list"], agent: agent)
                check(store.accessDescription(folder, agent: agent).contains("listing"), "listing labeled for \(agent)")
                store.recordProjectAccess(["folderId": folder.id.uuidString, "state": "verified", "operation": "read"], agent: agent)
                store.retainVerifiedAccess()
                store.recordProjectAccess(["folderId": folder.id.uuidString, "state": "configured"], agent: agent)
                check(store.accessDescription(folder, agent: agent).contains("file read") && store.accessDescription(folder, agent: agent).contains("historical"), "reconnect preserves historical read for \(agent)")
                store.recordProjectAccess(["folderId": folder.id.uuidString, "state": "failed", "detail": "Synthetic refusal"], agent: agent)
                let description = store.accessDescription(folder, agent: agent)
                check(description.contains("Failed") && description.contains("file read"), "failure retains successful evidence for \(agent)")
            }
            let message = Message(author: "Builder", text: "", state: "completed", requestId: "old")
            check(!store.canStopBuilderMessage(message), "finished receipt cannot stop another task")
            store.builderRunning = true
            check(!store.canStopBuilderMessage(Message(author: "Builder", text: "", state: "streaming", requestId: "unrelated")), "unrelated receipt cannot stop current Builder")
            store.builderRunning = false
            // Relaunch is a durable boundary in the app. Access events use coalesced
            // background saves, so finish that boundary before opening a second store.
            check(store.save(), "access evidence durably saved before relaunch")
        }
        do {
            let store = ConversationStore(directory: root)
            check(store.activeProject?.id == projectID && store.accessDescription(folder, agent: "codex").contains("file read"), "successful evidence survives relaunch")
            var project = store.activeProject!
            var changed = folder; changed.bookmark = Data([2]); project.folders = [changed]
            check(store.updateProject(project, reconnect: false), "same-ID replacement grant accepted")
            check(!store.accessDescription(changed, agent: "codex").contains("verified file read"), "changed grant invalidates historical evidence")
            store.recordProjectAccess(["folderId": changed.id.uuidString, "state": "verified", "operation": "read"], agent: "codex")
            project = store.activeProject!; project.folders = []
            check(store.updateProject(project, reconnect: false), "grant revoked")
            check(store.accessDescription(changed, agent: "codex") == "Not granted" && store.activeProject?.accessVerifications?.isEmpty == true, "revocation removes evidence")
        }
        print("PASS: access history, grant invalidation and Stop eligibility")
    }
}
