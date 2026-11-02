import AppKit
import Foundation
import SwiftUI

// Parchment must stay readable: ink and every teammate color need normal-text contrast
// on paper; Midnight must remain the classic look; adaptive colors must follow the
// window's appearance.
@main struct ThemePaletteTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            print("PASS: \(name)")
        }
        let white = ThemeRGB(red: 1, green: 1, blue: 1)
        let black = ThemeRGB(red: 0, green: 0, blue: 0)
        check(abs(ThemeRGB.contrast(white, black) - 21) < 0.01, "contrast math matches WCAG (21:1)")
        check(abs(ThemeRGB.contrast(white, white) - 1) < 0.0001, "same color is 1:1")

        let paper = ThemePalette.parchment
        let names = ["Jason", "Eve", "Claude", "Codex"]
        check(paper.isLight, "Parchment is a light theme")
        check(Set(paper.identities.keys) == Set(names), "Parchment tunes every teammate color")
        for background in [("parchment", paper.surface), ("card", paper.card), ("your message", paper.jasonBubble)] {
            check(ThemeRGB.contrast(paper.ink, background.1) >= 7, "ink is very readable on \(background.0)")
            check(ThemeRGB.contrast(paper.secondaryInk, background.1) >= 4.5, "secondary text is readable on \(background.0)")
            check(ThemeRGB.contrast(paper.accent, background.1) >= 4.5, "copper accent is readable on \(background.0)")
            check(ThemeRGB.contrast(paper.projectBlue, background.1) >= 4.5, "project blue is readable on \(background.0)")
            for name in names {
                check(ThemeRGB.contrast(paper.identity(name), background.1) >= 4.5, "\(name) is readable on \(background.0)")
            }
        }
        // The sidebar uses small text (12 pt), so it gets the full normal-text bar too.
        for background in [("sidebar", paper.sidebar), ("sidebar bottom", paper.sidebarFloor)] {
            for name in names {
                check(ThemeRGB.contrast(paper.identity(name), background.1) >= 4.5, "\(name) is readable as small text on the \(background.0)")
            }
            check(ThemeRGB.contrast(paper.secondaryInk, background.1) >= 4.5, "secondary text is readable on the \(background.0)")
            check(ThemeRGB.contrast(paper.accent, background.1) >= 4.5, "copper accent is readable on the \(background.0)")
            check(ThemeRGB.contrast(paper.projectBlue, background.1) >= 4.5, "project blue is readable on the \(background.0)")
            let dimmedTitle = background.1.mixed(with: paper.ink, amount: 0.76)
            check(ThemeRGB.contrast(dimmedTitle, background.1) >= 4.5, "unselected room titles are readable on the \(background.0)")
        }
        check(ThemeRGB.contrast(paper.ink, paper.sidebarFloor) >= 7, "ink is very readable at the bottom of the sidebar")
        check(paper.card.relativeLuminance > paper.surface.relativeLuminance, "cards are lighter than the page")
        check(paper.surface.relativeLuminance > paper.sidebar.relativeLuminance, "sidebar sits a shade darker than the page")

        let night = ThemePalette.midnight
        // Parchment polish: near-white canvas, solid brand mark, theme-aware Send.
        check(paper.agentBubble.relativeLuminance > paper.canvas.relativeLuminance, "style guide: near-white teammate cards sit on the parchment conversation area")
        check(paper.card.relativeLuminance > paper.jasonBubble.relativeLuminance, "your messages are a touch more tinted than agent bubbles")
        check(ThemeRGB.contrast(paper.ink, paper.canvas) >= 7, "ink is very readable on the canvas")
        check(ThemeRGB.contrast(paper.secondaryInk, paper.canvas) >= 4.5, "secondary text is readable on the canvas")
        check(ThemeRGB.contrast(paper.accent, paper.canvas) >= 4.5, "copper accent is readable on the canvas")
        for name in ["Jason", "Eve", "Claude", "Codex"] { check(ThemeRGB.contrast(paper.identity(name), paper.canvas) >= 4.5, "\(name) is readable on the canvas") }
        check(ThemeRGB.contrast(paper.brandMark, paper.sidebar) >= 12, "the brand mark is solid black on the Parchment sidebar")
        check(ThemeRGB.contrast(night.brandMark, night.sidebar) >= 15, "the brand mark is solid white on the Midnight sidebar")
        check(ThemeRGB.contrast(white, paper.sendFill) >= 7, "Send's white label is very readable on warm brown")
        check(ThemeRGB.contrast(white, night.sendFill) >= 3, "Send keeps its Midnight violet")
        check(night.canvas == night.surface, "Midnight's conversation background is unchanged")
        check(NSFont(name: SilkwireReadingType.regularName, size: 14) != nil, "Avenir Next is available on this Mac without bundling a font")
        check(SilkwireReadingType.nsBody(14).fontName == SilkwireReadingType.regularName, "the composer uses Avenir Next, not the system font")
        check(NSFont(name: SilkwireReadingType.demiBoldName, size: 14) != nil, "Avenir Next Demi Bold is available for lighter emphasis")
        // Reading comfort: softer Midnight, readable Staging orange on Parchment.
        check(night.agentBubble.relativeLuminance > night.canvas.relativeLuminance, "Midnight bubbles are lighter charcoal than the canvas behind them")
        check(ThemeRGB.contrast(night.bodyInk, night.agentBubble) >= 7, "Midnight body text stays very readable on its bubble")
        check(ThemeRGB.contrast(night.bodyInk, night.agentBubble) < ThemeRGB.contrast(white, night.surface), "Midnight body text is gentler than bright white on black")
        check(ThemeRGB.contrast(night.bodyInk, night.jasonBubble) >= 7, "Midnight body text is very readable on your messages")
        for name in ["Jason", "Eve", "Claude", "Codex"] { check(ThemeRGB.contrast(night.identity(name), night.agentBubble) >= 4.5, "\(name) is readable on a Midnight bubble") }
        for background in [("sidebar", paper.sidebar), ("sidebar bottom", paper.sidebarFloor), ("canvas", paper.canvas)] {
            check(ThemeRGB.contrast(paper.stagingTint, background.1) >= 4.5, "Staging orange controls are readable on the Parchment \(background.0)")
        }
        check(ThemeRGB.contrast(night.stagingTint, night.sidebar) >= 4.5, "Staging orange stays readable in Midnight")
        check(paper.bodyInk == paper.ink, "Parchment body text is unchanged")
        check(!night.isLight, "Midnight stays dark")
        check(night.accent == ThemeRGB(red: 0.70, green: 0.57, blue: 0.99), "Midnight accent is the classic purple")
        check(night.surface.relativeLuminance < 0.01 && night.surface.blue > night.surface.green, "Midnight surface stays deep ink-charcoal")
        check(night.sidebar.blue - night.sidebar.red > night.surface.blue - night.surface.red, "Midnight sidebar is a cooler blue-black than the page")
        check(night.window.relativeLuminance < night.surface.relativeLuminance, "Midnight window sits just behind the page")
        check(night.card.relativeLuminance > night.surface.relativeLuminance && night.card.blue > night.card.green, "Midnight cards lift off the page with a hint of plum")
        check(night.reading.relativeLuminance > night.surface.relativeLuminance, "Alexandria reads on a slightly lighter neutral charcoal in Midnight")
        // Trace's 802c249 review: green pill text must clear 4.5:1 on its 14% tint over cards and the page.
        func tinted(_ c: ThemeRGB, over bg: ThemeRGB) -> ThemeRGB { ThemeRGB(red: c.red * 0.14 + bg.red * 0.86, green: c.green * 0.14 + bg.green * 0.86, blue: c.blue * 0.14 + bg.blue * 0.86) }
        for (name, bg) in [("card", paper.agentBubble), ("page", paper.canvas), ("your card", paper.jasonBubble)] {
            check(ThemeRGB.contrast(paper.success, tinted(paper.success, over: bg)) >= 4.5, "Parchment success pill is readable on the \(name)")
            check(ThemeRGB.contrast(paper.attention, tinted(paper.attention, over: bg)) >= 4.5, "Parchment attention pill is readable on the \(name)")
        }
        for bg in [night.agentBubble, night.canvas, night.jasonBubble] {
            check(ThemeRGB.contrast(night.success, tinted(night.success, over: bg)) >= 4.5, "Midnight success pill is readable")
            check(ThemeRGB.contrast(night.attention, tinted(night.attention, over: bg)) >= 4.5, "Midnight attention pill is readable")
        }
        check(TranscriptCardActions.visible(hovering: false, keyboardFocused: true), "keyboard focus reveals Copy / Send to Builder")
        check(TranscriptCardActions.visible(hovering: true, keyboardFocused: false), "pointer hover reveals them")
        check(!TranscriptCardActions.visible(hovering: false, keyboardFocused: false), "otherwise they stay quiet")
        check(paper.reading == paper.paperWhite, "Parchment reading page keeps its bright sheet")
        check([night.surface, night.sidebar, night.card, night.reading, night.agentBubble].allSatisfy { $0.relativeLuminance < 0.02 }, "every Midnight surface is still truly dark")
        check(night.ink == white && night.lineOpacity == 0.075 && night.washStrength == 1, "Midnight tints are the classic white tints")
        check(night.well == black && night.wellStrength == 1, "Midnight composer and code shading keep their exact black tints")
        check(night.shade(0.73) == ThemeRGB(red: 0.73, green: 0.73, blue: 0.73) && night.shade(0.66) == ThemeRGB(red: 0.66, green: 0.66, blue: 0.66), "Midnight wordmark and spider greys are the classic solid greys")
        check(night.sidebarFloor.relativeLuminance < night.sidebar.relativeLuminance, "Midnight sidebar still darkens gently toward the bottom")
        check(night.sidebarFloor.relativeLuminance > night.surface.relativeLuminance, "Midnight sidebar is a lighter gray than the chat, top to bottom")
        check(abs(night.reading.red - night.reading.blue) < 0.01, "Midnight reading surface is a plain neutral charcoal")
        check(ThemeRGB.contrast(paper.shade(0.73), paper.surface) >= 4.5, "Parchment wordmark stays readable at its lightest point")
        check(night.jasonBubble.relativeLuminance > night.surface.relativeLuminance, "your Midnight messages sit on a lighter violet-charcoal bubble")
        check(night.identity("Claude") == ThemeRGB(red: 0.96, green: 0.72, blue: 0.51), "Midnight Claude color is unchanged")
        for name in names {
            check(ThemeRGB.contrast(night.identity(name), night.surface) >= 4.5, "\(name) is readable in Midnight")
        }

        check(ThemeChoice.decode(nil) == .midnight, "no saved choice keeps Midnight")
        check(ThemeChoice.decode("nonsense") == .midnight, "an unknown saved choice keeps Midnight")
        check(ThemeChoice.decode("parchment") == .parchment, "a saved Parchment choice is restored")
        check(ThemeChoice.allCases.map(\.title) == ["Midnight", "Parchment", "Match System"], "choices read plainly in order")
        check(ThemeChoice.system.palette(systemIsDark: true) == .midnight, "Match System in dark mode is Midnight")
        check(ThemeChoice.system.palette(systemIsDark: false) == .parchment, "Match System in light mode is Parchment")
        check(ThemeChoice.parchment.palette(systemIsDark: true) == .parchment, "choosing Parchment ignores the system")
        check(ThemeChoice.system.appearanceName == nil, "Match System lets macOS decide")
        check(ThemeChoice.parchment.appearanceName == .aqua, "Parchment uses the light appearance")
        check(ThemeChoice.midnight.appearanceName == .darkAqua, "Midnight uses the dark appearance")

        func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> (Double, Double, Double, Double) {
            var result = (0.0, 0.0, 0.0, 0.0)
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let c = color.usingColorSpace(.sRGB)!
                result = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
            }
            return result
        }
        func near(_ a: (Double, Double, Double, Double), _ b: ThemeRGB, _ alpha: Double) -> Bool {
            abs(a.0 - b.red) < 0.002 && abs(a.1 - b.green) < 0.002 && abs(a.2 - b.blue) < 0.002 && abs(a.3 - alpha) < 0.002
        }
        let surface = ThemePalette.adaptive { $0.surface }
        check(near(resolved(surface, .darkAqua), night.surface, 1), "adaptive surface is Midnight in a dark window")
        check(near(resolved(surface, .aqua), paper.surface, 1), "adaptive surface is Parchment in a light window")
        let line = ThemePalette.adaptive({ $0.ink }, alpha: { $0.lineOpacity })
        check(near(resolved(line, .darkAqua), white, 0.075), "hairline is faint white on Midnight")
        check(near(resolved(line, .aqua), paper.ink, 0.22), "hairline is faint ink on Parchment")
        let claude = ThemePalette.adaptive { $0.identity("Claude") }
        check(near(resolved(claude, .aqua), paper.identity("Claude"), 1), "teammate colors deepen on Parchment")
        let tooStrong = ThemePalette.adaptive({ $0.ink }, alpha: { _ in 3 })
        check(resolved(tooStrong, .aqua).3 <= 1, "tint strength never exceeds full opacity")

        check(PaperGrain.noise(12, 34) == PaperGrain.noise(12, 34), "paper grain never shimmers")
        let samples = (0..<400).map { PaperGrain.noise($0 % 20, $0 / 20) }
        check(samples.allSatisfy { $0 >= 0 && $0 <= 1 }, "paper grain stays in range")
        let speckled = samples.filter { $0 > 0.86 }.count
        check(speckled > 20 && speckled < 120, "paper grain is sparse, not noise")
    }
}
