import Foundation
import CoreGraphics
import ImageIO

// The unsandboxed lane and screenshot encoding, with real local processes and files.
@main struct ComputerHostLaneTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        func request(_ args: [String: Any]) -> ComputerRequest { try! ComputerRequest.validate(args) }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HostLane-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let logs = scratch.appendingPathComponent("logs")

        // Shell: real exit codes, both streams, the working directory and the saved full output.
        let ok = try await HostLane.shell(request(["action": "shell", "command": "pwd; echo out; echo err >&2; exit 3", "cwd": scratch.path]), logDirectory: logs)
        check(ok["exitCode"] as? Int == 3, "a nonzero exit code is reported, not hidden")
        check((ok["stdout"] as? String)?.contains("out") == true && (ok["stderr"] as? String)?.contains("err") == true, "stdout and stderr are both returned")
        check((ok["stdout"] as? String)?.contains(scratch.lastPathComponent) == true && ok["cwd"] as? String == scratch.path, "the command runs in the requested directory")
        let full = (ok["fullOutput"] as? String).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        check(full.contains("# exit: 3") && full.contains("--- stderr ---\nerr"), "the full output is saved with the exit code")
        let path = try await HostLane.shell(request(["action": "shell", "command": "command -v git && echo \"$SILKWIRE_AGENT_SHELL\"", "cwd": scratch.path]), logDirectory: logs)
        check(path["exitCode"] as? Int == 0 && (path["stdout"] as? String)?.contains("git") == true && (path["stdout"] as? String)?.contains("\n1") == true, "the login shell finds Jason's tools and marks agent commands")
        check(HostLane.environment()["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true && !HostLane.environment().keys.contains { $0.hasPrefix("SILKWIRE_") && $0 != "SILKWIRE_AGENT_SHELL" }, "Silkwire's own settings never leak into agent commands")
        do {
            _ = try await HostLane.shell(request(["action": "shell", "command": "sleep 20", "cwd": scratch.path, "timeout": 1]), logDirectory: logs)
            check(false, "a command past its timeout is stopped")
        } catch { check(error.localizedDescription.contains("did not finish within 1 s"), "a command past its timeout is stopped and explained") }
        do {
            _ = try await HostLane.shell(request(["action": "shell", "command": "true", "cwd": scratch.appendingPathComponent("missing").path]), logDirectory: logs)
            check(false, "a missing working directory is refused")
        } catch { check(error.localizedDescription.contains("does not exist"), "a missing working directory is refused before running") }
        let long = String(repeating: "a", count: 30_000) + "TAIL"
        let clipped = HostLane.clip(long)
        check(clipped.hasSuffix("TAIL") && clipped.contains("characters omitted") && clipped.utf16.count < 21_000, "long output keeps its head and tail with a note")
        check(HostLane.clip("short") == "short", "short output is unchanged")

        // Files: numbered reads with a hash; writes create folders and say what they replaced.
        let file = scratch.appendingPathComponent("nested/dir/notes.txt")
        let written = try HostLane.write(request(["action": "write", "path": file.path, "content": "one\ntwo\nthree\n"]))
        check(written["bytes"] as? Int == 14 && written["replacedExisting"] as? Bool == false, "writing creates missing folders")
        let again = try HostLane.write(request(["action": "write", "path": file.path, "content": "one\ntwo\nthree\nfour"]))
        check(again["replacedExisting"] as? Bool == true, "replacing an existing file is reported")
        let read = try HostLane.read(request(["action": "read", "path": file.path, "startLine": 2, "lineCount": 2]))
        check(read["text"] as? String == "2\ttwo\n3\tthree" && read["lines"] as? Int == 4 && read["truncated"] as? Bool == true, "reads return numbered lines and say when more remain")
        check((read["sha256"] as? String)?.count == 64 && read["sha256"] as? String == again["sha256"] as? String, "reads report the same hash the write returned")
        try Data([0xff, 0xfe, 0x00]).write(to: scratch.appendingPathComponent("binary.bin"))
        do { _ = try HostLane.read(request(["action": "read", "path": scratch.appendingPathComponent("binary.bin").path])); check(false, "binary files are refused") }
        catch { check(error.localizedDescription.contains("not UTF-8"), "binary files are refused with a pointer to shell") }

        // Screenshots: Retina-sized captures shrink to the long-edge and 2 MB bounds with a usable scale.
        let width = 3456, height = 2234
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var seed: UInt64 = 42
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                context.setFillColor(CGColor(red: CGFloat(seed >> 56) / 255, green: CGFloat((seed >> 48) & 0xff) / 255, blue: CGFloat((seed >> 40) & 0xff) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let frame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let shot = try NativeComputerDriver.encode(context.makeImage()!, frame: frame, backend: "test")
        let decoded = CGImageSourceCreateWithData(shot.png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        check(shot.png.count <= 1_900_000, "a noisy Retina capture fits the attachment bound (\(shot.png.count) bytes)")
        check(decoded.map { max($0.width, $0.height) <= 1568 } == true, "the long edge is at most 1,568 pixels")
        check(decoded.map { abs(Double($0.width) / frame.width - shot.scale) < 0.01 } == true, "the reported scale converts image pixels back to screen points")
        check((shot.description["frame"] as? [Int]) == [0, 0, 1728, 1117] && (shot.description["coordinates"] as? String)?.contains("imagePixelsPerPoint") == true, "the agent is told how to map pixels to click points")

        // Finding 5: recognized secrets are masked in shell output and file reads (synthetic values only).
        let synthetic = "export GITHUB_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwx\napi_key: sk-ABCDEFGHIJKLMNOPQRSTUVWX\nnothing-secret-here=42"
        let (masked, didRedact) = HostLane.scrubSecrets(synthetic)
        check(didRedact && !masked.contains("ghp_0123456789abcdefghijklmnopqrstuvwx") && !masked.contains("sk-ABCDEFGHIJKLMNOPQRSTUVWX"), "token-shaped secrets are masked")
        check(masked.contains("nothing-secret-here=42"), "ordinary output is left intact")
        check(HostLane.scrubSecrets("just some normal log output, 1a2b3c commit").1 == false, "plain output is not over-redacted")
        let secretFile = scratch.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: secretFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"OPENAI_API_KEY":"sk-synthetic00000000000000000000"}"#.write(to: secretFile, atomically: true, encoding: .utf8)
        let readSecret = try HostLane.read(request(["action": "read", "path": secretFile.path]))
        check(readSecret["redacted"] as? Bool == true && (readSecret["text"] as? String)?.contains("sk-synthetic00000000000000000000") == false, "reading a credential file masks its value and flags it redacted")
        let outFromShell = try await HostLane.shell(request(["action": "shell", "command": "echo 'token=ghp_ZYXWVUTSRQPONMLKJIHGFEDCBA098765'", "cwd": scratch.path]), logDirectory: logs)
        check(outFromShell["redacted"] as? Bool == true && (outFromShell["stdout"] as? String)?.contains("ghp_ZYXWVUTSRQPONMLKJIHGFEDCBA098765") == false, "shell stdout with a token is masked and flagged")
        let shellLog = (outFromShell["fullOutput"] as? String).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        check(!shellLog.contains("ghp_ZYXWVUTSRQPONMLKJIHGFEDCBA098765"), "the saved shell log never contains the secret either")

        // Finding 6: a project folder with a directory symlink pointing outside is not treated as inside.
        let projectRoot = scratch.appendingPathComponent("proj"); let outsideDir = scratch.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projectRoot.appendingPathComponent("link"), withDestinationURL: outsideDir)
        var ctx = ComputerActionContext(request: request(["action": "shell", "command": "rm x"]), projectFolders: [projectRoot.path], home: scratch.path)
        check(AskFirstPolicy.inside(projectRoot.appendingPathComponent("real.txt").path, ctx), "a real file inside the project is inside")
        check(!AskFirstPolicy.inside(projectRoot.appendingPathComponent("link/file.txt").path, ctx), "a file reached through a symlink out of the project is not inside")

        print("ComputerHostLaneTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
