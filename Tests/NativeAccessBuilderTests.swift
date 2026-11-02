import Foundation
import Darwin
@MainActor final class FixtureBuilderTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    private var step = 0
    let edits: Bool
    var sendsInFlight = 0
    var overlappingSends = false
    var failAcknowledgment = false
    init(edits: Bool = true) { self.edits = edits }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let result = ProviderIdentity(id:"fixture-builder",started:false,model:"fixture",runId:nil,requestId:nil,turnId:nil); self.identity = result; return result
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws {
        sendsInFlight += 1; if sendsInFlight > 1 { overlappingSends = true }; defer { sendsInFlight -= 1 }
        step += 1
        let reply: String
        if !edits { reply = "Done. Everything is built and tested." }
        else if step == 1 { reply = "<<BUILDER_READ {\"path\":\"greeting.swift\"}>>" }
        else if step == 2 {
            let marker = text.range(of:"\n")!; let object = try JSONSerialization.jsonObject(with:Data(text[marker.upperBound...].utf8)) as! [String:Any]
            let hash = (object["result"] as! [String:Any])["sha256"] as! String
            reply = "<<BUILDER_WRITE " + (try nativeJSON(["path":"greeting.swift","expectedSha256":hash,"content":"print(\"Hello, Jason!\")\n"])) + ">>"
        } else { reply = "Updated greeting. Tests have not run yet." }
        eventHandler?(.replace(reply)); eventHandler?(.finished(status:"completed",message:nil))
        try await Task.sleep(nanoseconds:30_000_000)
        if failAcknowledgment { throw nativeFailure("Fixture late acknowledgment failure.") }
    }
    func stop() async throws {}
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Fixture") }
}
@main struct NativeAccessBuilderTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0
        func check(_ value: Bool, _ name: String) throws { guard value else { throw nativeFailure("FAIL: " + name) }; passed += 1; print("PASS " + name) }
        func rejects(_ name: String, _ action: () throws -> Void) throws { do { try action() } catch { passed += 1; print("PASS " + name); return }; throw nativeFailure("FAIL accepted " + name) }
        let fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-native-access-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
        let root = fixture.appendingPathComponent("source"); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data("one\ntwo\nthree\n".utf8).write(to:root.appendingPathComponent("notes.md"))
        try Data([0,1,2]).write(to:root.appendingPathComponent("data.bin"))
        try Data("private".utf8).write(to:root.appendingPathComponent("credentials.txt"))
        try Data([1,2,3]).write(to:root.appendingPathComponent("image.png"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("escape"),withDestinationURL:fixture)
        print("FIXTURE \(fixture.path) root \(root.path)")
        let access = NativeProjectAccess(); let grant = NativeProjectFolderGrant(id:"app",name:"App Source",root:root); access.update(grants:[grant])
        let listing = try access.perform(NativeProjectReadRequest(action:"list",folderID:"app"))
        try check((listing["excludedCount"] as? Int) == 4,"excluded image/binary/protected/link counts")
        for index in 1...3 {
            if index == 2 { access.update(grants:[grant]) }
            let repeated = try access.perform(.init(action:"list",folderID:"app",path:""))
            try check((repeated["entries"] as? [[String:String]]) == (listing["entries"] as? [[String:String]]) && repeated["excludedCount"] as? Int == 4,"root listing remains complete after earlier scan and grant refresh \(index)")
        }
        let read = try access.perform(NativeProjectReadRequest(action:"read",folderID:nil,path:"notes.md",startLine:2,lineCount:1))
        try check((read["lines"] as? [String]) == ["2: two"],"UTF-8 line ranges")
        try check(read["folderName"] as? String == "App Source","folder-qualified reference")
        let pastEnd = try access.perform(.init(action:"read",folderID:"app",path:"notes.md",startLine:Int.max,lineCount:200))
        try check((pastEnd["lines"] as? [String])?.isEmpty == true,"extreme line offset is empty rather than overflowing")
        try check(read["sha256"] as? String == NativeScopedRoot.sha256(Data("one\ntwo\nthree\n".utf8)),"ordinary file read includes exact content revision")
        let repeatedTree = try access.perform(.init(action:"tree",folderID:"app",depth:1))
        let rootSearch = try access.perform(.init(action:"search",folderID:"app",query:"two"))
        try check((repeatedTree["entries"] as? [[String:Any]])?.contains { $0["path"] as? String == "notes.md" } == true && (rootSearch["matches"] as? [[String:Any]])?.contains { $0["path"] as? String == "notes.md" } == true,"tree and search remain usable after repeated root scans")
        try rejects("traversal rejected") { _ = try access.perform(.init(action:"read",folderID:"app",path:"../outside")) }
        try rejects("symlink rejected") { _ = try access.perform(.init(action:"read",folderID:"app",path:"escape/outside")) }
        try rejects("credentials rejected") { _ = try access.perform(.init(action:"read",folderID:"app",path:"credentials.txt")) }
        try rejects("binary rejected") { _ = try access.perform(.init(action:"read",folderID:"app",path:"data.bin")) }
        let uuid = UUID().uuidString
        access.update(grants:[NativeProjectFolderGrant(id:uuid,name:"UUID folder",root:root)])
        let uuidRead = try access.perform(.init(action:"read",folderID:uuid.lowercased(),path:"notes.md"))
        try check(uuidRead["folderId"] as? String == uuid.lowercased(),"UUID folder identity is case canonical without broadening grants")
        access.update(grants:[])
        try rejects("disconnect revokes actual operation") { _ = try access.perform(.init(action:"read",folderID:"app",path:"notes.md")) }
        access.update(grants:[grant]); let moved = fixture.appendingPathComponent("moved")
        try FileManager.default.moveItem(at:root,to:moved); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try rejects("root inode replacement rejected") { _ = try access.perform(.init(action:"list",folderID:"app")) }
        let scoped = try NativeScopedRoot(moved); let bytes = try scoped.readData("notes.md",singleLink:true); let hash = NativeScopedRoot.sha256(bytes)
        try scoped.write("notes.md",data:Data("changed\n".utf8),expected:hash)
        try check(try String(contentsOf:moved.appendingPathComponent("notes.md"),encoding:.utf8) == "changed\n","hash-checked replacement")
        try rejects("stale hash rejected") { try scoped.write("notes.md",data:bytes,expected:hash) }
        try scoped.write("new.swift",data:Data("// new\n".utf8),expected:nil)
        try rejects("new-file overwrite rejected") { try scoped.write("new.swift",data:bytes,expected:nil) }
        try FileManager.default.linkItem(at:moved.appendingPathComponent("new.swift"),to:moved.appendingPathComponent("hard.swift"))
        try rejects("hard-linked Builder read rejected") { _ = try scoped.readData("hard.swift",singleLink:true) }
        try rejects("hard-linked Builder write rejected") { try scoped.write("hard.swift",data:bytes,expected:NativeScopedRoot.sha256(Data("// new\n".utf8))) }
        try rejects("malformed broker request rejected") { _ = try NativeBuilder.parseRequest("Maybe <<BUILDER_READ {}>>") }
        let source = fixture.appendingPathComponent("builder-source"); try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data("print(\"Hello\")\n".utf8).write(to:source.appendingPathComponent("greeting.swift"))
        let environment = ["PATH":"/usr/bin:/bin:/opt/homebrew/bin","HOME":NSHomeDirectory(),"GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_NOSYSTEM":"1"]
        for args in [["init"],["add","greeting.swift"],["-c","user.name=Fixture","-c","user.email=fixture@invalid.local","commit","-m","Fixture"]] {
            let result = try await NativeProcess.run(executable:"/usr/bin/git",arguments:args,directory:source,environment:environment)
            guard result.exitCode == 0 else { throw nativeFailure("Git fixture failed") }
        }
        var receipts: [[String:Any]] = []
        let delayed = FixtureBuilderTransport()
        let builder = NativeBuilder(onReceipt:{ receipts.append($0) },storageRoot:fixture.appendingPathComponent("runs"),makeTransport:{ delayed }, ownership: HostOwnershipDefault.coordinator)
        await builder.start(source:source,task:"Change greeting to Hello, Jason!",build:"/usr/bin/true",test:"/usr/bin/grep -q 'Hello, Jason!' greeting.swift",edit:true)
        try check(!delayed.overlappingSends,"terminal event waits for send acknowledgment before continuation")
        let final = receipts.last ?? [:]
        if final["status"] as? String != "review" { print(try nativeJSON(final)) }
        try check(final["status"] as? String == "review","isolated edit reaches review")
        try check(final["editingVerified"] as? Bool == true,"completed write plus diff evidence")
        try check(final["sourceUnchanged"] as? Bool == true,"source Git state unchanged")
        try check((final["steps"] as? [[String:Any]])?.allSatisfy({ $0["status"] as? String == "passed" }) == true,"exact command results")
        try check((final["diff"] as? String)?.contains("Hello, Jason!") == true,"actual diff evidence")
        try check(try String(contentsOf:source.appendingPathComponent("greeting.swift"),encoding:.utf8) == "print(\"Hello\")\n","original bytes preserved")
        if let path = final["worktreePath"] as? String { try check(FileManager.default.fileExists(atPath:URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("receipt.json").path),"durable final receipt") }
        let failedAck = FixtureBuilderTransport(); failedAck.failAcknowledgment = true
        let rejectedAck = NativeBuilder(onReceipt:{ receipts.append($0) },storageRoot:fixture.appendingPathComponent("ack-runs"),makeTransport:{ failedAck }, ownership: HostOwnershipDefault.coordinator)
        await rejectedAck.start(source:source,task:"Reject late failed acknowledgment",build:"/usr/bin/true",test:"",edit:true)
        try check(receipts.last?["status"] as? String == "failed" && (receipts.last?["fileOperations"] as? [[String:Any]])?.isEmpty == true,"late failed acknowledgment cannot execute broker operation")
        let noEdit = NativeBuilder(onReceipt:{ receipts.append($0) },storageRoot:fixture.appendingPathComponent("summary-runs"),makeTransport:{ FixtureBuilderTransport(edits:false) }, ownership: HostOwnershipDefault.coordinator)
        await noEdit.start(source:source,task:"Change greeting",build:"/usr/bin/true",test:"",edit:true)
        try check(receipts.last?["status"] as? String == "failed" && receipts.last?["editingVerified"] as? Bool == false,"agent summary is not edit evidence")
        let verifier = NativeBuilder(onReceipt:{ receipts.append($0) },storageRoot:fixture.appendingPathComponent("boundary-runs"), ownership: HostOwnershipDefault.coordinator)
        await verifier.start(source:source,task:"Verify source boundary",build:"/usr/bin/touch '"+source.appendingPathComponent("escaped.txt").path+"'",test:"",edit:false)
        try check(receipts.last?["status"] as? String == "failed" && !FileManager.default.fileExists(atPath:source.appendingPathComponent("escaped.txt").path),"command sandbox denies original-source writes")
        // The probe file must be inside HOME for the denial to apply; a checkout
        // outside HOME (for example under /private/tmp) cannot exercise this rule.
        if FileManager.default.currentDirectoryPath.hasPrefix(NSHomeDirectory() + "/") {
            let readBoundary = NativeBuilder(onReceipt:{ receipts.append($0) },storageRoot:fixture.appendingPathComponent("read-boundary-runs"), ownership: HostOwnershipDefault.coordinator)
            await readBoundary.start(source:source,task:"Verify private home reads denied",build:"/bin/cat '"+FileManager.default.currentDirectoryPath+"/Package.swift'",test:"",edit:false)
            try check(receipts.last?["status"] as? String == "failed","command sandbox denies unrelated home reads")
        } else { print("SKIP command sandbox denies unrelated home reads (checkout is outside HOME; run from a checkout under HOME)") }
        let metadataBoundary = NativeBuilder(onReceipt:{ receipts.append($0) },storageRoot:fixture.appendingPathComponent("git-boundary-runs"), ownership: HostOwnershipDefault.coordinator)
        await metadataBoundary.start(source:source,task:"Verify Git metadata protected",build:"/usr/bin/git update-ref refs/heads/not-approved HEAD",test:"",edit:false)
        try check(receipts.last?["status"] as? String == "failed","command sandbox denies private Git metadata writes")
        let insideStorage = NativeBuilder(onReceipt:{ receipts.append($0) },storageRoot:source.appendingPathComponent("not-allowed"), ownership: HostOwnershipDefault.coordinator)
        await insideStorage.start(source:source,task:"Reject overlapping storage",build:"/usr/bin/true",test:"",edit:false)
        try check(receipts.last?["status"] as? String == "failed" && !FileManager.default.fileExists(atPath:source.appendingPathComponent("not-allowed").path),"overlapping storage rejected before touching source")
        let stopBuilder = NativeBuilder(onReceipt:{ receipts.append($0) },storageRoot:fixture.appendingPathComponent("stop-runs"), ownership: HostOwnershipDefault.coordinator)
        let job = Task { @MainActor in await stopBuilder.start(source:source,task:"Stop fixture",build:"/bin/sleep 60 & child=$!; printf '%s' \"$child\" > child.pid; wait",test:"/usr/bin/false",edit:false) }
        var childPID: Int32?
        for _ in 0..<200 {
            if let path = receipts.last?["worktreePath"] as? String, let text = try? String(contentsOfFile:URL(fileURLWithPath:path).appendingPathComponent("child.pid").path,encoding:.utf8), let pid = Int32(text) { childPID = pid; break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        try check(childPID != nil,"stop fixture spawned owned descendant")
        stopBuilder.stop(); await job.value
        try check(receipts.last?["status"] as? String == "stopped","Stop preserves terminal stopped receipt")
        try check((receipts.last?["steps"] as? [[String:Any]])?.count == 1,"Stop does not run later test command")
        if let childPID { try check(kill(childPID,0) != 0 && errno == ESRCH,"Stop terminates owned descendant process group") }
        print("\(passed) Native access/Builder checks passed. Fixture: \(fixture.path)")
    }
}
