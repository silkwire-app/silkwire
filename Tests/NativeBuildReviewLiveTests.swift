import Foundation

/// Opt-in review of a real *synthetic* Builder receipt, one fresh room/provider
/// at a time so another teammate's description cannot satisfy the evidence check.
@main struct NativeBuildReviewLiveTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        guard let path = ProcessInfo.processInfo.environment["SILKWIRE_BUILDER_RECEIPT"] else { throw nativeFailure("Select a synthetic Builder receipt.") }
        let data = try Data(contentsOf:URL(fileURLWithPath:path))
        guard let receipt = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let source = receipt["sourcePath"] as? String, source.contains("/silkwire-builder-live-"),
              let artifactID = receipt["id"] as? String, UUID(uuidString:artifactID) != nil,
              receipt["status"] as? String == "review", receipt["sourceUnchanged"] as? Bool == true else { throw nativeFailure("Only a completed synthetic unchanged-source Builder run may be reviewed.") }
        let text = String(decoding:try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
        let expected = NativeScopedRoot.sha256(Data(text.utf8))
        let selected = Set(CommandLine.arguments.dropFirst())
        for name in agents where selected.isEmpty || selected.contains(name) {
            print("TEST \(name) shared real Builder receipt")
            var events: [[String:Any]] = []
            let room = NativeRoom(emit:{events.append($0)})
            defer { room.close() }
            await room.dispatch(["action":"connect","conversationID":UUID().uuidString,"participants":[name]])
            guard events.contains(where: { $0["type"] as? String == "connection" && $0["agent"] as? String == name && $0["state"] as? String == "connected" }) else { throw nativeFailure("Synthetic review provider did not connect.") }
            let request = UUID().uuidString.lowercased()
            await room.dispatch(["action":"send","requestId":request,"text":"Synthetic build review only. Read the shared build artifact through READ_PROJECT artifact requests. Report both build and test exit codes plus one exact changed source line. Do not use direct runtime tools or execute anything. The artifact is the evidence, not this prompt or another agent's description.","targets":[name],"buildArtifacts":[["id":artifactID,"text":text]]])
            for _ in 0..<3000 where !events.contains(where: { $0["type"] as? String == "settled" && $0["requestId"] as? String == request }) { try await Task.sleep(for:.milliseconds(100)) }
            guard events.contains(where: { $0["type"] as? String == "artifactAccess" && $0["agent"] as? String == name && $0["sha256"] as? String == expected }),
                  events.contains(where: { $0["type"] as? String == "finished" && $0["agent"] as? String == name && $0["status"] as? String == "completed" }) else { throw nativeFailure("\(name) did not demonstrate an independent read of the exact real Builder artifact.") }
            print("PASS \(name): real shared receipt read with matching SHA-256; attributed review completed; no folder or execution grant")
        }
    }
}
