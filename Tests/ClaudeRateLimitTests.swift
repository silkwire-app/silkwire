import Foundation

// The Anthropic usage row reads only the limit notices Claude Code already
// includes in its reply stream. Unknown or incomplete notices show nothing.
@main struct ClaudeRateLimitTests {
    static func main() {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ label: String) { checks += 1; if ok { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) } }
        let session = ClaudeRateLimit.window(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.21, "resetsAt": 1_800_000_000]])
        check(session?.label == "5 hours" && abs((session?.remainingPercent ?? 0) - 79) < 0.001 && session?.resetsAt == 1_800_000_000, "a 5-hour notice shows what's left and when it resets")
        let weekly = ClaudeRateLimit.window(["type": "rate_limit_event", "rate_limit_info": ["rateLimitType": "seven_day", "utilization": 79, "resetsAt": 1_800_000_000_000.0]])
        check(weekly?.label == "Weekly" && abs((weekly?.remainingPercent ?? 0) - 21) < 0.001 && weekly?.resetsAt == 1_800_000_000, "weekly notices accept percentages and millisecond reset times")
        check(ClaudeRateLimit.window(["type": "rate_limit_event", "rate_limit_info": ["rateLimitType": "seven_day_opus", "utilization": 0.5]])?.label == "Weekly · Opus", "model-specific weekly limits are labelled plainly")
        check(ClaudeRateLimit.window(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "rateLimitType": "five_hour"]]) == nil, "a notice without a number shows nothing rather than a guess")
        check(ClaudeRateLimit.window(["type": "rate_limit_event", "rate_limit_info": ["status": "rejected", "rateLimitType": "five_hour"]])?.remainingPercent == 0, "a refused request means none left until the reset")
        check(ClaudeRateLimit.window(["type": "assistant"]) == nil && ClaudeRateLimit.window(["type": "rate_limit_event"]) == nil, "other events and empty notices are ignored")
        check((ClaudeRateLimit.window(["type": "rate_limit_event", "rate_limit_info": ["utilization": 140]])?.remainingPercent ?? -1) == 0, "readings never go below empty")
        print("ClaudeRateLimitTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
