import SwiftUI
import AppKit

struct MarkdownTable {
    let headers: [String]
    let alignments: [String]
    let rows: [[String]]
    var columnWeights: [Double] {
        headers.indices.map { column in
            sqrt(Double(min(400, max(1, ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 1))))
        }
    }
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var result: [String] = [], cell = "", ticks = 0
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "\\" {
                cell += "\\\\"; index += 2; continue
            }
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                cell.append("|"); index += 2; continue
            }
            if character == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                let count = index - start
                if ticks == 0 { ticks = count } else if ticks == count { ticks = 0 }
                cell += String(repeating: "`", count: count); continue
            }
            if character == "|", ticks == 0 { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
            index += 1
        }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        return result
    }
    static func parse(_ source: String) -> MarkdownTable? {
        let lines = source.components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].contains("|") else { return nil }
        let headers = cells(lines[0]), separators = cells(lines[1])
        guard !headers.isEmpty, headers.count == separators.count,
              separators.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        let alignments = separators.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? "center" : "right") : "left" }
        let rows = lines.dropFirst(2).map { line -> [String] in
            let values = cells(line)
            return Array((values + Array(repeating: "", count: headers.count)).prefix(headers.count))
        }
        return MarkdownTable(headers: headers, alignments: alignments, rows: rows)
    }
}

struct MarkdownBlock: Identifiable {
    let id: Int
    let kind: String
    let text: String
    let level: Int
    /// A numbered item's own marker ("1.", "10)"), kept apart so numbers hang in their own column.
    var marker: String = ""
    static func parse(_ source: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = [], paragraph: [String] = [], code: [String] = []
        var fence: String?
        func add(_ kind: String, _ text: String, _ level: Int = 0, marker: String = "") {
            result.append(MarkdownBlock(id: result.count, kind: kind, text: text, level: level, marker: marker))
        }
        func flush() { if !paragraph.isEmpty { add("paragraph", paragraph.joined(separator: "\n")); paragraph = [] } }
        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Nesting depth for list items: each tab, or every two spaces, is one step in.
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let depth = min(4, leading.filter { $0 == "\t" }.count + leading.filter { $0 == " " }.count / 2)
            if let current = fence {
                if trimmed.hasPrefix(current), trimmed.dropFirst(current.count).allSatisfy({ $0 == current.first! }) {
                    add("code", code.joined(separator: "\n")); code = []; fence = nil
                } else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); let marker = trimmed.first!; let count = trimmed.prefix { $0 == marker }.count
                fence = String(repeating: String(marker), count: count); continue
            }
            if index < lines.count, MarkdownTable.parse(line + "\n" + lines[index]) != nil {
                flush()
                var table = [line, lines[index]]; index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, lines[index].contains("|") {
                    table.append(lines[index]); index += 1
                }
                add("table", table.joined(separator: "\n")); continue
            }
            if trimmed.isEmpty { flush(); continue }
            let rule = trimmed.filter { !$0.isWhitespace }
            if rule.count >= 3, let marker = rule.first, ["-", "*", "_"].contains(marker), rule.allSatisfy({ $0 == marker }) {
                flush(); add("divider", ""); continue
            }
            let heading = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(heading), trimmed.dropFirst(heading).first == " " {
                flush(); add("heading", String(trimmed.dropFirst(heading + 1)), heading)
            } else if trimmed.hasPrefix("> ") {
                flush(); add("quote", String(trimmed.dropFirst(2)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush(); add("bullet", String(trimmed.dropFirst(2)), depth)
            } else if let number = trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
                flush(); add("number", String(trimmed[number.upperBound...]), depth, marker: String(trimmed[number]).trimmingCharacters(in: .whitespaces))
            } else { paragraph.append(line) }
        }
        flush()
        if fence != nil { add("code", code.joined(separator: "\n")) }
        return result
    }
}

/// Alexandria's reading typography, following the conventions of established document
/// stylesheets: a stepped heading scale, more space above a heading than below it,
/// about 70 characters per line, and hanging list indents. Sizes are relative to the
/// body size, so everything still holds when the reader enlarges the text.
enum DocumentTypography {
    static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.85
        case 2: return 1.45
        case 3: return 1.22
        case 4: return 1.08
        default: return 1.0
        }
    }
    /// Comfortable reading width: roughly 70 characters of body text.
    static func measure(_ bodySize: CGFloat) -> CGFloat { bodySize * 38 }
    static func bulletGlyph(_ level: Int) -> String { ["•", "◦", "▪︎", "–"][min(max(level, 0), 3)] }
    /// Space above a block, given the block before it.
    static func spaceBefore(_ block: MarkdownBlock, after previous: MarkdownBlock?, bodySize: CGFloat) -> CGFloat {
        guard let previous else { return 0 }
        let lists: Set<String> = ["bullet", "number"]
        if block.kind == "heading" {
            if previous.kind == "heading" { return bodySize * 0.5 }
            if block.level <= 2 { return bodySize * 1.7 }
            return bodySize * (block.level == 3 ? 1.3 : 1.0)
        }
        if previous.kind == "heading" { return bodySize * 0.5 }
        if lists.contains(block.kind) && lists.contains(previous.kind) { return bodySize * 0.3 }
        if block.kind == "quote" && previous.kind == "quote" { return bodySize * 0.2 }
        if block.kind == "divider" || previous.kind == "divider" { return bodySize * 0.9 }
        return bodySize * 0.8
    }
}

/// A note's settings (Obsidian front matter such as project, type, status, tags),
/// separated from its text so the reader can tuck them into a collapsed row.
/// Presentation only: the stored Markdown is never changed.
struct DocumentDetails: Equatable {
    struct Field: Equatable { let key: String; let value: String }
    let fields: [Field]
    let body: String
    static func field(_ line: String) -> Field? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,40}$"#, options: .regularExpression) != nil else { return nil }
        let rest = line[line.index(after: colon)...]
        guard rest.isEmpty || rest.first == " " else { return nil }
        return Field(key: key, value: rest.trimmingCharacters(in: .whitespaces))
    }
    /// Unfenced quotations are ambiguous: recognize only established note-setting keys.
    /// Explicit YAML front matter still accepts custom fields.
    /// Common Obsidian note properties. A quoted block at the very top counts as settings
    /// only when every line is one of these and there are at least two of them; any
    /// other quoted line keeps the whole quotation visible (Codex review).
    static let knownKeys: Set<String> = ["project", "type", "status", "created", "updated", "modified", "tags", "aliases",
        "author", "authors", "date", "source", "url", "category", "categories", "kind", "owner", "version", "priority",
        "summary", "description", "topic", "area", "related", "people", "due", "publish", "cssclasses", "stage", "reviewed"]
    static func quotedField(_ line: String) -> Field? {
        guard let found = field(line), knownKeys.contains(found.key.lowercased()) else { return nil }
        return found
    }
    static func split(_ source: String) -> DocumentDetails {
        let unchanged = DocumentDetails(fields: [], body: source)
        let lines = source.components(separatedBy: "\n")
        var start = 0
        while start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).isEmpty { start += 1 }
        guard start < lines.count else { return unchanged }
        if lines[start].trimmingCharacters(in: .whitespaces) == "---" {
            var fields: [Field] = [], index = start + 1
            while index < lines.count, index <= start + 60 {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line == "---" || line == "..." {
                    guard !fields.isEmpty else { return unchanged }
                    return DocumentDetails(fields: fields, body: lines[(index + 1)...].joined(separator: "\n"))
                }
                if let found = field(line) { fields.append(found) }
                else if line.hasPrefix("- "), let last = fields.popLast() {
                    let item = String(line.dropFirst(2))
                    fields.append(Field(key: last.key, value: last.value.isEmpty ? item : last.value + ", " + item))
                } else if !line.isEmpty { return unchanged }
                index += 1
            }
            return unchanged
        }
        // Imported notes may carry the same settings as quoted "key: value" lines at the top.
        var fields: [Field] = [], index = start, end = start
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { index += 1; continue }
            guard line.hasPrefix(">") else { break }
            // Preserve the whole quotation if any line is ordinary prose or an unknown field.
            guard let found = quotedField(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) else { return unchanged }
            fields.append(found); index += 1; end = index
        }
        guard fields.filter({ knownKeys.contains($0.key.lowercased()) }).count >= 2 else { return unchanged }
        return DocumentDetails(fields: fields, body: lines[end...].joined(separator: "\n"))
    }
}

@discardableResult func copyText(_ text: String, pasteboard: any NativeTextPasteboard = NSPasteboard.general) -> Bool { pasteboard.clearContents(); return pasteboard.setString(text, forType: .string) }
struct CopyFeedbackButton: View {
    let text: String
    var title = "Copy"
    @State private var copied = false
    @State private var reset: Task<Void, Never>?
    var body: some View {
        Button {
            guard copyText(text) else { copied = false; return }
            copied = true; reset?.cancel(); reset = Task { try? await Task.sleep(for: .milliseconds(1500)); if !Task.isCancelled { copied = false } }
        } label: { Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc") }
        .font(.caption).buttonStyle(.borderless).foregroundStyle(copied ? Color.purple : Color.secondary).help(copied ? "Copied" : title).onDisappear { reset?.cancel() }
    }
}

struct MessageMarkdown: View, Equatable {
    let source: String
    /// Alexandria pages may link to other pages (alexandria:// only); chat messages never can.
    var libraryLinks = false
    /// Body size, so bold text matches when Alexandria reads at a larger size.
    var bodySize: CGFloat = 14.5
    /// Alexandria reader preference: serif body text.
    var serif = false
    private func inline(_ source: String) -> AttributedString {
        var value = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        // Only ordinary web links are interactive; no file/custom-scheme launches from model text.
        let links = value.runs.compactMap { run in run.link.map { (run.range, $0) } }
        for (range, link) in links where !["https", "http"].contains(link.scheme?.lowercased() ?? "") && !(libraryLinks && link.scheme == Alexandria.linkScheme) { value[range].link = nil }
        // Bold reads as Avenir Next Demi Bold: enough emphasis, without breaking the lightness.
        let strong = value.runs.compactMap { run -> (Range<AttributedString.Index>, InlinePresentationIntent)? in
            guard let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) else { return nil }
            return (run.range, intent)
        }
        for (range, intent) in strong {
            var lighter = intent; lighter.remove(.stronglyEmphasized)
            value[range].inlinePresentationIntent = lighter.isEmpty ? nil : lighter
            value[range].font = serif ? .system(size: bodySize, weight: .semibold, design: .serif) : SilkwireReadingType.strong(bodySize)
        }
        return value
    }
    private func tableAlignment(_ value: String) -> Alignment { value == "right" ? .trailing : value == "center" ? .center : .leading }
    private func tableTextAlignment(_ value: String) -> TextAlignment { value == "right" ? .trailing : value == "center" ? .center : .leading }
    private func tableView(_ table: MarkdownTable) -> some View {
        VStack(spacing: 0) {
            TableRowLayout(weights: table.columnWeights) {
                ForEach(table.headers.indices, id: \.self) { column in
                    Text(inline(table.headers[column])).fontWeight(.semibold)
                        .multilineTextAlignment(tableTextAlignment(table.alignments[column]))
                        .frame(maxWidth: .infinity, alignment: tableAlignment(table.alignments[column])).padding(10)
                }
            }.background(SilkwireTheme.wash(0.08))
            ForEach(table.rows.indices, id: \.self) { row in
                TableRowLayout(weights: table.columnWeights) {
                    ForEach(table.headers.indices, id: \.self) { column in
                        Text(inline(table.rows[row][column]))
                            .multilineTextAlignment(tableTextAlignment(table.alignments[column]))
                            .frame(maxWidth: .infinity, alignment: tableAlignment(table.alignments[column])).padding(10)
                    }
                }.background(SilkwireTheme.wash(row.isMultiple(of: 2) ? 0.025 : 0.045))
            }
        }.frame(maxWidth: .infinity).textSelection(.enabled)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(SilkwireTheme.wash(0.12)))
    }
    /// Alexandria pages (not chat) get document typography. Presentation only.
    private var document: Bool { libraryLinks }
    private var markerWidth: CGFloat { document ? bodySize * 1.25 : 15 }
    private var numberWidth: CGFloat { document ? bodySize * 1.6 : 20 }
    private var indentStep: CGFloat { document ? bodySize * 1.5 : 18 }
    private func headingFont(_ level: Int) -> Font {
        guard document else { return level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline }
        let size = bodySize * DocumentTypography.headingScale(level)
        return serif ? .system(size: size, weight: .semibold, design: .serif) : SilkwireReadingType.strong(size)
    }
    private func detailsView(_ fields: [DocumentDetails.Field]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(field.key).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
                        Text(field.value).textSelection(.enabled)
                    }
                }
            }.padding(.top, 4)
        } label: { Text("Document details").foregroundStyle(.secondary) }
        .font(.system(size: max(11, bodySize * 0.8)))
    }
    var body: some View {
        let details = document ? DocumentDetails.split(source) : DocumentDetails(fields: [], body: source)
        let blocks = MarkdownBlock.parse(details.body)
        VStack(alignment: .leading, spacing: document ? 0 : 9) {
            if !details.fields.isEmpty { detailsView(details.fields).padding(.bottom, bodySize * 0.6) }
            if document {
                ForEach(blocks) { block in
                    blockView(block)
                        .padding(.top, DocumentTypography.spaceBefore(block, after: block.id > 0 ? blocks[block.id - 1] : nil, bodySize: bodySize))
                }
            } else {
                // Chat: consecutive prose blocks render as ONE selectable text, so a
                // reader can select across paragraphs, lists and quotes in one drag.
                ForEach(Self.chatGroups(blocks)) { group in
                    if group.prose {
                        Text(proseText(group.blocks)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let block = group.blocks.first {
                        blockView(block)
                    }
                }
            }
        }
        .frame(maxWidth: document ? DocumentTypography.measure(bodySize) : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    struct ChatGroup: Identifiable { let id: Int; let prose: Bool; var blocks: [MarkdownBlock] }
    /// Runs of prose blocks become one group; dividers, tables and code stay separate.
    static func chatGroups(_ blocks: [MarkdownBlock]) -> [ChatGroup] {
        var groups: [ChatGroup] = []
        for block in blocks {
            let prose = !["divider", "table", "code"].contains(block.kind)
            if prose, let last = groups.last, last.prose { groups[groups.count - 1].blocks.append(block) }
            else { groups.append(ChatGroup(id: groups.count, prose: prose, blocks: [block])) }
        }
        return groups
    }
    private func proseText(_ blocks: [MarkdownBlock]) -> AttributedString {
        var out = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                let previous = blocks[index - 1].kind
                let listRun = ["bullet", "number"].contains(block.kind) && ["bullet", "number"].contains(previous)
                out += AttributedString(listRun ? "\n" : "\n\n")
            }
            let indent = String(repeating: "    ", count: max(0, block.level))
            switch block.kind {
            case "heading":
                var heading = inline(block.text); heading.font = headingFont(block.level); out += heading
            case "bullet":
                out += AttributedString(indent + DocumentTypography.bulletGlyph(block.level) + " "); out += inline(block.text)
            case "number":
                out += AttributedString(indent + block.marker + " "); out += inline(block.text)
            case "quote":
                var quote = AttributedString("▎ ") + inline(block.text); quote.foregroundColor = .secondary; out += quote
            default:
                out += inline(block.text)
            }
        }
        return out
    }
    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
                switch block.kind {
                case "divider": Divider().padding(.vertical, 4)
                case "table":
                    if let table = MarkdownTable.parse(block.text) { tableView(table) }
                case "code":
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Code").font(.caption).foregroundStyle(.secondary); Spacer(); CopyFeedbackButton(text: block.text, title: "Copy code") }
                        // Wraps long lines so nothing is cut off; Copy code still copies the original text.
                        Text(block.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(12).background(SilkwireTheme.well(0.16), in: RoundedRectangle(cornerRadius: 8))
                case "heading":
                    Text(inline(block.text)).font(headingFont(block.level)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                case "bullet":
                    // Hanging indent: wrapped lines align with the text, not the bullet.
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(DocumentTypography.bulletGlyph(block.level)).frame(width: markerWidth, alignment: .leading)
                        Text(inline(block.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(block.level) * indentStep)
                case "number":
                    // Numbers right-align in their own column, so 9. and 10. line up.
                    HStack(alignment: .firstTextBaseline, spacing: document ? bodySize * 0.45 : 6) {
                        Text(block.marker).monospacedDigit().frame(width: numberWidth, alignment: .trailing)
                        Text(inline(block.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(block.level) * indentStep)
                case "quote": HStack(alignment: .top, spacing: 10) { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 3); Text(inline(block.text)).foregroundStyle(.secondary).textSelection(.enabled) }.fixedSize(horizontal: false, vertical: true)
                default: Text(inline(block.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
    }
}

// Each row measures wrapped content at the actual available column width. Its
// single background spans the tallest cell; no fixed height or intrinsic-width cap.
struct TableRowLayout: Layout {
    let weights: [Double]
    func widths(_ width: CGFloat) -> [CGFloat] {
        let minimum = min(100, width / CGFloat(max(1, weights.count)))
        let extra = max(0, width - minimum * CGFloat(weights.count)), sum = max(1, weights.reduce(0, +))
        return weights.map { minimum + extra * $0 / sum }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 640), cells = widths(width)
        return CGSize(width: width, height: subviews.enumerated().map { index, view in view.sizeThatFits(.init(width: cells[index], height: nil)).height }.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cells = widths(bounds.width)
        var x = bounds.minX
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: .init(width: cells[index], height: bounds.height))
            x += cells[index]
        }
    }
}
