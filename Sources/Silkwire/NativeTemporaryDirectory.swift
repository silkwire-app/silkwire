import Foundation
import Darwin

/// Workspace scratch storage must not inherit the app's protected data location.
/// Use the OS temporary area, with a real path and an exclusive
/// mode-0700 leaf. No fallback into Application Support or the shared /tmp alias.
enum NativeTemporaryDirectory {
    static func canonical(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw nativeFailure("Cannot resolve native temporary storage.") }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    static func systemParent() throws -> URL {
        // confstr(_CS_DARWIN_USER_TEMP_DIR) and NSTemporaryDirectory can both
        // return inherited TMPDIR. A fixed OS temporary parent avoids that loop.
        return try canonical(URL(fileURLWithPath: "/private/tmp"))
    }
    static func createWorkspace() throws -> URL {
        let parent: URL
        if NativeSandboxState.isSandboxed {
            // Nested native tests inherit the host's private scratch leaf. A new
            // sibling under /private/tmp is correctly denied by that host profile.
            let inherited = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) }
            let brokerParent = ProcessInfo.processInfo.environment[NativeCommandBroker.environmentKey].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            guard let candidate = [inherited, brokerParent].compactMap({ $0 }).compactMap({ try? canonical($0) }).first(where: { candidate in
                guard candidate.path.hasPrefix("/private/tmp/") || candidate.path.hasPrefix("/private/var/folders/"),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path) else { return false }
                return (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            }) else { throw nativeFailure("Nested workspace requires a private OS temporary directory from its host.") }
            parent = candidate
        } else { parent = try systemParent() }
        var template = Array(parent.appendingPathComponent("Silkwire-Workspace-XXXXXX").path.utf8CString)
        guard let path = mkdtemp(&template) else { throw nativeFailure("Cannot create private workspace temporary storage (errno \(errno)).") }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}
