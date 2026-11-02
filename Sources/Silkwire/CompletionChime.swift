import Foundation
import AppKit
import AVFoundation

/// Jason's original Web Audio recipes, rendered offline without opening an audio device.
enum CompletionChime {
    enum Choice: String, CaseIterable { case bell, glass, space, signature }
    struct Note: Equatable { let offset: Double; let hz: Double; let duration: Double }
    static let sampleRate = 48_000
    static func notes(_ choice: Choice) -> [Note] {
        let values: [(Double, Double, Double)]
        switch choice {
        case .bell: values = [(0,660,0.42),(0.19,880,0.52)]
        case .glass: values = [(0,880,0.36),(0.13,1108.7,0.38),(0.26,1320,0.4)]
        case .space: values = [(0,523.25,0.25),(0.12,784,0.25),(0.25,1046.5,0.38)]
        case .signature: values = [(0,587.33,0.3),(0.13,740,0.3),(0.26,880,0.3),(0.43,1174.66,0.45)]
        }
        return values.map { Note(offset: $0.0, hz: $0.1, duration: $0.2) }
    }
    static func envelope(_ age: Double, duration: Double) -> Double {
        guard age >= 0, age < duration + 0.025 else { return 0 }
        if age < 0.018 { return age / 0.018 }
        if age < duration { return pow(0.001, (age - 0.018) / (duration - 0.018)) }
        return 0.001 * (1 - (age - duration) / 0.025)
    }
    static func samples(_ choice: Choice = .signature, volume: Double = 100) -> [Double] {
        let notes = notes(choice)
        let end = notes.map { 0.02 + $0.offset + $0.duration + 0.04 }.max() ?? 0
        let gain = (volume.isFinite ? min(100, max(0, volume)) : 0) / 100 * 0.72
        return (0..<Int(ceil(end * Double(sampleRate)))).map { frame in
            let time = Double(frame) / Double(sampleRate) - 0.02
            return notes.reduce(0) { sum, note in
                let age = time - note.offset
                return sum + sin(2 * .pi * note.hz * age) * envelope(age, duration: note.duration) * gain
            }
        }
    }
    static func wav(_ choice: Choice = .signature, volume: Double = 100) -> Data {
        let pcm = samples(choice, volume: volume)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(value & 65535)); u16(UInt16(value >> 16)) }
        text("RIFF"); u32(UInt32(36 + pcm.count * 2)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(pcm.count * 2))
        for sample in pcm { u16(UInt16(bitPattern: Int16((min(1, max(-1, sample)) * 32767).rounded()))) }
        return data
    }
    /// Fail closed for command-line tests, verification bundles and automation.
    static func audible(bundleID: String?, environment: [String: String], isolated: Bool) -> Bool {
        guard !isolated, ["app.silkwire.staging", "app.silkwire.native.ready.preview"].contains(bundleID ?? "") else { return false }
        return !["SILKWIRE_ACCEPTANCE", "SILKWIRE_STAGING_CHECK", "SILKWIRE_COMMAND_SANDBOX", "SILKWIRE_TESTING", "XCTestConfigurationFilePath", "CI"].contains { environment[$0] != nil }
    }
}

/// A completion is evidence-backed and a live transition, never a history reload.
struct BuilderChimeGate {
    private var consumed: Set<String> = []
    mutating func consume(_ receipt: [String: Any], previouslyRunning: Bool) -> Bool {
        guard previouslyRunning, let id = receipt["id"] as? String, !id.isEmpty,
              receipt["status"] as? String == "review", receipt["finishedAt"] as? String != nil,
              !consumed.contains(id) else { return false }
        consumed.insert(id)
        guard let checks = receipt["checks"] as? [String: Any],
              let failed = checks["failed"] as? Int, failed == 0,
              let unconfirmed = checks["unconfirmed"] as? Int, unconfirmed == 0,
              let passed = checks["passed"] as? Int, passed > 0 else { return false }
        return true
    }
}

/// Serial playback preserves each complete melody; a second request never cuts it off.
@MainActor final class BuilderChimePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = BuilderChimePlayer()
    private var pending = 0
    private var player: AVAudioPlayer?
    /// `whenInactive`: also chirp while Silkwire is in the background, so Jason hears it from across the room.
    func play(isolated: Bool, whenInactive: Bool = false) {
        guard CompletionChime.audible(bundleID: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment, isolated: isolated), whenInactive || NSApplication.shared.isActive else { return }
        pending += 1
        startNext()
    }
    private func startNext() {
        guard player == nil, pending > 0 else { return }
        pending -= 1
        do {
            let next = try AVAudioPlayer(data: CompletionChime.wav())
            next.delegate = self; player = next
            if !next.play() { player = nil; pending = 0 }
        } catch { player = nil; pending = 0 }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.player = nil; self?.startNext() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.player = nil; self?.pending = 0 }
    }
}
