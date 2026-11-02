import Foundation
import Darwin
import SwiftUI

struct WorkspaceTask: Codable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var title: String
    var folderID: String
    var paths: [String]
    var owner: String
    var status = "working"
    var nextOwner: String?
    var workspaceID: String?
    var updatedAt = Date()
    var reservesPaths: Bool { !["review", "failed", "stopped", "done", "released"].contains(status) }
}

// Host-owned conversation ledger, separate from every agent's writable worktree.
// Claims serialize on the main actor. They coordinate assignments, not file grants.
@MainActor final class WorkspaceTaskBoard {
    private let root: URL
    private var file: URL { root.appendingPathComponent("task-board.json") }
    init(root: URL) { self.root = root }
    func tasks() throws -> [WorkspaceTask] {
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            if errno == ENOENT { return [] }; throw nativeFailure("Task ownership could not be read.")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size <= 262144 else { throw nativeFailure("Task ownership record is not a safe regular file.") }
        return try JSONDecoder().decode([WorkspaceTask].self, from: Data(contentsOf: file))
    }
    private func save(_ tasks: [WorkspaceTask]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(tasks)
        guard bytes.count <= 262144 else { throw nativeFailure("Task ledger capacity reached; existing assignments were preserved.") }
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func overlaps(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.contains { a in rhs.contains { b in a.isEmpty || b.isEmpty || a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") } }
    }
    func begin(owner: String, folderID: String, title: String, paths: [String], taskID: String?) throws -> WorkspaceTask {
        guard agents.contains(owner), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 24000, paths.count <= 40, paths.joined().utf8.count <= 4096 else { throw nativeFailure("Task needs an owner, title and at most 40 relative paths.") }
        let scope = paths.isEmpty ? [""] : try paths.map { try NativeScopedRoot.components($0, allowEmpty: true).joined(separator: "/") }
        var values = try tasks()
        var task = WorkspaceTask(title: limitedUTF16(title, to: 1000), folderID: folderID, paths: scope, owner: owner)
        if let taskID {
            guard let old = values.first(where: { $0.id == taskID.lowercased() }), old.folderID == folderID,
                  old.status == "handoff", old.nextOwner == owner else { throw nativeFailure("This handoff is not assigned to you. Read the task board first.") }
            task = old; task.owner = owner; task.status = "working"; task.nextOwner = nil; task.workspaceID = nil; task.updatedAt = Date()
        }
        guard !values.contains(where: { $0.id != task.id && $0.folderID == folderID && $0.reservesPaths && Self.overlaps($0.paths, task.paths) }) else {
            throw nativeFailure("Another teammate owns an overlapping task in this source. Read the task board, choose separate paths, or wait for a handoff.")
        }
        values.removeAll { $0.id == task.id }; values.append(task)
        // Do not silently discard an active assignment when bounding history.
        if values.count > 80 { if let index = values.firstIndex(where: { !$0.reservesPaths }) { values.remove(at: index) } else { throw nativeFailure("Task board is full; finish existing work first.") } }
        try save(values); return task
    }
    func update(_ id: String, owner: String, workspaceID: String? = nil, status: String? = nil) throws {
        var values = try tasks()
        guard let index = values.firstIndex(where: { $0.id == id && $0.owner == owner }) else { throw nativeFailure("Task is not owned by this teammate.") }
        if let workspaceID { values[index].workspaceID = workspaceID }
        if let status { values[index].status = status }
        values[index].updatedAt = Date(); try save(values)
    }
    func release(_ id: String, owner: String) throws {
        try update(id.lowercased(), owner: owner, status: "released")
    }
    func handoff(_ id: String, owner: String, to next: String) throws -> WorkspaceTask {
        guard agents.contains(next), next != owner else { throw nativeFailure("Choose another Project teammate for the handoff.") }
        var values = try tasks()
        guard let index = values.firstIndex(where: { $0.id == id.lowercased() && $0.owner == owner }), !values[index].reservesPaths else { throw nativeFailure("Finish or stop your workspace before handing it off.") }
        guard !values.contains(where: { $0.id != values[index].id && $0.folderID == values[index].folderID && $0.reservesPaths && Self.overlaps($0.paths, values[index].paths) }) else { throw nativeFailure("An overlapping task is now assigned; finish that task before handing this one off.") }
        values[index].status = "handoff"; values[index].nextOwner = next; values[index].updatedAt = Date()
        try save(values); return values[index]
    }
    func json() throws -> [[String: Any]] {
        let values = try tasks().sorted { a, b in a.reservesPaths != b.reservesPaths ? a.reservesPaths : a.updatedAt > b.updatedAt }
        return values.prefix(24).map { task in
            ["id": task.id, "title": limitedUTF16(task.title, to: 200), "folderId": task.folderID, "owner": task.owner, "status": task.status,
             "nextOwner": task.nextOwner as Any, "workspaceId": task.workspaceID as Any, "paths": Array(task.paths.prefix(8)), "pathsShortened": task.paths.count > 8,
             "boardShortened": values.count > 24]
        }
    }
}

struct WorkspaceTasksView: View {
    @ObservedObject var store: ConversationStore
    @State private var tasks: [WorkspaceTask] = []
    @State private var error: String?
    var body: some View {
        DisclosureGroup("Team task ownership and handoffs") {
            VStack(alignment: .leading, spacing: 8) {
                if let error { Text(error).foregroundStyle(.orange) }
                if tasks.isEmpty { Text("No task claims recorded for this conversation.").foregroundStyle(.secondary) }
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).fontWeight(.medium)
                        Text("\(names[task.owner] ?? task.owner) · \(task.status)" + (task.nextOwner.map { " → " + (names[$0] ?? $0) } ?? ""))
                        Text("Scope: " + task.paths.map { $0.isEmpty ? "whole source" : $0 }.joined(separator: ", ")).foregroundStyle(.secondary)
                        Text(task.id).font(.caption2).textSelection(.enabled)
                    }
                }
                Button("Refresh tasks") { refresh() }
            }.font(.caption).padding(.top, 8)
        }.task(id: store.transcriptRevision) { refresh() }
    }
    private func refresh() {
        do { tasks = try WorkspaceTaskBoard(root: store.workspaceStorage.appendingPathComponent(store.conversation.id.uuidString.lowercased())).tasks(); error = nil }
        catch { self.error = "Task ownership unavailable: " + error.localizedDescription }
    }
}
