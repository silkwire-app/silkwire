import Foundation

@main struct ReadMarksTests {
    static func main() throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL: " + label) }
            checks += 1; print("PASS " + label)
        }
        var old = Message(author: "Eve", text: "Earlier reply", state: "completed")
        var fresh = Message(author: "Claude", text: "", state: "queued")
        fresh.unread = true
        var other = Message(author: "Codex", text: "Done", state: "completed")
        other.unread = true

        try check(!ReadMarks.isUnread(old) && old.unread == nil, "older messages carry no marker and never count as unread")
        try check(ReadMarks.unreadCount([old, fresh, other]) == 2, "room count includes only marked unread replies")

        ReadMarks.toggle(&fresh)
        try check(fresh.unread == false, "clicking blue U makes it green R")
        ReadMarks.toggle(&fresh)
        try check(fresh.unread == true, "clicking green R marks it unread again, like Mark as Unread")
        ReadMarks.toggle(&old)
        try check(old.unread == nil, "clicking does nothing on a message without a marker")

        ReadMarks.toggle(&fresh)
        ReadMarks.textChanged(&fresh, newText: "")
        try check(fresh.unread == false, "the same text keeps a reply read")
        ReadMarks.textChanged(&fresh, newText: "More arrived")
        try check(fresh.unread == true, "new text after marking read restores unread (read means this version)")
        var unreadAlready = other
        ReadMarks.textChanged(&unreadAlready, newText: "Changed")
        try check(unreadAlready.unread == true, "new text keeps an unread reply unread")
        ReadMarks.textChanged(&old, newText: "Changed")
        try check(old.unread == nil, "new text never adds a marker to an older message")

        var room = [old, fresh, other]
        ReadMarks.markAllRead(&room)
        try check(ReadMarks.unreadCount(room) == 0 && room[0].unread == nil && room[1].unread == false && room[2].unread == false, "Mark all read clears the count without inventing markers")

        let saved = try JSONEncoder().encode([fresh, old])
        let restored = try JSONDecoder().decode([Message].self, from: saved)
        try check(restored[0].unread == true && restored[1].unread == nil, "markers survive saving and restarting")
        let legacy = Data("{\"id\":\"6F9619FF-8B86-D011-B42D-00C04FC964FF\",\"author\":\"Eve\",\"text\":\"Hi\",\"state\":\"completed\"}".utf8)
        try check(try JSONDecoder().decode(Message.self, from: legacy).unread == nil, "messages saved before this update still load")

        let prefs = try JSONDecoder().decode(WorkspacePreferences.self, from: Data("{}".utf8))
        try check(prefs.openFloor == false, "real conversation is off unless Jason turns it on")
        var on = WorkspacePreferences(); on.openFloor = true
        let reloaded = try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(on))
        try check(reloaded.openFloor == true && reloaded.startRepliesAtPrompt == true, "the real conversation setting is remembered")
        print("PASS " + String(checks) + " read marker and setting checks")
    }
}
