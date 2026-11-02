import Foundation
import AppKit
import Darwin

@main struct StagingTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw nativeFailure("FAIL " + name) }; passed += 1; print("PASS " + name)
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-staging-" + UUID().uuidString)
        let stable = fixture.appendingPathComponent("stable"), staging = fixture.appendingPathComponent("staging")
        try fm.createDirectory(at: stable, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let environment = WorkspaceEnvironment(staging: true, library: staging)
        try fm.createDirectory(at: environment.sources.appendingPathComponent("Silkwire"), withIntermediateDirectories: true)
        var project = Project(); project.name = "Silkwire"
        project.folders = [ProjectFolder(name: "Working source", path: stable.path, bookmark: Data([1]), builderAllowed: true)]
        var room = Conversation(); room.projectID = project.id; room.draft = "Keep my draft"
        room.identities = ["codex": ProviderIdentity(id: "owner-codex"), "claude": ProviderIdentity(id: "owner-claude"), "eve": ProviderIdentity(id: "agent:main:silkwire-native-dev:owner:collab")]
        room.messages = [Message(author: "Jason", text: "Owner history", state: "sent", requestId: "old-request"), Message(author: "Codex", text: "In progress", state: "streaming", requestId: "old-request")]
        room.draftAttachments = [Attachment(name: "hello.txt", mimeType: "text/plain", data: Data("fixture".utf8))]
        let workspace = ConversationWorkspace(activeID: room.id, conversations: [room], projects: [project])
        let original = try JSONEncoder().encode(workspace)
        try original.write(to: stable.appendingPathComponent("workspace.json"))
        let snapshot = try WorkspaceEnvironment.isolatedSnapshot(workspace)
        try check(snapshot.environment == "staging", "snapshot identifies its environment")
        try check(snapshot.conversations[0].id != room.id && snapshot.projects[0].id != project.id, "import creates new room and Project ownership")
        try check(snapshot.conversations[0].identities.isEmpty && snapshot.conversations[0].historyContext == nil, "provider sessions and old context verification are not imported")
        try check(snapshot.projects[0].connectedFolders.isEmpty && snapshot.projects[0].folderBookmark == nil, "all working-source permissions are dropped")
        try check(snapshot.conversations[0].draft == room.draft && snapshot.conversations[0].draftAttachments.first?.data == room.draftAttachments.first?.data && snapshot.conversations[0].messages.first?.text == room.messages.first?.text, "drafts, attachments and historical text survive")
        try check(snapshot.conversations[0].messages.allSatisfy { $0.requestId == nil } && snapshot.conversations[0].messages[1].state == "unconfirmed", "import never replays pending owner requests")
        try JSONEncoder().encode(snapshot).write(to: staging.appendingPathComponent("workspace.json"))
        var stableStore: ConversationStore? = ConversationStore(directory: stable)
        var stageStore: ConversationStore? = ConversationStore(environment: environment)
        try check(stableStore?.storageError == nil && stageStore?.storageError == nil, "stable and Staging acquire independent locks simultaneously")
        stableStore!.conversation.draft = "Stable-only message"; stableStore!.save()
        let stableBeforeStage = try Data(contentsOf: stable.appendingPathComponent("workspace.json"))
        stageStore!.conversation.messages.append(Message(author: "Jason", text: "Stage-only message", state: "sent")); stageStore!.save()
        try check(try Data(contentsOf: stable.appendingPathComponent("workspace.json")) == stableBeforeStage, "Staging writes leave stable bytes unchanged")
        try check(!stableStore!.conversation.messages.contains { $0.text == "Stage-only message" } && stageStore!.conversation.draft != "Stable-only message", "messages and drafts do not cross libraries")
        let duplicate = ConversationStore(environment: environment)
        try check(duplicate.storageError != nil, "duplicate Staging instance cannot overwrite an open Staging library")
        let wrongLibrary = ConversationStore(directory: stable, environment: environment)
        try check(wrongLibrary.storageError != nil, "Staging refuses a working-library override before locking or writing")
        try check(!environment.permits(stable) && environment.permits(environment.sources.appendingPathComponent("Silkwire")), "source grants confined to private source descendants")
        let escaped = environment.sources.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: escaped, withDestinationURL: stable)
        try check(!environment.permits(escaped), "symlink to working source does not grant access")
        let runtime = staging.appendingPathComponent("Runtime")
        try fm.createSymbolicLink(at: runtime, withDestinationURL: stable)
        try check(!environment.permitsManagedPath(runtime.appendingPathComponent("Provider Processes/Codex")), "redirected provider storage cannot escape Staging")
        let linkedLibrary = staging.appendingPathComponent("Diagnostics/linked-leaf")
        try fm.createDirectory(at: linkedLibrary, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedLibrary.appendingPathComponent("workspace.json"), withDestinationURL: stable.appendingPathComponent("workspace.json"))
        let linkedStore = ConversationStore(directory: linkedLibrary, environment: environment)
        try check(linkedStore.storageError != nil, "Staging rejects a workspace file linked to the working library")
        var unsafeProject = stageStore!.projects[0]; unsafeProject.folders = [ProjectFolder(name: "Protected live library", path: environment.library.path, bookmark: Data([1]), builderAllowed: true)]
        try check(!stageStore!.updateProject(unsafeProject, reconnect: false), "Project update cannot attach the live app library")
        stageStore!.shutdown(); stageStore = nil
        let reopened = ConversationStore(environment: environment)
        try check(reopened.storageError == nil && reopened.conversation.messages.contains { $0.text == "Stage-only message" }, "Staging persists independently across reopening")
        reopened.shutdown()
        stableStore!.shutdown(); stableStore = nil
        let stableAfterShutdown = try Data(contentsOf: stable.appendingPathComponent("workspace.json"))
        // A broken Staging file must not fall back to the stable library.
        try Data("corrupt".utf8).write(to: staging.appendingPathComponent("workspace.json"))
        let broken = ConversationStore(environment: environment)
        try check(broken.storageError != nil && (try Data(contentsOf: stable.appendingPathComponent("workspace.json"))) == stableAfterShutdown, "broken Staging fails closed without changing stable data")
        try check(try Data(contentsOf: stable.appendingPathComponent("workspace.json")) != original, "stable retained its own newer draft")
        print("PASS: \(passed) Staging isolation checks · \(fixture.path)")
    }
}
