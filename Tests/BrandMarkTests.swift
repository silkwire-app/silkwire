import Foundation
import AppKit

// Ari artwork: well-formed SVG for both finishes, faithful to the kit, and
// drawable by this macOS (the real question: can NSImage render the SVG?).
@main struct BrandMarkTests {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL " + label) }
        }
        for (finish, name) in [(AriArt.Finish.silverViolet, "silver-violet"), (.graphite, "graphite")] {
            let svg = AriArt.svg(finish)
            let parser = XMLParser(data: Data(svg.utf8))
            check(parser.parse(), "\(name): SVG is well-formed XML")
            check(!svg.contains("ID_"), "\(name): every gradient reference is resolved")
            check(svg.components(separatedBy: "fill='url(#").count - 1 == 18, "\(name): all 10 leg and palp paths and 8 body shapes are present")
            check(svg.contains("viewBox='-150.14 -58 300.28 71.6'"), "\(name): same canvas as the kit's on-strand small file")
            let image = AriArt.image(finish)
            check(image != nil, "\(name): macOS can draw the SVG")
            if let image {
                check(abs(image.size.width - 300.28) < 1 && abs(image.size.height - 71.6) < 1, "\(name): drawn at the kit's proportions (got \(image.size))")
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: 300, height: 72))
                NSGraphicsContext.restoreGraphicsState()
                var inked = 0
                for x in stride(from: 0, to: 300, by: 3) { for y in stride(from: 0, to: 72, by: 3) { if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { inked += 1 } } }
                check(inked > 60, "\(name): Ari actually renders pixels (\(inked) inked samples)")
            }
        }
        check(AriArt.svg(.silverViolet).contains("#a596d6") && !AriArt.svg(.graphite).contains("#a596d6"), "violet only in the Midnight finish")
        let app = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/Silkwire/SilkwireApp.swift"), encoding: .utf8)
        check(app.contains("AriSidebarMark()") || app.contains("AriWalkingMark("), "sidebar uses Ari (still or walking)")
        check(AriSidebarMark.nameLift < 0 && AriSidebarMark.nameLift >= -8, "name sits closer under the wire without touching it")
        let brand = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/Silkwire/BrandMark.swift"), encoding: .utf8)
        check(brand.contains("VStack(spacing: 0)"), "no extra gap between Ari and the name")
        print("\(checks - failures) of \(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
