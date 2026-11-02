import Foundation
import AppKit

@main struct CompletionChimeTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); count += 1; print("PASS: " + label)
        }
        let signature = CompletionChime.notes(.signature)
        check(signature.map(\.hz) == [587.33,740,880,1174.66], "signature preserves the original four pitches")
        check(signature.map(\.offset) == [0,0.13,0.26,0.43] && signature.map(\.duration) == [0.3,0.3,0.3,0.45], "original timing and held final note")
        check(CompletionChime.notes(.bell).count == 2 && CompletionChime.notes(.glass).count == 3 && CompletionChime.notes(.space).count == 3, "all four original recipes retained")
        check(CompletionChime.envelope(0, duration: 0.3) == 0 && abs(CompletionChime.envelope(0.018, duration: 0.3) - 1) < 1e-12, "rounded 18 ms linear attack")
        check(abs(CompletionChime.envelope(0.3, duration: 0.3) - 0.001) < 1e-12 && CompletionChime.envelope(0.326, duration: 0.3) == 0, "original exponential decay and 25 ms release")
        for choice in CompletionChime.Choice.allCases {
            let pcm = CompletionChime.samples(choice)
            let peak = pcm.map(abs).max() ?? 0
            print("MEASURED " + choice.rawValue + " peak dBFS: " + String(format: "%.4f", 20 * log10(peak)))
            check(pcm.allSatisfy(\.isFinite) && peak > 0 && peak < pow(10, -2.0/20), choice.rawValue + " measured below -2 dBFS, no clipping")
            check(pcm.prefix(960).allSatisfy { $0 == 0 } && pcm.suffix(500).allSatisfy { $0 == 0 }, choice.rawValue + " includes scheduling lead and silent tail")
            check(CompletionChime.samples(choice, volume: 0).allSatisfy { $0 == 0 } && CompletionChime.samples(choice, volume: -100).allSatisfy { $0 == 0 }, choice.rawValue + " zero and negative volume are silent")
            check(CompletionChime.samples(choice, volume: 200) == pcm, choice.rawValue + " volume clamped to 100")
            let half = CompletionChime.samples(choice, volume: 50)
            check(zip(pcm, half).allSatisfy { abs($0.0 / 2 - $0.1) < 1e-12 }, choice.rawValue + " volume scales linearly")
            let wav = CompletionChime.wav(choice)
            check(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: wav[8..<12], as: UTF8.self) == "WAVE" && wav.count == 44 + pcm.count * 2, choice.rawValue + " valid PCM WAV framing")
        }
        check(CompletionChime.samples(volume: .nan).allSatisfy { $0 == 0 }, "invalid volume fails silent")
        let pcm = CompletionChime.samples()
        // Independent transcription of the original Web Audio envelope at representative frames.
        for frame in [1000,1800,8000,15000,24000,33000] {
            let time = Double(frame)/48000 - 0.02
            var expected = 0.0
            for note in signature {
                let t = time - note.offset
                var gain = 0.0
                if t >= 0 && t < 0.018 { gain = t/0.018 }
                else if t >= 0.018 && t < note.duration { gain = exp(log(0.001) * (t-0.018)/(note.duration-0.018)) }
                else if t >= note.duration && t < note.duration+0.025 { gain = 0.001 * (1-(t-note.duration)/0.025) }
                expected += sin(2 * Double.pi * note.hz * t) * gain * 0.72
            }
            check(abs(pcm[frame]-expected) < 1e-12, "Web Audio reference sample " + String(frame))
        }
        var gate = BuilderChimeGate()
        func receipt(_ id: String, state: String = "review", failed: Int = 0, unconfirmed: Int = 0, passed: Int = 2) -> [String: Any] {
            ["id":id, "status":state, "finishedAt":"2026-10-26T00:00:00Z", "checks":["failed":failed,"unconfirmed":unconfirmed,"passed":passed]]
        }
        check(!gate.consume(receipt("history"), previouslyRunning: false), "history-only final receipt is quiet")
        check(gate.consume(receipt("live"), previouslyRunning: true), "live evidenced finish signals completion")
        check(!gate.consume(receipt("live"), previouslyRunning: true), "duplicate final receipt never replays")
        check(!gate.consume(receipt("failed", state: "failed", failed: 1), previouslyRunning: true), "failed task is quiet")
        check(!gate.consume(receipt("stopped", state: "stopped"), previouslyRunning: true), "stopped task is quiet")
        check(!gate.consume(receipt("red", failed: 1), previouslyRunning: true), "review receipt with red checks is quiet")
        check(!gate.consume(receipt("uncertain", unconfirmed: 1), previouslyRunning: true), "unconfirmed checks are quiet")
        check(!gate.consume(receipt("unchecked", passed: 0), previouslyRunning: true), "no evidence does not earn a happy sound")
        check(!gate.consume(["id":"running","status":"active"], previouslyRunning: true), "running receipts are quiet")
        check(!CompletionChime.audible(bundleID: nil, environment: [:], isolated: false), "command-line tests cannot open audio")
        check(!CompletionChime.audible(bundleID: "app.silkwire.verification", environment: [:], isolated: false), "verification bundle silent")
        check(!CompletionChime.audible(bundleID: "app.silkwire.staging", environment: [:], isolated: true), "Test identities and fixtures silent")
        for key in ["SILKWIRE_ACCEPTANCE","SILKWIRE_STAGING_CHECK","SILKWIRE_COMMAND_SANDBOX","SILKWIRE_TESTING","XCTestConfigurationFilePath","CI"] {
            check(!CompletionChime.audible(bundleID: "app.silkwire.staging", environment: [key:"1"], isolated: false), key + " automation silent")
        }
        check(CompletionChime.audible(bundleID: "app.silkwire.staging", environment: [:], isolated: false), "normal Staging UI eligible for playback")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("chime-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = WorkspaceEnvironment(staging: true, library: root)
        let store = ConversationStore(directory: root, environment: env, workspaceSandbox: env)
        var signals = 0
        store.builderCompletionHandler = { signals += 1 }
        store.setChime(false)
        store.signalBuilderCompletion(receipt("muted"), previouslyRunning: true)
        check(signals == 0, "saved mute suppresses Builder sound")
        store.setChime(true)
        store.signalBuilderCompletion(receipt("muted"), previouslyRunning: true)
        check(signals == 0, "unmuting never replays a muted finish")
        store.signalBuilderCompletion(receipt("store-live"), previouslyRunning: true)
        store.signalBuilderCompletion(receipt("store-live"), previouslyRunning: true)
        check(signals == 1, "store routes exactly one signal for a fresh successful finish")
        store.signalBuilderCompletion(receipt("store-history"), previouslyRunning: false)
        check(signals == 1, "store leaves loaded history silent")
        print("PASS: \(count) checks; audio never played")
    }
}
