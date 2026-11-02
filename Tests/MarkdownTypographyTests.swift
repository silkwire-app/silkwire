import Foundation

@main struct MarkdownTypographyTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        // Heading scale: every level is distinct and steps down; none smaller than body text.
        let scales = (1...6).map(DocumentTypography.headingScale)
        check(zip(scales, scales.dropFirst()).allSatisfy { $0 >= $1 }, "heading sizes step down by level")
        check(scales[0] > scales[1] && scales[1] > scales[2] && scales[2] > scales[3] && scales[3] > 1.0, "levels 1 to 4 are each visibly larger than body text")
        check(scales.allSatisfy { $0 >= 1.0 }, "no heading is smaller than body text")
        // Proportional sizing holds when the reader enlarges text.
        check(abs(DocumentTypography.measure(20) / DocumentTypography.measure(14.5) - 20 / 14.5) < 0.0001, "line length scales with text size")
        check((500...620).contains(DocumentTypography.measure(14.5)), "default line length is about 70 characters")

        // Spacing: more air above a heading than below it.
        let blocks = MarkdownBlock.parse("Intro\n\n## Overview\n\nBody\n\n- one\n- two\n\n### Detail\n\n#### Small\n\nText")
        check(blocks.map(\.kind) == ["paragraph", "heading", "paragraph", "bullet", "bullet", "heading", "heading", "paragraph"], "document parses into expected blocks")
        func space(_ i: Int) -> CGFloat { DocumentTypography.spaceBefore(blocks[i], after: i > 0 ? blocks[i - 1] : nil, bodySize: 15) }
        check(space(0) == 0, "first block has no extra space above")
        check(space(1) >= space(2) * 3, "space above a heading is well over the space below it")
        check(space(4) < space(3), "list items sit closer together than separate paragraphs")
        check(space(6) < space(5), "stacked headings stay together")

        // Lists: nesting and number markers.
        let list = MarkdownBlock.parse("- top\n  - nested\n    - deeper\n\t- tabbed\n1. first\n10. tenth\n   2) inner")
        check(list.map(\.level) == [0, 1, 2, 1, 0, 0, 1], "nesting depth from spaces and tabs")
        check(list[4].marker == "1." && list[4].text == "first", "number marker separated from its text")
        check(list[5].marker == "10." && list[6].marker == "2)" && list[6].text == "inner", "multi-digit and parenthesis markers")
        check(DocumentTypography.bulletGlyph(0) != DocumentTypography.bulletGlyph(1), "nested bullets use a different mark")
        check(MarkdownBlock.parse("# Heading\n\n- First\n- Second\n\n```swift\nlet x = 1\n```\n\n> Quoted\n\n1. Ordered").map(\.kind) == ["heading", "bullet", "bullet", "code", "quote", "number"], "existing block kinds unchanged")
        check(MarkdownBlock.parse("```\n    - indented code\n```").first?.text == "    - indented code", "code blocks keep their indentation")

        // Note settings (front matter) fold away; the body is untouched.
        let front = DocumentDetails.split("---\nproject: Collaborative Agent Workspace\ntype: product-map\ntags:\n  - product-map\n  - blue-sky\n---\n# Product Map\nBody")
        check(front.fields.map(\.key) == ["project", "type", "tags"], "front matter keys found")
        check(front.fields[2].value == "product-map, blue-sky", "front matter list values joined")
        check(front.body == "# Product Map\nBody", "body after front matter preserved exactly")
        let quoted = DocumentDetails.split("> project: Collaborative Agent Workspace\n\n> type: product-map\n> created: 2026-10-09\nProduct Map text")
        check(quoted.fields.count == 3 && quoted.body == "Product Map text", "imported quoted settings fold away")
        check(DocumentDetails.split("> Note: one real quote\n\nText").fields.isEmpty, "a single quote is never treated as settings")
        check(DocumentDetails.split("---\nJust a rule then prose.\n").fields.isEmpty, "a leading rule followed by prose is left alone")
        check(DocumentDetails.split("How to read it: the overview first.\nMore").fields.isEmpty, "ordinary sentences with colons are not settings")
        check(DocumentDetails.field("How to read it: x") == nil && DocumentDetails.field("status: curated")?.value == "curated", "settings keys are single words")
        check(DocumentDetails.split("No settings here").body == "No settings here", "pages without settings are unchanged")
        print("PASS: \(count) Markdown typography checks")
    }
}
