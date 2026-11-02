import Foundation

// Pure authorization regressions with synthetic directories only; no real data.
@main struct ProjectsAccessReviewTests {
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("projects-review-" + UUID().uuidString)
        let projects = fixture.appendingPathComponent("Projects")
        let library = fixture.appendingPathComponent("Staging")
        let outside = fixture.appendingPathComponent("Outside")
        let normal = projects.appendingPathComponent("Example")
        let protected = projects.appendingPathComponent("Example/secrets")
        for url in [outside, protected, library.appendingPathComponent("Sources/Example")] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var env = WorkspaceEnvironment(staging: true, library: library)
        env.projectsRoot = projects
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if condition { print("PASS: " + label) }
            else { failures += 1; print("FAIL: " + label) }
        }
        check(env.permitsReading(normal), "ordinary project remains readable")
        check(!env.permits(normal), "ordinary Projects source remains non-buildable")
        check(env.permitsReading(outside), "ordinary outside folder can be explicitly selected")
        var nestedBlocked = false
        do { _ = try NativeScopedRoot.components("secrets/sample.txt", allowEmpty: false) }
        catch { nestedBlocked = true }
        check(nestedBlocked, "protected relative folder is blocked by reader path validation")
        check(NativeScopedRoot.excluded(protected.lastPathComponent), "the direct-root fixture is an excluded directory name")
        // Root authorization must preserve the exclusions enforced below a root.
        check(!env.permitsReading(protected), "selecting an excluded directory as a root must be rejected")
        let linkedProjects = fixture.appendingPathComponent("LinkedProjects")
        try fm.createSymbolicLink(at: linkedProjects, withDestinationURL: outside)
        var linked = WorkspaceEnvironment(staging: true, library: library)
        linked.projectsRoot = linkedProjects
        let canonicalSelection = linkedProjects.standardizedFileURL.resolvingSymlinksInPath()
        check(!linked.permitsReading(linkedProjects), "a linked selection cannot silently expand a grant")
        check(linked.permitsReading(canonicalSelection), "explicitly selecting the real outside folder is eligible")
        check(!linked.permits(canonicalSelection), "even the linked-root case cannot enable builds")
        print("ProjectsAccessReviewTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
