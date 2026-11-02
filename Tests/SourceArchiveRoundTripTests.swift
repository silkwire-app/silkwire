import Foundation

@main struct SourceArchiveRoundTripTests {
    static func main() throws {
        guard let path = ProcessInfo.processInfo.environment["SILKWIRE_CANDIDATE_APP"] else {
            throw nativeFailure("Set SILKWIRE_CANDIDATE_APP to the built candidate bundle; no installed app is opened or changed.")
        }
        let app = URL(fileURLWithPath: path)
        let identity = try StagingInstaller.identify(app)
        let destination = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("silkwire-source-roundtrip-" + UUID().uuidString)
        let source = try StagingSourceArchive.restore(app: app, destination: destination)
        let recovered = try StagingInstaller.sourceDigest(source)
        precondition(identity.signatureValid && recovered.clean && recovered.headCommit == identity.revision && recovered.digest == identity.sourceDigest)
        print("PASS signed candidate source archive round trip: " + identity.revision + " · source SHA-256 " + recovered.digest)
        print("Recovered into a new directory; no installed app, source branch, library or account changed.")
    }
}
