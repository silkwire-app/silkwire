import Foundation

/// One validated `<<COMPUTER {...}>>` request. The model's reply text is only a
/// request; Silkwire checks it, applies Jason's ask-first list and performs it.
struct ComputerRequest: Equatable {
    enum Action: String, CaseIterable {
        case screenshot, click, doubleClick, rightClick, drag, scroll, type, key, open, focus, tree, wait, shell, read, write, task
        /// Actions that move the pointer or send keys need the wheel (idle/takeover rules).
        var drives: Bool { [.click, .doubleClick, .rightClick, .drag, .scroll, .type, .key].contains(self) }
        /// Screen and app observation/activation share the wheel too: they change focus or
        /// would capture Jason mid-gesture. Shell, files, wait and task never need it.
        var needsScreen: Bool { drives || [.screenshot, .tree, .open, .focus].contains(self) }
    }
    var action: Action
    var x: Double?
    var y: Double?
    var toX: Double?
    var toY: Double?
    var dx = 0
    var dy = 0
    var text: String?
    var keys: [KeyCombo] = []
    var app: String?
    var window: String?
    var url: String?
    var command: String?
    var cwd: String?
    var timeout: Int?
    var path: String?
    var content: String?
    var startLine = 1
    var lineCount = 200
    var depth = 6
    var seconds = 1.0
    var taskState: String?
    var title: String?
    var note: String?
    var reason: String?

    static let marker = "<<COMPUTER "
    static let correction = "No computer action ran. Return exactly ONE <<COMPUTER {JSON}>> marker with valid JSON and an offered action, no prose, fences or second request."
    private static let allowedKeys: [Action: Set<String>] = [
        .screenshot: ["app", "window"], .click: ["x", "y"], .doubleClick: ["x", "y"], .rightClick: ["x", "y"],
        .drag: ["from", "to"], .scroll: ["x", "y", "dx", "dy"], .type: ["text"], .key: ["keys"],
        .open: ["app", "url", "path"], .focus: ["app", "window"], .tree: ["app", "depth"], .wait: ["seconds"],
        .shell: ["command", "cwd", "timeout"], .read: ["path", "startLine", "lineCount"], .write: ["path", "content"],
        .task: ["state", "title", "note"]
    ]

    /// Whether a reply is trying to make a computer request: it starts with the marker, or
    /// one of its lines does (prose or fences around it get corrected). Another protocol's
    /// request that merely contains the text (a WORK_PROJECT edit of this file, a search)
    /// and prose quoting the marker mid-line are ordinary replies.
    static func isAttempt(_ reply: String) -> Bool {
        let value = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<<COMPUTER") { return true }
        guard !value.hasPrefix("<<") else { return false }
        return value.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("<<COMPUTER") }
    }
    /// nil: the reply makes no COMPUTER request. Throws: it tries to, but malformed.
    static func parse(_ reply: String) throws -> ComputerRequest? {
        let value = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAttempt(value) else { return nil }
        guard value.hasPrefix(marker), value.hasSuffix(">>"), value.utf16.count <= 1_100_000,
              let data = String(value.dropFirst(marker.count).dropLast(2)).data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw nativeFailure(correction) }
        return try validate(args)
    }

    static func validate(_ args: [String: Any]) throws -> ComputerRequest {
        guard let name = args["action"] as? String, let action = Action(rawValue: name) else { throw nativeFailure(correction + " Unknown action.") }
        let allowed = (allowedKeys[action] ?? []).union(["action", "reason"])
        if let extra = args.keys.sorted().first(where: { !allowed.contains($0) }) { throw nativeFailure("No computer action ran. \(name) does not accept \"\(extra)\".") }
        var request = ComputerRequest(action: action)
        request.reason = try string(args, "reason", limit: 300)
        func point(_ key: String) throws -> (Double, Double)? {
            guard let raw = args[key] else { return nil }
            guard let pair = raw as? [Any], pair.count == 2, let px = number(pair[0]), let py = number(pair[1]), coordinate(px), coordinate(py) else { throw nativeFailure("No computer action ran. \(key) must be [x, y] in screen points.") }
            return (px, py)
        }
        switch action {
        case .click, .doubleClick, .rightClick, .scroll:
            guard let px = args["x"].flatMap(number), let py = args["y"].flatMap(number), coordinate(px), coordinate(py) else {
                throw nativeFailure("No computer action ran. \(name) needs numeric x and y in screen points.")
            }
            request.x = px; request.y = py
            if action == .scroll {
                request.dx = try integer(args, "dx", range: -50...50) ?? 0
                request.dy = try integer(args, "dy", range: -50...50) ?? 0
                guard request.dx != 0 || request.dy != 0 else { throw nativeFailure("No computer action ran. scroll needs a nonzero dx or dy (lines).") }
            }
        case .drag:
            guard let from = try point("from"), let to = try point("to") else { throw nativeFailure("No computer action ran. drag needs from and to as [x, y].") }
            (request.x, request.y, request.toX, request.toY) = (from.0, from.1, to.0, to.1)
        case .type:
            guard let text = try string(args, "text", limit: 4000), !text.isEmpty else { throw nativeFailure("No computer action ran. type needs text (up to 4,000 characters).") }
            request.text = text
        case .key:
            let raw: [String]
            if let one = args["keys"] as? String { raw = [one] }
            else if let many = args["keys"] as? [String] { raw = many }
            else { throw nativeFailure("No computer action ran. key needs keys such as \"cmd+s\" or [\"cmd+a\", \"delete\"].") }
            guard (1...8).contains(raw.count) else { throw nativeFailure("No computer action ran. Send 1–8 key combinations per request.") }
            request.keys = try raw.map(KeyCombo.parse)
        case .screenshot, .focus, .tree:
            request.app = try appName(args)
            request.window = try string(args, "window", limit: 200)
            if request.window != nil, request.app == nil { throw nativeFailure("No computer action ran. window needs app.") }
            if action == .focus, request.app == nil { throw nativeFailure("No computer action ran. focus needs app.") }
            if action == .tree { request.depth = try integer(args, "depth", range: 1...12) ?? 6 }
        case .open:
            request.app = try appName(args)
            request.url = try string(args, "url", limit: 2000)
            request.path = try string(args, "path", limit: 1024)
            guard request.app != nil || request.url != nil || request.path != nil else { throw nativeFailure("No computer action ran. open needs app, url or path.") }
            if let url = request.url, URL(string: url)?.scheme.map({ ["http", "https"].contains($0.lowercased()) }) != true { throw nativeFailure("No computer action ran. open accepts http(s) URLs only.") }
            if let path = request.path { try validatePath(path) }
        case .wait:
            let value = args["seconds"].flatMap(number) ?? 1
            guard (0...30).contains(value) else { throw nativeFailure("No computer action ran. wait accepts 0–30 seconds.") }
            request.seconds = value
        case .shell:
            guard let command = try string(args, "command", limit: 8000), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw nativeFailure("No computer action ran. shell needs a command.") }
            request.command = command
            request.cwd = try string(args, "cwd", limit: 1024)
            if let cwd = request.cwd { try validatePath(cwd) }
            request.timeout = try integer(args, "timeout", range: 1...3600)
        case .read:
            guard let path = try string(args, "path", limit: 1024) else { throw nativeFailure("No computer action ran. read needs an absolute path.") }
            try validatePath(path); request.path = path
            request.startLine = try integer(args, "startLine", range: 1...10_000_000) ?? 1
            request.lineCount = try integer(args, "lineCount", range: 1...2000) ?? 200
        case .write:
            guard let path = try string(args, "path", limit: 1024), let content = args["content"] as? String else { throw nativeFailure("No computer action ran. write needs path and content.") }
            guard content.utf8.count <= 1_048_576, !content.contains("\0") else { throw nativeFailure("No computer action ran. write content must be UTF-8 text up to 1 MB.") }
            try validatePath(path); request.path = path; request.content = content
        case .task:
            guard let state = args["state"] as? String, ["start", "progress", "done", "blocked"].contains(state) else { throw nativeFailure("No computer action ran. task state must be start, progress, done or blocked.") }
            request.taskState = state
            request.title = try string(args, "title", limit: 200)
            request.note = try string(args, "note", limit: 4000)
            if state == "start", request.title?.isEmpty != false { throw nativeFailure("No computer action ran. task start needs a short title.") }
        }
        return request
    }

    /// Absolute or home-relative path; the host expands ~ and never follows it into a guess.
    static func expand(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }
    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/"), !path.contains("\0") else { throw nativeFailure("No computer action ran. Paths must be absolute (or start with ~/).") }
    }
    private static func appName(_ args: [String: Any]) throws -> String? {
        guard let app = try string(args, "app", limit: 200) else { return nil }
        guard !app.trimmingCharacters(in: .whitespaces).isEmpty, !app.contains("/") else { throw nativeFailure("No computer action ran. app is an application name or bundle ID, not a path.") }
        return app
    }
    private static func string(_ args: [String: Any], _ key: String, limit: Int) throws -> String? {
        guard let raw = args[key] else { return nil }
        guard let value = raw as? String, value.utf16.count <= limit, !value.contains("\0") else { throw nativeFailure("No computer action ran. \(key) must be text up to \(limit) characters.") }
        return value
    }
    private static func number(_ raw: Any) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue.isFinite ? value.doubleValue : nil
    }
    private static func integer(_ args: [String: Any], _ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let raw = args[key] else { return nil }
        guard let value = number(raw), value == value.rounded(), let whole = Int(exactly: value), range.contains(whole) else { throw nativeFailure("No computer action ran. \(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).") }
        return whole
    }
    private static func coordinate(_ value: Double) -> Bool { (-20_000...20_000).contains(value) }

    /// Plain-English line for Jason (banner, audit log, approval prompt).
    var summary: String {
        func at() -> String { "(\(Int(x ?? 0)), \(Int(y ?? 0)))" }
        switch action {
        case .screenshot: return "Screenshot of " + (app.map { $0 + (window.map { " · " + $0 } ?? "") } ?? "the screen")
        case .click: return "Click at " + at()
        case .doubleClick: return "Double-click at " + at()
        case .rightClick: return "Right-click at " + at()
        case .drag: return "Drag from " + at() + " to (\(Int(toX ?? 0)), \(Int(toY ?? 0)))"
        case .scroll: return "Scroll \(dy != 0 ? "\(dy) lines vertically" : "")\(dx != 0 && dy != 0 ? ", " : "")\(dx != 0 ? "\(dx) lines horizontally" : "") at " + at()
        case .type: return "Type \(text?.count ?? 0) characters"
        case .key: return "Press " + keys.map(\.description).joined(separator: ", ")
        case .open: return "Open " + [app, url, path].compactMap { $0 }.joined(separator: " · ")
        case .focus: return "Focus " + (app ?? "") + (window.map { " · " + $0 } ?? "")
        case .tree: return "Read the UI tree of " + (app ?? "the frontmost app")
        case .wait: return "Wait \(seconds) s"
        case .shell: return "Run `" + limitedUTF16(command ?? "", to: 160) + "`" + (cwd.map { " in " + $0 } ?? "")
        case .read: return "Read " + (path ?? "")
        case .write: return "Write \(content?.utf8.count ?? 0) bytes to " + (path ?? "")
        case .task: return "Task " + (taskState ?? "") + ((title ?? note).map { ": " + limitedUTF16($0, to: 160) } ?? "")
        }
    }
}

/// One key combination: modifiers plus a named key, e.g. cmd+shift+t or return.
struct KeyCombo: Equatable, CustomStringConvertible {
    enum Modifier: String, CaseIterable { case command = "cmd", shift, option = "alt", control = "ctrl", function = "fn" }
    var modifiers: [Modifier]
    var key: String
    var keyCode: UInt16
    var description: String { (modifiers.map(\.rawValue) + [key]).joined(separator: "+") }
    private static let modifierAliases: [String: Modifier] = ["cmd": .command, "command": .command, "⌘": .command, "shift": .shift, "⇧": .shift, "alt": .option, "option": .option, "opt": .option, "⌥": .option, "ctrl": .control, "control": .control, "⌃": .control, "fn": .function]
    /// macOS virtual key codes (ANSI layout) for keys Silkwire will press.
    static let codes: [String: UInt16] = {
        var map: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
                                       "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126]
        for (index, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { map["f\(index + 1)"] = UInt16(code) }
        return map
    }()
    static func parse(_ raw: String) throws -> KeyCombo {
        let parts = raw.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" names the = / + key pair; a bare "+" is not a key name here.
        guard parts.count >= 1, parts.count <= 5, let last = parts.last, !last.isEmpty else { throw nativeFailure("No computer action ran. Unknown key combination \"\(raw)\".") }
        var modifiers: [Modifier] = []
        for part in parts.dropLast() {
            guard let modifier = modifierAliases[part], !modifiers.contains(modifier) else { throw nativeFailure("No computer action ran. Unknown or repeated modifier in \"\(raw)\".") }
            modifiers.append(modifier)
        }
        guard let code = codes[last] else { throw nativeFailure("No computer action ran. Unknown key \"\(last)\" in \"\(raw)\".") }
        return KeyCombo(modifiers: Modifier.allCases.filter(modifiers.contains), key: last, keyCode: code)
    }
}
