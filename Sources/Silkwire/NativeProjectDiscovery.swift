import Foundation

// Discovery uses the same descriptor-relative reader and exclusions as individual
// reads. Partial inventories are explicit; omitted/excluded names are never echoed.
private struct NativeDiscoveryBudget {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    var nodes = 0, files = 0, bytes = 0, excluded = 0, unavailable = 0
    var reasons = Set<String>()
    var stopped = false
    mutating func check() throws -> Bool {
        try Task.checkCancellation()
        if ProcessInfo.processInfo.systemUptime >= deadline { reasons.insert("time"); stopped = true }
        return !stopped
    }
    mutating func append(_ item: [String: Any], to items: inout [[String: Any]]) -> Bool {
        // Reserve room for the result envelope and caller's folder identity.
        guard items.count < 128, let encoded = try? JSONSerialization.data(withJSONObject: items + [item]), encoded.count <= 8000 else {
            reasons.insert("output"); stopped = true; return false
        }
        items.append(item); return true
    }
    mutating func inventory(_ result: [String: Any]) {
        excluded += result["excludedCount"] as? Int ?? 0
        if result["shortened"] as? Bool == true || result["countsPartial"] as? Bool == true { reasons.insert("directoryInventory") }
    }
    func envelope(path: String, items: [[String: Any]], key: String) -> [String: Any] {
        var kept = items, limits = reasons
        while true {
            let result: [String: Any] = ["path": path, key: kept, "partial": !limits.isEmpty, "shortened": !limits.isEmpty,
                "limitsReached": limits.sorted(), "nodesExamined": nodes, "filesExamined": files,
                "bytesRead": bytes, "excludedCount": excluded, "unavailableCount": unavailable,
                "countsPartial": !limits.isEmpty, "untrusted": true]
            // JSON escaping can expand a valid path. Bound the encoded envelope,
            // too, leaving room for query/depth fields and the broker's identity.
            if kept.isEmpty || ((try? JSONSerialization.data(withJSONObject: result).count) ?? Int.max) <= 8800 { return result }
            kept.removeLast(); limits.insert("output")
        }
    }
}

extension NativeScopedRoot {
    /// Entries are relative to the granted folder, not to the requested subtree.
    /// Depth 1 returns immediate children; depths 2...4 descend further.
    func tree(path: String, depth: Int) throws -> [String: Any] {
        _ = try Self.components(path)
        guard (1...4).contains(depth) else { throw nativeFailure("Tree depth must be between 1 and 4.") }
        var budget = NativeDiscoveryBudget(), entries: [[String: Any]] = []
        func walk(_ directory: String, level: Int, initial: Bool = false) throws {
            guard try budget.check() else { return }
            let result: [String: Any]
            do { result = try list(directory) }
            catch { if initial { throw error }; budget.unavailable += 1; budget.reasons.insert("unavailable"); return }
            budget.inventory(result)
            for item in result["entries"] as? [[String: Any]] ?? [] {
                guard try budget.check() else { return }
                guard budget.nodes < 256, budget.files < 128 else { budget.reasons.insert("nodesOrFiles"); budget.stopped = true; return }
                guard let name = item["name"] as? String, let kind = item["kind"] as? String else { continue }
                let relative = directory.isEmpty ? name : directory + "/" + name
                budget.nodes += 1; if kind == "file" { budget.files += 1 }
                guard budget.append(["path": relative, "kind": kind, "depth": level], to: &entries) else { return }
                if kind == "directory" {
                    if level < depth { try walk(relative, level: level + 1) }
                    else { budget.reasons.insert("depth") }
                }
            }
        }
        try walk(path, level: 1, initial: true)
        try verifyRoot(); try Task.checkCancellation()
        var result = budget.envelope(path: path, items: entries, key: "entries")
        result["depth"] = depth
        return result
    }

    /// Case-sensitive literal filename and UTF-8 text search. No regular
    /// expressions, shell, repository internals, links, or external indexing.
    func search(path: String, query: String) throws -> [String: Any] {
        _ = try Self.components(path)
        guard !query.isEmpty, query.utf8.count <= 128, !query.contains("\0"), !query.contains("\n"), !query.contains("\r") else {
            throw nativeFailure("Use one nonempty literal search line of at most 128 UTF-8 bytes.")
        }
        var budget = NativeDiscoveryBudget(), matches: [[String: Any]] = []
        func emit(_ item: [String: Any]) -> Bool {
            guard matches.count < 64 else { budget.reasons.insert("hits"); budget.stopped = true; return false }
            return budget.append(item, to: &matches)
        }
        func walk(_ directory: String, level: Int, initial: Bool = false) throws {
            guard try budget.check() else { return }
            let result: [String: Any]
            do { result = try list(directory) }
            catch { if initial { throw error }; budget.unavailable += 1; budget.reasons.insert("unavailable"); return }
            budget.inventory(result)
            for item in result["entries"] as? [[String: Any]] ?? [] {
                guard try budget.check() else { return }
                guard budget.nodes < 256, budget.files < 128 else { budget.reasons.insert("nodesOrFiles"); budget.stopped = true; return }
                guard let name = item["name"] as? String, let kind = item["kind"] as? String else { continue }
                let relative = directory.isEmpty ? name : directory + "/" + name
                budget.nodes += 1
                if kind == "directory" {
                    if name.contains(query), !emit(["path": relative, "kind": kind, "match": "name"]) { return }
                    if level < 4 { try walk(relative, level: level + 1) }
                    else { budget.reasons.insert("depth") }
                    continue
                }
                budget.files += 1
                // Filename discovery does not falsely imply that contents were
                // readable, UTF-8, within budget, or inspected for this result.
                if name.contains(query), !emit(["path": relative, "kind": "file", "match": "name"]) { return }
                let data: Data
                do {
                    let info = try metadata(relative)
                    guard let size = info["bytes"] as? Int64, size <= 262144 else { budget.reasons.insert("fileSize"); continue }
                    guard Int64(budget.bytes) + size <= 1048576 else { budget.reasons.insert("bytes"); budget.stopped = true; return }
                    data = try readData(relative, limit: min(262144, 1048576 - budget.bytes))
                } catch { budget.unavailable += 1; budget.reasons.insert("unavailable"); continue }
                budget.bytes += data.count
                guard try budget.check() else { return }
                let hash = Self.sha256(data)
                let text = String(decoding: data, as: UTF8.self)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    guard try budget.check() else { return }
                    guard let range = line.range(of: query, options: .literal) else { continue }
                    let start = line.index(range.lowerBound, offsetBy: -80, limitedBy: line.startIndex) ?? line.startIndex
                    let end = line.index(range.upperBound, offsetBy: 200, limitedBy: line.endIndex) ?? line.endIndex
                    let excerpt = String(line[start..<end])
                    guard emit(["path": relative, "kind": "file", "match": "text", "lineNumber": index + 1,
                                "text": excerpt, "textShortened": start != line.startIndex || end != line.endIndex, "sha256": hash]) else { return }
                }
            }
        }
        try walk(path, level: 1, initial: true)
        try verifyRoot(); try Task.checkCancellation()
        var result = budget.envelope(path: path, items: matches, key: "matches")
        result["query"] = query; result["caseSensitive"] = true; result["maxDepth"] = 4
        return result
    }
}
