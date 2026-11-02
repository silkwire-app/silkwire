import Foundation

@main struct MessageSelectionTests {
    @MainActor static func main() {
        var failures = 0
        func check(_ value: Bool, _ label: String) { if value { print("PASS: " + label) } else { failures += 1; print("FAIL: " + label) } }
        let source = "First paragraph.\n\nSecond paragraph.\n\n- one\n- two\n\n> a quote\n\n```\nlet x = 1\n```\n\nAfter the code."
        let blocks = MarkdownBlock.parse(source)
        let groups = MessageMarkdown.chatGroups(blocks)
        check(groups.count == 3, "prose, code, prose become three groups (got \(groups.count))")
        check(groups.first?.prose == true && groups.first?.blocks.count == blocks.prefix { $0.kind != "code" }.count, "every prose block before the code shares one selectable group")
        check(groups.count > 1 && groups[1].prose == false && groups[1].blocks.first?.kind == "code", "code stays its own box with Copy code")
        check(groups.last?.prose == true && groups.last?.blocks.count == 1, "prose after the code starts a new selectable group")
        check(Set(groups.map { $0.id }).count == groups.count, "group identities are unique")
        let onlyProse = MessageMarkdown.chatGroups(MarkdownBlock.parse("A\n\nB\n\nC"))
        check(onlyProse.count == 1 && onlyProse[0].blocks.count == 3, "a reply with no code is one selectable text")
        print("MessageSelectionTests: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
