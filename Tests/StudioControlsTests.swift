import Foundation

@main struct StudioControlsTests {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            print("PASS: \(name)")
        }
        let team = ["eve", "claude", "codex"]
        check(ReplyOrdering.fixed.arrange(team, round: 2) == team, "fixed order")
        check(ReplyOrdering.rotating.arrange(team, round: 1) == ["claude", "codex", "eve"], "rotating leader")
        check(ReplyOrdering.rotating.arrange(team, round: 3) == team, "rotation wraps")
        check(ReplyOrdering.random.arrange([], round: 0).isEmpty, "empty recipients")
        check(ReplyOrdering.rotating.arrange(["eve"], round: 4) == ["eve"], "single recipient")
        for _ in 0..<50 {
            let shuffled = ReplyOrdering.random.arrange(team, round: 0)
            check(shuffled.count == 3 && Set(shuffled) == Set(team), "shuffle preserves every recipient exactly once")
        }
        var project = Project(); project.replyOrder = "random"
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        check(restored.replyOrder == "random", "project order persists")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        object.removeValue(forKey: "replyOrder")
        let legacy = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
        check(legacy.replyOrder == nil, "old projects remain decodable")
        var lastOrder = ["claude", "codex", "eve"]
        for _ in 0..<300 {
            let next = ReplyOrdering.random.arrange(team, round: 0, previous: lastOrder)
            check(next != lastOrder && Set(next) == Set(team), "shuffle never repeats the previous order and keeps everyone")
            lastOrder = next
        }
        check(ReplyOrdering.random.arrange(["eve", "claude"], round: 0, previous: ["eve", "claude"]) == ["claude", "eve"], "two-agent shuffle alternates")
        check(ReplyOrdering.fixed.arrange(team, round: 0, previous: team) == team, "fixed order ignores the previous order")
        print("PASS studio controls")
    }
}
