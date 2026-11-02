import Foundation

// Exercises the real wrapper and host classifier, with harmless shell commands in
// temporary files. This does not substitute for protected workspace execution.
@main struct ShellEvidenceReviewTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-shell-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cases: [(String, String)] = [
            ("printf ok", "passed"), ("false; true", "unconfirmed"),
            ("echo \"$(false)\"", "unconfirmed"), ("printf '%s' \"$(false)\"", "unconfirmed"),
            ("f() { false; }; echo \"$(f)\"", "unconfirmed"),
            ("echo `false`", "unconfirmed"), ("echo \"$(true)\"", "unconfirmed"),
            ("if false; then echo no; fi; echo yes", "passed"), ("exit 4", "failed")
        ]
        for (command, expected) in cases {
            let file = root.appendingPathComponent(UUID().uuidString + ".tsv")
            try Data().write(to: file)
            let result = try await NativeProcess.run(executable: "/bin/bash", arguments: ["-c", NativeBuilder.evidencePrelude, "fixture", command, file.path], directory: root, environment: ["PATH": "/usr/bin:/bin"])
            let record = try String(contentsOf: file, encoding: .utf8)
            // NativeProcess.run throws on timeout; a returned result did not time out.
            let status = NativeBuilder.checkStatus(stopped: false, exitCode: result.exitCode, timedOut: false, evidenceIntact: true, absorbed: NativeBuilder.absorbedStatuses(record).count, command: command)
            guard status == expected else { throw nativeFailure("FAIL \(command): \(status), expected \(expected)") }
            print("PASS \(command): wrapper exit \(result.exitCode), classified \(status)")
        }
        print("PASS: \(cases.count) actual shell-wrapper/classifier regressions; workspace sandbox not exercised")
    }
}
