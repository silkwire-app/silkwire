import Foundation
import Darwin

@main struct WorkspaceTemporaryTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        // A child process proves TMPDIR is ignored by the host allocator, rather
        // than depending on Foundation's in-process temporaryDirectory cache.
        if CommandLine.arguments.contains("--probe-workspace-temp") {
            print(try NativeTemporaryDirectory.createWorkspace().path)
            return
        }
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw nativeFailure("FAIL " + label) }
            print("PASS " + label)
        }
        let fixture = try NativeTemporaryDirectory.canonical(fm.temporaryDirectory).appendingPathComponent("silkwire-temp-policy-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let library = fixture.appendingPathComponent("Staging")
        let inherited = library.appendingPathComponent("Team Workspaces/room/tmp")
        try fm.createDirectory(at: inherited, withIntermediateDirectories: true)
        // WorkspaceEnvironment receives its normalized library identity; the
        // granted scratch/source URLs retain their POSIX real paths.
        let environment = WorkspaceEnvironment(staging: true, library: library.standardizedFileURL)
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--probe-workspace-temp"]
        var env = ProcessInfo.processInfo.environment; env["TMPDIR"] = inherited.path
        child.environment = env; child.standardOutput = output
        try child.run()
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        child.waitUntilExit()
        try check(child.terminationStatus == 0 && !path.isEmpty, "host creates scratch storage with protected inherited TMPDIR")
        let scratch = URL(fileURLWithPath: path)
        defer { try? fm.removeItem(at: scratch) }
        try check(path.hasPrefix(try NativeTemporaryDirectory.systemParent().path + "/") && !path.hasPrefix(library.path + "/"), "workspace scratch lives in OS temp outside Staging data")
        try check(path == (try NativeTemporaryDirectory.canonical(scratch)).path && !path.hasPrefix("/tmp/"), "scratch path is canonical without the /tmp alias")
        let attributes = try fm.attributesOfItem(atPath: path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "workspace scratch is private mode 0700")
        try check(environment.permitsReading(scratch), "production permits explicitly granted fixture roots in workspace scratch")
        let root = try NativeScopedRoot(scratch)
        _ = try root.list("")
        try check(true, "production no-link broker can open every scratch ancestor")
        let ordinary = try NativeTemporaryDirectory.canonical(fm.temporaryDirectory)
        try check(environment.permitsReading(ordinary) && !ordinary.path.hasPrefix(fm.homeDirectoryForCurrentUser.path + "/Library/"), "test runner supplies an eligible canonical fixture parent")
        let linked = fixture.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: scratch)
        try check(!environment.permitsReading(linked), "production still refuses linked Project roots")
        try check(!environment.permitsReading(inherited), "production still refuses Staging data as Project roots")
        try check(!environment.permitsReading(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")), "production still refuses the protected home Library")
    }
}
