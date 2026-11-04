import AppKit
import SwiftUI

// Silkwire's appearance choice: Midnight (the classic dark look), Parchment (warm paper
// with dark ink) and Match System. Colors are plain RGB values so they can be checked for
// readable contrast in tests. Views use adaptive colors (see SilkwireTheme) that resolve
// against the window's appearance, so switching themes never needs to rebuild a view.

struct ThemeRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }
    // Mixes toward another color: 0 keeps this color, 1 becomes the other.
    func mixed(with other: ThemeRGB, amount: Double) -> ThemeRGB {
        let t = min(max(amount, 0), 1)
        return ThemeRGB(red: red + (other.red - red) * t, green: green + (other.green - green) * t, blue: blue + (other.blue - blue) * t)
    }
    func nsColor(alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    // WCAG relative luminance (sRGB).
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            let c = min(max(channel, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    // WCAG contrast ratio, 1...21. 4.5 is the usual bar for normal text.
    static func contrast(_ a: ThemeRGB, _ b: ThemeRGB) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

struct ThemePalette: Equatable {
    let name: String
    let isLight: Bool
    let accent: ThemeRGB
    let sidebar: ThemeRGB
    // The lower end of the sidebar's gentle gradient.
    let sidebarFloor: ThemeRGB
    let surface: ThemeRGB
    let card: ThemeRGB
    let window: ThemeRGB
    let ink: ThemeRGB
    let secondaryInk: ThemeRGB
    // Hairlines are the ink color at low opacity.
    let lineOpacity: Double
    // Faint panels (cards, chips, rows) are the ink color at the requested opacity times this.
    let washStrength: Double
    // Recessed areas such as the composer and code blocks: the well color at the
    // requested opacity times this strength.
    let well: ThemeRGB
    let wellStrength: Double
    let jasonBubble: ThemeRGB
    let identities: [String: ThemeRGB]
    let projectBlue: ThemeRGB

    var colorScheme: ColorScheme { isLight ? .light : .dark }
    func identity(_ name: String) -> ThemeRGB { identities[name] ?? ink }
    // A solid grey step for metallic gradients: Midnight keeps the classic
    // Color(white:) greys; Parchment moves from paper toward ink by the same amount.
    func shade(_ white: Double) -> ThemeRGB {
        isLight ? surface.mixed(with: ink, amount: white) : ThemeRGB(red: white, green: white, blue: white)
    }

    // The classic Silkwire look, value for value.
    static let midnight = ThemePalette(
        name: "Midnight",
        isLight: false,
        accent: ThemeRGB(red: 0.70, green: 0.57, blue: 0.99),
        // Layered charcoal (Jason, Oct 26): still dark, but each surface is its own
        // quiet shade with a trace of color, the way Parchment separates its papers.
        // Style guide (Jason, Nov 2, from Claude.app's mockup): near-black frame #0d0d10,
        // chat and panels #151519, bubbles #1c1c21, borders #29292f.
        sidebar: ThemeRGB(hex: 0x0d0d10),
        sidebarFloor: ThemeRGB(hex: 0x0d0d10),
        surface: ThemeRGB(hex: 0x151519),
        card: ThemeRGB(hex: 0x151519),
        window: ThemeRGB(hex: 0x0d0d10),
        ink: ThemeRGB(red: 1, green: 1, blue: 1),
        secondaryInk: ThemeRGB(red: 0.66, green: 0.66, blue: 0.66),
        lineOpacity: 0.075,
        washStrength: 1,
        well: ThemeRGB(red: 0, green: 0, blue: 0),
        wellStrength: 1,
        jasonBubble: ThemeRGB(hex: 0x1c1c21),
        identities: [
            "Jason": ThemeRGB(red: 0.84, green: 0.87, blue: 0.94),
            "Eve": ThemeRGB(hex: 0xb5a8f9),
            "Claude": ThemeRGB(hex: 0xe4a97a),
            "Codex": ThemeRGB(red: 0.43, green: 0.84, blue: 0.78),
            "Grok": ThemeRGB(hex: 0x93aef9)
        ],
        projectBlue: ThemeRGB(red: 0.51, green: 0.73, blue: 1)
    )

    // Parchment: warm paper, lighter cards, deep ink, copper accent, and each
    // teammate's color deepened so it reads on paper.
    static let parchment = ThemePalette(
        name: "Parchment",
        isLight: true,
        accent: ThemeRGB(red: 0.565, green: 0.282, blue: 0.102),      // copper
        sidebar: ThemeRGB(red: 0.918, green: 0.875, blue: 0.784),     // folder edge
        sidebarFloor: ThemeRGB(red: 0.906, green: 0.863, blue: 0.769),
        surface: ThemeRGB(red: 0.937, green: 0.902, blue: 0.824),     // parchment
        card: ThemeRGB(red: 0.973, green: 0.949, blue: 0.894),        // fresh sheet
        window: ThemeRGB(red: 0.937, green: 0.902, blue: 0.824),
        ink: ThemeRGB(red: 0.169, green: 0.129, blue: 0.094),         // deep ink
        secondaryInk: ThemeRGB(red: 0.420, green: 0.353, blue: 0.278),
        lineOpacity: 0.22,
        washStrength: 1.6,
        well: ThemeRGB(red: 0.169, green: 0.129, blue: 0.094),
        wellStrength: 0.3,
        jasonBubble: ThemeRGB(red: 0.914, green: 0.902, blue: 0.871), // slate-tinted sheet
        identities: [
            "Jason": ThemeRGB(red: 0.243, green: 0.290, blue: 0.369),  // slate
            "Eve": ThemeRGB(red: 0.416, green: 0.247, blue: 0.710),    // plum
            "Claude": ThemeRGB(red: 0.600, green: 0.255, blue: 0.098), // terracotta
            "Codex": ThemeRGB(red: 0.110, green: 0.400, blue: 0.373),  // deep teal
            "Grok": ThemeRGB(red: 0.173, green: 0.369, blue: 0.620)    // deep blue
        ],
        projectBlue: ThemeRGB(red: 0.173, green: 0.369, blue: 0.620)
    )

    // Picks the palette for an AppKit appearance (dark appearances use Midnight).
    static func forAppearance(_ appearance: NSAppearance) -> ThemePalette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .midnight : .parchment
    }

    // A color that follows the window's appearance: Midnight in dark, Parchment in light.
    static func adaptive(_ pick: @escaping (ThemePalette) -> ThemeRGB, alpha: @escaping (ThemePalette) -> Double = { _ in 1 }) -> NSColor {
        NSColor(name: nil) { appearance in
            let palette = forAppearance(appearance)
            return pick(palette).nsColor(alpha: min(max(alpha(palette), 0), 1))
        }
    }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case midnight, parchment, system

    static let storageKey = "silkwire.appearance.theme"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .midnight: return "Midnight"
        case .parchment: return "Parchment"
        case .system: return "Match System"
        }
    }

    // Unknown or missing stored values keep the classic Midnight look rather than guessing.
    static func decode(_ raw: String?) -> ThemeChoice {
        raw.flatMap(ThemeChoice.init(rawValue:)) ?? .midnight
    }

    // Match System uses Parchment in light mode and Midnight in dark mode.
    func palette(systemIsDark: Bool) -> ThemePalette {
        switch self {
        case .midnight: return .midnight
        case .parchment: return .parchment
        case .system: return systemIsDark ? .midnight : .parchment
        }
    }

    // nil lets the app follow macOS.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .midnight: return .darkAqua
        case .parchment: return .aqua
        case .system: return nil
        }
    }

    @MainActor func applyToApplication() {
        NSApp?.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}

// Applies the saved theme to the whole app (every window and sheet) and keeps it current.
struct SilkwireAppearance: ViewModifier {
    @AppStorage(ThemeChoice.storageKey) private var themeRaw = ThemeChoice.midnight.rawValue
    func body(content: Content) -> some View {
        content
            .onAppear { ThemeChoice.decode(themeRaw).applyToApplication() }
            .onChange(of: themeRaw) { _, raw in ThemeChoice.decode(raw).applyToApplication() }
    }
}

extension View {
    func silkwireAppearance() -> some View { modifier(SilkwireAppearance()) }
}

// A whisper-quiet paper grain, shown only in Parchment. It never takes clicks and is
// invisible to VoiceOver. The pattern is fixed, so it never shimmers while you work.
struct PaperGrain: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if scheme == .light {
            Canvas(rendersAsynchronously: true) { context, size in
                let cell: CGFloat = 4
                let columns = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
                let ink = ThemePalette.parchment.ink.color
                for row in 0..<rows {
                    for column in 0..<columns {
                        let value = PaperGrain.noise(column, row)
                        guard value > 0.86 else { continue }
                        let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: 1, height: 1)
                        context.fill(Path(rect), with: .color(ink.opacity((value - 0.86) * 0.35)))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // Deterministic 0...1 value per grain cell.
    static func noise(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h & 0xFFFF) / 65_535
    }
}

// Parchment polish: a near-white conversation canvas so bubbles stand off the page,
// a solid brand mark (black on Parchment, white on Midnight) and a theme-aware Send.
extension ThemePalette {
    /// Style guide (Nov 2): the conversation area is the board surface in both themes (Parchment was near-white).
    var canvas: ThemeRGB { surface }
    /// Near-white paper for teammate cards, fields and the reading page on Parchment.
    var paperWhite: ThemeRGB { ThemeRGB(red: 0.992, green: 0.984, blue: 0.969) }
    var brandMark: ThemeRGB { isLight ? ThemeRGB(red: 0, green: 0, blue: 0) : ThemeRGB(red: 1, green: 1, blue: 1) }
    var sendFill: ThemeRGB { isLight ? ThemeRGB(red: 0.42, green: 0.212, blue: 0.075) : ThemeRGB(red: 0.61, green: 0.32, blue: 1) }
}

// Reading comfort: Midnight gets lighter charcoal bubbles and soft off-white body text
// (bright white on near-black is harsh for long reading); Parchment keeps deep ink.
// Staging's orange marker deepens to burnt orange on Parchment so it stays readable.
extension ThemePalette {
    /// Style guide (Nov 2): Parchment teammate cards lift to near-white, like Midnight's lighter cards.
    var agentBubble: ThemeRGB { isLight ? paperWhite : ThemeRGB(hex: 0x1c1c21) }
    /// Confirmed success only (a real passing receipt, "Ready").
    /// Parchment green is a shade deeper than the guide (#2E7D4F) so 12 pt pill text clears 4.5:1 on its tint.
    var success: ThemeRGB { isLight ? ThemeRGB(red: 0.13, green: 0.40, blue: 0.24) : ThemeRGB(red: 0.37, green: 0.83, blue: 0.54) }
    /// Jason must act, or something needs attention. Always paired with an icon, never color alone.
    /// Parchment burnt orange is a shade deeper than the guide (#985218) so pill text clears 4.5:1 on the page too.
    var attention: ThemeRGB { isLight ? ThemeRGB(red: 0.52, green: 0.27, blue: 0.07) : ThemeRGB(red: 0.96, green: 0.70, blue: 0.26) }
    /// Alexandria's page: Parchment keeps its bright sheet; Midnight gets a plain neutral charcoal.
    var reading: ThemeRGB { isLight ? paperWhite : ThemeRGB(hex: 0x151519) }
    var bodyInk: ThemeRGB { isLight ? ink : ThemeRGB(red: 0.86, green: 0.86, blue: 0.88) }
    var stagingTint: ThemeRGB { isLight ? ThemeRGB(red: 0.62, green: 0.27, blue: 0) : ThemeRGB(red: 1, green: 0.584, blue: 0) }
}

extension ThemeRGB {
    /// A 0xRRGGBB value, as written in Jason's style guides.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

// Midnight style guide (Jason, Nov 2): one set of borders, rows and chips for chat, Alexandria and
// Future alike. Parchment keeps its own look; these only change Midnight.
extension ThemePalette {
    /// Card, column and field edges on Midnight.
    var border: ThemeRGB { ThemeRGB(hex: 0x29292f) }
    /// The selected conversation in the sidebar.
    var selectedRow: ThemeRGB { ThemeRGB(hex: 0x212127) }
    /// Solid chip backgrounds behind each teammate's initial; nil uses a tint of their color.
    func chipFill(_ name: String) -> ThemeRGB? {
        guard !isLight else { return nil }
        switch name {
        case "Eve": return ThemeRGB(hex: 0x292541)
        case "Claude": return ThemeRGB(hex: 0x362b21)
        case "Codex": return ThemeRGB(hex: 0x203330)
        case "Grok": return ThemeRGB(hex: 0x1f2942)
        default: return nil
        }
    }
}
