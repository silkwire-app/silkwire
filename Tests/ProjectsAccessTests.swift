import Foundation

// Explicit Project grants can cover a whole Projects tree or a chosen folder
// elsewhere. Managed storage and private execution remain separate boundaries.
@main struct ProjectsAccessTests {
    static func main() throws {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ label: String) { checks += 1; if ok { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) } }
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-projects-" + UUID().uuidString)
        let projects = root.appendingPathComponent("Projects"), library = root.appendingPathComponent("Silkwire Staging")
        let chimes = projects.appendingPathComponent("silkwire/chimes"), outside = root.appendingPathComponent("Private")
        for url in [chimes, outside, library.appendingPathComponent("Sources/Silkwire")] { try files.createDirectory(at: url, withIntermediateDirectories: true) }
        try files.createSymbolicLink(at: projects.appendingPathComponent("sneaky"), withDestinationURL: outside)
        var env = WorkspaceEnvironment(staging: true, library: library)
        env.projectsRoot = projects

        check(env.permitsReading(chimes), "a folder inside Projects can be connected for reading")
        check(env.permitsReading(projects), "the whole Projects folder can be connected for reading")
        check(!env.permits(chimes), "external source folders never become managed storage")
        check(env.permitsReading(library.appendingPathComponent("Sources/Silkwire")) && env.permits(library.appendingPathComponent("Sources/Silkwire")), "Staging's private Sources copies stay readable and buildable")
        check(env.permitsReading(outside), "a specific outside folder is eligible for an explicit bookmarked grant")
        check(!env.permitsReading(projects.appendingPathComponent("sneaky")), "a link inside Projects that points elsewhere is refused")
        check(env.permitsReading(root), "a chosen ordinary parent can cover all its projects")
        check(!env.permitsReading(URL(fileURLWithPath: projects.path + "-lookalike/x")), "a look-alike name next to Projects is refused")
        var missing = WorkspaceEnvironment(staging: true, library: library)
        missing.projectsRoot = root.appendingPathComponent("NoSuchProjects")
        check(!missing.permitsReading(root.appendingPathComponent("NoSuchProjects/x")), "nothing is granted when the Projects folder does not exist")
        check(WorkspaceEnvironment(staging: false, library: library).permitsReading(outside), "the working app is unaffected")
        print("ProjectsAccessTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
