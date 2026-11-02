import SwiftUI
import AppKit
import CoreText

// The brand-kit Archivo face is bundled, not resolved from a host-installed font.
// CoreText reads the original WOFF2 directly on the macOS 14+ deployment target.
enum SilkwireBrandTypography {
    static let wordmarkSize: CGFloat = 18
    static let wordmarkTracking: CGFloat = wordmarkSize * 0.17
    static let wordmarkFont: Font = {
        guard let url = Bundle.main.url(forResource: "Archivo-Italic-Variable-latin", withExtension: "woff2", subdirectory: "Fonts"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let source = descriptors.first(where: { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == "ArchivoItalic-Regular" }) else {
            return .system(size: wordmarkSize).italic()
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        // OpenType axis tags: wght = 0x77676874, wdth = 0x77647468.
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(source, [
            kCTFontVariationAttribute: [0x77676874: 400, 0x77647468: 125]
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, wordmarkSize, nil))
    }()
}

struct SilkwireWordmark: View {
    var body: some View {
        Text("SILKWIRE")
            .font(SilkwireBrandTypography.wordmarkFont)
            .tracking(SilkwireBrandTypography.wordmarkTracking)
            .foregroundStyle(SilkwireTheme.brandMark)
            .fixedSize()
            .accessibilityLabel("Silkwire")
    }
}

enum SilkwireTheme {
    // Every color follows the window's appearance: Midnight when dark, Parchment when light.
    private static func adaptive(_ pick: @escaping (ThemePalette) -> ThemeRGB, alpha: @escaping (ThemePalette) -> Double = { _ in 1 }) -> Color {
        Color(nsColor: ThemePalette.adaptive(pick, alpha: alpha))
    }
    static let accent = adaptive { $0.accent }
    static let sidebar = adaptive { $0.sidebar }
    static let sidebarFloor = adaptive { $0.sidebarFloor }
    static let surface = adaptive { $0.surface }
    static let card = adaptive { $0.card }
    static let ink = adaptive { $0.ink }
    static let inkSoft = adaptive { $0.secondaryInk }
    static let line = adaptive({ $0.ink }, alpha: { $0.lineOpacity })
    static func well(_ opacity: Double) -> Color { adaptive({ $0.well }, alpha: { opacity * $0.wellStrength }) }
    static func shade(_ white: Double) -> Color { adaptive { $0.shade(white) } }
    static let jasonBubble = adaptive { $0.jasonBubble }
    static let canvas = adaptive { $0.canvas }
    static let reading = adaptive { $0.reading }
    static let brandMark = adaptive { $0.brandMark }
    // Parchment only: a hairline stroke gives Ari's fine legs more presence at sidebar size.
    static let brandMarkStroke = adaptive({ $0.brandMark }, alpha: { $0.isLight ? 1 : 0 })
    static let sendFill = adaptive { $0.sendFill }
    // Midnight keeps its soft violet glow at the conversation edges; Parchment stays an even canvas.
    static let canvasGlowLeading = adaptive({ $0.isLight ? $0.canvas : $0.accent }, alpha: { $0.isLight ? 1 : 0.022 })
    static let canvasGlowTrailing = adaptive({ $0.isLight ? $0.canvas : $0.accent }, alpha: { $0.isLight ? 1 : 0.015 })
    // Agent bubbles: a warm sheet on the Parchment canvas, the classic faint tint on Midnight.
    static let agentBubble = adaptive { $0.agentBubble }
    static let bodyInk = adaptive { $0.bodyInk }
    static let stagingTint = adaptive { $0.stagingTint }
    static let success = adaptive { $0.success }
    static let attention = adaptive { $0.attention }
    /// Fields, code and quotes: near-white on Parchment, a dark inset on Midnight.
    static let field = adaptive({ $0.isLight ? $0.paperWhite : $0.well }, alpha: { $0.isLight ? 1 : 0.3 })
    /// Parchment cards, columns and fields get a hairline edge; Midnight relies on fill steps.
    static let cardEdge = adaptive({ $0.ink }, alpha: { $0.isLight ? $0.lineOpacity : 0 })
    static let windowNSColor = ThemePalette.adaptive { $0.window }
    static let inkNSColor = ThemePalette.adaptive { $0.ink }
    // A faint panel tint: white on Midnight, ink on Parchment.
    static func wash(_ opacity: Double) -> Color { adaptive({ $0.ink }, alpha: { opacity * $0.washStrength }) }
    private static let identityColors: [String: Color] = Dictionary(uniqueKeysWithValues: ThemePalette.midnight.identities.keys.map { name in (name, adaptive { $0.identity(name) }) })
    static func identity(_ name: String) -> Color { identityColors[name] ?? ink }
    static func project(_ key: String) -> Color {
        switch key { case "mint": return identity("Codex"); case "peach": return identity("Claude"); case "blue": return adaptive { $0.projectBlue }; case "silver": return identity("Jason"); default: return accent }
    }
}
/// One card look everywhere: fill, 12 pt corners, 16 pt padding, hairline edge on Parchment only.
extension View {
    func silkwireCard(_ fill: Color = SilkwireTheme.agentBubble, padding inset: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return padding(inset).background(fill, in: shape)
            .overlay(shape.strokeBorder(SilkwireTheme.cardEdge, lineWidth: 0.5))
    }
}
/// A result capsule drawn only from real receipts and states, never from an agent's prose.
/// A card's secondary actions show on pointer hover or when the keyboard focuses one of them.
enum TranscriptCardActions { static func visible(hovering: Bool, keyboardFocused: Bool) -> Bool { hovering || keyboardFocused } }
struct ResultPill: View {
    let text: String
    let color: Color
    var symbol = "checkmark"
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}
struct InitialCircle: View {
    let name: String
    var size: CGFloat = 26
    var body: some View {
        Text(String(name.prefix(1))).font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(SilkwireTheme.identity(name))
            .frame(width: size, height: size)
            .background(SilkwireTheme.identity(name).opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(SilkwireTheme.identity(name).opacity(0.4), lineWidth: 0.7))
            .accessibilityHidden(true)
    }
}
// Native vector of the approved Silkwire spider silhouette.
struct SilkwireSpider: Shape {
    func path(in rect: CGRect) -> Path {
        var result = Path()
        for polygon in Self.polygons {
            guard let first = polygon.first else { continue }
            func point(_ pair: (Double, Double)) -> CGPoint { CGPoint(x: rect.minX + (pair.0 - 40) / 160 * rect.width, y: rect.minY + (pair.1 - 44) / 153 * rect.height) }
            result.move(to: point(first))
            for vertex in polygon.dropFirst() { result.addLine(to: point(vertex)) }
            result.closeSubpath()
        }
        return result
    }
    private static let polygons: [[(Double, Double)]] = [
        [(125, 110.7), (155.3, 94.4), (178.1, 63.2), (189.1, 45.3), (189.1, 45.3), (176.6, 62.1), (153.2, 92.1), (123.2, 107.4)],
        [(126.3, 113.6), (161, 116.3), (188.4, 98.1), (198.6, 87), (198.6, 87), (187.3, 96.5), (160.3, 113.3), (126.6, 109.8)],
        [(126.3, 118.6), (154.1, 132), (172.4, 150.8), (178.5, 161.4), (178.5, 161.4), (173.9, 149.7), (156, 129.5), (127.9, 115.2)],
        [(123.9, 121.9), (155.3, 145.8), (177.3, 178.6), (186.8, 196.1), (186.8, 196.1), (179, 177.7), (157.6, 143.7), (126.2, 118.9)],
        [(116.8, 107.4), (86.8, 92.1), (63.4, 62.1), (50.9, 45.3), (50.9, 45.3), (61.9, 63.2), (84.7, 94.4), (115, 110.7)],
        [(113.4, 109.8), (79.7, 113.3), (52.7, 96.5), (41.4, 87), (41.4, 87), (51.6, 98.1), (79, 116.3), (113.7, 113.6)],
        [(112.1, 115.2), (84, 129.5), (66.1, 149.7), (61.5, 161.4), (61.5, 161.4), (67.6, 150.8), (85.9, 132), (113.7, 118.6)],
        [(113.8, 118.9), (82.4, 143.7), (61, 177.7), (53.2, 196.1), (53.2, 196.1), (62.7, 178.6), (84.7, 145.8), (116.1, 121.9)],
        [(121.9, 107.4), (125.5, 108.2), (124.5, 104.1), (124.5, 104.1), (124.8, 107.5), (122.3, 106.1)],
        [(117.7, 106.1), (115.2, 107.5), (115.5, 104.1), (115.5, 104.1), (114.5, 108.2), (118.1, 107.4)],
        [(120, 121.6), (120.3, 121.6), (120.7, 121.7), (121, 121.8), (121.3, 122), (121.6, 122.2), (121.8, 122.5), (122, 122.7), (122.2, 123.1), (122.4, 123.4), (122.5, 123.8), (122.6, 124.2), (122.6, 124.6), (122.6, 125), (122.5, 125.4), (122.4, 125.7), (122.2, 126.1), (122, 126.4), (121.8, 126.7), (121.6, 127), (121.3, 127.2), (121, 127.4), (120.7, 127.5), (120.3, 127.6), (120, 127.6), (119.7, 127.6), (119.3, 127.5), (119, 127.4), (118.7, 127.2), (118.4, 127), (118.2, 126.7), (118, 126.4), (117.8, 126.1), (117.6, 125.7), (117.5, 125.4), (117.4, 125), (117.4, 124.6), (117.4, 124.2), (117.5, 123.8), (117.6, 123.4), (117.8, 123.1), (118, 122.7), (118.2, 122.5), (118.4, 122.2), (118.7, 122), (119, 121.8), (119.3, 121.7), (119.7, 121.6)],
        [(120, 125), (122.2, 125.2), (124.3, 125.8), (126.4, 126.7), (128.4, 127.9), (130.3, 129.5), (132, 131.4), (133.6, 133.6), (134.9, 136), (136, 138.5), (136.8, 141.3), (137.4, 144.1), (137.6, 146.9), (137.6, 149.8), (137.3, 152.6), (136.7, 155.3), (135.7, 157.9), (134.5, 160.3), (133, 162.4), (131.2, 164.3), (129.3, 165.9), (127.1, 167.2), (124.8, 168.1), (122.4, 168.7), (120, 168.9), (117.6, 168.7), (115.2, 168.1), (112.9, 167.2), (110.7, 165.9), (108.8, 164.3), (107, 162.4), (105.5, 160.3), (104.3, 157.9), (103.3, 155.3), (102.7, 152.6), (102.4, 149.8), (102.4, 146.9), (102.6, 144.1), (103.2, 141.3), (104, 138.5), (105.1, 136), (106.4, 133.6), (108, 131.4), (109.7, 129.5), (111.6, 127.9), (113.6, 126.7), (115.7, 125.8), (117.8, 125.2)],
        [(120, 104.5), (120.9, 104.6), (121.7, 104.9), (122.6, 105.3), (123.4, 105.9), (124.2, 106.6), (125, 107.5), (125.7, 108.5), (126.3, 109.6), (126.9, 110.8), (127.3, 112.1), (127.7, 113.4), (127.9, 114.7), (127.8, 116), (127.6, 117.3), (127.3, 118.6), (126.9, 119.8), (126.3, 120.9), (125.6, 121.9), (124.8, 122.7), (124, 123.5), (123, 124.1), (122, 124.5), (121, 124.8), (120, 124.8), (119, 124.8), (118, 124.5), (117, 124.1), (116, 123.5), (115.2, 122.7), (114.4, 121.9), (113.7, 120.9), (113.1, 119.8), (112.7, 118.6), (112.4, 117.3), (112.2, 116), (112.1, 114.7), (112.3, 113.4), (112.7, 112.1), (113.1, 110.8), (113.7, 109.6), (114.3, 108.5), (115, 107.5), (115.8, 106.6), (116.6, 105.9), (117.4, 105.3), (118.3, 104.9), (119.1, 104.6)]
    ]
}
struct WorkingSpider: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var reduceMotion: Bool
    @State private var rotating = false
    var body: some View {
        SilkwireSpider().fill(SilkwireTheme.accent).frame(width: 18, height: 18)
            .rotationEffect(.degrees(rotating && !systemReduceMotion && !reduceMotion ? 360 : 0))
            .onAppear { update() }
            .onChange(of: reduceMotion) { _, _ in update() }
            .onChange(of: systemReduceMotion) { _, _ in update() }
            .accessibilityHidden(true)
    }
    private func update() {
        if systemReduceMotion || reduceMotion { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { rotating = false } }
        else { rotating = false; withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { rotating = true } }
    }
}
struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 22
    var body: some View {
        Group {
            if project.icon == "spider" { SilkwireSpider().fill(SilkwireTheme.project(project.color)) }
            else if project.icon == "rocket" { RocketGlyph().fill(SilkwireTheme.project(project.color)).rotationEffect(.degrees(35)) }
            else if project.icon == "planet" {
                ZStack {
                    Circle().stroke(SilkwireTheme.project(project.color), lineWidth: 1.2).padding(size * 0.18)
                    Ellipse().stroke(SilkwireTheme.project(project.color), lineWidth: 1).frame(height: size * 0.32).rotationEffect(.degrees(-30))
                    RoundedRectangle(cornerRadius: 1).fill(SilkwireTheme.project(project.color)).frame(width: size * 0.18, height: size * 0.18).offset(x: size * 0.36, y: -size * 0.28)
                }
            }
            else { Image(systemName: project.icon == "star" ? "star.fill" : "folder.fill").resizable().scaledToFit().foregroundStyle(SilkwireTheme.project(project.color)) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
/// Talking and working are different things to Jason: a teammate who is only
/// answering shows "Replying"; "Working" is kept for real work (builds, edits,
/// tests, tools). Internal plumbing (start-up steps, usage checks) never shows.
/// Conversation-flow rules for the transcript (step 1 of "flow, not pop").
enum TranscriptFlow {
    /// A teammate's reply that has no words yet: queued, or streaming with nothing
    /// to show. Such replies get no card; they're named in the thinking line instead.
    static func isEmptyPending(_ author: String, text: String, state: String, attachments: Int, agentNames: Set<String>) -> Bool {
        agentNames.contains(author) && attachments == 0
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (state == "queued" || state == "streaming")
    }
    /// A teammate's reply that isn't finished yet. Jason: "cache the stream until the full
    /// comment is received, THEN display it nice and clean". Held replies get no card at
    /// all (no growing, no pushing cards below); they're named in the thinking line.
    /// A teammate's card appears with its first words and then types in live (Jason, Nov 2).
    /// Until there are words it stays hidden, so there is never an empty bubble.
    static func isHeld(_ author: String, state: String, agentNames: Set<String>, text: String = "") -> Bool {
        guard agentNames.contains(author) else { return false }
        if state == "queued" { return true }
        if state == "streaming" { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }
    /// Speaking order: rows already on screen when the conversation opened keep their saved
    /// order; every row that appears later goes below them in the order it first appeared.
    /// Nothing is ever inserted above a card that's already showing, and nothing re-sorts.
    static func displayOrder<T>(_ items: [T], id: (T) -> UUID, revealed: [UUID: Int]) -> [T] {
        let earlier = items.filter { revealed[id($0)] == nil }
        let later = items.filter { revealed[id($0)] != nil }.sorted { revealed[id($0)]! < revealed[id($1)]! }
        return earlier + later
    }
    /// One speaker at a time (Jason, Nov 2): replies get the floor in the order their first
    /// words arrived. Finished replies show; the first still-typing one shows live; every
    /// reply after it waits, buffered, until the one before it finishes.
    static func floorHolders(_ order: [UUID], typing: Set<UUID>) -> (shown: Set<UUID>, waiting: [UUID]) {
        var shown = Set<UUID>(), waiting: [UUID] = [], blocked = false
        for id in order {
            if blocked { waiting.append(id); continue }
            shown.insert(id)
            if typing.contains(id) { blocked = true }
        }
        return (shown, waiting)
    }
    /// Puts replies in the order they started speaking, without moving anything else
    /// (Jason's own messages keep their places).
    static func speakingOrder<T>(_ items: [T], id: (T) -> UUID, seq: [UUID: Int]) -> [T] {
        let slots = items.indices.filter { seq[id(items[$0])] != nil }
        let sorted = slots.map { items[$0] }.sorted { seq[id($0)]! < seq[id($1)]! }
        var out = items
        for (slot, item) in zip(slots, sorted) { out[slot] = item }
        return out
    }
    /// Visible ids that are new since the baseline and have no place yet, in saved order.
    static func newlyVisible(_ visible: [UUID], baseline: Set<UUID>, revealed: [UUID: Int]) -> [UUID] {
        visible.filter { !baseline.contains($0) && revealed[$0] == nil }
    }
    /// A row is drawn once it has a place (or was there at the start). Before the first
    /// baseline is taken, everything finished is drawn.
    static func isPlaced(_ id: UUID, baseline: Set<UUID>?, revealed: [UUID: Int]) -> Bool {
        guard let baseline else { return true }
        return baseline.contains(id) || revealed[id] != nil
    }
    /// "Eve is thinking…", "Eve and Claude are thinking…", "Eve, Claude and Codex are thinking…"
    static func thinkingText(_ names: [String]) -> String {
        var seen = Set<String>(); let unique = names.filter { seen.insert($0).inserted }
        switch unique.count {
        case 0: return ""
        case 1: return unique[0] + " is thinking…"
        case 2: return unique[0] + " and " + unique[1] + " are thinking…"
        default: return unique.dropLast().joined(separator: ", ") + " and " + unique.last! + " are thinking…"
        }
    }
}

/// One calm line instead of a stack of empty cards.
struct ThinkingLine: View {
    let names: [String]
    var reduceMotion: Bool
    var body: some View {
        HStack(spacing: 8) {
            WorkingSpider(reduceMotion: reduceMotion)
            Text(TranscriptFlow.thinkingText(names)).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(.horizontal, 18).padding(.vertical, 4)
        .accessibilityLabel(TranscriptFlow.thinkingText(names))
    }
}

enum SeatPhase {
    private static let plumbing = ["starting reply", "replying", "included usage", "thinking", "waiting", "queued", "connecting", "preparing"]
    private static let work = ["build", "test", "run", "edit", "writ", "check", "workspace", "install", "computer", "inspect", "read", "search", "diff", "review", "command", "shell", "tool"]
    /// True when the activity is just a teammate composing a reply.
    static func isConversational(_ activity: String) -> Bool {
        let a = activity.lowercased()
        if a.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if plumbing.contains(where: { a.contains($0) }) { return true }
        return !work.contains(where: { a.contains($0) })
    }
    static func label(_ activity: String) -> String { isConversational(activity) ? "Replying" : "Working" }
}

struct AgentStatus: View {
    let seat: Seat
    var reduceMotion: Bool
    var compact = false
    private var light: Color { seat.state == "connected" ? Color(red: 0.40, green: 0.77, blue: 0.57) : seat.state == "needsStop" || seat.state == "connecting" ? .orange : .gray }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 6) {
                if seat.active { WorkingSpider(reduceMotion: reduceMotion) }
                else { Circle().fill(light).frame(width: 5, height: 5).padding(.horizontal, 4) }
                Text(text(at: timeline.date)).font(.system(size: compact ? 10 : 11)).foregroundStyle(seat.active ? SilkwireTheme.accent : Color.secondary).lineLimit(1)
            }.help(seat.message + (seat.model.isEmpty ? "" : " · " + seat.model))
        }
    }
    private func text(at now: Date) -> String {
        if seat.active {
            let elapsed = max(0, Int(now.timeIntervalSince(seat.startedAt ?? now)))
            let time = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            // Builds and checks can run quietly for minutes; that is normal, not a fault.
            // Mention the quiet stretch only once it is unusually long, and factually.
            let quiet = max(0, Int(now.timeIntervalSince(seat.lastEventAt ?? now)))
            let phase = SeatPhase.label(seat.activity)
            if compact { return phase + " · " + time }
            let activity = SeatPhase.isConversational(seat.activity) ? phase : seat.activity
            return activity + " · " + time + (quiet >= 600 ? " · no new output for \(quiet / 60) min" : "")
        }
        switch seat.state { case "connected": return "Ready"; case "connecting": return "Connecting…"; case "needsStop": return "Previous reply unconfirmed"; default: return SiloIdentity.statusLabel(state: seat.state, message: seat.message) }
    }
}

struct RocketGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        p.move(to: pt(0.5, 0.03)); p.addCurve(to: pt(0.69, 0.70), control1: pt(0.77, 0.24), control2: pt(0.77, 0.50))
        p.addLine(to: pt(0.31, 0.70)); p.addCurve(to: pt(0.5, 0.03), control1: pt(0.23, 0.50), control2: pt(0.23, 0.24)); p.closeSubpath()
        p.move(to: pt(0.31, 0.43)); p.addLine(to: pt(0.07, 0.76)); p.addLine(to: pt(0.32, 0.68)); p.closeSubpath()
        p.move(to: pt(0.69, 0.43)); p.addLine(to: pt(0.93, 0.76)); p.addLine(to: pt(0.68, 0.68)); p.closeSubpath()
        p.move(to: pt(0.37, 0.77)); p.addLine(to: pt(0.5, 1)); p.addLine(to: pt(0.63, 0.77)); p.closeSubpath()
        return p
    }
}

// Reading type (font option B): Avenir Next for messages and the composer. It ships with
// every Mac and iPhone, so nothing extra is bundled, and it gives Silkwire more character
// than the system font. Archivo stays reserved for the wordmark.
enum SilkwireReadingType {
    static let family = "Avenir Next"
    static let regularName = "AvenirNext-Regular"
    static let demiBoldName = "AvenirNext-DemiBold"
    // Lighter emphasis: Demi Bold instead of Bold, still distinct from the airy body text.
    static func strong(_ size: CGFloat) -> Font { .custom(demiBoldName, size: size) }
    static func body(_ size: CGFloat) -> Font { .custom(family, size: size) }
    static func nsBody(_ size: CGFloat) -> NSFont { NSFont(name: regularName, size: size) ?? .systemFont(ofSize: size) }
}

/// Holds the latest transcript row frames without being SwiftUI state.
final class TranscriptFrameBox { var frames: [UUID: CGRect] = [:]; var viewport: CGFloat = 0 }

extension TranscriptFlow {
    enum FirstReplyScroll: Equatable { case bottom, top }
    /// Reveal timing: slow enough to read as "arriving", quick enough not to lag.
    static let revealDuration: Double = 0.45
    static let revealOffset: CGFloat = 18
    /// Where the first reply of a round should land so it stops at the top of the view:
    /// if it fits, scroll just far enough to show it whole (its top stays on screen);
    /// if it's taller than the window, put its top at the top edge and stop there.
    enum RoundScroll: Equatable { case bottom, prompt }
    /// Jason's prompt is the stopper: scroll replies up to the bottom as long as his prompt
    /// stays on screen; once moving further would push its top off, stop with it at the top.
    /// An unknown prompt position (scrolled far above) also stops at the prompt.
    static func roundScroll(hasPrompt: Bool, promptTop: CGFloat?, contentBottom: CGFloat?, viewport: CGFloat, margin: CGFloat = 8) -> RoundScroll {
        guard hasPrompt else { return .bottom }
        guard let promptTop else { return .prompt }
        guard let contentBottom, viewport > 0 else { return .bottom }
        let travel = max(0, contentBottom - viewport)
        return promptTop - travel >= margin ? .bottom : .prompt
    }
    /// A new prompt joins the current set while that set's first prompt is still on screen.
    /// True when the end of the conversation is on screen (within a hair), so following resumes.
    /// Auto-scroll pacing (Jason, Nov 2: "scroll slower, don't fly"): one gentle nudge at
    /// most every glideInterval ms, each easing over glideDuration seconds.
    static let glideInterval = 350
    static let glideDuration = 0.6
    static func isAtEnd(contentEnd: CGFloat, viewport: CGFloat, tolerance: CGFloat = 4) -> Bool {
        contentEnd <= viewport + tolerance
    }
    static func keepsRoundPrompt(currentTop: CGFloat?, viewport: CGFloat) -> Bool {
        guard let currentTop, viewport > 0 else { return false }
        return currentTop >= 0 && currentTop < viewport
    }
    static func firstReplyScroll(replyHeight: CGFloat?, viewport: CGFloat, startAtTop: Bool) -> FirstReplyScroll {
        guard startAtTop, let replyHeight, viewport > 0 else { return .bottom }
        return replyHeight <= viewport - 24 ? .bottom : .top
    }
}
