import Foundation
import AppKit

// Opt-in, live-service-dependent: SILKWIRE_WEB_LIVE=1. GET-only page loads of the two
// approved staging sites in a fresh ephemeral session; no forms, sign-ins or sends.
@main struct WebInspectionLiveTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard ProcessInfo.processInfo.environment["SILKWIRE_WEB_LIVE"] == "1" else { print("SKIP live web inspection (set SILKWIRE_WEB_LIVE=1; requires network and the live staging sites)"); return }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output/web-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures = 0
        // The homepage hero is WebGL animation; ?still is its documented still frame.
        let pages = NativeWebInspector.approvedHosts.sorted().map { ($0, "https://\($0)/") } + [("staging.silkwire.si-still", "https://staging.silkwire.si/?still"), ("staging.silkwire.app-still", "https://staging.silkwire.app/?still"), ("staging.silkwire.si-freeze", "https://staging.silkwire.si/?freeze=8")]
        for (site, address) in pages {
            let url = try NativeWebInspector.validate(address, policy: .init())
            do {
                let inspected = try await NativeWebInspector(policy: .init()).inspect(url, steps: [["wait": 3000]], viewport: "desktop")
                let result = inspected.result
                if let png = inspected.screenshot { try png.write(to: output.appendingPathComponent(site + ".png")) }
                let text = result["text"] as? String ?? ""
                print("LIVE \(site): HTTP \(result["httpStatus"] ?? "?") · title \"\(result["title"] ?? "")\" · final \(result["finalURL"] ?? "") · \(text.count) text characters · \((result["links"] as? [Any])?.count ?? 0) links · blocked \((result["blocked"] as? [String])?.count ?? 0) · screenshot \(inspected.screenshot.map { "\($0.count) bytes" } ?? "none")")
                let warnings = result["captureWarnings"] as? [String] ?? []
                if !warnings.isEmpty { print("  capture warnings: " + warnings.joined(separator: " | ")) }
                if (result["httpStatus"] as? Int).map({ !(200..<400).contains($0) }) ?? true || inspected.screenshot == nil { failures += 1 }
                // Still mode is the documented way to get a visible frame; it must survive
                // redirects and must not produce a dark capture. Animated pages may be dark.
                if address.hasSuffix("?still") {
                    let final = result["finalURL"] as? String ?? ""
                    if !final.hasSuffix("?still") || !warnings.isEmpty { print("  FAIL still-mode capture: final \(final)"); failures += 1 }
                }
            } catch { print("LIVE \(site): FAILED \(error.localizedDescription)"); failures += 1 }
        }
        print("Live screenshots: \(output.path)")
        guard failures == 0 else { throw nativeFailure("FAIL: \(failures) live staging site(s) not inspected") }
        print("PASS: live staging sites inspected")
    }
}
