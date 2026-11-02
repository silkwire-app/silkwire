import Foundation

// <<COMPUTER {...}>> parsing: exactly one marker, a known action, only its own
// fields, bounded values. Malformed requests run nothing and say why.
@main struct ComputerProtocolTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func parsed(_ text: String) -> ComputerRequest? { (try? ComputerRequest.parse(text)) ?? nil }
        func refused(_ text: String, mentioning: String? = nil) -> Bool {
            do { _ = try ComputerRequest.parse(text); return false }
            catch { return mentioning.map { error.localizedDescription.contains($0) } ?? error.localizedDescription.hasPrefix("No computer action ran.") }
        }

        // No marker at all is an ordinary reply, not an error.
        check((try? ComputerRequest.parse("Here is my plain answer.")) == .some(nil), "plain replies carry no request")
        check((try? ComputerRequest.parse("")) == .some(nil), "an empty reply carries no request")

        // Every action, with surrounding whitespace tolerated.
        let shot = parsed("  <<COMPUTER {\"action\":\"screenshot\"}>>\n")
        check(shot?.action == .screenshot && shot?.app == nil, "whole-screen screenshot")
        let window = parsed(#"<<COMPUTER {"action":"screenshot","app":"Safari","window":"Silkwire — Home"}>>"#)
        check(window?.app == "Safari" && window?.window == "Silkwire — Home", "app and window screenshot")
        let click = parsed(#"<<COMPUTER {"action":"click","x":120.5,"y":44,"reason":"Open the File menu"}>>"#)
        check(click?.action == .click && click?.x == 120.5 && click?.y == 44 && click?.reason == "Open the File menu", "click with coordinates and a reason")
        check(parsed(#"<<COMPUTER {"action":"doubleClick","x":1,"y":2}>>"#)?.action == .doubleClick, "double-click")
        check(parsed(#"<<COMPUTER {"action":"rightClick","x":1,"y":2}>>"#)?.action == .rightClick, "right-click")
        let drag = parsed(#"<<COMPUTER {"action":"drag","from":[10,20],"to":[300,400]}>>"#)
        check(drag?.x == 10 && drag?.y == 20 && drag?.toX == 300 && drag?.toY == 400, "drag from and to")
        let scroll = parsed(#"<<COMPUTER {"action":"scroll","x":500,"y":500,"dy":5}>>"#)
        check(scroll?.dy == 5 && scroll?.dx == 0, "scroll down five lines")
        check(parsed(#"<<COMPUTER {"action":"type","text":"hello >> world"}>>"#)?.text == "hello >> world", "typed text may contain >>")
        let keys = parsed(#"<<COMPUTER {"action":"key","keys":"cmd+shift+t"}>>"#)
        check(keys?.keys == [KeyCombo(modifiers: [.command, .shift], key: "t", keyCode: 17)], "key combination parses modifiers and key code")
        let sequence = parsed(#"<<COMPUTER {"action":"key","keys":["Command+A","delete","return"]}>>"#)
        check(sequence?.keys.map(\.description) == ["cmd+a", "delete", "return"], "key sequence, aliases and case are normalized")
        check(parsed(#"<<COMPUTER {"action":"key","keys":"ctrl+alt+f12"}>>"#)?.keys.first?.keyCode == 111, "function keys map to virtual key codes")
        check(parsed(#"<<COMPUTER {"action":"open","app":"Xcode"}>>"#)?.app == "Xcode", "open an app")
        check(parsed(#"<<COMPUTER {"action":"open","url":"https://staging.example-app.app"}>>"#)?.url == "https://staging.example-app.app", "open a web address")
        check(parsed(#"<<COMPUTER {"action":"focus","app":"Terminal"}>>"#)?.action == .focus, "focus an app")
        let tree = parsed(#"<<COMPUTER {"action":"tree","app":"Finder","depth":4}>>"#)
        check(tree?.depth == 4 && tree?.app == "Finder", "UI tree with depth")
        check(parsed(#"<<COMPUTER {"action":"tree"}>>"#)?.depth == 6, "UI tree of the frontmost app defaults to depth 6")
        check(parsed(#"<<COMPUTER {"action":"wait","seconds":2.5}>>"#)?.seconds == 2.5, "wait")
        let shell = parsed(#"<<COMPUTER {"action":"shell","command":"swift Scripts/build.swift --staging && echo done >> log.txt","cwd":"~/Projects/silkwire","timeout":900}>>"#)
        check(shell?.command == "swift Scripts/build.swift --staging && echo done >> log.txt" && shell?.cwd == "~/Projects/silkwire" && shell?.timeout == 900, "shell command with cwd and timeout")
        let read = parsed(#"<<COMPUTER {"action":"read","path":"/Users/alex/Projects/silkwire/README.md","startLine":10,"lineCount":50}>>"#)
        check(read?.startLine == 10 && read?.lineCount == 50, "read a file range")
        check(parsed(#"<<COMPUTER {"action":"write","path":"~/Projects/notes.txt","content":"line\n"}>>"#)?.content == "line\n", "write a file")
        let task = parsed(#"<<COMPUTER {"action":"task","state":"start","title":"Build and test Staging"}>>"#)
        check(task?.taskState == "start" && task?.title == "Build and test Staging", "start a durable task")
        check(parsed(#"<<COMPUTER {"action":"task","state":"done","note":"All 12 suites pass."}>>"#)?.taskState == "done", "finish a durable task")

        // Only the GUI actions take the wheel; observation of the screen shares it; shell never does.
        check(ComputerRequest.Action.click.drives && ComputerRequest.Action.type.drives && !ComputerRequest.Action.screenshot.drives, "input actions drive")
        check(ComputerRequest.Action.screenshot.needsScreen && ComputerRequest.Action.open.needsScreen && !ComputerRequest.Action.shell.needsScreen && !ComputerRequest.Action.task.needsScreen, "screen actions share the wheel; shell and tasks do not")

        // Malformed: prose, fences, two markers, bad JSON, unknown actions and fields.
        check(refused("Sure, taking a look.\n<<COMPUTER {\"action\":\"screenshot\"}>>"), "prose before a marker line is refused for correction")
        check((try? ComputerRequest.parse("Use the <<COMPUTER {...}>> marker to click.")) == .some(nil), "prose quoting the marker mid-line is an ordinary reply")
        check((try? ComputerRequest.parse(#"<<WORK_PROJECT {"action":"write","path":"Sources/Silkwire/ComputerProtocol.swift","content":"static let marker = \"<<COMPUTER \"\n<<COMPUTER {}>>"}>>"#)) == .some(nil), "another protocol's request that contains the marker is not a computer request")
        check((try? ComputerRequest.parse(#"<<READ_PROJECT {"action":"search","query":"<<COMPUTER"}>>"#)) == .some(nil), "a Project search for the marker is not a computer request")
        check(refused("<<COMPUTER {\"action\":\"screenshot\"}>> and then I will click"), "prose after a marker is refused")
        check(refused("```\n<<COMPUTER {\"action\":\"screenshot\"}>>\n```"), "fenced markers are refused")
        check(refused("<<COMPUTER {\"action\":\"screenshot\"}>>\n<<COMPUTER {\"action\":\"screenshot\"}>>"), "two markers are refused")
        check(refused("<<COMPUTER {action:screenshot}>>"), "invalid JSON is refused")
        check(refused("<<COMPUTER [\"screenshot\"]>>"), "a non-object payload is refused")
        check(refused("<<COMPUTER {\"action\":\"format_disk\"}>>", mentioning: "Unknown action"), "unknown actions are refused")
        check(refused(#"<<COMPUTER {"action":"click","x":1,"y":2,"button":"middle"}>>"#, mentioning: "does not accept \"button\""), "fields another action owns are refused")
        check(refused(#"<<COMPUTER {"action":"screenshot","command":"rm -rf ~"}>>"#, mentioning: "does not accept \"command\""), "a shell command smuggled into a screenshot is refused")
        check(refused("<<COMPUTER {\"action\":\"screenshot\"}"), "an unterminated marker is refused")

        // Field validation and bounds.
        check(refused(#"<<COMPUTER {"action":"click","x":"10","y":20}>>"#), "string coordinates are refused")
        check(refused(#"<<COMPUTER {"action":"click","x":true,"y":20}>>"#), "boolean coordinates are refused")
        check(refused(#"<<COMPUTER {"action":"click","x":10}>>"#), "a click without y is refused")
        check(refused(#"<<COMPUTER {"action":"click","x":1e9,"y":20}>>"#), "off-screen coordinates are refused")
        check(refused(#"<<COMPUTER {"action":"drag","from":[1,2,3],"to":[4,5]}>>"#), "a malformed drag point is refused")
        check(refused(#"<<COMPUTER {"action":"scroll","x":1,"y":2}>>"#), "a scroll without distance is refused")
        check(refused(#"<<COMPUTER {"action":"scroll","x":1,"y":2,"dy":500}>>"#), "an oversized scroll is refused")
        check(refused(#"<<COMPUTER {"action":"scroll","x":1,"y":2,"dy":1.5}>>"#), "fractional scroll lines are refused")
        check(refused(#"<<COMPUTER {"action":"type","text":""}>>"#), "empty typing is refused")
        check(refused("<<COMPUTER {\"action\":\"type\",\"text\":\"" + String(repeating: "a", count: 4001) + "\"}>>"), "typing over 4,000 characters is refused")
        check(refused(#"<<COMPUTER {"action":"key","keys":"cmd+hyper+t"}>>"#, mentioning: "modifier"), "unknown modifiers are refused")
        check(refused(#"<<COMPUTER {"action":"key","keys":"cmd+cmd+t"}>>"#), "repeated modifiers are refused")
        check(refused(#"<<COMPUTER {"action":"key","keys":"cmd+launchrockets"}>>"#, mentioning: "Unknown key"), "unknown key names are refused")
        check(refused(#"<<COMPUTER {"action":"key","keys":[]}>>"#), "an empty key list is refused")
        check(refused(#"<<COMPUTER {"action":"key","keys":["a","b","c","d","e","f","g","h","i"]}>>"#), "more than eight key combinations are refused")
        check(refused(#"<<COMPUTER {"action":"focus"}>>"#), "focus without an app is refused")
        check(refused(#"<<COMPUTER {"action":"screenshot","window":"Inbox"}>>"#), "a window without its app is refused")
        check(refused(#"<<COMPUTER {"action":"open","app":"/Applications/Safari.app"}>>"#), "app paths are refused (names or bundle IDs only)")
        check(refused(#"<<COMPUTER {"action":"open"}>>"#), "open without a target is refused")
        check(refused(#"<<COMPUTER {"action":"open","url":"file:///etc/passwd"}>>"#), "non-web URLs are refused")
        check(refused(#"<<COMPUTER {"action":"open","url":"javascript:alert(1)"}>>"#), "script URLs are refused")
        check(refused(#"<<COMPUTER {"action":"tree","depth":40}>>"#), "deep trees are refused")
        check(refused(#"<<COMPUTER {"action":"wait","seconds":120}>>"#), "long waits are refused")
        check(refused(#"<<COMPUTER {"action":"shell","command":"   "}>>"#), "blank shell commands are refused")
        check(refused(#"<<COMPUTER {"action":"shell","command":"ls","cwd":"relative/dir"}>>"#), "relative working directories are refused")
        check(refused(#"<<COMPUTER {"action":"shell","command":"ls","timeout":0}>>"#), "zero timeouts are refused")
        check(refused(#"<<COMPUTER {"action":"shell","command":"ls","timeout":7200}>>"#), "timeouts over an hour are refused")
        check(refused(#"<<COMPUTER {"action":"read","path":"notes.txt"}>>"#), "relative read paths are refused")
        check(refused(#"<<COMPUTER {"action":"read","path":"/tmp/a","lineCount":5000}>>"#), "oversized read ranges are refused")
        check(refused(#"<<COMPUTER {"action":"write","path":"/tmp/a"}>>"#), "write without content is refused")
        check(refused(#"<<COMPUTER {"action":"task","state":"start"}>>"#), "a task start without a title is refused")
        check(refused(#"<<COMPUTER {"action":"task","state":"abandon"}>>"#), "unknown task states are refused")
        check(refused("<<COMPUTER {\"action\":\"click\",\"x\":1,\"y\":2,\"reason\":\"" + String(repeating: "r", count: 301) + "\"}>>"), "long reasons are refused")

        // Home-relative paths expand; plain-English summaries name what happens.
        check(ComputerRequest.expand("~/Projects/silkwire", home: "/Users/alex") == "/Users/alex/Projects/silkwire" && ComputerRequest.expand("/etc/hosts", home: "/Users/alex") == "/etc/hosts", "home-relative paths expand")
        check(click?.summary == "Click at (120, 44)" && shell?.summary.hasPrefix("Run `swift Scripts/build.swift") == true && keys?.summary == "Press cmd+shift+t", "summaries describe the action for Jason")

        print("ComputerProtocolTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
