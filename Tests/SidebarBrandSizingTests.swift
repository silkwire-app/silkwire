import Foundation

// Caller-binding and geometry regression, not a screenshot/pixel acceptance test.
@main struct SidebarBrandSizingTests {
    static func main() throws {
        let app = try String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)
        guard let start = app.range(of: "            AriWalkingMark(behavior:"),
              let end = app.range(of: "            HStack(spacing: 8)", range: start.upperBound..<app.endIndex) else {
            fatalError("Sidebar brand caller unavailable")
        }
        let header = String(app[start.lowerBound..<end.lowerBound])
        precondition(header.contains(".frame(maxWidth: .infinity)"))
        precondition(!header.contains("maxWidth: 200"), "Do not restore the undersized fixed cap")
        precondition(header.contains(".padding(.horizontal, 14)"), "Brand and search share horizontal insets")
        precondition(header.contains("reduceMotion: store.preferences.reduceMotion"))
        precondition(header.contains("skitterCadence: AriSidebar.skitterCadence"))
        for finish in [AriWalkModel.Finish.graphite, .silver] {
            let mark = AriMarkLayout(kind: .stackedQuiet, finish: finish, violet: finish == .silver, small: true)
            let strandFraction = (mark.strandX1 - mark.strandX0) / mark.viewBox.width
            precondition(strandFraction > 0.95 && strandFraction <= 1)
            precondition(mark.word != nil)
            for sidebarWidth in [245.0, 278.0, 350.0] {
                let available = sidebarWidth - 28
                let scale = available / mark.viewBox.width
                let priorScale = 200 / mark.viewBox.width
                precondition(scale > priorScale, "Ari and her outlined wordmark grow together at every supported width")
                let wire = (mark.strandX1 - mark.strandX0) * scale
                precondition(wire / available > 0.95 && wire <= available)
                precondition(mark.viewBox.height * scale > 0)
                print("PASS: sidebar \(sidebarWidth) pt, mark \(available) pt, strand \(wire) pt, scale versus old cap \(scale / priorScale)")
            }
        }
        print("PASS: sidebar header source binding, near-search-width strand, proportional scaling and motion settings; visual acceptance still requires native UI review")
    }
}
