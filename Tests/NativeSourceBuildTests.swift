import Foundation

// Verification-only Builder gate: no model is contacted and no source is edited.
// The actual native app must build in the same private command boundary offered
// to the user, not merely in the implementation agent's unrestricted shell.
@main struct NativeSourceBuildTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let source = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let output = source.appendingPathComponent("output/native-source-builder-\(UUID())")
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-source-build-\(UUID())")
        try FileManager.default.createDirectory(at:output, withIntermediateDirectories:true)
        var receipt: [String:Any] = [:]
        let builder = NativeBuilder(onReceipt:{ receipt = $0 },storageRoot:storage, ownership: HostOwnershipDefault.coordinator)
        await builder.start(source:source, task:"Verify the standalone Silkwire native app from its canonical clean source, without editing or contacting a model.",
                            build:"/usr/bin/swift -module-cache-path \"$TMPDIR/script-modules\" Scripts/build.swift",
                            test:"/usr/bin/codesign --verify --deep --strict \"output/release/Silkwire Dev.app\"", edit:false)
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json"))
        print("Receipt: \(output.path)/result.json")
        guard receipt["status"] as? String == "review", receipt["sourceUnchanged"] as? Bool == true,
              (receipt["steps"] as? [[String:Any]])?.count == 2,
              (receipt["steps"] as? [[String:Any]])?.allSatisfy({ $0["status"] as? String == "passed" && ($0["exitCode"] as? NSNumber)?.intValue == 0 }) == true else { throw nativeFailure("Full native source build failed inside the actual Builder boundary. Inspect the retained receipt.") }
        print("PASS: actual native Silkwire source builds and signed package verifies in a private Builder worktree; canonical source unchanged")
    }
}
