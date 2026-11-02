#!/usr/bin/env swift
import Foundation
import CryptoKit

// Explicit asset-authoring step, not part of Builder's restricted command run.
// Apple's actool uses ibtoold/global scratch space on the current toolchain.
// Keep static native brand resources versioned and fail normal builds on source drift.
let files = FileManager.default
let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
func capture(_ arguments: [String]) throws -> String {
    let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath:"/usr/bin/xcrun"); process.arguments = arguments; process.standardOutput = pipe
    try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    return String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
}
do {
    let source = root.appendingPathComponent("Resources/Assets/Colors.xcassets")
    let stage = root.appendingPathComponent("output/palette-\(UUID())")
    let destination = root.appendingPathComponent("Resources/Compiled/macOS")
    try files.createDirectory(at:stage,withIntermediateDirectories:true)
    _ = try capture(["actool",source.path,"--compile",stage.path,"--platform","macosx","--minimum-deployment-target","14.0","--output-partial-info-plist",stage.appendingPathComponent("asset-info.plist").path])
    let data = try Data(contentsOf:stage.appendingPathComponent("Assets.car"))
    let iconset = stage.appendingPathComponent("Silkwire.iconset")
    try files.createDirectory(at:iconset,withIntermediateDirectories:true)
    let iconSource = root.appendingPathComponent("Resources/Assets/SilkwireAppIcon-1024.png")
    for (size,name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")] {
        let job = Process(); job.executableURL = URL(fileURLWithPath:"/usr/bin/sips"); job.arguments = ["-z","\(size)","\(size)",iconSource.path,"--out",iconset.appendingPathComponent(name+".png").path]; job.standardOutput = FileHandle.nullDevice
        try job.run(); job.waitUntilExit(); guard job.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }
    let iconJob = Process(); iconJob.executableURL = URL(fileURLWithPath:"/usr/bin/iconutil"); iconJob.arguments = ["-c","icns",iconset.path,"-o",stage.appendingPathComponent("Silkwire.icns").path]
    try iconJob.run(); iconJob.waitUntilExit(); guard iconJob.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    let icon = try Data(contentsOf:stage.appendingPathComponent("Silkwire.icns"))
    guard let enumerator = files.enumerator(at:source,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { throw CocoaError(.fileReadUnknown) }
    var hashes: [String:String] = [:]
    for case let file as URL in enumerator {
        let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        if values.isRegularFile == true { hashes["Colors.xcassets/"+String(file.path.dropFirst(source.path.count+1))] = sha(try Data(contentsOf:file)) }
    }
    hashes["SilkwireAppIcon-1024.png"] = sha(try Data(contentsOf:iconSource))
    let tool = try capture(["--find","actool"])
    let manifest: [String:Any] = ["schema":1,"sourceFiles":hashes,"compiledFiles":["Assets.car":sha(data),"Silkwire.icns":sha(icon)],"platform":"macosx","minimumOS":"14.0","sdkVersion":try capture(["--sdk","macosx","--show-sdk-version"]),"generator":"Scripts/regenerate-brand-assets.swift","actoolPath":tool,"actoolSha256":sha(try Data(contentsOf:URL(fileURLWithPath:tool)))]
    try files.createDirectory(at:destination,withIntermediateDirectories:true)
    if files.fileExists(atPath:destination.appendingPathComponent("Assets.car").path) {
        try files.copyItem(at:destination.appendingPathComponent("Assets.car"),to:stage.appendingPathComponent("previous-Assets.car"))
    }
    try data.write(to:destination.appendingPathComponent("Assets.car"),options:.atomic)
    try icon.write(to:destination.appendingPathComponent("Silkwire.icns"),options:.atomic)
    try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:destination.appendingPathComponent("BrandAssets.json"),options:.atomic)
    print("Generated native macOS accent catalog and app icon; source/artifact hashes recorded.")
} catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
