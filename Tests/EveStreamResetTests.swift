import Foundation

// Synthetic transport, production room routing. No real provider or executable.
@MainActor final class ResetProbeTransport: NativeAgentTransport {
    var eventHandler: ((NativeAgentEvent) -> Void)?
    var identity: ProviderIdentity?
    var prompts: [String] = []
    func connect(_ previous: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity {
        let value = previous ?? ProviderIdentity(id: UUID().uuidString, started: false)
        identity = value; return value
    }
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws { prompts.append(text) }
    func stop() async throws { eventHandler?(.finished(status: "interrupted", message: nil)) }
    func stopPrevious() async throws {}
    func close() {}
    func connectionDetail() async throws -> ConnectionDetail { throw nativeFailure("Synthetic fixture") }
}

@MainActor final class ResetProbeRoom {
    let transport = ResetProbeTransport()
    let requestID = UUID().uuidString
    var events: [[String: Any]] = []
    var visible = ""
    lazy var room = NativeRoom(emit: { [weak self] event in
        guard let self else { return }
        self.events.append(event)
        if event["type"] as? String == "replace" { self.visible = event["text"] as? String ?? "" }
        if event["type"] as? String == "delta" { self.visible += event["text"] as? String ?? "" }
    }, factory: { [unowned self] _, _ in self.transport })
    func start(folder: URL) async throws {
        await room.dispatch(["action": "connect", "conversationID": UUID().uuidString, "participants": ["eve"], "projectFolders": [["id": "notes", "name": "Synthetic notes", "root": folder.path]]])
        await room.dispatch(["action": "send", "requestId": requestID, "text": "Synthetic stream reset probe", "targets": ["eve"]])
        try await EveStreamResetTests.wait("dispatch") { self.transport.prompts.count == 1 }
    }
    var settled: Bool { events.contains { $0["type"] as? String == "settled" && $0["requestId"] as? String == requestID } }
    var terminal: String? { events.last { $0["type"] as? String == "finished" && $0["requestId"] as? String == requestID }?["status"] as? String }
    func emit(_ event: NativeAgentEvent) { transport.eventHandler?(event) }
}

@MainActor @main struct EveStreamResetTests {
    static var checks = 0, failures = 0
    static func check(_ value: Bool, _ label: String) {
        checks += 1
        if value { print("PASS: " + label) } else { failures += 1; print("FAIL: " + label) }
    }
    static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { throw nativeFailure("Fixture timeout: " + label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-stream-reset-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "SYNTHETIC-RESET-TOKEN".write(to: root.appendingPathComponent("known.txt"), atomically: true, encoding: .utf8)
        let preview = "Previously published prose"
        let replacement = ResetProbeRoom()
        try await replacement.start(folder: root)
        replacement.emit(.delta(preview))
        let resets: [NativeAgentEvent] = [.replace(""), .replace(""), .delta(""), .replace(" \n ")]
        for event in resets { replacement.emit(event) }
        check(replacement.visible == preview, "empty and whitespace resets retain the published preview")
        replacement.emit(.delta("New answer"))
        check(replacement.visible == " \n New answer", "first post-reset delta replaces, never concatenates the old preview")
        replacement.emit(.delta(" continues"))
        check(replacement.visible == " \n New answer continues", "subsequent deltas append only to the new answer")
        replacement.emit(.replace("Final corrected answer"))
        check(replacement.visible == "Final corrected answer", "nonempty authoritative replacement remains authoritative")
        replacement.emit(.finished(status: "completed", message: nil))
        try await wait("replacement settles") { replacement.settled }
        check(replacement.terminal == "completed" && replacement.transport.prompts.count == 1, "normal completion does not duplicate dispatch")
        replacement.room.close()

        for status in ["completed", "interrupted", "failed", "cancelled", "unconfirmed"] {
            let probe = ResetProbeRoom(); try await probe.start(folder: root)
            probe.emit(.delta(preview)); probe.emit(.replace(""))
            probe.emit(.finished(status: status, message: "Synthetic terminal"))
            try await wait("terminal settles") { probe.settled }
            check(probe.visible == preview, status + ": terminal event retains preview")
            check(probe.terminal == (status == "completed" ? "failed" : status), status + ": stale preview is not promoted to logical success")
            probe.room.close()
        }

        let markers = ["<<READ_PROJECT {\"action\":\"list\"}>>", "<<WORK_PROJECT {\"action\":\"board\"}>>", "<<INSPECT_WEB {\"url\":\"https://invalid.example/\"}>>", "<<COMPUTER {\"action\":\"screenshot\"}>>"]
        for marker in markers {
            for directReplacement in [false, true] {
                let probe = ResetProbeRoom(); try await probe.start(folder: root)
                probe.emit(.delta(preview))
                let offset = probe.events.count
                if directReplacement { probe.emit(.replace(marker)) }
                else {
                    probe.emit(.replace(""))
                    for character in marker { probe.emit(.delta(String(character))) }
                }
                // Failure must not flush a hidden command into the transcript. No command executes.
                probe.emit(.finished(status: "failed", message: "Synthetic failure before execution"))
                try await wait("hidden command settles") { probe.settled }
                let textEvents = probe.events.dropFirst(offset).filter { ["delta", "replace"].contains($0["type"] as? String ?? "") }
                check(textEvents.isEmpty && probe.visible == preview, "command remains hidden across replacement/reset and failure: " + marker.components(separatedBy: " ")[0])
                check(probe.transport.prompts.count == 1, "failed command causes no broker continuation")
                probe.room.close()
            }
        }

        let read = ResetProbeRoom(); try await read.start(folder: root)
        read.emit(.delta(preview)); read.emit(.replace(""))
        let offset = read.events.count
        let command = "<<READ_PROJECT {\"action\":\"read\",\"folderId\":\"notes\",\"path\":\"known.txt\"}>>"
        for character in command { read.emit(.delta(String(character))) }
        read.emit(.finished(status: "completed", message: nil))
        try await wait("actual private broker continuation") { read.transport.prompts.count == 2 }
        check(read.transport.prompts.last?.contains("SYNTHETIC-RESET-TOKEN") == true, "reset does not bypass or break the scoped reader")
        check(!read.events.dropFirst(offset).contains { ["delta", "replace"].contains($0["type"] as? String ?? "") }, "validated reader command emits no transient raw fragments")
        read.emit(.delta("Answer after read")); read.emit(.finished(status: "completed", message: nil))
        try await wait("reader settles") { read.settled }
        check(read.visible == "Answer after read" && read.terminal == "completed", "broker continuation replaces the retained preview with its actual answer")
        read.room.close()
        print("EveStreamResetTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
