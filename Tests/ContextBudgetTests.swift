import Foundation

@main struct ContextBudgetTests {
    static var failures = 0
    static func check(_ condition: Bool, _ label: String) {
        if condition { print("pass: \(label)") } else { failures += 1; print("FAIL: \(label)") }
    }
    static func message(_ author: String, _ text: String) -> [String: String] { ["author": author, "text": text] }
    static func total(_ history: [[String: String]]) -> Int { history.reduce(0) { $0 + ContextBudget.cost($1["author"] ?? "", $1["text"] ?? "") } }

    static func main() {
        let empty = ContextBudget.compact([], limit: 4000)
        check(empty.history.isEmpty && empty.gauge.level == .comfortable && empty.gauge.notice == nil, "empty conversation is comfortable")

        let small = [message("Jason", "Hello team"), message("Claude", "Hi Jason")]
        let kept = ContextBudget.compact(small, limit: 4000)
        check(kept.history == small, "short conversations are sent unchanged")
        check(kept.gauge.level == .comfortable && kept.gauge.notice == nil, "short conversations do not warn")

        let nearly = [message("Jason", String(repeating: "a", count: 3200))]
        let low = ContextBudget.compact(nearly, limit: 4000)
        check(low.history == nearly, "the warning light changes nothing that is sent")
        check(low.gauge.level == .low && low.gauge.notice?.contains("getting long") == true, "about 80 percent full turns the light on")

        var long: [[String: String]] = []
        for index in 0..<40 { long.append(message(index % 2 == 0 ? "Jason" : "Eve", "Message \(index) " + String(repeating: "detail ", count: 60))) }
        long.append(message("Jason", "NEWEST request, keep word for word"))
        let compacted = ContextBudget.compact(long, limit: 4000)
        check(compacted.gauge.level == .compacted, "long conversations compact automatically")
        check(total(compacted.history) <= 4000 && compacted.gauge.sent <= 4000, "compacted history fits the budget")
        check(compacted.history.last == long.last, "the newest message stays word for word")
        check(compacted.history.first?["author"] == ContextBudget.condensedAuthor, "older messages become one labelled Silkwire entry")
        check(compacted.history.first?["text"]?.contains("full transcript remains saved") == true, "the condensed entry says the original is preserved")
        check(compacted.gauge.notice?.contains("Original messages preserved") == true, "Jason sees a plain notice")
        check(compacted.gauge.used > compacted.gauge.sent, "compaction actually reduces what is sent")
        check(compacted.gauge.condensed + compacted.gauge.omitted + compacted.history.count - 1 == long.count, "every message is kept, condensed or counted")
        check(compacted.gauge.trimmed == 0, "ordinary messages are never counted as trimmed")

        // Review finding: long messages must never lose their ending silently.
        let longReply = message("Codex", String(repeating: "x", count: 20_000) + "THE ENDING")
        let trimmedRoom = ContextBudget.compact([message("Jason", "hi"), longReply], limit: 100_000)
        let sentReply = trimmedRoom.history.last?["text"] ?? ""
        check(sentReply.hasSuffix(ContextBudget.trimNote), "a trimmed message carries a visible note for the reader")
        check(sentReply.utf16.count <= ContextBudget.messageLimit, "a trimmed message, note included, stays within the message limit")
        check(trimmedRoom.gauge.trimmed == 1, "every trim is counted")
        check(trimmedRoom.gauge.level != .comfortable, "a trim always lights the gauge")
        check(trimmedRoom.gauge.notice?.contains("1 long message was trimmed") == true, "Jason is told about the trim")

        let huge = ContextBudget.compact([message("Jason", String(repeating: "z", count: 50_000))], limit: 4000)
        check(total(huge.history) <= 4000, "one enormous message is clipped to fit")
        check(huge.history.last?["text"]?.hasSuffix(ContextBudget.trimNote) == true, "the enormous message is labelled, not silently cut")
        check(huge.gauge.trimmed == 1, "a message trimmed twice is counted once")

        check(ContextBudget.limit(fixedPromptSize: 10_000) == Int(Double(32_000 - 10_000 - 800) * 0.8), "history gets what is left of the prompt, with margin")
        check(ContextBudget.limit(fixedPromptSize: 40_000) == 1_500, "a crowded prompt still leaves a small minimum")
        check(ContextBudget.limit(fixedPromptSize: 0) <= ContextBudget.historyLimit, "history never exceeds its overall allowance")

        // Review finding: messages left out before compaction are counted, never silent.
        let windowed = ContextBudget.compact(small, limit: 4000, alreadyOmitted: 5)
        check(windowed.gauge.level == .compacted && windowed.history.first?["author"] == ContextBudget.condensedAuthor, "messages outside the window are announced")
        check(windowed.history.first?["text"]?.contains("5 oldest messages left out") == true && windowed.gauge.notice?.contains("5 oldest left out") == true, "the window count reaches agents and Jason")
        check(Array(windowed.history.dropFirst()) == small && windowed.gauge.verbatim == 2, "recent messages stay intact and are reported honestly")
        check(compacted.gauge.verbatim == compacted.history.count - 1, "the report counts only word-for-word messages as supplied")
        // Review finding: tiny allowances still fit.
        for tiny in [400, 600, 900, 1500] {
            let squeezed = ContextBudget.compact(long, limit: tiny, alreadyOmitted: 3)
            check(total(squeezed.history) <= tiny, "a \(tiny)-character allowance is respected")
            check(squeezed.gauge.condensed + squeezed.gauge.omitted + squeezed.history.count - 1 == long.count + 3, "nothing vanishes uncounted at \(tiny) characters")
        }

        // Review finding (Eve): tiny budgets must never overflow, and trims stay labelled.
        for width in [5, 12, 50, 110, 200] {
            let fitted = ContextBudget.fit(String(repeating: "y", count: 5_000), to: width)
            check(fitted.trimmed && fitted.text.utf16.count <= width, "a \(width)-character fit never overflows")
            if width > ContextBudget.shortTrimNote.utf16.count + 1 { check(fitted.text.hasSilkwireTrim, "a \(width)-character fit is still labelled as trimmed") }
        }
        for tiny in [60, 120, 250] {
            let squeezed = ContextBudget.compact([message("Jason", String(repeating: "q", count: 9_000))], limit: tiny)
            check(total(squeezed.history) <= tiny, "one huge message fits a \(tiny)-character allowance")
        }
        let longReply2 = String(repeating: "r", count: 60_000)
        let unclipped = ContextBudget.compact([message("Codex", longReply2)], limit: 100_000)
        check(unclipped.gauge.trimmed == 1 && unclipped.history.first?["text"]?.hasSilkwireTrim == true, "messages longer than 48,000 characters reach compaction and are labelled")

        let emoji = ContextBudget.clip(String(repeating: "\u{1F600}", count: 20), to: 10)
        check(emoji.utf16.count <= 10 && emoji.hasSuffix("\u{2026}"), "clipping never splits a character")
        check(ContextBudget.excerpt("a\n\n  b\tc") == "a b c", "excerpts collapse whitespace")

        var hugeRoom: [[String: String]] = []
        for index in 0..<200 { hugeRoom.append(message(index % 3 == 0 ? "Jason" : "Codex", "Line \(index) \"quoted\" path/with/slashes\n" + String(repeating: "detail ", count: 80))) }
        let fixedPart = String(repeating: "c", count: 24_000)
        let fitted = ContextBudget.fitPrompt(limit: ContextBudget.limit(fixedPromptSize: 26_000)) { limit in fixedPart + ((try? String(data: JSONSerialization.data(withJSONObject: ContextBudget.compact(hugeRoom, limit: limit).history), encoding: .utf8)) ?? "") }
        check(fitted.text.utf16.count <= ContextBudget.promptCap, "a long room plus large instructions still fits the 32,000-character send limit")
        check(fitted.text.contains("Line 199"), "the newest message survives fitting")
        let roomy = ContextBudget.fitPrompt(limit: 4000) { _ in "short" }
        check(roomy.limit == 4000 && roomy.text == "short", "prompts already under the limit are untouched")
        let follow = ContextBudget.fitFollowUp(prefix: String(repeating: "p", count: 20_000), result: String(repeating: "r", count: 30_000), suffix: "END")
        check(follow.utf16.count <= ContextBudget.promptCap && follow.hasSuffix("END") && follow.contains("shortened this result"), "oversized follow-up results are clipped with a label, keeping the closing instructions")
        check(ContextBudget.fitFollowUp(prefix: "a", result: "b", suffix: "c") == "abc", "small follow-ups are unchanged")

        let overfull = ContextBudget.fitPrompt(limit: 8_000) { limit in String(repeating: "i", count: 33_000) + String(repeating: "h", count: limit) }
        check(!overfull.fits && overfull.limit == 0, "instructions alone over the limit are reported as not fitting, never looped forever")
        let fitsFlag = ContextBudget.fitPrompt(limit: 8_000) { limit in String(repeating: "h", count: limit) + String(repeating: "i", count: 30_000) }
        check(fitsFlag.fits && fitsFlag.text.utf16.count <= ContextBudget.promptCap, "a prompt that can fit is reported as fitting")
        let emojiFollow = ContextBudget.fitFollowUp(prefix: String(repeating: "\u{1F600}", count: 6_000), result: String(repeating: "\u{1F600}", count: 12_000), suffix: "END")
        check(emojiFollow.utf16.count <= ContextBudget.promptCap && emojiFollow.hasSuffix("END"), "emoji-heavy follow-ups fit the UTF-16 limit and keep the closing instructions")
        let hugePrefix = ContextBudget.fitFollowUp(prefix: String(repeating: "\u{1F600}", count: 20_000), result: "RESULT", suffix: "END")
        check(hugePrefix.utf16.count <= ContextBudget.promptCap && hugePrefix.hasSuffix("END") && hugePrefix.contains("left this result out"), "when instructions alone fill the limit, the result is left out with a label and the ending survives")
        check(ContextBudget.clipUTF16(String(repeating: "\u{1F600}", count: 5), to: 3).utf16.count == 2, "UTF-16 clipping never splits an emoji")
        if failures > 0 { print("FAIL: \(failures) ContextBudget checks"); exit(1) }
        print("PASS: ContextBudgetTests")
    }
}
