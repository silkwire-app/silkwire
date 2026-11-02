import Foundation

/// Monotonic liveness policy used by the actual transport, separately testable without a socket.
struct EveConnectionWatchdog {
    private(set) var lastFrame: TimeInterval
    private var lastWake: TimeInterval
    private var graceFor: TimeInterval?
    private var graceUntil: TimeInterval = 0
    init(now: TimeInterval) { lastFrame = now; lastWake = now }
    mutating func receivedFrame(at now: TimeInterval) { lastFrame = now }
    mutating func isDead(at now: TimeInterval, tickSeconds: TimeInterval) -> Bool {
        defer { lastWake = now }
        if now - lastWake > 5, graceFor != lastFrame {
            graceFor = lastFrame; graceUntil = now + 5
        }
        if graceFor == lastFrame, now < graceUntil { return false }
        return now - lastFrame > max(1, tickSeconds) * 2
    }
}
