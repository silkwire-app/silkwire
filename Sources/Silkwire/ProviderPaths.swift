import Foundation

/// Where provider command-line tools usually live: Apple-silicon Homebrew, Intel Homebrew,
/// then the user's own ~/.local/bin. The first executable found wins.
enum ProviderPaths {
    static var codex: String {
        firstExecutable(["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home(".local/bin/codex")]) ?? "/opt/homebrew/bin/codex"
    }
    static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private static func home(_ path: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path).path
    }
}
