import Foundation
import Darwin

@main struct StagingInstallerMemoryTests {
    static func main() throws {
        setbuf(stdout, nil)
        let files = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/Silkwire-HashMemory-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 8 MiB on disk, 512 MiB of logical reads. No owner data or large allocation.
        let original = root.appendingPathComponent("000.bin")
        try Data(repeating: 0x5a, count: 8 * 1024 * 1024).write(to: original)
        for index in 1..<64 { try files.linkItem(at: original, to: root.appendingPathComponent(String(format: "%03d.bin", index))) }
        let sem = DispatchSemaphore(value: 0)
        final class Result: @unchecked Sendable { var failure: Error?; var metrics: [String: Any] = [:] }
        let result = Result()
        DispatchQueue(label: "installer.hash-memory-test", autoreleaseFrequency: .workItem).async {
            defer { sem.signal() }
            do {
                try autoreleasepool {
                    let before = try Self.rss()
                    let inventory = try StagingInstaller.manifest(root)
                    let after = try Self.rss(), growth = max(0, after - before)
                    result.metrics = ["files": inventory.count, "logicalBytesHashed": 512 * 1024 * 1024, "rssBefore": before, "rssAfter": after, "growthBytes": growth]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: result.metrics, options: [.sortedKeys]), as: UTF8.self))
                    guard inventory.count == 64, Set(inventory.values).count == 1, growth < 96 * 1024 * 1024 else {
                        throw NSError(domain: "InstallerMemory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Hashing retained too much memory or changed the digest: \(growth) bytes growth"])
                    }
                }
            } catch { result.failure = error }
        }
        sem.wait()
        try JSONSerialization.data(withJSONObject: result.metrics, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("results.json"))
        if let failure = result.failure { throw failure }
        print("PASS: 512 MiB hash workload remains below 96 MiB RSS growth; identical file digests. Evidence: " + root.path)
    }
    nonisolated private static func rss() throws -> Int {
            let job = Process(), pipe = Pipe(); job.executableURL = URL(fileURLWithPath: "/bin/ps"); job.arguments = ["-p", String(getpid()), "-o", "rss="]; job.standardOutput = pipe
            try job.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); job.waitUntilExit()
            return (Int(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) * 1024
        }

}
