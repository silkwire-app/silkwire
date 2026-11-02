import Foundation

// Scan each incoming byte once, not the accumulated prefix on every pipe read.
// A resumed provider thread can be megabytes and arrive in thousands of chunks.
struct NativeJSONLineFramer {
    private var partial = Data()
    let limit: Int
    init(limit: Int = 36 * 1024 * 1024) { self.limit = limit }
    mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0
            for index in bytes.indices where bytes[index] == 10 {
                guard partial.count + index - start <= limit else { throw nativeFailure("Codex event exceeded the local bound.") }
                partial.append(contentsOf: bytes[start..<index])
                if !partial.isEmpty { lines.append(partial) }
                partial = Data(); start = index + 1
            }
            guard partial.count + bytes.count - start <= limit else { throw nativeFailure("Codex event exceeded the local bound.") }
            partial.append(contentsOf: bytes[start..<bytes.count])
        }
        return lines
    }
}

// Framing AND JSON decoding stay off the UI actor. One queue preserves wire
// order; main-actor delivery still applies RPC/turn/generation fences.
final class NativeJSONLineDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.silkwire.codex-json." + UUID().uuidString, qos: .userInitiated)
    private var framer = NativeJSONLineFramer()
    private var failed = false
    func finish(_ deliver: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: deliver) }
    }
    func receive(_ chunk: Data, deliver: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [self] in
            guard !failed else { return }
            do {
                for line in try framer.append(chunk) {
                    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { throw nativeFailure("Codex returned invalid JSON.") }
                    DispatchQueue.main.async { deliver(.success(message)) }
                }
            } catch {
                failed = true
                // No raw parser diagnostics: they can contain provider content.
                let message = error.localizedDescription
                DispatchQueue.main.async { deliver(.failure(nativeFailure(message))) }
            }
        }
    }
}
