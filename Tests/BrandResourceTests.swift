import Foundation

@main struct BrandResourceTests {
    @MainActor static func main() async throws {
        let files = FileManager.default, source = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let fixture = source.appendingPathComponent("output/brand-integrity-\(UUID())")
        for directory in ["Scripts","Resources/Assets"] { try files.createDirectory(at:fixture.appendingPathComponent(directory),withIntermediateDirectories:true) }
        for relative in ["Scripts/build.swift","Resources/Assets/Colors.xcassets","Resources/Assets/SilkwireAppIcon-1024.png","Resources/Compiled"] {
            try files.copyItem(at:source.appendingPathComponent(relative),to:fixture.appendingPathComponent(relative))
        }
        let color = fixture.appendingPathComponent("Resources/Assets/Colors.xcassets/AccentColor.colorset/Contents.json")
        let original = try Data(contentsOf:color)
        var changed = original; changed.append(10); try changed.write(to:color)
        func check(_ label: String) async throws {
            let result = try await NativeProcess.run(executable:"/usr/bin/swift", arguments:["-module-cache-path",fixture.appendingPathComponent("ModuleCache").path,fixture.appendingPathComponent("Scripts/build.swift").path],directory:fixture,environment:nativeProviderEnvironment())
            guard result.exitCode != 0, result.stderr.contains("Native brand resource source/artifact mismatch"), !files.fileExists(atPath:fixture.appendingPathComponent("Sources").path) else { throw nativeFailure("Brand drift did not fail before source compilation: " + label) }
            print("PASS: " + label + " fails closed before compilation; no stale native brand resource accepted")
        }
        try await check("source palette drift")
        try original.write(to:color)
        let catalog = fixture.appendingPathComponent("Resources/Compiled/macOS/Assets.car")
        var artifact = try Data(contentsOf:catalog); artifact[0] ^= 1; try artifact.write(to:catalog)
        try await check("compiled catalog corruption")
    }
}
