import Foundation

// The sidebar fuel gauge shows, per connection, the usage window closest to running out
// and when the readings were last checked.
@main struct FuelGaugeTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            print("PASS: \(name)")
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let later = now.addingTimeInterval(3600).timeIntervalSince1970
        let fiveHour = UsageWindow(label: "5 hours", remainingPercent: 96, resetsAt: later)
        let weekly = UsageWindow(label: "Weekly", remainingPercent: 40, resetsAt: nil)
        check(FuelGauge.mostConstrained([fiveHour, weekly], now: now)?.label == "Weekly", "the window closest to empty is shown")
        check(FuelGauge.mostConstrained([weekly, fiveHour], now: now)?.label == "Weekly", "order of windows does not matter")
        let expired = UsageWindow(label: "Expired", remainingPercent: 5, resetsAt: now.addingTimeInterval(-60).timeIntervalSince1970)
        let broken = UsageWindow(label: "Broken", remainingPercent: -3, resetsAt: nil)
        let impossible = UsageWindow(label: "Impossible", remainingPercent: .nan, resetsAt: nil)
        check(FuelGauge.mostConstrained([fiveHour, expired, broken, impossible], now: now)?.label == "5 hours", "expired or invalid readings never win")
        check(FuelGauge.mostConstrained([], now: now) == nil, "no readings shows nothing rather than a guess")
        check(FuelGauge.mostConstrained([expired, broken], now: now) == nil, "only invalid readings shows nothing")

        check(FuelGauge.checkedLabel(nil, now: now) == "Not checked yet", "never checked")
        check(FuelGauge.checkedLabel(now.addingTimeInterval(-20), now: now) == "Checked just now", "seconds ago")
        check(FuelGauge.checkedLabel(now.addingTimeInterval(-5 * 60 - 10), now: now) == "Checked 5 min ago", "minutes ago")
        check(FuelGauge.checkedLabel(now.addingTimeInterval(-2 * 3600 - 5), now: now) == "Checked 2 hr ago", "hours ago")
        check(FuelGauge.checkedLabel(now.addingTimeInterval(-3 * 86400), now: now) == "Checked 3 d ago", "days ago")
        check(FuelGauge.checkedLabel(now.addingTimeInterval(30), now: now) == "Checked just now", "a slightly ahead clock is not shown as negative")

        check(FuelGauge.checkedLabel(now.addingTimeInterval(10 * 60), now: now) == "Check time unclear", "a check time well in the future is not shown as fresh")

        let pins = FuelGauge.decodePins(FuelGauge.encodePins(["codex": "5 hours", "claude": "Weekly"]))
        check(pins == ["codex": "5 hours", "claude": "Weekly"], "sidebar pins survive saving and loading")
        check(FuelGauge.decodePins("garbage\n=x\ncodex=") == [:], "damaged pin text is ignored")
        check(FuelGauge.sidebarWindows([fiveHour, weekly], mode: .auto, pinned: nil, now: now).map(\.label) == ["Weekly"], "auto shows the lowest remaining")
        check(FuelGauge.sidebarWindows([fiveHour, weekly], mode: .auto, pinned: "5 hours", now: now).map(\.label) == ["5 hours"], "a pinned meter replaces the automatic choice")
        check(FuelGauge.sidebarWindows([fiveHour, weekly], mode: .auto, pinned: "Monthly", now: now).map(\.label) == ["Weekly"], "a pin that no longer exists falls back to auto")
        check(FuelGauge.sidebarWindows([fiveHour, weekly, expired], mode: .all, pinned: nil, now: now).map(\.label) == ["Weekly", "5 hours"], "every-meter mode lists valid meters, lowest first")

        check(!FuelGauge.shouldAutoRefresh(checkedAt: now.addingTimeInterval(-29 * 60), loading: false, busy: false, now: now), "no automatic check before 30 minutes")
        check(FuelGauge.shouldAutoRefresh(checkedAt: now.addingTimeInterval(-31 * 60), loading: false, busy: false, now: now), "automatic check after 30 idle minutes")
        check(!FuelGauge.shouldAutoRefresh(checkedAt: now.addingTimeInterval(-31 * 60), loading: false, busy: true, now: now), "never interrupts a reply in progress")
        check(!FuelGauge.shouldAutoRefresh(checkedAt: now.addingTimeInterval(-31 * 60), loading: true, busy: false, now: now), "never starts a second check")
        check(!FuelGauge.shouldAutoRefresh(checkedAt: nil, loading: false, busy: false, now: now), "never runs before a first check")

        let gauge = AllowancePresentation(window: FuelGauge.mostConstrained([fiveHour, weekly], now: now), checkedAt: now, now: now)
        check(gauge.label == "40% left" && gauge.level == .amber, "the chosen window drives the colour: 40% is amber")
        print("PASS: 24 fuel gauge checks")
    }
}
