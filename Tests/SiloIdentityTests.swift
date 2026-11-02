import Foundation

// Which room am I in? Pills, status wording and strip color for one-on-one vs team rooms.
@main struct SiloIdentityTests {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        let team = ["eve", "claude", "codex"]
        check(SiloIdentity.pills(participants: team, focusedAgent: nil) == team, "team room shows every teammate's pill")
        check(SiloIdentity.pills(participants: team, focusedAgent: "eve") == ["eve"], "Eve's one-on-one shows only Eve's pill")
        check(SiloIdentity.pills(participants: team, focusedAgent: "codex") == ["codex"], "Codex's one-on-one shows only Codex's pill")
        check(SiloIdentity.pills(participants: ["claude", "codex"], focusedAgent: "eve").isEmpty, "a one-on-one whose teammate left the Project never falls back to the team's pills")

        check(SiloIdentity.statusLabel(state: "disconnected", message: "Not in this one-on-one") == "Not in this chat", "teammates outside a one-on-one read 'Not in this chat'")
        check(SiloIdentity.statusLabel(state: "disconnected", message: "Not connected") == "Disconnected", "a real disconnection still says Disconnected")
        check(SiloIdentity.statusLabel(state: "disconnected", message: "Not in this Project") == "Disconnected", "teammates outside the Project keep the existing wording")

        check(SiloIdentity.colorName(focusedAgent: "eve", names: names) == "Eve", "Eve's room is marked in Eve's color")
        check(SiloIdentity.colorName(focusedAgent: "claude", names: names) == "Claude", "Claude's room is marked in Claude's color")
        check(SiloIdentity.colorName(focusedAgent: nil, names: names) == nil, "team rooms use the Silkwire accent")
        check(SiloIdentity.colorName(focusedAgent: "stranger", names: names) == nil, "unknown teammate falls back to the accent safely")

        check(SiloLayout.minimumColumnWidth == 460, "a conversation column is never narrower than 460 points")
        check(SiloLayout.fitsSideBySide(availableWidth: 920) && !SiloLayout.fitsSideBySide(availableWidth: 919), "two columns appear side by side only when both fit at full minimum width")
        check(!SiloLayout.fitsSideBySide(availableWidth: .infinity) && !SiloLayout.fitsSideBySide(availableWidth: 2000, columns: 0), "nonsense widths never claim columns fit")
        let app = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/Silkwire/SilkwireApp.swift"), encoding: .utf8)
        check(!app.contains("siloStrip"), "room-color strips are gone (name and single pill identify the room)")
        check(app.contains("minWidth: SiloLayout.minimumColumnWidth"), "conversation column uses the shared minimum width")
        print("\(checks - failures) of \(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
