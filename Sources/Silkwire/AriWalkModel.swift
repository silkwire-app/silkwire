import Foundation
import CoreGraphics

// Ari, walking: the model.
//
// A line-for-line Swift port of ari-engine.js from the brand kit (Project Ari/ari-walking), so the app and the
// website draw the same spider with the same gait. Pure geometry, no SwiftUI: AriWalkingMark.swift draws it.
//
// Units: "spider units" (her front leg is about 1.06 long) until projected; the projection multiplies by L design
// units per spider unit. With L = 100 the numbers match the brand-kit SVGs exactly.
//
// The gait is an alternating tetrapod, the way real spiders walk: legs L1 R2 L3 R4 swing while R1 L2 R3 L4 hold the
// line, then they swap, with a slight back-to-front ripple. Each leg's knee and ankle are solved every frame so its
// three segments keep their lengths. At amplitude 0 the pose is exactly the approved static mark.

struct AriWalkModel {
    enum Finish: String { case chrome, silver, graphite, black }

    struct Gait {
        var duty = 0.62       // fraction of the cycle a foot is on the line (at least four feet are always down)
        var stride = 0.22     // how far a foot travels back during one stance
        var lift = 0.075      // how high a foot lifts in swing
        var frontLift = 0.10  // the front pair lifts a little higher
        var ripple = 0.035    // phase lead of each leg over the one in front of it
        var bob = 0.008       // body rise and fall, twice per cycle
        var abdLag = 0.9      // the abdomen follows a little late (radians at twice the stride frequency)
        var abdBob = 0.007
        var palp = 0.012      // palps tick up and down
        // skittering: the same gait, faster, with lower, quicker steps (blended in by `pace`, 0 = walk, 1 = skitter)
        var skDuty = 0.56
        var skStride = 0.25
        var skLift = 0.62     // fraction of the walking lift
        var skBob = 0.005
    }

    enum Kind { case leg, palp, pro, ped, abd }

    struct Point: Equatable {
        var x: Double
        var y: Double
        var cg: CGPoint { CGPoint(x: x, y: y) }
    }

    struct Stop {
        var location: Double
        var hex: String
        var alpha: Double
    }

    /// One drawable piece. Legs and palps are polygons (tapered segments plus joint discs, all wound the same way so
    /// a single non-zero fill has no holes). Body parts are ellipses.
    struct Piece {
        var key: String
        var kind: Kind
        var z: Double
        var polygons: [[Point]] = []
        var center = Point(x: 0, y: 0)
        var rx = 0.0
        var ry = 0.0
        var tip = Point(x: 0, y: 0)
        var lifted = false
    }

    let L: Double
    let finish: Finish
    let gait: Gait
    let light: Bool
    let legStops: [Stop]
    let ballStops: [Stop]
    let rimAlpha: Double
    let top: Double
    let ground: Double
    /// How far the line moves under her on screen per stride at full amplitude (drives the travelling glint).
    let groundPerCycle: Double
    private(set) var left = 0.0
    private(set) var right = 0.0
    private(set) var rest: [Piece] = []
    private var restOpacity: [String: Double] = [:]

    private let D: Double
    private let ox: Double
    private let oy: Double
    private let fw: SIMD3<Double>
    private let lf: SIMD3<Double>
    private let legWidths: [Double]
    private let palpWidths: [Double]
    private let legs: [Leg]

    private struct Leg {
        let key: String
        let H: SIMD3<Double>
        let K: SIMD3<Double>
        let A: SIMD3<Double>
        let T: SIMD3<Double>
        let nK: Double
        let nA: Double
        let l1: Double
        let l2: Double
        let l3: Double
        let th3: Double
        let bend: Double
        let phase: Double
        let lift: Double
    }

    // The model, identical to the static mark. X forward, Y up, Z to her left.
    private static let legTable: [(hip: Double, pts: [SIMD3<Double>])] = [
        (28, [SIMD3(40, 0.44, 0.40), SIMD3(38, 0.80, 0.14), SIMD3(36, 1.06, 0)]),
        (62, [SIMD3(74, 0.42, 0.38), SIMD3(72, 0.72, 0.12), SIMD3(70, 0.94, 0)]),
        (98, [SIMD3(106, 0.36, 0.32), SIMD3(112, 0.60, 0.11), SIMD3(116, 0.78, 0)]),
        (128, [SIMD3(132, 0.44, 0.38), SIMD3(138, 0.78, 0.13), SIMD3(142, 1.02, 0)]),
    ]
    private static let bodyTable: [(kind: Kind, key: String, c: SIMD3<Double>, r: SIMD3<Double>)] = [
        (.pro, "pro", SIMD3(0.02, 0.13, 0), SIMD3(0.10, 0.085, 0.09)),
        (.ped, "ped", SIMD3(-0.115, 0.14, 0), SIMD3(0.045, 0.032, 0.032)),
        (.abd, "abd", SIMD3(-0.29, 0.215, 0), SIMD3(0.19, 0.185, 0.185)),
    ]
    private static let palpFrom = SIMD3<Double>(0.09, 0.11, 0.03)
    private static let palpMid = SIMD3<Double>(0.15, 0.07, 0.04)
    private static let palpTip = SIMD3<Double>(0.19, 0.095, 0.05)

    init(L: Double = 100, heading: Double = 145, D: Double = 8, finish: Finish, violet: Bool = true,
         legW: Double = 1, ox: Double = 0, oy: Double = 0, gait: Gait = Gait()) {
        self.L = L
        self.D = D
        self.ox = ox
        self.oy = oy
        self.finish = finish
        self.gait = gait
        let ps = heading * .pi / 180
        fw = SIMD3(cos(ps), 0, sin(ps))
        lf = SIMD3(-sin(ps), 0, cos(ps))
        let isLight = finish == .chrome || finish == .silver
        light = isLight
        let v = (finish == .chrome || finish == .black) ? true : violet
        legStops = AriWalkModel.legStops(finish, v)
        ballStops = AriWalkModel.ballStops(finish, v)
        rimAlpha = isLight ? 0.42 : 0.55
        top = oy - 0.46 * L
        ground = oy
        groundPerCycle = gait.stride / gait.duty * abs(cos(ps)) * L
        legWidths = [0.030, 0.024, 0.015, 0].map { $0 * legW }
        palpWidths = [0.013, 0.009, 0].map { $0 * legW }

        var built: [Leg] = []
        for side in [1.0, -1.0] {
            for (i, g) in AriWalkModel.legTable.enumerated() {
                var H = AriWalkModel.pol(side * g.hip, 0.095, 0.125)
                H.x += 0.02
                let K = AriWalkModel.pol(side * g.pts[0].x, g.pts[0].y, g.pts[0].z)
                let A = AriWalkModel.pol(side * g.pts[1].x, g.pts[1].y, g.pts[1].z)
                let T = AriWalkModel.pol(side * g.pts[2].x, g.pts[2].y, g.pts[2].z)
                let dx = T.x - H.x, dz = T.z - H.z, q = hypot(dx, dz)
                let dir = (dx / q, dz / q), perp = (-dz / q, dx / q)
                func plane(_ P: SIMD3<Double>) -> (rho: Double, n: Double, h: Double) {
                    let vx = P.x - H.x, vz = P.z - H.z
                    return (vx * dir.0 + vz * dir.1, vx * perp.0 + vz * perp.1, P.y - H.y)
                }
                let k = plane(K), a = plane(A), t = plane(T)
                let l1 = hypot(k.rho, k.h), l2 = hypot(a.rho - k.rho, a.h - k.h), l3 = hypot(a.rho - t.rho, a.h - t.h)
                let th3 = atan2(a.h - t.h, a.rho - t.rho)
                let cross = a.rho * k.h - a.h * k.rho
                let bend: Double = cross > 0 ? 1 : (cross < 0 ? -1 : 1)
                // diagonal groups: L1 R2 L3 R4 together, R1 L2 R3 L4 half a cycle later; hind legs lead slightly
                let group: Double = ((side == 1) == (i % 2 == 0)) ? 0 : 0.5
                let key = "leg" + (side > 0 ? "L" : "R") + String(i + 1)
                built.append(Leg(key: key, H: H, K: K, A: A, T: T, nK: k.n, nA: a.n, l1: l1, l2: l2, l3: l3, th3: th3,
                                 bend: bend, phase: group + Double(i) * gait.ripple,
                                 lift: i == 0 ? gait.frontLift : gait.lift))
            }
        }
        legs = built

        // the rest pose: extents, and the depth range that sets each leg's opacity
        let r = pose(phase: 0, amplitude: 0)
        rest = r
        let legZ = r.filter { $0.kind == .leg }.map(\.z)
        let zMin = legZ.min() ?? 0, zMax = legZ.max() ?? 1
        let range = zMax - zMin == 0 ? 1 : zMax - zMin
        var op: [String: Double] = [:]
        var xs: [Double] = []
        for it in r {
            if it.kind == .leg || it.kind == .palp {
                op[it.key] = min(1, 0.78 + 0.22 * (it.z - zMin) / range)
                for poly in it.polygons { for p in poly { xs.append(p.x) } }
            } else {
                xs.append(it.center.x - it.rx)
                xs.append(it.center.x + it.rx)
            }
        }
        restOpacity = op
        left = xs.min() ?? 0
        right = xs.max() ?? 0
    }

    func opacity(_ key: String) -> Double { restOpacity[key] ?? 1 }

    /// How far the line moves under her per stride at full amplitude, for a pace (0 walk, 1 skitter).
    func groundAt(pace k: Double) -> Double {
        AriWalkModel.lerp(gait.stride, gait.skStride, k) / AriWalkModel.lerp(gait.duty, gait.skDuty, k) * abs(fw.x) * L
    }

    private static func lerp(_ x: Double, _ y: Double, _ t: Double) -> Double { x + (y - x) * t }

    /// One frame. `phase` is in strides (any real number); `amplitude` 0...1, where 0 is the approved rest pose;
    /// `pace` 0...1 blends the walk into the skitter.
    func pose(phase p: Double, amplitude a: Double, pace k: Double = 0) -> [Piece] {
        let tw = 2 * Double.pi
        let duty = AriWalkModel.lerp(gait.duty, gait.skDuty, k)
        let stride = AriWalkModel.lerp(gait.stride, gait.skStride, k)
        let liftF = AriWalkModel.lerp(1, gait.skLift, k)
        let bob = a * AriWalkModel.lerp(gait.bob, gait.skBob, k) * (0.5 - 0.5 * cos(2 * tw * p))
        let abob = a * AriWalkModel.lerp(gait.abdBob, gait.skBob, k) * (0.5 - 0.5 * cos(2 * tw * p - gait.abdLag))
        let sw = 1 - duty
        var items: [Piece] = []
        items.reserveCapacity(13)
        for g in legs {
            var u = (p + g.phase).truncatingRemainder(dividingBy: 1)
            if u < 0 { u += 1 }
            var dx = 0.0, lift = 0.0
            if u < sw {
                let s = u / sw
                let e = 0.5 - 0.5 * cos(Double.pi * s)
                dx = stride * (-0.5 + e)
                lift = g.lift * liftF * pow(sin(Double.pi * s), 0.85)
            } else {
                let s = (u - sw) / duty
                dx = stride * (0.5 - s)
            }
            let T2 = SIMD3(g.T.x + a * dx, g.T.y + a * lift, g.T.z)
            let H2 = SIMD3(g.H.x, g.H.y + bob, g.H.z)
            let pts = a == 0 ? [g.H, g.K, g.A, g.T] : solve(g, H2, T2)
            let t = taper(pts, widths: legWidths)
            var piece = Piece(key: g.key, kind: .leg, z: t.z)
            piece.polygons = t.polygons
            piece.tip = t.tip
            piece.lifted = a * lift > 1e-4
            items.append(piece)
        }
        for side in [1.0, -1.0] {
            let tick = a * gait.palp * sin(tw * p + (side > 0 ? 0 : Double.pi))
            func m(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(v.x, v.y + bob, v.z * side) }
            let mid = SIMD3(AriWalkModel.palpMid.x, AriWalkModel.palpMid.y + tick * 0.5, AriWalkModel.palpMid.z)
            let tip = SIMD3(AriWalkModel.palpTip.x, AriWalkModel.palpTip.y + tick, AriWalkModel.palpTip.z)
            let t = taper([m(AriWalkModel.palpFrom), m(mid), m(tip)], widths: palpWidths)
            var piece = Piece(key: side > 0 ? "palpL" : "palpR", kind: .palp, z: t.z)
            piece.polygons = t.polygons
            items.append(piece)
        }
        for b in AriWalkModel.bodyTable {
            let off = b.kind == .abd ? abob : bob
            let c = project(world(SIMD3(b.c.x, b.c.y + off, b.c.z)))
            var piece = Piece(key: b.key, kind: b.kind, z: c.z)
            piece.center = c.pt
            piece.rx = sqrt(pow(b.r.x * fw.x, 2) + pow(b.r.z * lf.x, 2)) * c.k * L
            piece.ry = b.r.y * c.k * L
            items.append(piece)
        }
        items.sort { $0.z < $1.z }   // far to near
        return items
    }

    // MARK: geometry

    private static func pol(_ a: Double, _ r: Double, _ y: Double) -> SIMD3<Double> {
        SIMD3(r * cos(a * .pi / 180), y, r * sin(a * .pi / 180))
    }

    private func world(_ P: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(P.x * fw.x + P.z * lf.x, P.y, P.x * fw.z + P.z * lf.z)
    }

    private func project(_ P: SIMD3<Double>) -> (pt: Point, k: Double, z: Double) {
        let k = D / (D - P.z)
        return (Point(x: ox + P.x * k * L, y: oy - P.y * k * L), k, P.z)
    }

    /// Solves one leg for a hip at H2 and a tip at T2: tarsus angle held, femur and tibia by two-bone IK.
    private func solve(_ g: Leg, _ H2: SIMD3<Double>, _ T2: SIMD3<Double>) -> [SIMD3<Double>] {
        let dx = T2.x - H2.x, dz = T2.z - H2.z, q = hypot(dx, dz)
        let dir = (dx / q, dz / q), perp = (-dz / q, dx / q)
        let th = T2.y - H2.y
        var ar = q + g.l3 * cos(g.th3)
        var ah = th + g.l3 * sin(g.th3)
        var d = hypot(ar, ah)
        let dMax = g.l1 + g.l2 - 1e-4, dMin = abs(g.l1 - g.l2) + 1e-4
        if d > dMax { ar *= dMax / d; ah *= dMax / d; d = dMax }
        if d < dMin { ar *= dMin / d; ah *= dMin / d; d = dMin }
        let base = atan2(ah, ar)
        let alpha = acos(min(1, max(-1, (g.l1 * g.l1 + d * d - g.l2 * g.l2) / (2 * g.l1 * d))))
        let ka = base + g.bend * alpha
        let kr = g.l1 * cos(ka), kh = g.l1 * sin(ka)
        func back(_ rho: Double, _ n: Double, _ h: Double) -> SIMD3<Double> {
            SIMD3(H2.x + rho * dir.0 + n * perp.0, H2.y + h, H2.z + rho * dir.1 + n * perp.1)
        }
        return [H2, back(kr, g.nK, kh), back(ar, g.nA, ah), T2]
    }

    /// Tapered segments through the projected points, with a round disc at each inner joint.
    private func taper(_ pts3: [SIMD3<Double>], widths: [Double]) -> (polygons: [[Point]], z: Double, tip: Point) {
        let P = pts3.map { project(world($0)) }
        var W: [Double] = []
        for i in 0..<P.count { W.append(widths[i] * L * P[i].k / 2) }
        var polys: [[Point]] = []
        for i in 0..<(P.count - 1) {
            let a = P[i].pt, b = P[i + 1].pt
            var dx = b.x - a.x, dy = b.y - a.y
            let q = hypot(dx, dy)
            let qq = q == 0 ? 1 : q
            dx /= qq
            dy /= qq
            let quad = [Point(x: a.x - dy * W[i], y: a.y + dx * W[i]),
                        Point(x: b.x - dy * W[i + 1], y: b.y + dx * W[i + 1]),
                        Point(x: b.x + dy * W[i + 1], y: b.y - dx * W[i + 1]),
                        Point(x: a.x + dy * W[i], y: a.y - dx * W[i])]
            polys.append(quad)
            if i > 0 && W[i] > 0.05 {
                polys.append(AriWalkModel.disc(center: a, radius: W[i], matching: AriWalkModel.signedArea(quad)))
            }
        }
        let z = P.reduce(0.0) { $0 + $1.z } / Double(P.count)
        return (polys, z, P[P.count - 1].pt)
    }

    private static func signedArea(_ poly: [Point]) -> Double {
        var s = 0.0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            s += a.x * b.y - b.x * a.y
        }
        return s
    }

    /// A round joint as a polygon wound the same way as the leg segments around it.
    private static func disc(center c: Point, radius r: Double, matching sign: Double) -> [Point] {
        let n = 24
        var pts: [Point] = []
        for j in 0..<n {
            let t = Double(j) / Double(n) * 2 * Double.pi
            pts.append(Point(x: c.x + r * cos(t), y: c.y + r * sin(t)))
        }
        return sign < 0 ? Array(pts.reversed()) : pts
    }

    // MARK: finishes (same stops as the brand-kit SVGs)

    private static func s(_ l: Double, _ h: String, _ a: Double = 1) -> Stop { Stop(location: l, hex: h, alpha: a) }

    private static func legStops(_ f: Finish, _ v: Bool) -> [Stop] {
        switch f {
        case .chrome: return [s(0, "#ffffff"), s(0.40, "#cfd2dc"), s(0.62, "#7d8090"), s(0.82, "#9d92c9"), s(1, "#d6b08c")]
        case .black: return [s(0, "#9a9dad"), s(0.42, "#2e2f39"), s(0.62, "#15151b"), s(1, "#4a3a8c")]
        case .silver: return [s(0, "#ffffff"), s(0.45, "#d7d9e0"), s(0.72, "#9a9da8"), s(1, v ? "#a79ccc" : "#b4b7c2")]
        case .graphite: return [s(0, "#9a9dad"), s(0.42, "#3a3b45"), s(0.68, "#1a1a21"), s(1, v ? "#4a3a8c" : "#33343d")]
        }
    }

    private static func ballStops(_ f: Finish, _ v: Bool) -> [Stop] {
        switch f {
        case .chrome:
            return [s(0, "#ffffff"), s(0.30, "#e6e8ef"), s(0.50, "#a3a6b4"), s(0.535, "#2a2a33"), s(0.64, "#1f1e28"),
                    s(0.78, "#4e4670"), s(0.92, "#8d6bff"), s(1, "#d9a77a")]
        case .black:
            return [s(0, "#dcdee8"), s(0.30, "#6a6c7a"), s(0.5, "#15151c"), s(0.72, "#17151f"), s(0.9, "#4b3a9e"),
                    s(1, "#8d6bff")]
        case .silver:
            return [s(0, "#ffffff"), s(0.34, "#eef0f4"), s(0.52, "#c3c6cf"), s(0.56, "#6e717c"), s(0.72, "#8a8d98"),
                    s(0.9, v ? "#a596d6" : "#b9bcc6"), s(1, v ? "#9f8fe0" : "#c9ccd6")]
        case .graphite:
            return [s(0, "#d6d8e0"), s(0.30, "#6a6c78"), s(0.5, "#17171d"), s(0.72, "#1b1b22"),
                    s(0.9, v ? "#4b3a9e" : "#2e2f38"), s(1, v ? "#8d6bff" : "#45464f")]
        }
    }
}

// MARK: - Layout: Ari on her strand, with the wordmark beneath (matches the brand-kit stacked SVGs)

struct AriMarkLayout {
    enum Kind { case strand, stacked, stackedQuiet }

    struct Word {
        var tx: Double
        var ty: Double
        var scale: Double
        var opacity: Double
        var hex: String
    }

    let model: AriWalkModel
    let viewBox: CGRect
    let strandX0: Double
    let strandX1: Double
    let strandY: Double
    let strandWidth: Double
    let strandStops: [AriWalkModel.Stop]
    let glintHex: String
    let glintGap: Double
    let glintHalf: Double
    let word: Word?

    init(kind: Kind, finish: AriWalkModel.Finish, violet: Bool, small: Bool) {
        let L = 100.0, legW = small ? 1.6 : 1
        let probe = AriWalkModel(L: L, finish: finish, violet: violet, legW: legW)
        let span = probe.right - probe.left
        let m = AriWalkModel(L: L, finish: finish, violet: violet, legW: legW, ox: -(probe.left + probe.right) / 2)
        model = m
        let x0 = m.left - 0.42 * L, x1 = m.right + 0.42 * L
        strandX0 = x0
        strandX1 = x1
        strandY = 0
        let sw = (small ? 0.016 : 0.011) * L
        strandWidth = sw
        let dark = finish == .chrome || finish == .silver
        let col = dark ? "#d6d8e0" : "#2a2b33", hi = dark ? "#ffffff" : "#000000"
        let w = x1 - x0
        strandStops = [
            AriWalkModel.Stop(location: 0, hex: col, alpha: 0),
            AriWalkModel.Stop(location: (m.left - x0) / w, hex: col, alpha: 0.85),
            AriWalkModel.Stop(location: (m.left + span * 0.3 - x0) / w, hex: hi, alpha: 0.95),
            AriWalkModel.Stop(location: (m.right - span * 0.3 - x0) / w, hex: hi, alpha: 0.95),
            AriWalkModel.Stop(location: (m.right - x0) / w, hex: col, alpha: 0.85),
            AriWalkModel.Stop(location: 1, hex: col, alpha: 0),
        ]
        glintHex = dark ? "#ffffff" : "#9a9dad"
        glintGap = w * 0.62
        glintHalf = span * 0.16
        var bottom = sw
        if kind == .strand {
            word = nil
        } else {
            let quiet = kind == .stackedQuiet
            let b = AriWordmark.bounds
            let cw = (quiet ? 0.6 : 0.7) * span / (b.maxX - b.minX) * AriWordmark.capHeight
            let ws = cw / AriWordmark.capHeight
            let base = 0.62 * cw + cw
            word = Word(tx: -(b.minX + b.maxX) / 2 * ws, ty: base, scale: ws, opacity: quiet ? 0.78 : 1,
                        hex: dark ? "#f2f2f6" : "#22232b")
            bottom = base + 0.02 * cw
        }
        let pad = 0.12 * L
        viewBox = CGRect(x: x0 - 0.04 * L, y: m.top - pad, width: w + 0.08 * L, height: bottom - m.top + pad * 2)
    }
}

// MARK: - The wordmark: SILKWIRE in Archivo Italic, width 125, weight 400, tracking 0.17em, as outlines (font size 100)

enum AriWordmark {
    static let bounds = (minX: 4.54, minY: -69.85, maxX: 710.92, maxY: 1.2)
    static let capHeight = 68.6

    enum Op {
        case move(Double, Double)
        case line(Double, Double)
        case quad(Double, Double, Double, Double)
        case close
    }

    static let ops: [Op] = parse(pathData)

    /// Absolute M, L, H, V, Q and Z, with implicit line-tos after a move-to. Whitespace and line breaks are ignored.
    static func parse(_ d: String) -> [Op] {
        let t = tokens(d)
        var ops: [Op] = []
        var i = 0
        var cmd: Character = "M"
        var cx = 0.0, cy = 0.0
        func next() -> Double? {
            if i < t.count, case let .num(v) = t[i] { i += 1; return v }
            return nil
        }
        while i < t.count {
            if case let .cmd(c) = t[i] {
                cmd = c
                i += 1
                if c == "Z" || c == "z" { ops.append(.close); continue }
            }
            switch cmd {
            case "M":
                guard let x = next(), let y = next() else { break }
                ops.append(.move(x, y)); cx = x; cy = y; cmd = "L"
            case "L":
                guard let x = next(), let y = next() else { break }
                ops.append(.line(x, y)); cx = x; cy = y
            case "H":
                guard let x = next() else { break }
                ops.append(.line(x, cy)); cx = x
            case "V":
                guard let y = next() else { break }
                ops.append(.line(cx, y)); cy = y
            case "Q":
                guard let x1 = next(), let y1 = next(), let x = next(), let y = next() else { break }
                ops.append(.quad(x1, y1, x, y)); cx = x; cy = y
            default:
                i += 1
            }
            if i < t.count, case .num = t[i], cmd == "Z" || cmd == "z" { i += 1 }
        }
        return ops
    }

    private enum Token { case cmd(Character), num(Double) }

    private static func tokens(_ d: String) -> [Token] {
        var out: [Token] = []
        var num = ""
        func flush() {
            if !num.isEmpty, let v = Double(num) { out.append(.num(v)) }
            num = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush(); out.append(.cmd(ch))
            } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" || ch == "\r" {
                flush()
            } else if ch == "-" || ch == "+" {
                if let last = num.last, last != "e" && last != "E" { flush() }
                num.append(ch)
            } else if ch == "." {
                if num.contains(".") { flush() }
                num.append(ch)
            } else {
                num.append(ch)
            }
        }
        flush()
        return out
    }

    static let pathData = """
M39.2 1.2Q32.2 1.2 25.9 0.5Q19.7 -0.3 14.9 -2.1Q10 -4 7.3 -7.4Q4.5 -10.8 4.5 -16Q4.5 -17.5 4.8 -19
Q5 -20.5 5.4 -21.6H16.2Q16 -21 15.7 -19.9Q15.4 -18.8 15.4 -17.6Q15.4 -14.4 18.2 -12.2Q21.1 -10.1 26.4 -9
Q31.7 -7.9 39.1 -7.9Q43.8 -7.9 48.5 -8.5Q53.2 -9.1 57 -10.5Q60.8 -11.9 63.2 -14.2Q65.5 -16.5 65.5 -19.9
Q65.5 -22.7 63.4 -24.5Q61.3 -26.4 57.8 -27.5Q54.2 -28.6 49.9 -29.4Q45.5 -30.2 41 -30.9Q36 -31.7 30.9 -32.9
Q25.8 -34 21.6 -35.9Q17.4 -37.8 14.9 -40.9Q12.3 -44 12.3 -48.7Q12.3 -53.2 14.5 -57.1Q16.6 -60.9 21 -63.8
Q25.5 -66.6 32.3 -68.2Q39.2 -69.9 48.6 -69.9Q57.3 -69.9 63.2 -68.6Q69.2 -67.3 72.8 -65.1Q76.4 -62.9 78 -60
Q79.7 -57.1 79.7 -53.9Q79.7 -53.2 79.6 -52.2Q79.5 -51.2 79.1 -49.2H68.4Q68.7 -50.5 68.8 -51.1
Q68.8 -51.7 68.8 -51.9Q68.8 -55.5 63.8 -58.1Q58.7 -60.8 49.4 -60.8Q41 -60.8 35.3 -59.5Q29.6 -58.2 26.7 -55.9
Q23.8 -53.6 23.8 -50.4Q23.8 -47.7 26.1 -46.1Q28.3 -44.5 32.1 -43.5Q35.9 -42.5 40.6 -41.8Q45.4 -41 50.4 -40.1
Q55.6 -39.1 60.4 -37.8Q65.1 -36.6 68.9 -34.7Q72.7 -32.8 74.9 -29.7Q77.1 -26.7 77.1 -22.2Q77.1 -15.7 74.1 -11.2
Q71.1 -6.7 65.9 -4Q60.6 -1.2 53.8 -0Q47 1.2 39.2 1.2Z M107.9 0 120 -68.7H130.8L118.7 0Z M157.3 0 169.4 -68.7
H180.2L169.8 -9.6H212.9L211.2 0Z M242.6 0 254.7 -68.7H265.5L258.7 -30.1L311.1 -68.7H326.3L289.2 -40.9L315.3 0
H302.4L280.6 -34.8L256.6 -17.9L253.4 0Z M358 0 344.9 -68.7H356.1L364.5 -21.6Q364.8 -20.4 365.1 -18.4
Q365.4 -16.5 365.8 -14.4Q366.1 -12.3 366.3 -10.7H367.1Q367.7 -12.3 368.6 -14.3Q369.4 -16.3 370.3 -18.3
Q371.1 -20.3 371.7 -21.6L393.5 -68.7H408.6L415.6 -21.6Q415.9 -19.9 416.1 -18Q416.4 -16.1 416.6 -14.2
Q416.8 -12.3 416.9 -10.7H417.7Q418.5 -12.3 419.4 -14.4Q420.3 -16.4 421.3 -18.4Q422.2 -20.3 422.8 -21.6
L446.1 -68.7H457.3L422.3 0H408.3L401 -47.5Q400.9 -48.7 400.6 -50.5Q400.4 -52.3 400.2 -54.4
Q399.9 -56.4 399.7 -58.2H399Q398.4 -56.6 397.5 -54.6Q396.6 -52.5 395.8 -50.6Q395 -48.7 394.4 -47.5L372.3 0Z 
M474.5 0 486.6 -68.7H497.4L485.3 0Z M523.9 0 536 -68.7H585.5Q592.1 -68.7 596.5 -66.5Q600.8 -64.3 602.9 -60.6
Q605 -56.8 605 -52Q605 -46.7 603.1 -41.9Q601.1 -37.2 597.4 -33.7Q593.6 -30.2 588.2 -28.4L597.9 0H586.3
L577.4 -26.8H539.5L534.7 0ZM541.1 -36H579Q583.2 -36 586.6 -37.8Q589.9 -39.7 591.8 -42.9
Q593.7 -46.2 593.7 -50.3Q593.7 -54.5 591.1 -57Q588.6 -59.4 583.4 -59.4H545.2Z M631.2 0 643.3 -68.7H710.9
L709.3 -59.4H652.5L649.1 -39.7H700.2L698.5 -30.5H647.4L643.6 -9.2H701.2L699.6 0Z
"""
}

// MARK: - The walker: when she walks, how fast, and how she starts and settles

/// Integrates amplitude, pace, phase and ground travel over time. Not observable on purpose: the view's TimelineView
/// redraws every frame while she moves, and nothing else needs to know.
final class AriWalker {
    enum Mode {
        case once      // still until asked: walk(), skitter() or hover
        case loop      // walks forever
        case skitter   // skitters forever
        case wander    // walks slowly, freezes, skitters, freezes, walks on (a 9-second loop)
    }

    /// Wander: segment end time, amplitude, pace. Each freeze keeps the pace of the move before it for half a second,
    /// so she stops the way she moved (gently after a walk, abruptly after a skitter), then takes on the next pace.
    static let wander: [(until: Double, amp: Double, pace: Double)] = [
        (4.6, 1, 0), (5.1, 0, 0), (5.8, 0, 1), (7.2, 1, 1), (7.7, 0, 1), (9.0, 0, 0),
    ]

    var cadence = 1.15            // seconds per walking stride
    var skitterCadence = 0.3      // seconds per skittering stride (larger is slower)
    var mode: Mode = .once
    var hoverSkitters = false
    private(set) var amp = 0.0
    private(set) var pace = 0.0   // 0 walk, 1 skitter
    private(set) var phase = 0.0
    private(set) var dist = 0.0
    private var walkUntil: TimeInterval = 0
    private var walkFrom: TimeInterval = 0     // a delayed one-off walk holds still until this moment
    private var untilPace = 0.0
    private var hovering = false
    private var hoverStart: TimeInterval = 0
    private var clock = 0.0
    private var last: TimeInterval?

    var currentCadence: Double { cadence + (skitterCadence - cadence) * pace }

    /// Walk at least `cycles` strides from `now`.
    /// With a `delay`, she holds the approved pose until `now + delay`, then walks the full `cycles`.
    /// A walk already under way is extended, never paused.
    func walk(cycles: Double, now: TimeInterval, delay: Double = 0) {
        untilPace = 0
        let underway = now >= walkFrom && now < walkUntil
        if underway {
            walkUntil = max(walkUntil, now + cycles * cadence)        // a replay mid-walk keeps her going `cycles` strides from now
        } else {
            walkFrom = now + max(0, delay)
            walkUntil = max(walkUntil, walkFrom + cycles * cadence)
        }
    }

    /// Skitter at least `cycles` strides from `now`.
    func skitter(cycles: Double, now: TimeInterval) {
        untilPace = 1
        walkFrom = min(walkFrom, now)
        walkUntil = max(walkUntil, now + cycles * skitterCadence)
    }

    /// Pointer over her: she walks (or skitters). Pointer leaves: she finishes the step she is in and settles.
    func hover(_ inside: Bool, now: TimeInterval) {
        if inside {
            if !hovering { hoverStart = now }
            hovering = true
        } else if hovering {
            hovering = false
            untilPace = hoverSkitters ? 1 : 0
            walkFrom = min(walkFrom, now)
            walkUntil = max(walkUntil, now + 0.6 * currentCadence)
        }
    }

    func stopAll() { mode = .once; hovering = false; walkUntil = 0; walkFrom = 0; amp = 0 }

    private func goal(at now: TimeInterval) -> (amp: Double, pace: Double) {
        switch mode {
        case .wander:
            let seg = AriWalker.wander.first(where: { clock < $0.until }) ?? AriWalker.wander[0]
            return (seg.amp, seg.pace)
        case .loop: return (1, 0)
        case .skitter: return (1, 1)
        case .once:
            if hovering { return (1, hoverSkitters ? 1 : 0) }
            if now >= walkFrom && now < walkUntil { return (1, untilPace) }
            return (0, pace)
        }
    }

    /// True once a one-off walk has finished and she is back in the approved pose.
    /// A walk that is still waiting out its delay is not settled, so the timeline keeps running until she starts.
    func isSettled(at now: TimeInterval) -> Bool { mode == .once && amp == 0 && goal(at: now).amp == 0 && now >= walkUntil }

    func advance(to now: TimeInterval, model: AriWalkModel, reduceMotion: Bool) {
        if reduceMotion { amp = 0; last = now; return }
        guard let previous = last, now - previous < 0.25 else { last = now; return }   // resuming: start clean, no jump
        let dt = min(0.05, max(0, now - previous))
        last = now
        if dt == 0 { return }
        if hovering && now - hoverStart > 8 { hovering = false }   // never more than eight seconds at a time
        if mode == .wander {
            clock = (clock + dt).truncatingRemainder(dividingBy: AriWalker.wander[AriWalker.wander.count - 1].until)
        }
        let g = goal(at: now)
        pace += (g.pace - pace) * (1 - exp(-dt / 0.12))
        let k = pace
        let tau = g.amp > amp ? 0.22 + (0.06 - 0.22) * k : 0.26 + (0.08 - 0.26) * k
        amp += (g.amp - amp) * (1 - exp(-dt / tau))
        if g.amp == 0 && amp < 0.003 { amp = 0; return }          // settled: exactly the approved pose
        let c = 0.55 + 0.45 * amp                                    // strides slow down as she settles
        let dp = dt / currentCadence * c
        phase += dp
        dist += dp * amp * model.groundAt(pace: k)
    }
}
