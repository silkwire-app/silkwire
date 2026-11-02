import Foundation

/// Reads the plan-limit notices Claude Code includes in its own reply stream
/// ("rate_limit_event"). No extra sign-in, token or network request: Silkwire
/// only listens to what Claude Code already reports while replying. If a notice
/// carries no actual percentage, nothing is shown rather than a guess.
enum ClaudeRateLimit {
    static func window(_ event: [String: Any]) -> UsageWindow? {
        guard event["type"] as? String == "rate_limit_event",
              let info = (event["rate_limit_info"] ?? event["rateLimitInfo"]) as? [String: Any] else { return nil }
        let kind = (info["rateLimitType"] ?? info["rate_limit_type"]) as? String ?? ""
        let label: String
        switch kind {
        case "five_hour": label = "5 hours"
        case "seven_day": label = "Weekly"
        case "": label = "Current window"
        default:
            label = kind.hasPrefix("seven_day_") ? "Weekly · " + kind.dropFirst(10).replacingOccurrences(of: "_", with: " ").capitalized : kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
        var resets = number(info["resetsAt"] ?? info["resets_at"])
        if let value = resets, value > 1e12 { resets = value / 1000 } // milliseconds → seconds
        let status = info["status"] as? String ?? ""
        if let used = number(info["utilization"]) {
            let usedPercent = used <= 1 ? used * 100 : used
            return UsageWindow(label: label, remainingPercent: max(0, min(100, 100 - usedPercent)), resetsAt: resets)
        }
        // A refusal is unambiguous: nothing left until the reset.
        if status == "rejected" { return UsageWindow(label: label, remainingPercent: 0, resetsAt: resets) }
        return nil
    }
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value.isFinite ? value : nil }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
