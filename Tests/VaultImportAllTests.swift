import Foundation

// The import window's plan: whole vault by default (including top-level notes),
// 'Import all N remaining', optional trial batch, and only-some-folders.
// Synthetic scans only; no real vault is read.
@main struct VaultImportAllTests {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        func note(_ path: String) -> VaultNote { VaultNote(relativePath: path, title: path, body: "x", modified: nil) }
        var notes = [note("README.md")]
        for i in 0..<100 { notes.append(note("Projects/P\(i).md")) }
        for i in 0..<52 { notes.append(note("Channel/C\(i).md")) }
        let scan = VaultScan(vaultName: "Agent Collaboration", vaultID: "v1", notes: notes)
        check(scan.notes.count == 153, "fixture mirrors a 153-note vault with one top-level note")

        let all = VaultImport.plan(scan, wholeVault: true, folders: [], trialOnly: false, skipping: [])
        check(all.count == 153, "whole vault imports every note by default")
        check(all.contains { $0.relativePath == "README.md" }, "whole vault includes notes that aren't in any folder")
        check(VaultImport.buttonTitle(count: 153, remaining: 153, anyDone: false) == "Import all 153 notes", "first import says 'Import all 153 notes'")

        let done = Set(notes.filter { $0.relativePath != "README.md" }.map(\.relativePath))
        let rest = VaultImport.plan(scan, wholeVault: true, folders: [], trialOnly: false, skipping: done)
        check(rest.map(\.relativePath) == ["README.md"], "continuing finds the one missing top-level note")
        check(VaultImport.buttonTitle(count: 1, remaining: 1, anyDone: true) == "Import the last remaining note", "one left reads naturally")

        let half = Set(notes.prefix(80).map(\.relativePath))
        let remaining = VaultImport.remaining(scan, wholeVault: true, folders: [], skipping: half)
        check(remaining == 73, "remaining counts only notes not yet imported")
        check(VaultImport.buttonTitle(count: 73, remaining: 73, anyDone: true) == "Import all 73 remaining", "continuing says 'Import all N remaining'")

        let trial = VaultImport.plan(scan, wholeVault: true, folders: [], trialOnly: true, skipping: [])
        check(trial.count == VaultImport.trialBatch, "'Just try a few first' brings in a small batch")
        check(VaultImport.buttonTitle(count: trial.count, remaining: 153, anyDone: false) == "Import 25 of 153", "trial button shows how many of the total")

        let some = VaultImport.plan(scan, wholeVault: false, folders: ["Channel"], trialOnly: false, skipping: [])
        check(some.count == 52 && some.allSatisfy { $0.folder == "Channel" }, "only-some-folders imports just the ticked folders")
        let none = VaultImport.plan(scan, wholeVault: false, folders: [], trialOnly: false, skipping: [])
        check(none.isEmpty && VaultImport.buttonTitle(count: 0, remaining: 0, anyDone: false) == "Nothing to import", "no folders ticked imports nothing and says so")
        let finished = VaultImport.plan(scan, wholeVault: true, folders: [], trialOnly: false, skipping: Set(notes.map(\.relativePath)))
        check(finished.isEmpty && VaultImport.buttonTitle(count: 0, remaining: 0, anyDone: true) == "Everything is already imported", "a fully imported vault says so")

        let paths = all.map(\.relativePath)
        check(Set(paths).count == paths.count, "no note is imported twice in one go")
        check(VaultImport.selection(scan, folders: ["Projects"], limit: 10).count == 10, "existing batch selection still works")

        print("\(checks - failures) of \(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
