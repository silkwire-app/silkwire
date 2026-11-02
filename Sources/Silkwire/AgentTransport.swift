import Foundation

// App-owned provider boundary. External runtimes remain external integrations.
enum NativeAgentRole { case conversation, builder }
enum NativeAgentEvent {
    case identity(ProviderIdentity)
    case activity(String)
    case delta(String)
    case replace(String)
    case finished(status: String, message: String?)
    case disconnected(message: String, uncertain: Bool)
    case recovery(requestID: String, status: String, text: String?)
}
@MainActor protocol NativeAgentTransport: AnyObject {
    var eventHandler: ((NativeAgentEvent) -> Void)? { get set }
    var identity: ProviderIdentity? { get }
    func connect(_ identity: ProviderIdentity?, capabilities: String) async throws -> ProviderIdentity
    func send(text: String, requestID: String, attachments: [Attachment], capabilities: String) async throws
    func stop() async throws
    func stopPrevious() async throws
    func close()
    func connectionDetail() async throws -> ConnectionDetail
}
struct NativeProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var truncated: Bool
}
struct NativeProjectFolderGrant: Sendable {
    var id: String
    var name: String
    var root: URL
}
struct NativeBuildArtifact: Sendable {
    var id: String
    var text: String
    /// Transcript state of the receipt entry (streaming, completed, failed, interrupted, unconfirmed).
    var state = ""
}
struct NativeProjectReadRequest: Sendable {
    var action: String
    var folderID: String?
    var path: String = ""
    var startLine = 1
    var lineCount = 100
    var artifactID: String?
    var query: String?
    var depth = 3
}
func nativeJSON(_ value: Any) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), encoding: .utf8) ?? ""
}
func nativeEncoded<T: Encodable>(_ value: T) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) as? [String: Any] ?? [:]
}
func nativeFailure(_ text: String) -> NSError { NSError(domain: "Silkwire", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
