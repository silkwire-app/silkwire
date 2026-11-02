import SwiftUI

// Ari on her strand, walking, for the sidebar header.
//
// When the view first appears she walks a few strides, then settles into the approved pose and holds still while the
// work happens. Hover over her and she walks (or skitters); move the pointer away and she finishes her step and stops
// (never more than eight seconds at a time). With Reduce Motion on, from the system or the app's own setting, she
// never moves.
//
//     AriWalkingMark(reduceMotion: reduceMotion)              // stacked, quiet wordmark, follows light and dark
//         .frame(width: 240)
//
//     AriWalkingMark(hover: .skitter)                         // the Easter egg skitters instead of walking
//     AriWalkingMark(hover: .skitter, skitterCadence: 0.45)   // ...a gentler skitter
//     AriWalkingMark(layout: .strand, behavior: .wander)     // walk, freeze, skitter, freeze, on a loop
//
// The geometry, the gait and the walker live in AriWalkModel.swift (no SwiftUI there, so it is unit-testable).
// While she is settled the TimelineView is paused and nothing redraws.

struct AriWalkingMark: View {
    typealias Layout = AriMarkLayout.Kind

    enum Behavior: Equatable {
        case intro(strides: Double)   // walk on first appearance, then settle
        case loop                     // walk forever (marketing, empty states)
        case skitter                  // skitter forever
        case wander                   // walk slowly, freeze, skitter, freeze, walk on
        case still                    // only move on hover
    }

    enum Hover { case walk, skitter, off }

    var layout: Layout
    var behavior: Behavior
    var hover: Hover
    /// Sturdier legs and strand; use under about 320 pt wide.
    var small: Bool
    /// Seconds per walking stride; nil = 1.3 for loop and wander, 1.15 otherwise (as on the website).
    var cadence: Double?
    /// Seconds per skittering stride. 0.3 is the default; 0.4 to 0.5 is a gentler skitter, 0.2 a frantic one.
    var skitterCadence: Double
    /// A soft highlight that drifts back along the strand while she walks.
    var glint: Bool
    /// nil follows the colour scheme: silver with violet on dark, graphite without violet on light (the approved pair).
    var finish: AriWalkModel.Finish?
    var violet: Bool?
    /// The app's own Reduce Motion setting; the system setting is always respected as well.
    var reduceMotion: Bool
    /// Change this value to play the opening walk again (for example when the main window reopens).
    var replayTrigger: Int

    init(layout: Layout = .stackedQuiet, behavior: Behavior = .intro(strides: 2.5), hover: Hover = .walk,
         small: Bool = true, cadence: Double? = nil, skitterCadence: Double = 0.3, glint: Bool = true,
         finish: AriWalkModel.Finish? = nil, violet: Bool? = nil, reduceMotion: Bool = false, replayTrigger: Int = 0) {
        self.layout = layout
        self.behavior = behavior
        self.hover = hover
        self.small = small
        self.cadence = cadence
        self.skitterCadence = skitterCadence
        self.glint = glint
        self.finish = finish
        self.violet = violet
        self.reduceMotion = reduceMotion
        self.replayTrigger = replayTrigger
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var walker = AriWalker()
    @State private var animating = false
    @State private var introPlayed = false

    private var resolvedFinish: AriWalkModel.Finish { finish ?? (colorScheme == .dark ? .silver : .graphite) }
    private var resolvedViolet: Bool { violet ?? (colorScheme == .dark) }
    private var still: Bool { reduceMotion || systemReduceMotion }
    private var resolvedCadence: Double { cadence ?? ((behavior == .loop || behavior == .wander) ? 1.3 : 1.15) }

    var body: some View {
        let mark = AriMarkLayout(kind: layout, finish: resolvedFinish, violet: resolvedViolet, small: small)
        let walker = self.walker
        let still = self.still
        let cadence = resolvedCadence
        let skitterCadence = self.skitterCadence
        let showGlint = glint
        let hoverStyle = hover
        TimelineView(.animation(minimumInterval: nil, paused: !animating)) { timeline in
            Canvas { context, size in
                walker.cadence = cadence
                walker.skitterCadence = skitterCadence
                walker.advance(to: timeline.date.timeIntervalSinceReferenceDate, model: mark.model, reduceMotion: still)
                AriRenderer.draw(mark, walker: walker, glint: showGlint, into: &context, size: size)
            }
        }
        .aspectRatio(mark.viewBox.width / mark.viewBox.height, contentMode: .fit)
        .contentShape(Rectangle())
        .onHover { inside in
            guard hoverStyle != .off, !still else { return }
            walker.hoverSkitters = hoverStyle == .skitter
            walker.hover(inside, now: Date.timeIntervalSinceReferenceDate)
            if inside { animating = true }
        }
        .onAppear { start() }
        .onChange(of: still) { _, isStill in
            if isStill { walker.stopAll(); animating = false } else { start() }
        }
        .onChange(of: replayTrigger) { _, _ in replay() }
        .onChange(of: behavior) { _, _ in walker.mode = .once; start() }
        .task(id: animating) {
            // pause the timeline once she has settled, so a resting sidebar costs nothing
            guard animating else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if walker.isSettled(at: Date.timeIntervalSinceReferenceDate) { animating = false; return }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Silkwire")
        .accessibilityAddTraits(.isImage)
    }

    private func replay() {
        guard !still else { return }
        walker.walk(cycles: 2.5, now: Date.timeIntervalSinceReferenceDate)
        animating = true
    }

    private func start() {
        guard !still else { return }
        walker.cadence = resolvedCadence
        walker.skitterCadence = skitterCadence
        switch behavior {
        case .intro(let strides):
            guard !introPlayed else { return }
            introPlayed = true
            walker.mode = .once
            walker.walk(cycles: strides, now: Date.timeIntervalSinceReferenceDate, delay: AriSidebar.introDelay)
            animating = true
        case .loop:
            walker.mode = .loop
            animating = true
        case .skitter:
            walker.mode = .skitter
            animating = true
        case .wander:
            walker.mode = .wander
            animating = true
        case .still:
            walker.mode = .once
        }
    }
}

// MARK: - Drawing

enum AriRenderer {
    static func draw(_ mark: AriMarkLayout, walker: AriWalker, glint: Bool, into context: inout GraphicsContext,
                     size: CGSize) {
        let vb = mark.viewBox
        guard vb.width > 0, vb.height > 0, size.width > 0, size.height > 0 else { return }
        let s = min(size.width / vb.width, size.height / vb.height)
        var ctx = context
        ctx.translateBy(x: (size.width - vb.width * s) / 2, y: (size.height - vb.height * s) / 2)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -vb.minX, y: -vb.minY)
        let m = mark.model

        // the strand
        let x0 = mark.strandX0, x1 = mark.strandX1, y = mark.strandY, w = mark.strandWidth
        ctx.fill(Path(CGRect(x: x0, y: y - w / 2, width: x1 - x0, height: w)),
                 with: .linearGradient(gradient(mark.strandStops), startPoint: CGPoint(x: x0, y: y),
                                       endPoint: CGPoint(x: x1, y: y)))
        if glint && walker.amp > 0 { drawGlints(mark, dist: walker.dist, amp: walker.amp, into: ctx) }

        // Ari, far to near
        let legShading = GraphicsContext.Shading.linearGradient(gradient(m.legStops), startPoint: CGPoint(x: 0, y: m.top),
                                                                endPoint: CGPoint(x: 0, y: m.ground))
        let ball = gradient(m.ballStops)
        let rim = Gradient(stops: [.init(color: .black.opacity(0), location: 0.55),
                                   .init(color: .black.opacity(m.rimAlpha), location: 1)])
        let spec = Gradient(stops: [.init(color: .white.opacity(0.95), location: 0),
                                    .init(color: .white.opacity(0.35), location: 0.5),
                                    .init(color: .white.opacity(0), location: 1)])
        for piece in m.pose(phase: walker.phase, amplitude: walker.amp, pace: walker.pace) {
            switch piece.kind {
            case .leg, .palp:
                var path = Path()
                for poly in piece.polygons {
                    guard let first = poly.first else { continue }
                    path.move(to: first.cg)
                    for p in poly.dropFirst() { path.addLine(to: p.cg) }
                    path.closeSubpath()
                }
                var c = ctx
                c.opacity = m.opacity(piece.key)
                c.fill(path, with: legShading)
            case .pro, .ped, .abd:
                let cx = piece.center.x, cy = piece.center.y, rx = piece.rx, ry = piece.ry
                ctx.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)),
                         with: .linearGradient(ball, startPoint: CGPoint(x: 0, y: cy - ry), endPoint: CGPoint(x: 0, y: cy + ry)))
                fillOval(ctx, center: CGPoint(x: cx, y: cy), rx: rx, ry: ry, rotation: .zero, gradient: rim)
                if piece.kind != .ped {
                    fillOval(ctx, center: CGPoint(x: cx - rx * 0.30, y: cy - ry * 0.58), rx: rx * 0.30, ry: ry * 0.14,
                             rotation: .degrees(-18), gradient: spec)
                }
            }
        }

        // the wordmark, as outlines
        if let word = mark.word {
            var c = ctx
            c.translateBy(x: word.tx, y: word.ty)
            c.scaleBy(x: word.scale, y: word.scale)
            c.opacity = word.opacity
            if m.finish == .chrome {
                // brushed steel, as on the website: a soft vertical gradient through the letters
                let steel = Gradient(colors: [color("#f6f7fa", 1), color("#b3b6c2", 1)])
                c.fill(wordPath, with: .linearGradient(steel, startPoint: CGPoint(x: 0, y: AriWordmark.bounds.minY),
                                                        endPoint: CGPoint(x: 0, y: AriWordmark.bounds.maxY)))
            } else {
                c.fill(wordPath, with: .color(color(word.hex, 1)))
            }
        }
    }

    /// An elliptical radial gradient: a unit circle, scaled to the oval (as SVG does for objectBoundingBox).
    private static func fillOval(_ ctx: GraphicsContext, center: CGPoint, rx: Double, ry: Double, rotation: Angle,
                                 gradient: Gradient) {
        guard rx > 0, ry > 0 else { return }
        var c = ctx
        c.translateBy(x: center.x, y: center.y)
        c.rotate(by: rotation)
        c.scaleBy(x: rx, y: ry)
        c.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
               with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: 1))
    }

    /// Highlights spaced along the strand, drifting back under her at the speed of her planted feet.
    private static func drawGlints(_ mark: AriMarkLayout, dist: Double, amp: Double, into ctx: GraphicsContext) {
        let x0 = mark.strandX0, x1 = mark.strandX1, span = x1 - x0, gap = mark.glintGap, half = mark.glintHalf
        guard gap > 0, span > 0 else { return }
        var c = ctx
        c.clip(to: Path(CGRect(x: x0, y: mark.strandY - 20, width: span, height: 40)))
        let base = Swift.min(1, amp * 1.3)
        let tint = color(mark.glintHex, 1)
        let glow = Gradient(stops: [.init(color: tint.opacity(0), location: 0), .init(color: tint, location: 0.5),
                                    .init(color: tint.opacity(0), location: 1)])
        let wrapped = (dist.truncatingRemainder(dividingBy: gap) + gap).truncatingRemainder(dividingBy: gap)
        var g0 = x0 + wrapped - gap
        while g0 < x1 {
            let mid = g0 + half
            let fade = Swift.max(0, Swift.min(1, Swift.min((mid - x0) / (span * 0.22), (x1 - mid) / (span * 0.22))))
            if fade > 0 {
                for (height, alpha) in [(mark.strandWidth * 3.2, 0.16), (mark.strandWidth, 0.9)] {
                    var g = c
                    g.opacity = base * fade * alpha
                    g.fill(Path(CGRect(x: g0, y: mark.strandY - height / 2, width: 2 * half, height: height)),
                           with: .linearGradient(glow, startPoint: CGPoint(x: g0, y: 0), endPoint: CGPoint(x: g0 + 2 * half, y: 0)))
                }
            }
            g0 += gap
        }
    }

    static let wordPath: Path = {
        var path = Path()
        for op in AriWordmark.ops {
            switch op {
            case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): path.addLine(to: CGPoint(x: x, y: y))
            case let .quad(qx, qy, x, y): path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: qx, y: qy))
            case .close: path.closeSubpath()
            }
        }
        return path
    }()

    static func color(_ hex: String, _ alpha: Double) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return Color(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255, opacity: alpha)
    }

    static func gradient(_ stops: [AriWalkModel.Stop]) -> Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: color($0.hex, $0.alpha), location: $0.location) })
    }
}

/// Silkwire's settings for Ari in the sidebar (Jason: skitter 0.60 s a stride at her slowest, 0.30 at her fastest).
enum AriSidebar {
    static let skitterCadence = 0.6
    static let fastestSkitterCadence = 0.3
    /// Jason: start a little later and walk long enough to be noticed. She holds still while the window settles,
    /// then takes one long walk (about 8 seconds at 1.15 s a stride) before she stops.
    static let introDelay = 1.5
    static let introStrides = 7.0
}
