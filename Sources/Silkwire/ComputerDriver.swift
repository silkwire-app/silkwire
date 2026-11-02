import AppKit
import ApplicationServices
import CryptoKit
import ImageIO
import ScreenCaptureKit

/// The app, bundle and window an action lands in, read just before it runs.
struct ComputerTarget: Equatable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
}
/// A screenshot for the agent: PNG, its frame in global screen points, and image pixels per point.
struct ComputerScreenshot {
    var png: Data
    var frame: CGRect
    var scale: Double
    var backend: String
    var description: [String: Any] {
        ["frame": [Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)], "imagePixelsPerPoint": (scale * 1000).rounded() / 1000, "backend": backend,
         "coordinates": "Click coordinates are global screen points: x = frame[0] + imageX / imagePixelsPerPoint, y = frame[1] + imageY / imagePixelsPerPoint."]
    }
}

/// What the control center needs from the Mac. Tests inject a synthetic driver.
@MainActor protocol ComputerDriving: AnyObject {
    var backendName: String { get }
    /// When Silkwire last posted a synthetic event (never counted as Jason's input).
    var lastSyntheticEvent: Date { get }
    func target(for request: ComputerRequest) -> ComputerTarget
    func screenshot(app: String?, window: String?) async throws -> ComputerScreenshot
    /// Pointer/keyboard/app/tree actions. `shouldContinue` is checked between events;
    /// false means Jason took the wheel and the rest of the action must not happen.
    func perform(_ request: ComputerRequest, shouldContinue: @escaping @MainActor () -> Bool) async throws -> [String: Any]
}

/// Native input (CGEvent), capture (ScreenCaptureKit) and UI tree (Accessibility).
/// Peekaboo, when installed and permitted, captures, reads trees and opens apps.
/// Input is always posted here and tagged, so Jason's real input stays distinguishable.
@MainActor final class NativeComputerDriver: ComputerDriving {
    static let eventTag: Int64 = 0x5349_4C4B // "SILK"
    let peekaboo = ["/opt/homebrew/bin/peekaboo", "/usr/local/bin/peekaboo"].first { FileManager.default.isExecutableFile(atPath: $0) }
    var backendName: String { peekaboo == nil ? "built-in (ScreenCaptureKit, CGEvent, Accessibility)" : "Peekaboo for capture/tree/apps · built-in input" }
    private(set) var lastSyntheticEvent = Date.distantPast
    /// Overlay window numbers excluded from captures, and a hook to hide them for Peekaboo.
    var overlayWindows: () -> [Int] = { [] }
    var hideOverlay: (Bool) -> Void = { _ in }
    var onPointer: (CGPoint) -> Void = { _ in }
    private let source = CGEventSource(stateID: .privateState)
    private let scratch: URL

    init(scratch: URL) { self.scratch = scratch }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: Targets

    static func runningApp(_ name: String) -> NSRunningApplication? {
        let lower = name.lowercased()
        let apps = NSWorkspace.shared.runningApplications
        return apps.first { $0.bundleIdentifier?.lowercased() == lower } ?? apps.first { $0.localizedName?.lowercased() == lower }
    }
    private static func onScreenWindows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }
    private static func bounds(_ window: [String: Any]) -> CGRect? {
        (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }
    /// Frontmost ordinary window containing a point, front to back.
    static func windowAt(_ point: CGPoint) -> [String: Any]? {
        onScreenWindows().first { ($0[kCGWindowLayer as String] as? Int) == 0 && (bounds($0)?.contains(point) ?? false) }
    }
    /// Accessibility answers from a hung app can take seconds; never wait long on the main thread.
    nonisolated static let axTimeout: Float = 0.5
    private static func axTitle(of window: AXUIElement) -> String? {
        var title: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success ? title as? String : nil
    }
    private static func focusedWindowTitle(_ pid: pid_t) -> String? {
        // Silkwire's own windows: asking Accessibility about ourselves would wait on this thread.
        if pid == getpid() { return NSApp?.keyWindow?.title ?? NSApp?.mainWindow?.title }
        guard accessibilityGranted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return axTitle(of: window as! AXUIElement)
    }
    /// The title of the window under a point, through Accessibility. CoreGraphics only
    /// reports other apps' window titles with Screen Recording, which Peekaboo users may not grant Silkwire.
    private static func windowTitle(at point: CGPoint, pid: pid_t) -> String? {
        if pid == getpid() { return NSApp?.windows.first { $0.isVisible && $0.frame.contains(NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)) }?.title }
        guard accessibilityGranted else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success, let element else { return focusedWindowTitle(pid) }
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() { return axTitle(of: window as! AXUIElement) }
        return axTitle(of: element) ?? focusedWindowTitle(pid)
    }
    func target(for request: ComputerRequest) -> ComputerTarget {
        if [.click, .doubleClick, .rightClick, .drag, .scroll].contains(request.action), let x = request.x, let y = request.y,
           let window = Self.windowAt(CGPoint(x: x, y: y)), let pid = window[kCGWindowOwnerPID as String] as? pid_t {
            let app = NSRunningApplication(processIdentifier: pid)
            let listed = (window[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ComputerTarget(appName: app?.localizedName ?? window[kCGWindowOwnerName as String] as? String, bundleID: app?.bundleIdentifier, windowTitle: listed ?? Self.windowTitle(at: CGPoint(x: x, y: y), pid: pid))
        }
        if let name = request.app {
            let app = Self.runningApp(name)
            return ComputerTarget(appName: app?.localizedName ?? name, bundleID: app?.bundleIdentifier, windowTitle: request.window)
        }
        if [.type, .key, .tree].contains(request.action), let app = NSWorkspace.shared.frontmostApplication {
            return ComputerTarget(appName: app.localizedName, bundleID: app.bundleIdentifier, windowTitle: Self.focusedWindowTitle(app.processIdentifier))
        }
        return ComputerTarget()
    }

    // MARK: Capture

    func screenshot(app: String?, window: String?) async throws -> ComputerScreenshot {
        // Peekaboo has its own permissions, so it goes first; the built-in capture needs Silkwire's.
        var peekabooError: String?
        if let peekaboo {
            do { return try await peekabooScreenshot(peekaboo, app: app, window: window) }
            catch { peekabooError = limitedUTF16(error.localizedDescription, to: 160) }
        }
        guard Self.screenRecordingGranted else { throw nativeFailure("Screen Recording permission is needed: System Settings → Privacy & Security → Screen Recording → Silkwire Staging. Nothing was captured." + (peekabooError.map { " Peekaboo also failed: " + $0 } ?? "")) }
        var shot = try await nativeScreenshot(app: app, window: window)
        if let peekabooError { shot.backend += " (Peekaboo failed: \(peekabooError))" }
        return shot
    }
    private func nativeScreenshot(app: String?, window: String?) async throws -> ComputerScreenshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        let filter: SCContentFilter, frame: CGRect
        if let app {
            let lower = app.lowercased()
            let candidates = content.windows.filter { item in
                item.windowLayer == 0 && item.isOnScreen && item.frame.width > 40 && item.frame.height > 40 &&
                    (item.owningApplication?.applicationName.lowercased() == lower || item.owningApplication?.bundleIdentifier.lowercased() == lower) &&
                    (window == nil || (item.title ?? "").localizedCaseInsensitiveContains(window!))
            }
            guard let match = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw nativeFailure("No visible window for \(app)\(window.map { " titled “\($0)”" } ?? ""). Open or focus it first.")
            }
            filter = SCContentFilter(desktopIndependentWindow: match); frame = match.frame
        } else {
            let main = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else { throw nativeFailure("No display is available to capture.") }
            let hidden = Set(overlayWindows())
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { hidden.contains(Int($0.windowID)) })
            frame = CGDisplayBounds(display.displayID)
        }
        let backing = NSScreen.screens.first?.backingScaleFactor ?? 2
        configuration.width = max(1, Int(frame.width * backing)); configuration.height = max(1, Int(frame.height * backing))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try Self.encode(image, frame: frame, backend: "built-in ScreenCaptureKit")
    }
    private func peekabooScreenshot(_ executable: String, app: String?, window: String?) async throws -> ComputerScreenshot {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = scratch.appendingPathComponent("capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        var arguments = ["see", "--no-elements", "--format", "png", "--path", file.path]
        let frame: CGRect
        if let app {
            arguments += ["--app", app]; if let window { arguments += ["--window-title", window] }
            guard let found = Self.windowFrame(app: app, title: window) else { throw nativeFailure("No visible window for \(app).") }
            frame = found
        } else { arguments += ["--mode", "screen", "--screen-index", "0"]; frame = CGDisplayBounds(CGMainDisplayID()) }
        // Peekaboo cannot exclude Silkwire's banner and pointer, so they step aside briefly.
        hideOverlay(true); defer { hideOverlay(false) }
        let result = try await Self.peekabooRun(executable, arguments, scratch: scratch)
        guard result.exitCode == 0, let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw nativeFailure("Peekaboo capture exited \(result.exitCode): " + limitedUTF16((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines), to: 300))
        }
        return try Self.encode(image, frame: frame, backend: "Peekaboo")
    }
    static func windowFrame(app: String, title: String?) -> CGRect? {
        let lower = app.lowercased(), pid = runningApp(app)?.processIdentifier
        return onScreenWindows().filter { item in
            (item[kCGWindowLayer as String] as? Int) == 0 &&
                ((item[kCGWindowOwnerPID as String] as? pid_t) == pid || (item[kCGWindowOwnerName as String] as? String)?.lowercased() == lower) &&
                (title == nil || ((item[kCGWindowName as String] as? String) ?? "").localizedCaseInsensitiveContains(title!))
        }.compactMap(bounds).max { $0.width * $0.height < $1.width * $1.height }
    }
    /// Downscale so the long edge is at most 1,568 px and the PNG fits the 2 MB attachment bound.
    static func encode(_ image: CGImage, frame: CGRect, backend: String) throws -> ComputerScreenshot {
        var longEdge = min(1568.0, Double(max(image.width, image.height)))
        while true {
            let factor = longEdge / Double(max(image.width, image.height))
            let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { break }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let data = NSMutableData()
            if let scaled = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, scaled, nil)
                if CGImageDestinationFinalize(destination), data.length <= 1_900_000 {
                    return ComputerScreenshot(png: data as Data, frame: frame, scale: frame.width > 0 ? Double(width) / frame.width : 1, backend: backend)
                }
            }
            guard longEdge >= 320 else { break }
            longEdge *= 0.75
        }
        throw nativeFailure("The screenshot could not be encoded within 2 MB.")
    }

    // MARK: Actions

    func perform(_ request: ComputerRequest, shouldContinue: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
        switch request.action {
        case .click, .doubleClick, .rightClick, .drag, .scroll, .type, .key:
            guard Self.accessibilityGranted else { throw nativeFailure("Accessibility permission is needed to move the pointer and type: System Settings → Privacy & Security → Accessibility → Silkwire Staging. Nothing was done.") }
            return try await input(request, shouldContinue: shouldContinue)
        case .open: return try await open(request)
        case .focus: return try await focus(request)
        case .tree: return try await tree(request)
        case .wait:
            try await Task.sleep(for: .milliseconds(Int(request.seconds * 1000)))
            return ["waited": request.seconds]
        default: throw nativeFailure("This driver does not perform \(request.action.rawValue).")
        }
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
        lastSyntheticEvent = Date()
    }
    private func mouse(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: clicks)
        post(event)
        if type == .mouseMoved || type == .leftMouseDragged { onPointer(point) }
    }
    private func input(_ request: ComputerRequest, shouldContinue: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
        func pause() async throws { try await Task.sleep(for: .milliseconds(35)) }
        func interrupted(_ done: String) -> [String: Any] { ["interrupted": true, "performed": done, "note": "Jason took the wheel; the rest of this action did not happen. Wait for the next result before continuing."] }
        let point = CGPoint(x: request.x ?? 0, y: request.y ?? 0)
        guard shouldContinue() else { return interrupted("nothing") }
        switch request.action {
        case .click, .doubleClick, .rightClick:
            mouse(.mouseMoved, point); try await pause()
            guard shouldContinue() else { return interrupted("moved the pointer only") }
            let right = request.action == .rightClick
            for count in 1...(request.action == .doubleClick ? 2 : 1) {
                guard shouldContinue() else { return interrupted("completed \(count - 1) clicks") }
                mouse(right ? .rightMouseDown : .leftMouseDown, point, right ? .right : .left, clicks: Int64(count))
                mouse(right ? .rightMouseUp : .leftMouseUp, point, right ? .right : .left, clicks: Int64(count))
                if count == 1, request.action == .doubleClick { try await Task.sleep(for: .milliseconds(60)) }
            }
            return ["performed": request.summary]
        case .drag:
            let end = CGPoint(x: request.toX ?? 0, y: request.toY ?? 0)
            mouse(.mouseMoved, point); try await pause()
            guard shouldContinue() else { return interrupted("moved the pointer only") }
            mouse(.leftMouseDown, point)
            let steps = 16
            for step in 1...steps {
                guard shouldContinue() else { mouse(.leftMouseUp, CGPoint(x: point.x + (end.x - point.x) * Double(step - 1) / Double(steps), y: point.y + (end.y - point.y) * Double(step - 1) / Double(steps))); return interrupted("drag released early at step \(step - 1) of \(steps)") }
                mouse(.leftMouseDragged, CGPoint(x: point.x + (end.x - point.x) * Double(step) / Double(steps), y: point.y + (end.y - point.y) * Double(step) / Double(steps)))
                try await Task.sleep(for: .milliseconds(14))
            }
            mouse(.leftMouseUp, end)
            return ["performed": request.summary]
        case .scroll:
            mouse(.mouseMoved, point); try await pause()
            guard shouldContinue() else { return interrupted("moved the pointer only") }
            // Positive dy scrolls the content down (like a web page's deltaY).
            post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(-request.dy), wheel2: Int32(-request.dx), wheel3: 0))
            return ["performed": request.summary]
        case .type:
            let characters = Array(request.text ?? "")
            for (index, character) in characters.enumerated() {
                guard shouldContinue() else { return interrupted("typed \(index) of \(characters.count) characters") }
                if character == "\n" || character == "\r\n" { press(KeyCombo(modifiers: [], key: "return", keyCode: 36)) }
                else if character == "\t" { press(KeyCombo(modifiers: [], key: "tab", keyCode: 48)) }
                else {
                    let units = Array(String(character).utf16)
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                        event?.flags = []
                        event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                        post(event)
                    }
                }
                try await Task.sleep(for: .milliseconds(8))
            }
            return ["performed": request.summary]
        case .key:
            for (index, combo) in request.keys.enumerated() {
                guard shouldContinue() else { return interrupted("pressed \(index) of \(request.keys.count) key combinations") }
                press(combo); try await Task.sleep(for: .milliseconds(40))
            }
            return ["performed": request.summary]
        default: return [:]
        }
    }
    private func press(_ combo: KeyCombo) {
        var flags: CGEventFlags = []
        for modifier in combo.modifiers {
            switch modifier { case .command: flags.insert(.maskCommand); case .shift: flags.insert(.maskShift); case .option: flags.insert(.maskAlternate); case .control: flags.insert(.maskControl); case .function: flags.insert(.maskSecondaryFn) }
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down)
            event?.flags = flags
            post(event)
        }
    }

    private func open(_ request: ComputerRequest) async throws -> [String: Any] {
        if let app = request.app, request.url == nil, request.path == nil, let peekaboo {
            let result = try? await Self.peekabooRun(peekaboo, ["app", "launch", app, "--foreground", "--wait-ready"], scratch: scratch)
            if result?.exitCode == 0 { return ["performed": request.summary, "backend": "Peekaboo"] }
        }
        var arguments: [String] = []
        if let app = request.app { arguments += app.contains(".") && !app.contains(" ") ? ["-b", app] : ["-a", app] }
        if let url = request.url { arguments.append(url) }
        if let path = request.path { arguments.append(ComputerRequest.expand(path)) }
        let result = try await NativeProcess.run(executable: "/usr/bin/open", arguments: arguments, directory: FileManager.default.homeDirectoryForCurrentUser, environment: nativeProviderEnvironment(), timeoutSeconds: 30)
        guard result.exitCode == 0 else { throw nativeFailure("open exited \(result.exitCode): " + limitedUTF16(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), to: 300)) }
        try await Task.sleep(for: .milliseconds(600))
        return ["performed": request.summary, "backend": "built-in"]
    }
    private func focus(_ request: ComputerRequest) async throws -> [String: Any] {
        guard let app = request.app else { throw nativeFailure("focus needs app.") }
        var focused = false, backend = "built-in"
        if let peekaboo, (try? await Self.peekabooRun(peekaboo, ["app", "focus", app, "--foreground"], scratch: scratch))?.exitCode == 0 { focused = true; backend = "Peekaboo" }
        if !focused {
            let result = try await NativeProcess.run(executable: "/usr/bin/open", arguments: app.contains(".") && !app.contains(" ") ? ["-b", app] : ["-a", app], directory: FileManager.default.homeDirectoryForCurrentUser, environment: nativeProviderEnvironment(), timeoutSeconds: 30)
            guard result.exitCode == 0 else { throw nativeFailure("Could not focus \(app): " + limitedUTF16(result.stderr, to: 200)) }
        }
        var raised: String?
        if let title = request.window, let running = Self.runningApp(app), Self.accessibilityGranted {
            let element = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(element, Self.axTimeout)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] {
                for window in windows {
                    var name: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &name) == .success, let name = name as? String, name.localizedCaseInsensitiveContains(title) {
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString); AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue); raised = name; break
                    }
                }
            }
            if raised == nil { return ["performed": "Focused \(app); no window titled “\(title)” was found", "backend": backend] }
        }
        try await Task.sleep(for: .milliseconds(300))
        return ["performed": request.summary, "window": raised ?? NSNull(), "backend": backend]
    }

    // MARK: UI tree

    private func tree(_ request: ComputerRequest) async throws -> [String: Any] {
        if let peekaboo {
            if let result = try? await Self.peekabooRun(peekaboo, ["see", "--tree", "--no-screenshot", "--app", request.app ?? "frontmost", "--depth", String(request.depth), "--max-elements", "600"], scratch: scratch), result.exitCode == 0, !result.stdout.isEmpty {
                return ["tree": limitedUTF16(result.stdout, to: 24_000), "truncated": result.stdout.utf16.count > 24_000, "backend": "Peekaboo"]
            }
        }
        guard Self.accessibilityGranted else { throw nativeFailure("Accessibility permission is needed to read UI elements: System Settings → Privacy & Security → Accessibility → Silkwire Staging.") }
        guard let app = request.app.flatMap(Self.runningApp) ?? NSWorkspace.shared.frontmostApplication else { throw nativeFailure("\(request.app ?? "That app") is not running.") }
        // Off the main thread, so a hung app cannot freeze the banner's Stop or takeover detection.
        let pid = app.processIdentifier, depth = request.depth
        let (text, count) = await Task.detached(priority: .userInitiated) { Self.axTree(pid: pid, depth: depth) }.value
        return ["app": app.localizedName ?? "", "tree": limitedUTF16(text, to: 24_000), "elements": count, "truncated": count >= 600 || text.utf16.count > 24_000, "backend": "built-in Accessibility",
                "coordinates": "Frames are [x,y width×height] in global screen points; click the center of an element."]
    }

    /// Accessibility tree text: up to 600 elements, 80 children each, 0.5 s per call, 8 s overall.
    nonisolated static func axTree(pid: pid_t, depth: Int) -> (String, Int) {
        var lines: [String] = [], count = 0
        let deadline = Date().addingTimeInterval(8)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func walk(_ element: AXUIElement, level: Int) {
            guard count < 600, level <= depth, Date() < deadline else { return }
            count += 1
            AXUIElementSetMessagingTimeout(element, axTimeout)
            let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
            let label = [attribute(element, kAXTitleAttribute) as? String, attribute(element, kAXDescriptionAttribute) as? String, (attribute(element, kAXValueAttribute)).map { "\($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.map { limitedUTF16($0.replacingOccurrences(of: "\n", with: " "), to: 120) }.joined(separator: " · ")
            var frame = ""
            if let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute), CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                var point = CGPoint.zero, extent = CGSize.zero
                AXValueGetValue(position as! AXValue, .cgPoint, &point); AXValueGetValue(size as! AXValue, .cgSize, &extent)
                frame = " [\(Int(point.x)),\(Int(point.y)) \(Int(extent.width))×\(Int(extent.height))]"
            }
            lines.append(String(repeating: "  ", count: level) + role + (label.isEmpty ? "" : " “\(label)”") + frame)
            for child in ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(80) { walk(child, level: level + 1) }
        }
        walk(AXUIElementCreateApplication(pid), level: 0)
        if Date() >= deadline { lines.append("[Stopped after 8 s: the app answered Accessibility slowly.]") }
        return (lines.joined(separator: "\n"), count)
    }
    static func peekabooRun(_ executable: String, _ arguments: [String], scratch: URL) async throws -> NativeProcessResult {
        var environment = nativeProviderEnvironment()
        environment["PEEKABOO_NO_COLOR"] = "1"
        return try await NativeProcess.run(executable: executable, arguments: arguments, directory: scratch, environment: environment, timeoutSeconds: 30, outputLimit: 2_000_000)
    }
}

/// The unsandboxed lane: shell commands and files as Jason's user, with real
/// network and filesystem access. Builder's private-workspace lane is unchanged.
enum HostLane {
    static func environment() -> [String: String] {
        var values = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SILKWIRE_") && !$0.key.hasPrefix("XPC_") }
        values["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        values["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + (values["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        values["SILKWIRE_AGENT_SHELL"] = "1"
        values["GIT_TERMINAL_PROMPT"] = "0"
        return values
    }
    static func defaultDirectory() -> String {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
        return FileManager.default.fileExists(atPath: projects.path) ? projects.path : FileManager.default.homeDirectoryForCurrentUser.path
    }
    /// Runs under a login zsh so Jason's PATH and tools apply. Full output is saved
    /// to `logDirectory`; the agent gets a bounded head and tail plus that path.
    static func shell(_ request: ComputerRequest, logDirectory: URL) async throws -> [String: Any] {
        let directory = URL(fileURLWithPath: ComputerRequest.expand(request.cwd ?? defaultDirectory()))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw nativeFailure("The working directory \(directory.path) does not exist. Nothing ran.") }
        let started = Date()
        let timeout = request.timeout ?? 900
        let result: NativeProcessResult
        do { result = try await NativeProcess.run(executable: "/bin/zsh", arguments: ["-l", "-c", request.command ?? ""], directory: directory, environment: environment(), timeoutSeconds: Double(timeout), outputLimit: 32 * 1024 * 1024, standardSignals: true, returnInterruptedResult: true) }
        catch is CancellationError { throw CancellationError() }
        catch { throw nativeFailure(Task.isCancelled ? "Stopped." : "The command did not finish within \(timeout) s (or could not start); its process group was stopped. Raise timeout (up to 3600) or run it in the background. \(error.localizedDescription)") }
        let id = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = logDirectory.appendingPathComponent(id + ".log")
        let stdout = redact(result.stdout), stderr = redact(result.stderr)
        let redacted = stdout != result.stdout || stderr != result.stderr
        let saved = (try? Data(("$ " + redact(request.command ?? "") + "\n# cwd: " + directory.path + "\n# exit: \(result.exitCode)\n\n--- stdout ---\n" + stdout + "\n--- stderr ---\n" + stderr).utf8).write(to: log, options: .atomic)) != nil
        var value: [String: Any] = ["exitCode": Int(result.exitCode), "cwd": directory.path, "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
                                    "stdout": clip(stdout), "stderr": clip(stderr, head: 2000, tail: 6000), "outputTruncated": result.truncated, "redacted": redacted]
        if redacted { value["redactionNotice"] = "Recognized credentials were removed. Do not reconstruct or overwrite files from redacted output." }
        if !saved { value["outputWarning"] = "Full shell output could not be saved." }
        if saved { value["fullOutput"] = log.path }
        if Task.isCancelled { value["stopped"] = true }
        return value
    }
    /// Best-effort recognized-secret filtering, independent of approval. This is
    /// not a detector for arbitrary private prose or unknown credential formats.
    static let secretRules: [(String, Int)] = [
        (#"-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----"#, 0),
        (#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{6,}"#, 0),
        (#"\b(?:sk|rk|pk)-[A-Za-z0-9_-]{16,}"#, 0),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, 0),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, 0),
        (#"\bxox[baprs]-[A-Za-z0-9-]{10,}"#, 0),
        (#"\bAKIA[0-9A-Z]{12,}"#, 0),
        (#"\bAIza[0-9A-Za-z_-]{30,}"#, 0),
        (#"(?i)\bBearer\s+([A-Za-z0-9._~+/-]{12,}=*)"#, 1),
        (#"(?i)\b(?:password|passwd|secret|secret[_-]?key|token|access[_-]?key|access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|auth[_-]?token|authorization)\b["']?\s*[:=]\s*["']?([^\s"',;}]{6,})"#, 1),
        (#"(?i)"(?:password|passwd|secret|secret_key|token|access_key|access_token|refresh_token|api_key|client_secret|authorization)"\s*:\s*"([^"]{6,})""#, 1),
    ]
    static func scrubSecrets(_ value: String) -> (String, Bool) {
        let filtered = redact(value); return (filtered, filtered != value)
    }
    static func redact(_ value: String) -> String {
        var text = NativeBuilder.scrub(value)
        for pattern in [
            #"(?i)([\"']?(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|client[_-]?secret|password|authorization|openai_api_key)[\"']?\s*[=:]\s*)[\"'][^\"'\r\n]*[\"']"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#,
            #"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"#
        ] {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        for (pattern, group) in secretRules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let mutable = NSMutableString(string: text)
            for match in matches.reversed() {
                let range = match.range(at: group)
                if range.location != NSNotFound { mutable.replaceCharacters(in: range, with: "[redacted]") }
            }
            text = mutable as String
        }
        return text
    }
    static func clip(_ text: String, head: Int = 6000, tail: Int = 14000) -> String {
        guard text.utf16.count > head + tail + 200 else { return text }
        let start = ContextBudget.clipUTF16(text, to: head)
        var end = String(text.suffix(tail)); while end.utf16.count > tail { end.removeFirst() }
        return start + "\n[… \(text.utf16.count - head - tail) characters omitted; read fullOutput for all of it …]\n" + end
    }
    static func read(_ request: ComputerRequest) throws -> [String: Any] {
        let url = URL(fileURLWithPath: ComputerRequest.expand(request.path ?? ""))
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw nativeFailure("\(url.path) is not a regular file.") }
        guard (values.fileSize ?? 0) <= 16 * 1024 * 1024 else { throw nativeFailure("\(url.path) is over 16 MB; use shell to inspect part of it.") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw nativeFailure("\(url.path) is not UTF-8 text; use shell (for example xxd or file) instead.") }
        let lines = text.components(separatedBy: "\n")
        let first = min(request.startLine, max(1, lines.count)), last = min(lines.count, first + request.lineCount - 1)
        let body = lines[(first - 1)..<last].enumerated().map { "\(first + $0.offset)\t\($0.element)" }.joined(separator: "\n")
        // Known credential stores are withheld as a whole, including formats we
        // do not recognize. The rule also checks the resolved path for symlinks.
        let sensitive = AskFirstPolicy.isCredentialPath(url.path) || AskFirstPolicy.isCredentialPath(url.resolvingSymlinksInPath().path)
        let filtered = sensitive ? "[redacted credential store]" : redact(body)
        return ["path": url.path, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "lines": lines.count, "startLine": first, "endLine": last,
                "text": ContextBudget.clipUTF16(filtered, to: 24_000), "truncated": filtered.utf16.count > 24_000 || last < lines.count,
                "redacted": filtered != body, "redactionNotice": filtered != body ? "Credentials were removed. This is not complete file content; do not reconstruct or overwrite from it." : ""]
    }
    static func write(_ request: ComputerRequest) throws -> [String: Any] {
        let url = URL(fileURLWithPath: ComputerRequest.expand(request.path ?? ""))
        let existed = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((request.content ?? "").utf8)
        try data.write(to: url, options: .atomic)
        return ["path": url.path, "bytes": data.count, "replacedExisting": existed, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
}
