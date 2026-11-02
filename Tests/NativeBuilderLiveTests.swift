import Foundation
import Darwin

// Explicit opt-in integration gate. Uses the existing ChatGPT sign-in and its
// default included-usage model; never an API credential or model override.
@main struct NativeBuilderLiveTests {
    @MainActor static func validate(_ final: [String:Any]) throws {
        guard final["status"] as? String == "review", final["sourceUnchanged"] as? Bool == true, final["editingVerified"] as? Bool == true,
              (final["steps"] as? [[String:Any]])?.count == 2,
              (final["steps"] as? [[String:Any]])?.allSatisfy({ $0["status"] as? String == "passed" && ($0["exitCode"] as? NSNumber)?.intValue == 0 }) == true,
              (final["diff"] as? String)?.contains("Hello, Jason!") == true,
              let source = final["sourcePath"] as? String,
              try String(contentsOf:URL(fileURLWithPath:source).appendingPathComponent("greeting.swift"),encoding:.utf8) == "print(\"Hello\")\n" else { throw nativeFailure("Real Builder gate failed; inspect the preserved receipt.") }
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        if let evidence = ProcessInfo.processInfo.environment["SILKWIRE_BUILDER_RECEIPT"] {
            let receipt = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:evidence))) as! [String:Any]
            try validate(receipt)
            print("PASS persisted real Codex receipt: read/hash-write, exact Swift compile/run, unchanged source; no model replay")
            return
        }
        guard ProcessInfo.processInfo.environment["SILKWIRE_LIVE_BUILDER"] == "1" else { throw nativeFailure("Set SILKWIRE_LIVE_BUILDER=1 for the approved signed-in integration gate.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-builder-live-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let original = "print(\"Hello\")\n"
        try Data(original.utf8).write(to:source.appendingPathComponent("greeting.swift"))
        try Data("greeting\n.build/\n".utf8).write(to:source.appendingPathComponent(".gitignore"))
        let env = ["PATH":"/usr/bin:/bin:/opt/homebrew/bin","HOME":NSHomeDirectory(),"GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_NOSYSTEM":"1"]
        for args in [["init"],["add","greeting.swift",".gitignore"],["-c","user.name=Silkwire Fixture","-c","user.email=fixture@invalid.local","commit","-m","Synthetic greeting"]] {
            let result = try await NativeProcess.run(executable:"/usr/bin/git",arguments:args,directory:source,environment:env)
            guard result.exitCode == 0 else { throw nativeFailure("Cannot create synthetic source fixture.") }
        }
        var final: [String:Any] = [:], lastStatus = ""
        let builder = NativeBuilder(onReceipt:{ receipt in
            final = receipt
            let status = receipt["status"] as? String ?? ""
            if status != lastStatus { print("Builder status: " + status); lastStatus = status }
        },storageRoot:root.appendingPathComponent("runs"), ownership: HostOwnershipDefault.coordinator)
        await builder.start(source:source,task:"Read greeting.swift through the native BUILDER_READ plain-text broker. Replace only greeting.swift so its exact content is print(\"Hello, Jason!\") followed by a newline. Use the exact SHA-256 from your read in BUILDER_WRITE. Do not use native tools or run commands; the app compiles/tests after your final summary.",build:"/usr/bin/swiftc -module-cache-path \"$TMPDIR/modules\" greeting.swift -o greeting",test:"test \"$(./greeting)\" = \"Hello, Jason!\"",edit:true)
        let evidence = root.appendingPathComponent("live-result.json")
        try JSONSerialization.data(withJSONObject:final,options:[.prettyPrinted,.sortedKeys]).write(to:evidence)
        print("Receipt: " + evidence.path)
        print("Result: " + (final["status"] as? String ?? "missing") + "; " + (final["message"] as? String ?? ""))
        try validate(final)
        print("PASS real signed-in Codex read/hash-write + exact Swift compile/run + unchanged source + durable receipt")
    }
}
