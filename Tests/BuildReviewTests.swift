import Foundation

@MainActor final class BuildReviewFixture: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var response = ""
    var prompts: [String] = []
    var capabilities: [String] = []
    func connect(_ saved: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let id = saved ?? ProviderIdentity(id:UUID().uuidString); identity = id; return id
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        prompts.append(text); self.capabilities.append(capabilities)
        let reply = text.contains("PROJECT READER RESULT") ? "Reviewed exact receipt: BUILD-EXIT-7; failed, not passed." : response
        eventHandler?(.replace(reply)); eventHandler?(.finished(status:"completed",message:nil)); await Task.yield()
    }
    func stop() async throws { eventHandler?(.finished(status:"interrupted",message:nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture only") }
}
@main struct BuildReviewTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition,label); count += 1; print("PASS "+label) }
        let artifactID = UUID().uuidString.lowercased()
        let receipt = "Branch: silkwire/isolated\nBase: 012345\nCommand: swift build\nResult: failed · exit 7\nBUILD-EXIT-7\nDiff: +fixed"
        let reader = NativeProjectAccess()
        reader.updateArtifacts([NativeBuildArtifact(id:artifactID,text:receipt)])
        let result = try reader.perform(.init(action:"artifact",startLine:2,lineCount:3,artifactID:artifactID))
        check(result["sha256"] as? String == NativeScopedRoot.sha256(Data(receipt.utf8)),"review artifact version is exact content hash")
        check(result["lines"] as? [String] == ["2: Base: 012345","3: Command: swift build","4: Result: failed · exit 7"],"bounded artifact reads preserve exact line numbers and failed exit code")
        check(result["shortened"] as? Bool == true,"artifact range signals remaining content")
        let pastEnd = try reader.perform(.init(action:"artifact",startLine:Int.max,lineCount:200,artifactID:artifactID))
        check((pastEnd["lines"] as? [String])?.isEmpty == true,"extreme artifact range cannot overflow")
        reader.updateArtifacts([])
        var denied = false
        do { _ = try reader.perform(.init(action:"artifact",artifactID:artifactID)) } catch { denied = true }
        check(denied,"artifact removal revokes old IDs")
        var events: [[String:Any]] = [], transports: [String:BuildReviewFixture] = [:]
        let room = NativeRoom(emit:{events.append($0)},factory:{agent,_ in
            let item = BuildReviewFixture(); item.response = "<<READ_PROJECT {\"action\":\"artifact\",\"artifactId\":\"\(artifactID)\",\"lineCount\":100}>>"; transports[agent] = item; return item
        })
        await room.dispatch(["action":"connect","conversationID":UUID().uuidString,"participants":agents])
        let request = UUID().uuidString
        await room.dispatch(["action":"send","requestId":request,"text":"Review the last build evidence, including failed exit code.","targets":agents,"buildArtifacts":[["id":artifactID,"text":receipt]],"history":[["author":"Builder","state":"completed","text":"Previous build finished for review."]]])
        for _ in 0..<200 where !events.contains(where: { $0["type"] as? String == "settled" && $0["requestId"] as? String == request }) { try await Task.sleep(for:.milliseconds(10)) }
        for agent in agents {
            check(transports[agent]?.prompts.count == 2 && transports[agent]?.prompts.last?.contains("BUILD-EXIT-7") == true,"\(agent) independently reads exact shared build receipt without any folder grant")
            check(transports[agent]?.capabilities.first?.contains(artifactID) == true,"\(agent) receives current artifact inventory")
        }
        check(transports["eve"]?.prompts.first?.contains("Previous build finished for review.") == true,"Builder result is no longer dropped from shared history")
        check(events.filter { $0["type"] as? String == "artifactAccess" && $0["sha256"] as? String == NativeScopedRoot.sha256(Data(receipt.utf8)) }.count == 3,"every reviewer has an evidenced read of the same artifact revision")
        check(!events.contains { ($0["text"] as? String ?? "").contains("<<READ_PROJECT") },"build artifact protocol stays hidden from transcript")
        check(events.filter { $0["type"] as? String == "context" && $0["capabilityHash"] as? String != nil }.count == 3,"each acknowledged dispatch records its capability fingerprint")
        await room.dispatch(["action":"connect","conversationID":UUID().uuidString,"participants":agents])
        let nextRequest = UUID().uuidString
        for item in transports.values { item.response = "No artifacts in this new conversation." }
        await room.dispatch(["action":"send","requestId":nextRequest,"text":"New conversation; no previous artifacts.","targets":["eve"]])
        for _ in 0..<200 where !events.contains(where: { $0["type"] as? String == "settled" && $0["requestId"] as? String == nextRequest }) { try await Task.sleep(for:.milliseconds(5)) }
        check(transports["eve"]?.capabilities.first?.contains(artifactID) == false,"reused room clears former conversation build artifacts")
        room.close()
        print("PASS: \(count) shared read-only Builder review checks")
    }
}
