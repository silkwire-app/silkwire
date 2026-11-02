import Foundation

// Idle and takeover rules for agents driving the Mac: agents wait for Jason to be
// idle (or invited), any real input pauses them at once, one drives at a time.
@main struct DriveArbiterTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

        // Waiting for Jason to be idle.
        var wheel = DriveArbiter(idleSeconds: 20, lastHumanInput: start)
        check(wheel.status(at: at(0)) == .none, "nobody wants the wheel at first")
        check(wheel.request("claude", at: at(1)), "the first teammate to ask holds the wheel")
        check(!wheel.mayAct("claude", at: at(1)), "the holder may not act while Jason was just active")
        check(wheel.status(at: at(1)) == .waiting(agent: "claude", remaining: 19), "status counts down to the idle threshold")
        check(!wheel.mayAct("claude", at: at(19.9)), "19.9 seconds idle is not enough")
        check(wheel.mayAct("claude", at: at(20)), "20 seconds idle lets the holder drive")
        check(wheel.status(at: at(20)) == .driving(agent: "claude"), "status shows Claude driving")
        check(!wheel.mayAct("codex", at: at(25)), "a teammate without the wheel never acts")

        // Takeover: any real input pauses immediately and restarts the idle clock.
        wheel.noteAction("claude", at: at(21))
        check(wheel.humanInput(at: at(22)), "Jason's input while Claude drives is a takeover")
        check(!wheel.mayAct("claude", at: at(22)), "the takeover pauses Claude immediately")
        check(wheel.status(at: at(22)) == .paused(agent: "claude", remaining: 20), "status says paused with a fresh countdown")
        check(wheel.driver == "claude", "Claude keeps its place at the wheel while paused")
        check(!wheel.humanInput(at: at(30)), "further input while paused is not another takeover")
        check(!wheel.mayAct("claude", at: at(45)), "input during the pause restarts the countdown")
        check(wheel.mayAct("claude", at: at(50)), "Claude resumes after Jason is idle again")
        check(wheel.status(at: at(50)) == .driving(agent: "claude"), "status returns to driving after the pause")

        // Jitter and stale reports are not takeovers.
        check(!wheel.humanInput(at: at(51), pointerDelta: 0.5), "sub-jitter pointer movement does not take over")
        check(wheel.mayAct("claude", at: at(51)), "jitter leaves Claude driving")
        check(!wheel.observeSystemIdle(60, at: at(55)), "an older OS idle report never makes Jason more active")
        check(wheel.observeSystemIdle(0.1, at: at(56)), "an OS report of fresh hardware input is a takeover")
        check(!wheel.mayAct("claude", at: at(56)), "the OS-reported input pauses Claude")

        // "Let them drive" overrides the idle wait until Jason's next input.
        wheel.letThemDrive(at: at(57))
        check(wheel.mayAct("claude", at: at(57)), "Let them drive lets the holder act immediately")
        check(!wheel.humanInput(at: at(58), pointerDelta: 5), "moving a hand off the mouse right after the click does not cancel")
        check(wheel.mayAct("claude", at: at(58)), "the invitation survives the grace period")
        check(wheel.humanInput(at: at(60), pointerDelta: 40), "real input after the grace period takes over")
        check(!wheel.invited && !wheel.mayAct("claude", at: at(60)), "the takeover withdraws the invitation")

        // Finding 2: within the grace, hand-off mouse motion is ignored but a key press still takes over.
        var grace = DriveArbiter(idleSeconds: 20, lastHumanInput: start)
        grace.request("claude", at: at(0)); grace.letThemDrive(at: at(1))
        check(!grace.humanInput(at: at(1.5), pointerDelta: 40), "mouse motion during the invitation grace does not take over")
        check(grace.mayAct("claude", at: at(1.5)), "the agent keeps driving through hand-off motion")
        check(grace.humanInput(at: at(1.6)), "a key press during the invitation grace still takes over")
        check(!grace.mayAct("claude", at: at(1.6)), "the key press pauses the agent inside the grace window")

        // One teammate drives; the others queue in order and inherit on release.
        wheel = DriveArbiter(idleSeconds: 20, lastHumanInput: start)
        check(wheel.request("claude", at: at(1)), "Claude holds the wheel")
        check(!wheel.request("codex", at: at(2)), "Codex queues behind Claude")
        check(!wheel.request("eve", at: at(3)), "Eve queues behind Codex")
        check(!wheel.request("codex", at: at(4)) && wheel.queue == ["codex", "eve"], "asking twice keeps one place in line")
        check(wheel.position("claude") == 0 && wheel.position("codex") == 1 && wheel.position("eve") == 2, "queue positions are reported")
        check(wheel.mayAct("claude", at: at(30)) && !wheel.mayAct("codex", at: at(30)) && !wheel.mayAct("eve", at: at(30)), "only the holder acts even when Jason is idle")
        wheel.release("claude", at: at(31))
        check(wheel.driver == "codex" && wheel.queue == ["eve"], "Codex inherits the wheel when Claude releases it")
        check(wheel.mayAct("codex", at: at(31)), "the next holder still honors the idle period, which has already passed")
        wheel.release("eve", at: at(32))
        check(wheel.driver == "codex" && wheel.queue.isEmpty, "a queued teammate can leave the line")
        wheel.release("codex", at: at(33))
        check(wheel.driver == nil && wheel.status(at: at(33)) == .none, "releasing the last holder clears the wheel")

        // The invitation belongs to the current drive, not to the next request.
        wheel.request("claude", at: at(40)); wheel.letThemDrive(at: at(40))
        wheel.release("claude", at: at(41))
        check(!wheel.invited, "an invitation ends when nobody is left driving")
        wheel.humanInput(at: at(42)); wheel.request("codex", at: at(43))
        check(!wheel.mayAct("codex", at: at(43)), "a new drive waits for idle again")

        // A holder that stopped acting yields to someone waiting; Stop clears everything.
        wheel = DriveArbiter(idleSeconds: 20, lastHumanInput: start)
        wheel.request("claude", at: at(1)); wheel.noteAction("claude", at: at(21)); wheel.request("eve", at: at(22))
        check(wheel.expireIdleHolder(at: at(100), after: 120) == nil, "a recent holder keeps the wheel")
        check(wheel.expireIdleHolder(at: at(141), after: 120) == "claude" && wheel.driver == "eve", "a holder idle for two minutes yields to the next in line")
        wheel.request("codex", at: at(142)); wheel.letThemDrive(at: at(142))
        wheel.stopAll()
        check(wheel.driver == nil && wheel.queue.isEmpty && !wheel.invited && wheel.status(at: at(200)) == .none, "Stop clears the holder, the line and the invitation")

        // Settings change the threshold.
        wheel = DriveArbiter(idleSeconds: 45, lastHumanInput: start)
        wheel.request("eve", at: at(1))
        check(!wheel.mayAct("eve", at: at(30)) && wheel.mayAct("eve", at: at(45)), "a custom idle period is honored")

        print("DriveArbiterTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
