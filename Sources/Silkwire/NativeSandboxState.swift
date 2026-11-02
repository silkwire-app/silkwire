import Foundation
import Darwin

enum NativeSandboxState {
    /// Ask the kernel, never an inherited environment flag. A missing API means
    /// no optimization: the normal sandbox launcher must succeed or fail closed.
    static var isSandboxed: Bool {
        guard let library = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_LAZY) else { return false }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "sandbox_check") else { return false }
        let check = unsafeBitCast(symbol, to: (@convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32).self)
        return check(getpid(), nil, 0) == 1
    }
    /// Read system-owned toolchain selection, avoiding xcrun/xcodebuild service
    /// discovery inside a command sandbox. These paths grant no permissions.
    static var appleToolchain: (compiler: String, sdk: String, developer: String)? {
        let files = FileManager.default
        let selected = URL(fileURLWithPath: "/var/db/xcode_select_link").resolvingSymlinksInPath()
        let developer = files.fileExists(atPath: selected.path) ? selected : URL(fileURLWithPath: "/Library/Developer/CommandLineTools")
        for (compiler, sdk) in [("Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"), ("usr/bin/swiftc", "SDKs/MacOSX.sdk")] {
            let executable = developer.appendingPathComponent(compiler), platform = developer.appendingPathComponent(sdk)
            if files.isExecutableFile(atPath: executable.path), files.fileExists(atPath: platform.path) {
                return (executable.path, platform.path, developer.path)
            }
        }
        return nil
    }
}
