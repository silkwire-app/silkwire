import Foundation

/// Recover the exact installed source into a new directory. Existing branches and checkouts are never reset.
enum StagingSourceArchive {
    struct Manifest: Codable {
        let revision: String
        let sourceDigest: String
        let bundleSHA256: String
    }
    static func restore(app: URL, destination: URL) throws -> URL {
        let identity = try StagingInstaller.identify(app)
        guard identity.signatureValid, identity.sourceStatus == "clean" else {
            throw nativeFailure("The installed Staging build has no verified clean source archive. Its existing source was not replaced.")
        }
        let source = app.appendingPathComponent("Contents/Resources/Source")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        guard manifest.revision == identity.revision, manifest.sourceDigest == identity.sourceDigest else {
            throw nativeFailure("Installed source provenance does not match the app. Nothing restored.")
        }
        return try restore(archive: source.appendingPathComponent("source.bundle"), manifest: manifest, destination: destination)
    }
    static func restore(archive: URL, manifest: Manifest, destination: URL) throws -> URL {
        guard manifest.revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              StagingInstaller.sha(try Data(contentsOf: archive)) == manifest.bundleSHA256,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw nativeFailure("Source archive is invalid or the destination already exists. No existing source was changed.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func git(_ args: [String]) throws {
            let job = Process(); job.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            job.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=always"] + args
            job.currentDirectoryURL = destination
            job.environment = ["PATH": "/usr/bin:/bin", "HOME": destination.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
            job.standardOutput = FileHandle.nullDevice; job.standardError = FileHandle.nullDevice
            try job.run(); job.waitUntilExit()
            guard job.terminationStatus == 0 else { throw nativeFailure("Source recovery failed at git \(args.first ?? ""). The partial copy was retained at \(destination.path).") }
        }
        try git(["init", "-q"])
        try git(["fetch", "--no-tags", archive.path, "HEAD"])
        try git(["checkout", "-q", "-b", "preserved/installed-" + manifest.revision, "FETCH_HEAD"])
        let recovered = try StagingInstaller.sourceDigest(destination)
        guard recovered.clean, recovered.headCommit == manifest.revision, recovered.digest == manifest.sourceDigest else {
            throw nativeFailure("Recovered source did not match the installed source digest. The copy was retained for inspection; nothing was connected.")
        }
        return destination
    }
}
