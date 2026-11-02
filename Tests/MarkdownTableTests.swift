import Foundation

@main struct MarkdownTableTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            print("PASS: \(name)")
        }
        let source = "Before\n\n| Order | Outcome |\n| ---: | :--- |\n| 1 | **Comfortable composing** |\n| 2 | Singing silk |\n\nAfter"
        let blocks = MarkdownBlock.parse(source)
        check(blocks.map(\.kind) == ["paragraph", "table", "paragraph"], "table separates surrounding prose")
        let table = MarkdownTable.parse(blocks[1].text)!
        check(table.headers == ["Order", "Outcome"], "headers parsed")
        check(table.alignments == ["right", "left"], "column alignment")
        check(table.rows.count == 2 && table.rows[0][1] == "**Comfortable composing**", "inline Markdown retained")
        check(MarkdownTable.parse("A | B\n:---: | ---\na | b")?.alignments == ["center", "left"], "optional outer pipes")
        check(MarkdownTable.cells("| a\\|b | `c|d` |") == ["a|b", "`c|d`"], "escaped and code pipes")
        check(MarkdownTable.parse("| A | B |\n| --- | --- |\n| only |").map { $0.rows[0] == ["only", ""] } == true, "short rows padded")
        check(MarkdownTable.parse("A | B\n--- | nope") == nil, "malformed separator remains prose")
        check(MarkdownBlock.parse("```\n| A | B |\n| --- | --- |\n```").first?.kind == "code", "fenced tables remain code")
        check(MarkdownBlock.parse("| A | B |\n| ---").first?.kind == "paragraph", "incomplete streaming table stays readable")
        print("PASS: 10 Markdown table checks")
    }
}
