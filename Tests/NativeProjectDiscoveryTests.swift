import Foundation

@main struct NativeProjectDiscoveryTests {
    static func main() async throws {
        var passed = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw nativeFailure("FAIL " + label) }; passed += 1; print("PASS " + label)
        }
        func rejects(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { passed += 1; print("PASS " + label); return }; throw nativeFailure("FAIL accepted " + label)
        }
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-discovery-" + UUID().uuidString)
        let visible = base.appendingPathComponent("visible")
        let fm = FileManager.default
        try fm.createDirectory(at: visible.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
        let bytes = Data("alpha\nneedle literal .*\nlast\n".utf8)
        try bytes.write(to: visible.appendingPathComponent("needle.swift"))
        try Data("nested needle".utf8).write(to: visible.appendingPathComponent("nested/child.txt"))
        for name in [".hidden", "credentials.txt", "image.png", "data.bin"] { try Data("needle".utf8).write(to: visible.appendingPathComponent(name)) }
        try fm.createDirectory(at: visible.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("needle".utf8).write(to: visible.appendingPathComponent("node_modules/leak.txt"))
        try fm.createSymbolicLink(at: visible.appendingPathComponent("escape"), withDestinationURL: base)
        let root = try NativeScopedRoot(base)
        let first = try root.tree(path: "visible", depth: 3)
        let second = try root.tree(path: "visible", depth: 3)
        let firstRows = first["entries"] as? [[String: Any]] ?? []
        try check(try nativeJSON(firstRows) == nativeJSON(second["entries"] ?? []), "repeated scoped tree is stable")
        try check(first["partial"] as? Bool == false, "complete bounded tree reports completeness")
        try check(first["excludedCount"] as? Int == 6, "hidden, protected, binary, image, dependency and link exclusions counted")
        let treeJSON = try nativeJSON(first)
        try check(!["credentials.txt", ".hidden", "image.png", "data.bin", "node_modules", "escape"].contains(where: treeJSON.contains), "excluded names do not leak into tree")
        let shallow = try root.tree(path: "visible", depth: 1)
        try check(shallow["partial"] as? Bool == true && (shallow["limitsReached"] as? [String])?.contains("depth") == true, "depth cutoff explicitly partial")
        let search = try root.search(path: "visible", query: "needle")
        let hits = search["matches"] as? [[String: Any]] ?? []
        try check(hits.contains { $0["match"] as? String == "name" && $0["path"] as? String == "visible/needle.swift" }, "literal filename hit")
        try check(hits.contains { $0["match"] as? String == "text" && $0["lineNumber"] as? Int == 2 && $0["sha256"] as? String == NativeScopedRoot.sha256(bytes) }, "matched text carries exact file hash and relative line number")
        let literal = try root.search(path: "visible", query: ".*")
        try check((literal["matches"] as? [[String: Any]])?.count == 1, "query is literal, not regex")
        try check(!(try nativeJSON(search)).contains("credentials.txt"), "excluded paths absent from search")
        let changedBytes = Data("needle changed\n".utf8)
        try changedBytes.write(to: visible.appendingPathComponent("needle.swift"))
        let changed = try root.search(path: "visible", query: "needle")
        try check((changed["matches"] as? [[String: Any]] ?? []).contains {
            $0["path"] as? String == "visible/needle.swift" && $0["lineNumber"] as? Int == 1 && $0["sha256"] as? String == NativeScopedRoot.sha256(changedBytes)
        }, "changed content returns its new version hash, not an earlier snapshot")
        try rejects("traversal denied") { _ = try root.tree(path: "../outside", depth: 2) }
        try rejects("excluded subtree denied") { _ = try root.search(path: "visible/node_modules", query: "needle") }
        try rejects("link subtree denied") { _ = try root.search(path: "visible/escape", query: "needle") }
        try rejects("excessive depth denied") { _ = try root.tree(path: "visible", depth: 5) }
        try rejects("empty query denied") { _ = try root.search(path: "visible", query: "") }
        let many = base.appendingPathComponent("many")
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<150 { try Data("needle\n".utf8).write(to: many.appendingPathComponent("file-\(i).txt")) }
        let limited = try root.search(path: "many", query: "needle")
        try check(limited["partial"] as? Bool == true, "bounded search reports partial results")
        try check((limited["matches"] as? [[String: Any]] ?? []).count <= 64 && (try nativeJSON(limited)).utf8.count < 10000, "hit and encoded output limits")
        let limitedTree = try root.tree(path: "many", depth: 2)
        try check(limitedTree["partial"] as? Bool == true && (try nativeJSON(limitedTree)).utf8.count < 10000, "partial directory inventories keep tree output bounded")
        let oversized = base.appendingPathComponent("oversized")
        try fm.createDirectory(at: oversized, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 262145).write(to: oversized.appendingPathComponent("huge.txt"))
        let skipped = try root.search(path: "oversized", query: "A")
        try check((skipped["limitsReached"] as? [String])?.contains("fileSize") == true && skipped["bytesRead"] as? Int == 0, "oversized file skipped before content read")
        let oversizedName = try root.search(path: "oversized", query: "huge")
        try check((oversizedName["matches"] as? [[String: Any]] ?? []).contains { $0["match"] as? String == "name" }, "filename discovery does not require readable bounded content")
        let byteLimited = base.appendingPathComponent("byte-limited")
        try fm.createDirectory(at: byteLimited, withIntermediateDirectories: true)
        for i in 0..<5 { try Data(repeating: 65, count: 262144).write(to: byteLimited.appendingPathComponent("file-\(i).txt")) }
        let byteSearch = try root.search(path: "byte-limited", query: "not-present")
        try check((byteSearch["limitsReached"] as? [String])?.contains("bytes") == true && byteSearch["bytesRead"] as? Int == 1048576, "aggregate byte budget stops before another file read")
        let cancelled = Task { try root.search(path: "many", query: "needle") }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw nativeFailure("FAIL cancellation ignored") }
        catch is CancellationError { passed += 1; print("PASS cancellation propagated") }
        print("\(passed) scoped discovery checks passed")
    }
}
