import Foundation

@main struct CombinedReaderReviewTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let prose = "> Warning: Keep this visible\n> Action: Read carefully\n# Product Map\nBody"
        check(DocumentDetails.split(prose).body == prose && DocumentDetails.split(prose).fields.isEmpty, "ordinary colon-bearing quotations remain visible")
        check(AlexandriaReading.displayBody(prose, title: "Product Map") == prose, "a heading after quoted prose is not suppressed")
        let mixed = "> project: Example\n> type: map\n> Warning: Keep visible\n# Product Map"
        check(DocumentDetails.split(mixed).fields.isEmpty, "mixed metadata and prose keep the whole quotation")
        check(AlexandriaReading.displayBody(mixed, title: "Product Map") == mixed, "mixed quoted prose prevents title suppression")
        let single = "> status: quoted prose\n# Product Map"
        check(AlexandriaReading.displayBody(single, title: "Product Map") == single, "one ambiguous quoted field is preserved")
        let imported = "> project: Example\n\n> type: map\n> tags: [one, two]\n# Product Map\n\n## Overview\nBody"
        let displayed = AlexandriaReading.displayBody(imported, title: "Product Map")
        let details = DocumentDetails.split(displayed)
        check(details.fields.count == 3, "title suppression retains all recognized imported settings")
        check(details.body == "\n## Overview\nBody", "combined reader removes only the repeated title")
        check(imported.contains("# Product Map"), "input Markdown remains unchanged")
        let yaml = "\n---\ncustom_key: custom value\ntags:\n  - one\n  - two\n---\n# Product Map\nText"
        let yamlDisplay = AlexandriaReading.displayBody(yaml, title: "Product Map")
        check(DocumentDetails.split(yamlDisplay).fields.first?.key == "custom_key", "explicit YAML retains custom fields")
        check(DocumentDetails.split(yamlDisplay).body == "Text", "leading blank YAML and repeated title compose correctly")
        let malformed = "---\nstatus: unfinished\n# Product Map\nText"
        check(AlexandriaReading.displayBody(malformed, title: "Product Map") == malformed, "unclosed front matter is not skipped")
        check(DocumentDetails.split("> custom_key: visible\n> other_key: visible\nText").fields.isEmpty, "unknown unfenced fields remain document content")
        check(DocumentDetails.split("> PROJECT: Example\n> TYPE: map\nText").fields.count == 2, "recognized quoted keys are case insensitive")
        check(SiloLayout.drawerHeight(available: 800, composerHeight: 220) == 551, "drawer stops above composer and divider")
        check(SiloLayout.drawerHeight(available: 800, composerHeight: 400) == 371, "drawer follows a taller composer")
        check(SiloLayout.drawerHeight(available: 200, composerHeight: 220) == 0, "no drawer overlay when transcript has no room")
        check(SiloLayout.drawerHeight(available: 800, composerHeight: 0) == 0, "unmeasured composer fails closed")
        check(SiloLayout.drawerHeight(available: .infinity, composerHeight: 200) == 0 && SiloLayout.drawerHeight(available: 800, composerHeight: .nan) == 0, "invalid drawer geometry fails closed")
        for size: CGFloat in [12, 14.5, 20, 28] {
            check(DocumentTypography.headingScale(1) * size > DocumentTypography.headingScale(2) * size && DocumentTypography.headingScale(2) * size > size, "heading hierarchy scales at body size \(size)")
        }
        print("PASS: \(count) combined reader and silo regression checks (model-level, not rendered UI)")
    }
}
