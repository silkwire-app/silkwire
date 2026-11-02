import Foundation
import AppKit
import CoreGraphics

@main struct NativeInstalledSmokeTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let files = FileManager.default
        guard let path = ProcessInfo.processInfo.environment["SILKWIRE_SMOKE_FIXTURE"],
              path.hasPrefix(files.currentDirectoryPath + "/output/acceptance-") else { throw nativeFailure("Select an isolated acceptance fixture, never the owner library.") }
        let fixture = URL(fileURLWithPath:path).appendingPathComponent("workspace.json")
        let original = try JSONDecoder().decode(ConversationWorkspace.self, from:Data(contentsOf:fixture))
        let directory = URL(fileURLWithPath:files.currentDirectoryPath).appendingPathComponent("output/installed-smoke-\(UUID())")
        try files.createDirectory(at:directory, withIntermediateDirectories:true)
        try Data(contentsOf:fixture).write(to:directory.appendingPathComponent("workspace.json"))
        let appURL = ProcessInfo.processInfo.environment["SILKWIRE_SMOKE_APP"].map { URL(fileURLWithPath:$0) } ?? files.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Silkwire Dev.app")
        guard let bundle = Bundle(url:appURL), let accent = NSColor(named:"AccentColor",bundle:bundle)?.usingColorSpace(.sRGB),
              abs(accent.redComponent-0.70) < 0.015, abs(accent.greenComponent-0.57) < 0.015, abs(accent.blueComponent-0.99) < 0.015 else { throw nativeFailure("Installed native accent color does not match approved violet.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = ProcessInfo.processInfo.environment["SILKWIRE_SMOKE_BACKGROUND"] != "1"; configuration.createsNewApplicationInstance = true
        configuration.environment = ["SILKWIRE_DEV_DATA":directory.path]
        let app = try await NSWorkspace.shared.openApplication(at:appURL, configuration:configuration)
        var window: [String:Any]?
        for _ in 0..<100 {
            guard !app.isTerminated else { throw nativeFailure("Installed app exited before opening its native window.") }
            let windows = CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
            window = windows.first {
                guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                      ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let bounds = $0[kCGWindowBounds as String] as? [String:Any] else { return false }
                return ((bounds["Width"] as? NSNumber)?.doubleValue ?? 0) >= 840
            }
            if window != nil { break }; try await Task.sleep(for:.milliseconds(100))
        }
        if window == nil {
            let windows = CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
            let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier }
            print("Smoke diagnostic: pid \(app.processIdentifier), launched \(app.bundleURL?.path ?? "unknown"), own windows \(own)")
        }
        guard let window, let bounds = window[kCGWindowBounds as String] as? [String:Any], (bounds["Width"] as? NSNumber)?.doubleValue ?? 0 >= 840 else { app.terminate(); throw nativeFailure("Installed native window was not found.") }
        try await Task.sleep(for:.seconds(3))
        guard app.terminate() else { throw nativeFailure("Could not request normal shutdown of the isolated installed instance.") }
        for _ in 0..<100 { if app.isTerminated { break }; try await Task.sleep(for:.milliseconds(100)) }
        guard app.isTerminated else { throw nativeFailure("Isolated installed app did not finish normal shutdown.") }
        let saved = try JSONDecoder().decode(ConversationWorkspace.self, from:Data(contentsOf:directory.appendingPathComponent("workspace.json")))
        let reopenedApp = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        defer { if !reopenedApp.isTerminated { reopenedApp.terminate() } }
        try await Task.sleep(for: .seconds(1))
        let reopenedWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard !reopenedApp.isTerminated, reopenedApp.processIdentifier != app.processIdentifier,
              reopenedWindows.contains(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == reopenedApp.processIdentifier && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }) else { throw nativeFailure("Installed app did not reopen its native window.") }
        guard reopenedApp.terminate() else { throw nativeFailure("Reopened isolated app did not accept normal shutdown.") }
        for _ in 0..<100 { if reopenedApp.isTerminated { break }; try await Task.sleep(for: .milliseconds(100)) }
        guard reopenedApp.isTerminated else { throw nativeFailure("Reopened isolated app did not finish normal shutdown.") }
        let reopened = try JSONDecoder().decode(ConversationWorkspace.self, from: Data(contentsOf: directory.appendingPathComponent("workspace.json")))
        for saved in [saved, reopened] {
        try saved.validate()
        guard saved.activeID == original.activeID, saved.conversations.map(\.id) == original.conversations.map(\.id), saved.projects == original.projects else { throw nativeFailure("Installed app changed fixture Project/conversation identities.") }
        for before in original.conversations {
            guard let after = saved.conversations.first(where: { $0.id == before.id }), before.draft == after.draft,
                  before.messages.map(\.id) == after.messages.map(\.id), before.messages.map(\.text) == after.messages.map(\.text),
                  before.draftAttachments.map(\.id) == after.draftAttachments.map(\.id), before.identities.allSatisfy({ after.identities[$0.key]?.id == $0.value.id }),
                  before.historyContext?.mapValues(\.requestID) == after.historyContext?.mapValues(\.requestID) else { throw nativeFailure("Installed app did not preserve exact synthetic library content/session identities.") }
        }
        }
        let receipt: [String:Any] = ["passed":true,"app":appURL.path,"pid":app.processIdentifier,"fixture":directory.path,"normalShutdown":true,"projects":saved.projects.count,"messages":saved.conversations.reduce(0) { $0+$1.messages.count },"ownerLibraryOpened":false,"nativeWindow":true,"nativeVioletAccentVerified":true,"quitReopenVerified":true]
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("receipt.json"))
        print("PASS: installed release opens and reopens real native windows, preserves fixture Projects/history/draft/attachments/sessions and exits normally; owner library never opened. Receipt: \(directory.path)/receipt.json")
    }
}
