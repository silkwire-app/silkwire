import Foundation

@MainActor final class ConnectionFixture: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    let agent: String
    var connectCount = 0, closed = false, capabilities = ""
    var connectionDelay = 0.0
    init(_ agent:String) { self.agent = agent }
    func connect(_ saved:ProviderIdentity?, capabilities:String) async throws -> ProviderIdentity {
        connectCount += 1; self.capabilities = capabilities
        if connectionDelay > 0 { try await Task.sleep(for: .seconds(connectionDelay)) }
        identity = saved ?? ProviderIdentity(id:UUID().uuidString,started:false)
        return identity!
    }
    func send(text:String,requestID:String,attachments:[Attachment],capabilities:String) async throws { preconditionFailure("Connection tests must never send") }
    func stop() async throws {}
    func stopPrevious() async throws {}
    func close() { closed = true }
    func connectionDetail() async throws -> ConnectionDetail {
        if agent == "codex" { try await Task.sleep(for:.milliseconds(100)) }
        return ConnectionDetail(agent:agent,installed:true,signedIn:true,account:"Synthetic account",model:"Fixture",effort:"Default",speed:"Default",permissions:"Fixture",usage:[],models:[],note:nil)
    }
}
@main struct ConnectionLifecycleTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); checks += 1; print("PASS: " + label) }
        func wait(_ condition:()->Bool) async throws {
            for _ in 0..<300 { if condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
            throw nativeFailure("Connection fixture timed out")
        }
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/connection-lifecycle-\(UUID())")
        let folder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let bookmark = try folder.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
        let grant = ProjectFolder(name:"App Source",path:folder.resolvingSymlinksInPath().path,bookmark:bookmark)
        check(try nativeResolveProjectFolder(grant).path == folder.path,"ordinary persistent bookmark resolves existing granted root")
        var wrong = grant; wrong.path += "-other"
        check((try? nativeResolveProjectFolder(wrong)) == nil,"resolved bookmark never grants a different stored path")
        var broken = grant; broken.bookmark = Data("not a bookmark".utf8)
        check((try? nativeResolveProjectFolder(broken)) == nil,"malformed bookmark cannot fall back to path-only access")
        var project = Project(); project.name = "Fixture"; project.folders = [broken]
        var conversation = Conversation(); conversation.projectID = project.id; conversation.draft = "Keep my draft"
        let directory = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(ConversationWorkspace(activeID:conversation.id,conversations:[conversation],projects:[project])).write(to:directory.appendingPathComponent("workspace.json"))
        var made:[ConnectionFixture] = []
        let store = ConversationStore(directory:directory,transportFactory:{ agent,_ in let transport = ConnectionFixture(agent); made.append(transport); return transport })
        await store.start()
        try await wait { !store.connecting && made.count == 3 }
        check(store.seats.values.allSatisfy { $0.state == "connected" },"unavailable folder cannot prevent provider connections")
        check(store.folderIssues[broken.id] != nil && made.allSatisfy { !$0.capabilities.contains("App Source") },"unavailable folder is visible but never granted to provider broker")
        let count = made.count, ids = store.conversation.identities.mapValues(\.id)
        await store.start(); await Task.yield()
        check(made.count == count && store.conversation.identities.mapValues(\.id) == ids,"repeated production view startup preserves live room and provider identities")
        store.disconnect()
        store.refreshConnections()
        try await wait { !store.connectionDetails.isEmpty }
        check(store.connectionsLoading && store.connectionDetails.count < 3,"independent account results publish before slow provider finishes")
        try await wait { !store.connectionsLoading }
        check(store.connectionDetails.count == 3,"account inspection works without initialized provider seats")
        store.recoverAgent("codex")
        try await wait { !store.connecting && store.seats["codex"]?.state == "connected" }
        check(store.seats.values.allSatisfy { $0.state == "connected" },"Connect from inspection-only room initializes room instead of stuck recovery")
        check(store.conversation.draft == conversation.draft && store.conversation.messages.isEmpty,"connection lifecycle never dispatches or clears draft")
        store.shutdown()
        var events:[[String:Any]] = []
        let room = NativeRoom(emit:{ events.append($0) },factory:{ agent,_ in ConnectionFixture(agent) })
        await room.dispatch(["action":"reconnectAgent","agent":"codex"])
        check(events.contains { $0["type"] as? String == "connection" && $0["state"] as? String == "disconnected" },"missing seat recovery emits a terminal disconnected state")
        check(events.contains { $0["type"] as? String == "recoveryReady" && $0["message"] as? String != nil },"failed recovery carries readable reason")
        room.close()
        for useOuterWatchdog in [false, true] {
            var partialEvents: [[String: Any]] = [], transports: [String: ConnectionFixture] = [:]
            let partial = NativeRoom(emit: { partialEvents.append($0) }, factory: { agent, _ in
                let transport = ConnectionFixture(agent)
                if agent == "codex", transports[agent] == nil { transport.connectionDelay = 0.2 }
                transports[agent] = transport; return transport
            }, connectionTimeout: useOuterWatchdog ? 5 : 0.05)
            let initial = Task { await partial.dispatch(["action": "connect", "conversationID": UUID().uuidString, "participants": agents]) }
            try await wait { partialEvents.filter { $0["state"] as? String == "connected" }.count == 2 }
            if useOuterWatchdog { partial.expireConnections() }
            try await wait { partialEvents.contains { $0["type"] as? String == "ready" } }
            check(transports["codex"]?.closed == true && transports["eve"]?.closed == false && transports["claude"]?.closed == false, "\(useOuterWatchdog ? "outer watchdog" : "per-provider deadline") closes only lagging provider and preserves healthy teammates")
            await partial.dispatch(["action": "reconnectAgent", "agent": "codex"])
            await initial.value
            check(partialEvents.filter { $0["agent"] as? String == "codex" && $0["state"] as? String == "connected" }.count == 1 && partialEvents.filter { $0["type"] as? String == "ready" }.count == 1, "targeted retry succeeds; late original completion cannot overwrite it or duplicate readiness")
            check(transports["eve"]?.connectCount == 1 && transports["claude"]?.connectCount == 1, "targeted retry never reconnects or replays healthy teammates")
            partial.close()
        }
        print("PASS: \(checks) bookmark, production startup, partial inspection and recovery lifecycle checks")
    }
}
