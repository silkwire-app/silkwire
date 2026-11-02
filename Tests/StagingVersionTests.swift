import Foundation

// Date-based version labels for the Update window.
@main struct StagingVersionTests {
    static func main() {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ label: String) { checks += 1; if ok { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) } }
        func identity(_ manifest: String, _ built: Date?) -> StagingInstaller.Identity {
            StagingInstaller.Identity(path: "/tmp/" + manifest, bundleID: "app.silkwire.staging", environment: "staging", revision: String(repeating: String(manifest.prefix(1)), count: 40), sourceStatus: "clean", sourceDigest: "", executableSHA256: manifest, manifestSHA256: manifest, fileCount: 9, signatureValid: true, builtAt: built)
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 8))!
        let a = identity("a", day1), b = identity("b", day1.addingTimeInterval(3600)), c = identity("c", day1.addingTimeInterval(7200)), d = identity("d", day2), old = identity("e", nil)
        let labels = StagingVersion.labels([c, old, a, d, b])
        check(StagingVersion.label(a, in: labels) == "2026.10.26.1" && StagingVersion.label(b, in: labels) == "2026.10.26.2" && StagingVersion.label(c, in: labels) == "2026.10.26.3", "builds on the same day are numbered in build order")
        check(StagingVersion.label(d, in: labels) == "2026.10.27.1", "numbering starts again each day")
        check(StagingVersion.label(old, in: labels) == "Earlier build " + old.shortRevision, "older builds without a build time are labelled plainly")
        let installedCopy = identity("b", day1.addingTimeInterval(3600))
        check(StagingVersion.label(installedCopy, in: StagingVersion.labels([a, b, installedCopy])) == "2026.10.26.2", "an installed copy shares its build's label instead of taking a new number")
        print("StagingVersionTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
