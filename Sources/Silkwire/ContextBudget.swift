import Foundation

// Keeps the quoted room history Silkwire sends each teammate within a fixed
// budget. Only the copy sent to agents shrinks; the saved transcript on Jason's
// Mac is never changed. Newest messages stay word for word; older ones become
// short excerpts in one clearly labelled Silkwire entry; the oldest may be
// counted rather than quoted when even excerpts no longer fit. Nothing is cut
// silently: every trimmed message carries a visible note and is counted, and
// messages left out before compaction (alreadyOmitted) are counted too.
enum ContextBudget {
    static let historyLimit = 48_000
    static let messageLimit = 12_000
    static let excerptLimit = 360
    static let warningFraction = 0.75
    static let recentShare = 0.75
    static let condensedAuthor = "Silkwire"
    static let trimNote = "\n[Silkwire trimmed the rest of this long message for length; the full message is saved on Jason's Mac.]"
    static let condensedHeader = "EARLIER CONVERSATION, CONDENSED BY SILKWIRE. Short excerpts of older messages; the full transcript remains saved on Jason's Mac."
    static let shortTrimNote = " [trimmed]"

    // History gets what remains of the prompt cap after fixed parts, with
    // margin for JSON escaping, so the room never has to drop whole messages.
    static func limit(fixedPromptSize: Int, promptCap: Int = 32_000) -> Int {
        min(historyLimit, max(1_500, Int(Double(promptCap - fixedPromptSize - 800) * 0.8)))
    }

    // Every room transport (Claude, Codex, Eve) refuses text over this size.
    static let promptCap = 32_000
    static let resultNote = "\n[Silkwire shortened this result to fit the reply limit. Ask for a narrower range or fewer lines.]"

    // Measures the real assembled prompt (JSON escaping and all) and shrinks the
    // history allowance until it fits, so a long room never blocks a send.
    // `fits` is false only when the fixed parts (instructions, brief, request) are
    // too long on their own; history is then empty and the transport refuses the
    // send with a plain explanation rather than anything being cut silently.
    static func fitPrompt(limit start: Int, cap: Int = promptCap, build: (Int) -> String) -> (text: String, limit: Int, fits: Bool) {
        var limit = max(0, start)
        var text = build(limit)
        var guardCount = 0
        while text.utf16.count > cap && limit > 0 && guardCount < 64 {
            let over = text.utf16.count - cap
            limit = max(0, min(limit - 1, limit - over - 256))
            text = build(limit)
            guardCount += 1
        }
        if text.utf16.count > cap && limit > 0 { limit = 0; text = build(0) }
        return (text, limit, text.utf16.count <= cap)
    }

    static let omittedNote = "\n[Silkwire left this result out because the instructions alone filled the reply limit. Ask for a narrower range or fewer lines.]\n"

    // Clips by UTF-16 length (what transports measure), never splitting a character.
    static func clipUTF16(_ text: String, to limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        guard limit > 0 else { return "" }
        var clipped = String(text.prefix(limit))
        while clipped.utf16.count > limit { clipped.removeLast() }
        return clipped
    }

    // Follow-up results (reader, web, workspace) are clipped with a visible label
    // instead of making the whole reply fail. The closing instructions always survive.
    static func fitFollowUp(prefix: String, result: String, suffix: String, cap: Int = promptCap) -> String {
        let whole = prefix + result + suffix
        guard whole.utf16.count > cap else { return whole }
        let room = cap - prefix.utf16.count - suffix.utf16.count - resultNote.utf16.count
        if room > 0 { return prefix + clipUTF16(result, to: room) + resultNote + suffix }
        let space = max(0, cap - suffix.utf16.count - omittedNote.utf16.count)
        return clipUTF16(prefix, to: space) + omittedNote + suffix
    }

    enum Level: String, Equatable { case comfortable, low, compacted }

    struct Gauge: Equatable {
        let used: Int
        let limit: Int
        let sent: Int
        let level: Level
        let condensed: Int
        let omitted: Int
        let trimmed: Int
        // Messages delivered word for word (not condensed, omitted or trimmed).
        let verbatim: Int
        var fraction: Double { limit > 0 ? min(1, Double(used) / Double(limit)) : 1 }
        var notice: String? {
            var parts: [String] = []
            switch level {
            case .comfortable: break
            case .low:
                if Double(used) >= Double(limit) * ContextBudget.warningFraction { parts.append("This conversation is getting long. Silkwire will condense older messages automatically.") }
            case .compacted:
                var pieces: [String] = []
                if condensed > 0 { pieces.append("\(condensed) older message\(condensed == 1 ? "" : "s") condensed") }
                if omitted > 0 { pieces.append("\(omitted) oldest left out") }
                if pieces.isEmpty { pieces.append("older messages condensed") }
                parts.append("Context refreshed: " + pieces.joined(separator: "; ") + ".")
            }
            if trimmed > 0 { parts.append("\(trimmed) long message\(trimmed == 1 ? " was" : "s were") trimmed for length.") }
            guard !parts.isEmpty else { return nil }
            return (parts + ["Original messages preserved."]).joined(separator: " ")
        }
    }

    static func cost(_ author: String, _ text: String) -> Int { author.utf16.count + text.utf16.count + 24 }

    // Clips by UTF-16 width without splitting a character; the ellipsis counts.
    static func clip(_ text: String, to limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        guard limit > 1 else { return "" }
        var out = "", used = 0
        for character in text {
            let width = String(character).utf16.count
            if used + width > limit - 1 { break }
            out.append(character); used += width
        }
        return out + "\u{2026}"
    }

    // Fits a message within a width, always labelling any trim for the reader.
    static func fit(_ text: String, to limit: Int) -> (text: String, trimmed: Bool) {
        guard text.utf16.count > limit else { return (text, false) }
        if limit > trimNote.utf16.count + 1 { return (clip(text, to: limit - trimNote.utf16.count) + trimNote, true) }
        // Too little room for the full note: a short label still marks the trim, never overflowing.
        if limit > shortTrimNote.utf16.count + 1 { return (clip(text, to: limit - shortTrimNote.utf16.count) + shortTrimNote, true) }
        return (clip(text, to: max(0, limit)), true)
    }

    static func excerpt(_ text: String) -> String {
        clip(text.split(whereSeparator: \.isWhitespace).joined(separator: " "), to: excerptLimit)
    }

    static func compact(_ history: [[String: String]], limit: Int = historyLimit, alreadyOmitted: Int = 0) -> (history: [[String: String]], gauge: Gauge) {
        var trimmed = 0
        let messages: [[String: String]] = history.map {
            let fitted = fit($0["text"] ?? "", to: messageLimit)
            if fitted.trimmed { trimmed += 1 }
            return ["author": $0["author"] ?? "", "text": fitted.text]
        }
        func size(_ m: [String: String]) -> Int { cost(m["author"] ?? "", m["text"] ?? "") }
        func total(_ list: [[String: String]]) -> Int { list.reduce(0) { $0 + size($1) } }
        func intact(_ list: [[String: String]]) -> Int { list.filter { !($0["text"] ?? "").hasSilkwireTrim }.count }
        let used = total(messages)
        let prior = max(0, alreadyOmitted)
        if prior == 0 && used <= limit {
            let level: Level = trimmed > 0 || Double(used) >= Double(limit) * warningFraction ? .low : .comfortable
            return (messages, Gauge(used: used, limit: limit, sent: used, level: level, condensed: 0, omitted: 0, trimmed: trimmed, verbatim: intact(messages)))
        }
        let reserve = cost(condensedAuthor, condensedHeader) + 80
        let recentBudget = prior == 0 && messages.count == 1 ? limit : used + reserve <= limit ? used : max(0, min(Int(Double(limit) * recentShare), limit - reserve))
        var recent: [[String: String]] = [], recentCost = 0
        for message in messages.reversed() {
            let author = message["author"] ?? "", text = message["text"] ?? ""
            let itemCost = cost(author, text)
            if recentCost + itemCost <= recentBudget { recent.insert(message, at: 0); recentCost += itemCost; continue }
            if recent.isEmpty {
                let wasTrimmed = text.hasSilkwireTrim
                let fitted = fit(text, to: max(0, recentBudget - cost(author, "")))
                if fitted.trimmed && !wasTrimmed { trimmed += 1 }
                recent.insert(["author": author, "text": fitted.text], at: 0); recentCost += cost(author, fitted.text)
            }
            break
        }
        let older = Array(messages.dropLast(recent.count))
        var remaining = limit - recentCost - reserve
        var lines: [String] = []
        for message in older.reversed() {
            let line = "\n- \(message["author"] ?? ""): \(excerpt(message["text"] ?? ""))"
            guard line.utf16.count <= remaining else { break }
            lines.insert(line, at: 0); remaining -= line.utf16.count
        }
        var omitted = older.count - lines.count + prior
        func entry() -> [String: String] {
            var text = condensedHeader
            if omitted > 0 { text += " \(omitted) oldest message\(omitted == 1 ? "" : "s") left out entirely." }
            return ["author": condensedAuthor, "text": text + lines.joined()]
        }
        var result = [entry()] + recent
        // Small allowances: shed detail oldest-first, counting it, until the result fits.
        while total(result) > limit {
            if !lines.isEmpty { lines.removeFirst(); omitted += 1 }
            else if recent.count > 1 { recent.removeFirst(); omitted += 1 }
            else { break }
            result = [entry()] + recent
        }
        if total(result) > limit, let last = recent.last {
            let author = last["author"] ?? "", text = last["text"] ?? ""
            let wasTrimmed = text.hasSilkwireTrim
            let room = limit - size(entry()) - cost(author, "")
            if room > trimNote.utf16.count + 1 {
                let fitted = fit(text, to: room)
                if fitted.trimmed && !wasTrimmed { trimmed += 1 }
                recent[recent.count - 1] = ["author": author, "text": fitted.text]
                result = [entry()] + recent
            } else {
                // No room for the condensed entry at all: keep the newest message, labelled.
                let fitted = fit(text, to: max(0, limit - cost(author, "")))
                if fitted.trimmed && !wasTrimmed { trimmed += 1 }
                recent = [["author": author, "text": fitted.text]]
                result = recent
            }
        }
        return (result, Gauge(used: used, limit: limit, sent: total(result), level: .compacted, condensed: lines.count, omitted: omitted, trimmed: trimmed, verbatim: intact(recent)))
    }
}

extension String {
    // True when Silkwire labelled this text as trimmed (full or short note).
    var hasSilkwireTrim: Bool { hasSuffix(ContextBudget.trimNote) || hasSuffix(ContextBudget.shortTrimNote) }
}
