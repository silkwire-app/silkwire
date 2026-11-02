import Foundation
import AppKit
import Darwin

/// Only a separately copied candidate in a marked private session can enter this mode.
/// No provider runtime, owner library, clipboard or global input event is used.
enum AgentTestSession {
    static func validate(library: URL) throws {
        // standardizedFileURL rewrites /private/tmp to the /tmp alias on macOS.
        // Keep the real path selected by mkdtemp and compare canonical paths.
        let root = library.deletingLastPathComponent()
        guard root.path.hasPrefix("/private/tmp/Silkwire-AgentTest-"),
              try NativeTemporaryDirectory.canonical(root).path == root.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let marker = try JSONSerialization.jsonObject(with: NativeScopedRoot(root).readData("session.json", limit: 65536)) as? [String: Any],
              let session = marker["session"] as? String, UUID(uuidString: session) != nil,
              try NativeTemporaryDirectory.canonical(Bundle.main.bundleURL).path == root.appendingPathComponent("Silkwire Agent Test.app").path,
              marker["testExecutableSHA256"] as? String == (try StagingInstaller.sha(Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Silkwire")))),
              Bundle.main.object(forInfoDictionaryKey: "SilkwireAgentTestSession") as? String == session,
              Bundle.main.bundleIdentifier == marker["testBundleID"] as? String,
              Bundle.main.bundleIdentifier?.hasPrefix("app.silkwire.agent-test.") == true,
              marker["revision"] as? String == Bundle.main.object(forInfoDictionaryKey: "SilkwireGitRevision") as? String,
              marker["simulatedTeammates"] as? Bool == true else {
            throw nativeFailure("Private agent test configuration is missing or invalid. Owner data was not opened.")
        }
        var info = stat()
        if lstat(library.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  try NativeTemporaryDirectory.canonical(library).path == root.path + "/Library" else { throw nativeFailure("Private test library must be a real directory in this session.") }
        }
    }
    @MainActor private static var controller: AgentTestController?
    @MainActor static func start(store: ConversationStore) async {
        guard store.environment.agentTest, store.storageError == nil else { return }
        if store.conversations.count == 1, store.conversation.messages.isEmpty {
            store.renameConversation("Test Room One")
            store.conversation.messages = (0..<45).map { Message(author: "Codex", text: "Synthetic scroll fixture \($0)\n\nThis conversation belongs only to the private candidate.", state: "completed") }
            _ = store.save()
            _ = store.newConversation(title: "Test Room Two", reconnect: false)
        }
        store.connect()
        controller = AgentTestController(store: store)
    }
}

@MainActor final class AgentTestTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    private(set) var identity: ProviderIdentity?
    let agent: String
    init(agent: String) { self.agent = agent }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = ProviderIdentity(id: "synthetic-agent-test-" + agent + "-" + UUID().uuidString, started: false)
        self.identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        eventHandler?(.delta("Simulated \(names[agent] ?? agent): received the private test message."))
        eventHandler?(.finished(status: "completed", message: nil))
    }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: "Synthetic test stopped")) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Simulated teammate; no sign-in inspection.") }
}

/// Local request/response transport for test drivers. Commands are restricted to
/// this app's windows. It deliberately cannot execute shell or control other apps.
@MainActor final class AgentTestController {
    let store: ConversationStore
    let root: URL
    private var listener: Task<Void, Never>?
    private var accepted = Set<String>()
    private var lastScroll: [String: Double] = [:]
    private let instance = UUID().uuidString
    init(store: ConversationStore) {
        self.store = store; root = store.directory.deletingLastPathComponent()
        try? JSONSerialization.data(withJSONObject: ["instance": instance, "pid": getpid()]).write(to: root.appendingPathComponent("controller.json"), options: .atomic)
        listener = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views($0) } }
    private var window: NSWindow? { NSApp.windows.first { item in
        item.isVisible && item.title.contains("Silkwire") && item.contentView.map { views($0).contains { $0 is AttachmentTextView } } == true
    } }
    private var transcripts: [NSScrollView] {
        guard let content = window?.contentView else { return [] }
        return views(content).compactMap { $0 as? NSScrollView }.filter {
            !$0.isHiddenOrHasHiddenAncestor && !($0.documentView is NSTextView) && ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height
        }
    }
    /// Same top-left global screen-point convention as COMPUTER, scoped to our view.
    private func screenRect(_ view: NSView?) -> [Double] {
        guard let view, let window = view.window else { return [] }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let top = NSScreen.screens.first?.frame.maxY ?? window.frame.maxY
        return [rect.minX, top - rect.maxY, rect.width, rect.height].map(Double.init)
    }
    private var composer: AttachmentTextView? {
        guard let content = window?.contentView else { return nil }
        return views(content).compactMap { $0 as? AttachmentTextView }.first {
            $0.isEditable && !$0.isHidden && $0.identifier?.rawValue == "silkwire-composer-" + store.conversation.id.uuidString
        }
    }
    private func state() -> [String: Any] {
        ["pid": getpid(), "library": store.directory.path, "simulatedTeammates": true, "busy": store.busy, "connecting": store.connecting,
         "activeRoom": store.conversation.id.uuidString, "draft": store.conversation.draft,
         "rooms": store.conversations.map { ["id": $0.id.uuidString, "title": $0.title] },
         "identities": store.conversation.identities.mapValues { $0.id }, "storageError": store.storageError ?? "",
         "nativeDraft": composer?.string ?? "", "composerFocused": composer.map { window?.firstResponder === $0 } ?? false, "lastScroll": lastScroll,
         "bundleID": Bundle.main.bundleIdentifier ?? "", "liveComputerControl": store.computer != nil,
         "windowFrame": screenRect(window?.contentView), "composerFrame": screenRect(composer),
         "transcriptFrame": screenRect(transcripts.max { $0.frame.height < $1.frame.height })]
    }
    private func poll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("requests"), includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil, accepted.insert(id).inserted else { continue }
            var reply: [String: Any] = [:]
            do {
                let request = try JSONSerialization.jsonObject(with: NativeScopedRoot(root.appendingPathComponent("requests")).readData(file.lastPathComponent, limit: 65536)) as? [String: Any] ?? [:]
                guard request["instance"] as? String == instance else { continue }
                let result = try perform(request)
                reply = ["ok": true, "state": state(), "result": result]
            } catch { reply = ["ok": false, "error": error.localizedDescription, "state": state()] }
            try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("responses/" + id + ".json"), options: .atomic)
        }
    }
    private func perform(_ request: [String: Any]) throws -> [String: Any] {
        guard store.environment.agentTest else { throw nativeFailure("Private tests only") }
        switch request["action"] as? String {
        case "status": store.composerFlush?()
        case "switchRoom":
            guard let value = request["room"] as? String, let id = UUID(uuidString: value), store.selectConversation(id) else { throw nativeFailure("Room unavailable or busy") }
        case "focus", "paste":
            guard let window, let field = composer else { throw nativeFailure("No editable composer is mounted") }
            guard window.makeFirstResponder(field) else { throw nativeFailure("Composer did not accept focus") }
            if request["action"] as? String == "paste" {
                guard let text = request["text"] as? String, text.utf8.count <= 24000 else { throw nativeFailure("Paste needs bounded UTF-8 text") }
                field.insertText(text, replacementRange: field.selectedRange())
                store.composerFlush?()
            }
        case "scroll":
            guard let scroll = transcripts.max(by: { $0.frame.height < $1.frame.height }),
                  let document = scroll.documentView,
                  let fraction = request["fraction"] as? Double, fraction.isFinite, (0...1).contains(fraction) else { throw nativeFailure("Scrollable transcript unavailable, or invalid fraction") }
            let y = max(0, document.bounds.height - scroll.contentSize.height) * fraction
            let before = scroll.contentView.bounds.origin.y
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            lastScroll = ["before": before, "after": scroll.contentView.bounds.origin.y, "documentHeight": document.bounds.height, "viewportHeight": scroll.contentSize.height]
        case "send":
            store.composerFlush?(); guard store.canSend else { throw nativeFailure("Private test room is not ready to send") }; store.send()
        case "screenshot":
            guard let content = window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw nativeFailure("Window unavailable") }
            content.cacheDisplay(in: content.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw nativeFailure("Cannot capture private window") }
            try data.write(to: root.appendingPathComponent("screenshot.png"), options: .atomic)
        case "computer":
            guard let marker = request["marker"] as? String, let parsed = try ComputerRequest.parse(marker) else { throw nativeFailure("Supply one valid COMPUTER marker.") }
            return try performComputer(parsed)
        case "quit": store.shutdown(); DispatchQueue.main.async { NSApp.terminate(nil) }
        default: throw nativeFailure("Unknown private test action")
        }
        return [:]
    }
    /// Shared production parser, private backend. No CGEvent, global capture,
    /// shell, credential access, clipboard or other application can be reached.
    private func performComputer(_ request: ComputerRequest) throws -> [String: Any] {
        guard let window, let content = window.contentView else { throw nativeFailure("Private candidate window unavailable") }
        if let app = request.app {
            let allowed = [Bundle.main.bundleIdentifier ?? "", "Silkwire Agent Test"].map { $0.lowercased() }
            guard allowed.contains(app.lowercased()) else { throw nativeFailure("Private computer control cannot target another application.") }
        }
        if let title = request.window { guard window.title.localizedCaseInsensitiveContains(title) else { throw nativeFailure("That window is outside this private candidate.") } }
        var result: [String: Any] = ["action": request.action.rawValue, "backend": "private AppKit window", "scope": "private-candidate-window"]
        func point() throws -> NSPoint {
            guard let x = request.x, let y = request.y else { throw nativeFailure("This action needs private-window coordinates.") }
            let top = NSScreen.screens.first?.frame.maxY ?? window.frame.maxY
            let local = window.convertPoint(fromScreen: NSPoint(x: x, y: top - y))
            guard content.bounds.contains(content.convert(local, from: nil)) else { throw nativeFailure("The point is outside the private candidate window. No input posted.") }
            return local
        }
        switch request.action {
        case .focus:
            _ = try perform(["action": "focus"])
        case .type:
            _ = try perform(["action": "paste", "text": request.text ?? ""])
        case .click, .doubleClick, .rightClick:
            let local = try point(), right = request.action == .rightClick
            for count in 1...(request.action == .doubleClick ? 2 : 1) {
                for down in [true, false] {
                    let type: NSEvent.EventType = right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
                    guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: down ? 1 : 0) else { throw nativeFailure("Cannot create private-window input.") }
                    window.sendEvent(event)
                }
            }
        case .scroll:
            let local = try point()
            guard let scroll = transcripts.first(where: { $0.bounds.contains($0.convert(local, from: nil)) }), let document = scroll.documentView else { throw nativeFailure("Point at this candidate's scrollable transcript.") }
            let before = scroll.contentView.bounds.origin
            let after = NSPoint(x: min(max(0, before.x + CGFloat(request.dx) * 36), max(0, document.bounds.width - scroll.contentSize.width)),
                                y: min(max(0, before.y + CGFloat(request.dy) * 36), max(0, document.bounds.height - scroll.contentSize.height)))
            scroll.contentView.scroll(to: after); scroll.reflectScrolledClipView(scroll.contentView)
            lastScroll = ["before": before.y, "after": scroll.contentView.bounds.origin.y, "documentHeight": document.bounds.height, "viewportHeight": scroll.contentSize.height]
        case .key:
            guard request.keys.allSatisfy({ key in
                (key.key == "a" && key.modifiers == [.command]) ||
                ([51, 117].contains(key.keyCode) && key.modifiers.isEmpty) ||
                ([36, 76].contains(key.keyCode) && (key.modifiers.isEmpty || key.modifiers == [.command]))
            }) else { throw nativeFailure("Private keys support select-all, delete and Return. Clipboard/global shortcuts are unavailable.") }
            _ = try perform(["action": "focus"])
            guard let field = composer else { throw nativeFailure("Composer unavailable") }
            for key in request.keys {
                if key.key == "a", key.modifiers.count == 1, key.modifiers.contains(.command) { field.selectAll(nil) }
                else if key.modifiers.isEmpty, key.keyCode == 51 { field.deleteBackward(nil) }
                else if key.modifiers.isEmpty, key.keyCode == 117 { field.deleteForward(nil) }
                else if [36, 76].contains(key.keyCode), key.modifiers.count == 1, key.modifiers.contains(.command) {
                    store.composerFlush?(); guard store.canSend else { throw nativeFailure("Synthetic room is not ready to send") }; store.send()
                } else if [36, 76].contains(key.keyCode), key.modifiers.isEmpty { field.insertNewline(nil) }
                else { throw nativeFailure("Private keys support select-all, delete and Return. Clipboard/global shortcuts are unavailable.") }
            }
            store.composerFlush?()
        case .screenshot:
            _ = try perform(["action": "screenshot"])
            result["screenshot"] = root.appendingPathComponent("screenshot.png").path
            result["frame"] = screenRect(content)
            result["imagePixelsPerPoint"] = window.backingScaleFactor
        case .tree:
            result["window"] = window.title; result["frame"] = screenRect(content)
            result["composerFrame"] = screenRect(composer)
            result["rooms"] = store.conversations.map { ["id": $0.id.uuidString, "title": $0.title] }
        default:
            throw nativeFailure("Private COMPUTER requests operate only this window. Shell, files, app launching and global controls are unavailable.")
        }
        return result
    }
}
