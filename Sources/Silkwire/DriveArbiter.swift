import Foundation

/// Who may move the pointer and send keys, and when. Pure state: the control
/// center feeds it Jason's real input and the clock, and asks before every step.
///
/// - One teammate holds the wheel; others queue in request order.
/// - The holder acts only after Jason has been idle `idleSeconds`, or after he
///   pressed "Let them drive".
/// - Any real input from Jason pauses the holder at once and withdraws the invitation.
struct DriveArbiter: Equatable {
    enum Status: Equatable {
        case none
        /// The holder wants the wheel and waits for Jason to be idle (or invite it).
        case waiting(agent: String, remaining: Int)
        case driving(agent: String)
        /// Jason's input took over mid-drive; the holder resumes after the idle period.
        case paused(agent: String, remaining: Int)
        var agent: String? {
            switch self { case .none: return nil; case .waiting(let agent, _), .driving(let agent), .paused(let agent, _): return agent }
        }
    }
    var idleSeconds: Double
    /// A short grace after "Let them drive" so moving a hand off the mouse does not cancel it.
    var inviteGrace: Double = 1.5
    /// Pointer movement smaller than this (points) is sensor jitter, not a takeover.
    var jitter: Double = 2
    private(set) var driver: String?
    private(set) var queue: [String] = []
    private(set) var lastHumanInput: Date
    private(set) var invited = false
    private(set) var invitedAt: Date?
    private(set) var tookOver = false
    private(set) var lastAction: Date?

    init(idleSeconds: Double = 20, lastHumanInput: Date = Date()) {
        self.idleSeconds = idleSeconds; self.lastHumanInput = lastHumanInput
    }

    func idle(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(lastHumanInput)) }

    /// Joins the line. True when this teammate holds the wheel (it may still have to wait).
    @discardableResult mutating func request(_ agent: String, at now: Date) -> Bool {
        if driver == nil { driver = agent; lastAction = now; queue.removeAll { $0 == agent }; return true }
        if driver == agent { return true }
        if !queue.contains(agent) { queue.append(agent) }
        return false
    }
    func position(_ agent: String) -> Int? {
        if driver == agent { return 0 }
        return queue.firstIndex(of: agent).map { $0 + 1 }
    }

    /// The holder may act now: Jason is idle long enough or has invited the agents.
    func mayAct(_ agent: String, at now: Date) -> Bool {
        driver == agent && (invited || idle(at: now) >= idleSeconds)
    }

    /// Real input from Jason (never Silkwire's own tagged events). Returns true when
    /// this input took the wheel from a teammate that was allowed to act.
    @discardableResult mutating func humanInput(at now: Date, pointerDelta: Double? = nil) -> Bool {
        if let delta = pointerDelta, delta < jitter { return false }
        if pointerDelta != nil, invited, let invitedAt, now.timeIntervalSince(invitedAt) < inviteGrace { return false }
        let wasActing = driver.map { mayAct($0, at: now) } ?? false
        if now > lastHumanInput { lastHumanInput = now }
        invited = false; invitedAt = nil
        if wasActing { tookOver = true }
        return wasActing
    }
    /// The OS reports Jason's last hardware input this many seconds ago. Catches
    /// input an event monitor missed; it can only make Jason less idle.
    mutating func observeSystemIdle(_ seconds: Double, at now: Date) -> Bool {
        let input = now.addingTimeInterval(-max(0, seconds))
        guard input > lastHumanInput.addingTimeInterval(0.25) else { return false }
        return humanInput(at: input)
    }

    /// Jason pressed "Let them drive": the holder may act now, until his next input.
    mutating func letThemDrive(at now: Date) {
        invited = true; invitedAt = now; tookOver = false
    }
    /// The holder performed a step.
    mutating func noteAction(_ agent: String, at now: Date) {
        guard driver == agent else { return }
        lastAction = now; tookOver = false
    }
    /// Done driving (reply finished, task ended or stopped). The next in line takes over.
    mutating func release(_ agent: String, at now: Date) {
        queue.removeAll { $0 == agent }
        guard driver == agent else { return }
        tookOver = false
        if queue.isEmpty { driver = nil; invited = false; invitedAt = nil; lastAction = nil }
        else { driver = queue.removeFirst(); lastAction = now }
    }
    /// A holder that has not acted for `after` seconds yields to a waiting teammate.
    @discardableResult mutating func expireIdleHolder(at now: Date, after: TimeInterval) -> String? {
        guard let holder = driver, !queue.isEmpty, let last = lastAction, now.timeIntervalSince(last) >= after else { return nil }
        release(holder, at: now)
        return holder
    }
    /// The banner's Stop: nobody drives until asked again.
    mutating func stopAll() {
        driver = nil; queue = []; invited = false; invitedAt = nil; tookOver = false; lastAction = nil
    }

    func status(at now: Date) -> Status {
        guard let driver else { return .none }
        if mayAct(driver, at: now) { return .driving(agent: driver) }
        let remaining = Int(max(0, idleSeconds - idle(at: now)).rounded(.up))
        return tookOver ? .paused(agent: driver, remaining: remaining) : .waiting(agent: driver, remaining: remaining)
    }
}
