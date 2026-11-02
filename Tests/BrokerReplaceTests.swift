import Foundation

@main struct BrokerReplaceTests {
    static var failures = 0
    static func check(_ condition: Bool, _ label: String) {
        if condition { print("pass: \(label)") } else { failures += 1; print("FAIL: \(label)") }
    }
    static func refused(_ body: () throws -> String) -> Bool { (try? body()) == nil }

    static func main() {
        let source = "line one\nlet value = 1\nline three\n"
        check((try? BrokerReplace.apply(source, find: "let value = 1", replacement: "let value = 2")) == "line one\nlet value = 2\nline three\n", "a unique passage is replaced exactly")
        check(refused { try BrokerReplace.apply(source, find: "missing text", replacement: "x") }, "absent text changes nothing")
        check(refused { try BrokerReplace.apply(source, find: "line", replacement: "x") }, "ambiguous text changes nothing")
        check(refused { try BrokerReplace.apply("aaa", find: "aa", replacement: "b") }, "overlapping matches count as ambiguous")
        check(refused { try BrokerReplace.apply(source, find: "", replacement: "x") }, "empty find text is refused")
        check((try? BrokerReplace.apply("a.*b", find: ".*", replacement: "-")) == "a-b", "matching is literal, not a pattern")
        check((try? BrokerReplace.apply("keep \u{1F600} here", find: "\u{1F600}", replacement: "smile")) == "keep smile here", "emoji and other wide characters replace cleanly")
        check((try? BrokerReplace.apply(source, find: "line three\n", replacement: "")) == "line one\nlet value = 1\n", "text can be removed")
        let large = String(repeating: "filler line\n", count: 20_000) + "UNIQUE-MARKER\n"
        check((try? BrokerReplace.apply(large, find: "UNIQUE-MARKER", replacement: "DONE"))?.hasSuffix("DONE\n") == true, "a small edit to a large file needs no whole-file resend")
        if failures > 0 { print("FAIL: \(failures) BrokerReplace checks"); exit(1) }
        print("PASS: BrokerReplaceTests")
    }
}
