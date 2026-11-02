import Foundation

@main struct NativeJSONLinesTests {
    @MainActor static func main() async throws {
        func check(_ condition: Bool, _ name: String) { precondition(condition, name); print("PASS: " + name) }
        let payload = Data("\n{\"text\":\"café 👻\\nnext\"}\n{\"id\":2}\n".utf8)
        var framer = NativeJSONLineFramer(), lines: [Data] = []
        for byte in payload { lines += try framer.append(Data([byte])) }
        let first = try JSONSerialization.jsonObject(with: lines[0]) as? [String: String]
        check(lines.count == 2 && first?["text"] == "café 👻\nnext", "byte-fragmented UTF-8 and escaped newlines preserve frames and order")
        var bounded = NativeJSONLineFramer(limit: 4)
        _ = try bounded.append(Data("1234".utf8))
        check(try bounded.append(Data([10])).first == Data("1234".utf8), "exact frame bound allows terminating newline")
        do { _ = try bounded.append(Data("12345".utf8)); preconditionFailure("Oversized frame accepted") } catch {}
        print("PASS: unterminated oversized frame rejected")
        var many = NativeJSONLineFramer(limit: 2)
        check(try many.append(Data("{}\n{}\n{}\n".utf8)).count == 3, "bounds apply per frame rather than coalesced pipe chunk")
        let body = Data(("{\"id\":1,\"result\":\"" + String(repeating: "x", count: 12 * 1024 * 1024) + "\"}\n").utf8)
        let decoder = NativeJSONLineDecoder()
        var delivered: [Int] = [], errors = 0, worstGap = 0.0
        let heartbeat = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                worstGap = max(worstGap, Date().timeIntervalSince(last)); last = Date()
            }
        }
        defer { heartbeat.cancel() }
        let start = Date()
        for offset in stride(from: 0, to: body.count, by: 16384) {
            decoder.receive(body.subdata(in: offset..<min(body.count, offset + 16384))) { result in
                switch result { case .success(let message): delivered.append(message["id"] as! Int); case .failure: errors += 1 }
            }
        }
        decoder.receive(Data("{\"id\":2}\n".utf8)) { if case .success(let message) = $0 { delivered.append(message["id"] as! Int) } }
        var drained = false
        decoder.finish { drained = delivered == [1, 2] }
        for _ in 0..<1000 {
            if delivered.count == 2 || errors > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let elapsed = Date().timeIntervalSince(start)
        check(delivered == [1, 2] && drained && errors == 0 && elapsed < 3, "12 MiB JSON frame in 16 KiB chunks decodes promptly and drains before exit callback")
        check(worstGap < 0.25, "large fragmented decoding keeps UI actor heartbeat responsive")
        print(String(format: "Large-frame decode %.3f s; worst UI heartbeat gap %.3f s", elapsed, worstGap))
        let invalid = NativeJSONLineDecoder()
        var results: [String] = []
        let receive: (Result<[String: Any], Error>) -> Void = { result in
            switch result { case .success: results.append("success"); case .failure(let error): results.append(error.localizedDescription) }
        }
        invalid.receive(Data("{private-invalid-content}\n".utf8), deliver: receive)
        invalid.receive(Data("{\"id\":3}\n".utf8), deliver: receive)
        try await Task.sleep(for: .milliseconds(100))
        check(results == ["Codex returned invalid JSON."], "invalid input fails closed without exposing parser content or delivering later frames")
    }
}
