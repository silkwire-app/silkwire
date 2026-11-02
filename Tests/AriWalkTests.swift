import Foundation

@main struct AriWalkTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let model = AriWalkModel(finish: .graphite)
        let rest = model.pose(phase: 0, amplitude: 0)
        check(rest.count == 13, "eight legs, two palps and three body parts")
        check(rest.filter { $0.kind == .leg }.allSatisfy { !$0.lifted }, "at rest every foot is on the line")
        let again = model.pose(phase: 0.37, amplitude: 0)
        check(zip(rest, again).allSatisfy { $0.key == $1.key && $0.center == $1.center }, "at amplitude 0 the pose is the approved still mark, whatever the phase")
        let walking = model.pose(phase: 0.3, amplitude: 1)
        check(walking.filter { $0.kind == .leg && !$0.lifted }.count >= 4, "at least four feet hold the line mid-stride")

        let layout = AriMarkLayout(kind: .stackedQuiet, finish: .graphite, violet: false, small: true)
        check(layout.viewBox.width > 0 && layout.viewBox.height > 0 && layout.word != nil, "the sidebar layout has a size and the name beneath")
        check(!AriWordmark.ops.isEmpty, "the SILKWIRE lettering outline parses")

        // The walker: a short walk, then truly still.
        let walker = AriWalker()
        walker.skitterCadence = AriSidebar.skitterCadence
        var t = 1000.0
        walker.advance(to: t, model: model, reduceMotion: false)
        check(walker.isSettled(at: t), "before anything happens she is settled")
        walker.walk(cycles: 2.5, now: t)
        for _ in 0..<60 { t += 1.0 / 60; walker.advance(to: t, model: model, reduceMotion: false) }
        check(walker.amp > 0.5 && !walker.isSettled(at: t), "she walks when asked")
        for _ in 0..<(60 * 8) { t += 1.0 / 60; walker.advance(to: t, model: model, reduceMotion: false) }
        check(walker.amp == 0 && walker.isSettled(at: t), "after the opening walk she settles back to exactly the still pose")
        let phase = walker.phase
        for _ in 0..<60 { t += 1.0 / 60; walker.advance(to: t, model: model, reduceMotion: false) }
        check(walker.phase == phase, "once settled nothing changes, so nothing needs redrawing")

        // Hover walks for at most eight seconds, then she stops even if the pointer stays.
        walker.hover(true, now: t)
        for _ in 0..<(60 * 2) { t += 1.0 / 60; walker.advance(to: t, model: model, reduceMotion: false) }
        check(walker.amp > 0.5, "hovering over her starts her walking again")
        walker.hover(false, now: t)
        for _ in 0..<(60 * 6) { t += 1.0 / 60; walker.advance(to: t, model: model, reduceMotion: false) }
        check(walker.isSettled(at: t), "moving the pointer away lets her settle")

        // The opening walk: hold still through the delay (without pausing her clock), then one long walk, then settle.
        let intro = AriWalker()
        var u = 5000.0
        intro.advance(to: u, model: model, reduceMotion: false)
        intro.walk(cycles: AriSidebar.introStrides, now: u, delay: AriSidebar.introDelay)
        check(!intro.isSettled(at: u), "a delayed walk keeps her clock running so she can start on time")
        for _ in 0..<Int(60 * (AriSidebar.introDelay - 0.2)) { u += 1.0 / 60; intro.advance(to: u, model: model, reduceMotion: false) }
        check(intro.amp == 0 && intro.phase == 0, "during the delay she holds exactly the still pose")
        for _ in 0..<(60 * 2) { u += 1.0 / 60; intro.advance(to: u, model: model, reduceMotion: false) }
        check(intro.amp > 0.5, "after the delay she starts walking")
        for _ in 0..<(60 * 5) { u += 1.0 / 60; intro.advance(to: u, model: model, reduceMotion: false) }
        check(intro.amp > 0.5 && !intro.isSettled(at: u), "she is still walking well into the opening walk")
        for _ in 0..<(60 * 6) { u += 1.0 / 60; intro.advance(to: u, model: model, reduceMotion: false) }
        check(intro.amp == 0 && intro.isSettled(at: u), "after the long opening walk she settles back to the still pose")
        // Hovering during the delay starts her straight away, and leaving lets her settle.
        let eager = AriWalker()
        var v = 9000.0
        eager.advance(to: v, model: model, reduceMotion: false)
        eager.walk(cycles: 1, now: v, delay: 1)
        eager.hover(true, now: v)
        for _ in 0..<30 { v += 1.0 / 60; eager.advance(to: v, model: model, reduceMotion: false) }
        check(eager.amp > 0.5, "hovering during the delay starts her walking")
        eager.hover(false, now: v)
        for _ in 0..<(60 * 5) { v += 1.0 / 60; eager.advance(to: v, model: model, reduceMotion: false) }
        check(eager.amp == 0 && eager.isSettled(at: v), "leaving her during the delay carries on into the opening walk, then she settles")

        // Replay while she is already walking: she keeps going the full replay from that moment (Codex review).
        let replay = AriWalker()
        var w = 12000.0
        replay.advance(to: w, model: model, reduceMotion: false)
        replay.walk(cycles: 2, now: w)                                   // would end 2.3 s after starting
        for _ in 0..<Int(60 * 1.7) { w += 1.0 / 60; replay.advance(to: w, model: model, reduceMotion: false) }
        replay.walk(cycles: 2.5, now: w)                                 // replay mid-walk: ~2.9 s more from here
        for _ in 0..<Int(60 * 2.0) { w += 1.0 / 60; replay.advance(to: w, model: model, reduceMotion: false) }
        check(replay.amp > 0.5 && !replay.isSettled(at: w), "a replay mid-walk extends her walk from that moment, not from when she first started")
        for _ in 0..<(60 * 4) { w += 1.0 / 60; replay.advance(to: w, model: model, reduceMotion: false) }
        check(replay.amp == 0 && replay.isSettled(at: w), "after the replayed walk she settles back to the still pose")

        // Reduce Motion: never moves.
        let calm = AriWalker()
        calm.walk(cycles: 3, now: t)
        for _ in 0..<60 { t += 1.0 / 60; calm.advance(to: t, model: model, reduceMotion: true) }
        check(calm.amp == 0 && calm.phase == 0, "with Reduce Motion on she never moves")

        // Jason's skitter range.
        check(AriSidebar.skitterCadence == 0.6 && AriSidebar.fastestSkitterCadence == 0.3, "skitter is 0.60 s a stride at her slowest, 0.30 at her fastest")
        let app = (try? String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)) ?? ""
        check(app.contains("AriWalkingMark(behavior: .intro(strides: AriSidebar.introStrides), skitterCadence: AriSidebar.skitterCadence, reduceMotion: store.preferences.reduceMotion)"), "the sidebar shows walking Ari with the longer opening walk and honours the app's Reduce Motion setting")
        check(AriSidebar.introDelay >= 1 && AriSidebar.introStrides * 1.15 >= 7, "Jason: she starts a little later and walks long enough to be noticed")
        let mark = (try? String(contentsOfFile: "Sources/Silkwire/AriWalkingMark.swift", encoding: .utf8)) ?? ""
        check(mark.contains("TimelineView(.animation(minimumInterval: nil, paused: !animating))"), "her animation clock is paused whenever she is still")
        print("PASS: \(count) walking Ari checks")
    }
}
