// swift-tools-version: 6.0
import PackageDescription
import Foundation
let testing = ProcessInfo.processInfo.environment["SILKWIRE_TESTING"] == "1"
let package = Package(
    name: "Silkwire",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Silkwire", targets: ["Silkwire"])],
    targets: [.executableTarget(name: "Silkwire", path: "Sources/Silkwire", swiftSettings: testing ? [.define("SILKWIRE_TESTING")] : [], linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit"), .linkedFramework("UserNotifications"), .linkedFramework("CryptoKit")])],
    swiftLanguageModes: [.v5]
)
