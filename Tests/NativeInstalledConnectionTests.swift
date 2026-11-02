import Foundation
import AppKit

@main struct NativeInstalledConnectionTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let files = FileManager.default
        let directory = URL(fileURLWithPath:files.currentDirectoryPath).appendingPathComponent("output/release-connections-\(UUID())")
        try files.createDirectory(at:directory,withIntermediateDirectories:true)
        var project = Project(); project.name = "Synthetic connection verification"
        // Issued by a DIFFERENT executable/signing identity than the app. This
        // covers the replacement-build bookmark boundary the earlier smoke missed.
        let source = directory.appendingPathComponent("source")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        let bookmark = try source.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        project.folders = [ProjectFolder(name: "App Source", path: source.resolvingSymlinksInPath().path, bookmark: bookmark)]
        var conversation = Conversation(); conversation.projectID = project.id; conversation.draft = "Unsent synthetic draft"
        let workspace = ConversationWorkspace(activeID:conversation.id,conversations:[conversation],projects:[project])
        let file = directory.appendingPathComponent("workspace.json")
        try JSONEncoder().encode(workspace).write(to:file)
        let appURL = ProcessInfo.processInfo.environment["SILKWIRE_CONNECTION_APP"].map { URL(fileURLWithPath:$0) } ?? files.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Silkwire Dev.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false; configuration.createsNewApplicationInstance = true
        configuration.environment = ["SILKWIRE_DEV_DATA":directory.path]
        let app = try await NSWorkspace.shared.openApplication(at:appURL,configuration:configuration)
        defer { if !app.isTerminated { app.terminate() } }
        var saved = workspace
        for _ in 0..<240 {
            guard !app.isTerminated else { throw nativeFailure("Production app exited during connection.") }
            saved = try JSONDecoder().decode(ConversationWorkspace.self,from:Data(contentsOf:file))
            if saved.conversations.first?.identities.count == 3 { break }
            try await Task.sleep(for:.milliseconds(250))
        }
        let connected = saved.conversations.first?.identities.keys.sorted() ?? []
        print("Production app saved connected identities: \(connected); isolated fixture \(directory.path)")
        guard app.terminate() else { throw nativeFailure("Could not normally close isolated release.") }
        for _ in 0..<100 { if app.isTerminated { break }; try await Task.sleep(for:.milliseconds(100)) }
        guard app.isTerminated, connected.count == 3 else { throw nativeFailure("Normal production bundle did not connect all3 agents.") }
        saved = try JSONDecoder().decode(ConversationWorkspace.self,from:Data(contentsOf:file))
        guard saved.conversations.first?.draft == conversation.draft, saved.conversations.first?.messages.isEmpty == true else { throw nativeFailure("Connection changed draft or dispatched a message.") }
        print("PASS: production bundle connects three actual providers with an externally issued folder bookmark and synthetic library, no diagnostic mode and no message dispatch.")
    }
}
