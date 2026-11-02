import Foundation

/// Import committed source from an explicitly granted Project folder. A bundle
/// supplies source, never permissions, provider identities or executable hooks.
enum StagingBundleImport {
    static func restore(root: URL, path: String, revision: String, sha256: String, destination: URL, physicalEvidence: HostLocalExecutionEvidence? = nil,
                        authorize: @escaping @MainActor () throws -> Void = {}) async throws -> URL {
        try await authorize()
        guard revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw nativeFailure("Bundle import needs the exact 40-character revision and 64-character SHA-256 from its receipt.")
        }
        let reader = try NativeScopedRoot(root)
        let bytes = try await Task.detached(priority: .utility) {
            let data = try reader.readGitBundle(path)
            guard NativeScopedRoot.sha256(data) == sha256 else { throw nativeFailure("Git bundle SHA-256 does not match; no source imported.") }
            return data
        }.value
        try Task.checkCancellation()
        try await authorize()
        // The coordinator supplies a new UUID destination in private managed
        // storage. Never reuse a checkout, reset a branch, or write the input root.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let archive = destination.appendingPathComponent("input.bundle"), source = destination.appendingPathComponent("source")
        try bytes.write(to: archive, options: [.withoutOverwriting])
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let environment = await NativeBuilder.commandEnvironment(temporary: destination)
        func git(_ arguments: [String]) async throws -> String {
            try Task.checkCancellation()
            try await authorize()
            let inheritedSandbox = NativeSandboxState.isSandboxed
            if inheritedSandbox { try await physicalEvidence?.invalidateExternalWork("Nested bundle preparation inherits the outer sandbox without an independent inner exit witness.") }
            let safe = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never", "-c", "protocol.file.allow=always", "-c", "transfer.fsckObjects=true"] + arguments
            let result = try await NativeProcess.run(executable: inheritedSandbox ? "/usr/bin/git" : "/usr/bin/sandbox-exec", arguments: inheritedSandbox ? safe : ["-p", NativeBuilder.privatePreparationSandbox(writable: [destination]), "/usr/bin/git"] + safe, directory: source, environment: environment, timeoutSeconds: 60, outputLimit: 65536, physicalEvidence: inheritedSandbox ? nil : physicalEvidence, sandboxedPrivate: !inheritedSandbox)
            try Task.checkCancellation()
            try await authorize()
            guard result.exitCode == 0, !result.truncated else { throw nativeFailure("Git bundle import failed at \(arguments.first ?? "git"): " + limitedUTF16(result.stderr, to: 2000)) }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "--template="])
        _ = try await git(["bundle", "verify", "--", archive.path])
        let heads = try await git(["bundle", "list-heads", archive.path])
        guard let reference = heads.split(separator: "\n").compactMap({ line -> String? in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == revision, parts[1] == "HEAD" || parts[1].hasPrefix("refs/heads/") else { return nil }
            return String(parts[1])
        }).first else { throw nativeFailure("The bundle does not advertise the requested revision. No different revision was substituted.") }
        _ = try await git(["fetch", "-q", "--no-tags", archive.path, reference])
        guard try await git(["rev-parse", "FETCH_HEAD"]) == revision else { throw nativeFailure("Imported revision does not match its receipt.") }
        _ = try await git(["checkout", "-q", "-b", "imported/" + revision, revision])
        guard try await git(["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty else { throw nativeFailure("Imported source is not clean; nothing connected.") }
        try reader.verifyRoot()
        return source
    }
}
