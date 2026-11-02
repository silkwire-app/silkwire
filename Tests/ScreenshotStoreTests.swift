import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main struct ScreenshotStoreTests {
    static func main() async throws {
        let files = FileManager.default
        // Every fixture is synthetic and stays in this private worktree's ignored output.
        let stage = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("output/tests/ScreenshotFixtures-" + UUID().uuidString)
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: stage) }
        let root = stage.appendingPathComponent("Projects")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        let store = try ScreenshotStore(projectsDirectory: root)
        let project = UUID(), conversation = UUID(), message = UUID(), attachment = UUID(), other = UUID()
        let png = try makePNG(width: 800, height: 400, red: 0.8)
        let secondPNG = try makePNG(width: 200, height: 100, red: 0.2)
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "ScreenshotStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            count += 1; print("PASS " + label)
        }
        func reject(_ label: String, _ action: () async throws -> Void) async throws {
            var failed = false
            do { try await action() } catch { failed = true }
            try check(failed, label)
        }
        let empty = try await store.list(projectID: project)
        try check(empty.items.isEmpty && empty.nextOffset == nil, "new project starts with an empty gallery")
        let item = try await store.savePNG(png, projectID: project, conversationID: conversation, messageID: message,
            attachmentID: attachment, name: "../../Screenshot.png", createdAt: Date(timeIntervalSince1970: 100))
        try check(item.name == "Screenshot.png" && item.pixelWidth == 800 && item.pixelHeight == 400, "display name cannot become a path; dimensions are recorded")
        try check(item.byteCount == png.count && item.sha256.count == 64, "reference includes original byte count and digest")
        let original = try await store.original(projectID: project, attachmentID: attachment)
        try check(original == png, "original bytes round trip without image re-encoding")
        let thumbnail = try await store.thumbnail(projectID: project, attachmentID: attachment)
        let thumbSource = CGImageSourceCreateWithData(thumbnail as CFData, nil)!
        let thumbImage = CGImageSourceCreateImageAtIndex(thumbSource, 0, nil)!
        try check(thumbImage.width == 320 && thumbImage.height == 160, "thumbnail is directly downsampled to a bounded size with aspect ratio")
        let folder = root.appendingPathComponent(project.uuidString.lowercased() + "/Screenshots/" + attachment.uuidString.lowercased())
        let metadataURL = folder.appendingPathComponent("metadata.json")
        let metadata = try Data(contentsOf: metadataURL)
        let fields = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
        try check(fields["data"] == nil && fields["thumbnail"] == nil && metadata.count < 2048, "persistent reference contains metadata, not inline image data")
        let attrs = try files.attributesOfItem(atPath: folder.appendingPathComponent("original.png").path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "new screenshot files are owner-only")
        let folderAttrs = try files.attributesOfItem(atPath: folder.path)
        try check((folderAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "new screenshot directories are owner-only")
        let retry = try await store.savePNG(png, projectID: project, conversationID: conversation, messageID: message, attachmentID: attachment)
        try check(retry == item, "retry with the same identity and bytes returns the original record")
        try await reject("same attachment identity cannot overwrite different pixels") {
            _ = try await store.savePNG(secondPNG, projectID: project, conversationID: conversation, messageID: message, attachmentID: attachment)
        }
        try await reject("same identity cannot move to a different conversation silently") {
            _ = try await store.savePNG(png, projectID: project, conversationID: other, messageID: message, attachmentID: attachment)
        }
        let later = try await store.savePNG(secondPNG, projectID: project, conversationID: other, messageID: UUID(), createdAt: Date(timeIntervalSince1970: 200))
        let firstPage = try await store.list(projectID: project, limit: 1)
        try check(firstPage.items.map(\.id) == [later.id] && firstPage.nextOffset == 1 && !firstPage.scanTruncated, "gallery is newest-first and paginated")
        let next = try await store.list(projectID: project, offset: 1, limit: 1)
        try check(next.items.map(\.id) == [item.id] && next.nextOffset == nil, "next page returns the remaining record")
        let filtered = try await store.list(projectID: project, conversationID: conversation)
        try check(filtered.items == [item], "conversation filter does not mix screenshot ownership")
        let otherProject = UUID()
        let separate = try await store.savePNG(png, projectID: otherProject, conversationID: conversation, messageID: message, attachmentID: attachment)
        let separatePage = try await store.list(projectID: otherProject)
        try check(separatePage.items == [separate] && separate.projectID != item.projectID, "project identity separates identical attachment IDs")
        let reopened = try ScreenshotStore(projectsDirectory: root)
        let reopenedPage = try await reopened.list(projectID: project, conversationID: conversation)
        try check(reopenedPage.items == [item], "metadata gallery survives reopening without an in-memory index")
        try await reject("invalid PNG is rejected") {
            _ = try await store.savePNG(Data("not a screenshot".utf8), projectID: project, conversationID: conversation, messageID: message)
        }
        try await reject("oversized image input is rejected before decoding") {
            _ = try await store.savePNG(Data(repeating: 0, count: ScreenshotStore.maxImageBytes + 1), projectID: project, conversationID: conversation, messageID: message)
        }
        try await reject("unbounded gallery page request is refused") { _ = try await store.list(projectID: project, limit: 501) }
        try await reject("negative page offset is refused") { _ = try await store.list(projectID: project, offset: -1) }
        let outside = stage.appendingPathComponent("Unrelated")
        try files.createDirectory(at: outside, withIntermediateDirectories: false)
        let linkedProject = UUID()
        try files.createSymbolicLink(at: root.appendingPathComponent(linkedProject.uuidString.lowercased()), withDestinationURL: outside)
        try await reject("project symlink cannot redirect screenshot writes") {
            _ = try await store.savePNG(png, projectID: linkedProject, conversationID: conversation, messageID: message)
        }
        try check(try files.contentsOfDirectory(atPath: outside.path).isEmpty, "unrelated fixture directory remains untouched")
        try await reject("project symlink cannot redirect gallery reads") { _ = try await store.list(projectID: linkedProject) }
        let partialID = UUID()
        try files.createDirectory(at: root.appendingPathComponent(project.uuidString.lowercased() + "/Screenshots/" + partialID.uuidString.lowercased()), withIntermediateDirectories: false)
        let partial = try await store.list(projectID: project)
        try check(partial.items.count == 2 && partial.unavailableIDs.contains(partialID), "incomplete saves are reported, not published as screenshots")
        let originalURL = folder.appendingPathComponent("original.png")
        let retainedURL = folder.appendingPathComponent("retained.png")
        try files.moveItem(at: originalURL, to: retainedURL)
        try files.createSymbolicLink(at: originalURL, withDestinationURL: retainedURL)
        try await reject("original-image symlinks are refused") { _ = try await store.original(projectID: project, attachmentID: attachment) }
        let metadataOnly = try await store.list(projectID: project, conversationID: conversation)
        try check(metadataOnly.items == [item], "gallery listing never opens full-size original files")
        try files.removeItem(at: originalURL)
        try files.linkItem(at: retainedURL, to: originalURL)
        try await reject("hard-linked image files are refused") { _ = try await store.original(projectID: project, attachmentID: attachment) }
        try files.removeItem(at: originalURL)
        try Data("tampered".utf8).write(to: originalURL)
        try await reject("corrupt originals fail size or digest verification") { _ = try await store.original(projectID: project, attachmentID: attachment) }
        let intactThumbnail = try await store.thumbnail(projectID: project, attachmentID: attachment)
        try check(intactThumbnail == thumbnail, "thumbnail access remains independent of original loading")
        let missingRoot = stage.appendingPathComponent("Missing")
        try await reject("store never invents a default root or creates an ungranted storage home") { _ = try ScreenshotStore(projectsDirectory: missingRoot) }
        let rootLink = stage.appendingPathComponent("LinkedRoot")
        try files.createSymbolicLink(at: rootLink, withDestinationURL: root)
        try await reject("symlink storage root is refused") { _ = try ScreenshotStore(projectsDirectory: rootLink) }
        try check(try Data(contentsOf: retainedURL) == png, "original preserved throughout synthetic failure tests")
        count += try await transactionChecks(root: root, png: png, differentPNG: secondPNG)
        let retainedRoot = stage.appendingPathComponent("RetainedProjects")
        try files.moveItem(at: root, to: retainedRoot)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        try await reject("replacing a storage root invalidates existing gallery access") {
            _ = try await store.list(projectID: project)
        }
        try await reject("replacing a storage root cannot redirect screenshot writes") {
            _ = try await store.savePNG(png, projectID: project, conversationID: conversation, messageID: message)
        }
        try check(try files.contentsOfDirectory(atPath: root.path).isEmpty, "replacement root remains untouched")
        print("PASS \(count) screenshot storage checks; no live library, vault, account or network accessed")
    }

    static func transactionChecks(root: URL, png: Data, differentPNG: Data) async throws -> Int {
        let files = FileManager.default
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "ScreenshotTransactionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            count += 1; print("PASS " + label)
        }
        func reject(_ label: String, _ action: () async throws -> Void) async throws {
            var failed = false
            do { try await action() } catch { failed = true }
            try check(failed, label)
        }
        func parent(_ project: UUID) -> URL { root.appendingPathComponent(project.uuidString.lowercased() + "/Screenshots") }
        func assetFolder(_ project: UUID, _ asset: UUID) -> URL { parent(project).appendingPathComponent(asset.uuidString.lowercased()) }
        let conversation = UUID(), message = UUID()
        for step in ScreenshotStore.SaveStep.allCases {
            let project = UUID(), asset = UUID()
            var observed: [ScreenshotStore.SaveStep] = []
            let interrupted = try ScreenshotStore(projectsDirectory: root, saveStep: { current in
                observed.append(current)
                if current == step { throw NSError(domain: "SyntheticScreenshotInterruption", code: 1) }
            })
            var inlineOriginal: Data? = png
            var failed = false
            do {
                _ = try await interrupted.savePNG(png, projectID: project, conversationID: conversation,
                    messageID: message, attachmentID: asset)
                inlineOriginal = nil
            } catch { failed = true }
            try check(failed && observed.last == step && inlineOriginal == png, "interruption at \(step) returns failure and keeps caller original")
            let reopened = try ScreenshotStore(projectsDirectory: root)
            let before = try await reopened.list(projectID: project)
            let published = step == .published || step == .directoriesFlushed
            try check(before.items.count == (published ? 1 : 0) && before.unavailableIDs.isEmpty,
                "interruption at \(step) exposes only a complete transaction, never temporary files")
            let pendingBefore = try files.contentsOfDirectory(at: parent(project), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".pending-") }
            let recovered = try await reopened.savePNG(png, projectID: project, conversationID: conversation,
                messageID: message, attachmentID: asset)
            let recoveredBytes = try await reopened.original(projectID: project, attachmentID: asset)
            let after = try await reopened.list(projectID: project)
            try check(recoveredBytes == png && after.items == [recovered], "retry after \(step) recovers exactly one verified screenshot")
            let again = try await reopened.savePNG(png, projectID: project, conversationID: conversation,
                messageID: message, attachmentID: asset)
            try check(again == recovered, "retry after \(step) remains idempotent")
            try check(pendingBefore.allSatisfy { files.fileExists(atPath: $0.path) }, "retry after \(step) never deletes interrupted transaction evidence")
        }
        var normalSteps: [ScreenshotStore.SaveStep] = []
        let observedStore = try ScreenshotStore(projectsDirectory: root, saveStep: { normalSteps.append($0) })
        _ = try await observedStore.savePNG(png, projectID: UUID(), conversationID: conversation, messageID: message)
        try check(normalSteps == ScreenshotStore.SaveStep.allCases, "successful save reaches directory flush before returning its reference")

        // Fixtures for the previous writer, which created the public directory first.
        for mode in 0...2 {
            let project = UUID(), asset = UUID(), folder = assetFolder(project, asset)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let partial = mode == 1 ? Data(png.prefix(23)) : png
            if mode > 0 { try partial.write(to: folder.appendingPathComponent("original.png")) }
            if mode == 2 { try Data([137, 80, 78]).write(to: folder.appendingPathComponent("thumbnail.png")) }
            let reopened = try ScreenshotStore(projectsDirectory: root)
            let result = try await reopened.savePNG(png, projectID: project, conversationID: conversation,
                messageID: message, attachmentID: asset)
            let retained = try files.contentsOfDirectory(at: parent(project), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".incomplete-") }
            try check(retained.count == 1, "legacy partial mode \(mode) is retained separately before retry")
            if mode > 0 { try check(try Data(contentsOf: retained[0].appendingPathComponent("original.png")) == partial, "legacy partial mode \(mode) preserves every existing original byte") }
            let page = try await reopened.list(projectID: project)
            let bytes = try await reopened.original(projectID: project, attachmentID: asset)
            try check(page.items == [result] && bytes == png, "legacy partial mode \(mode) recovers without duplicate gallery entries")
        }
        let reopened = try ScreenshotStore(projectsDirectory: root)
        let unknownProject = UUID(), unknownAsset = UUID(), marker = Data("must remain".utf8)
        let unknown = assetFolder(unknownProject, unknownAsset)
        try files.createDirectory(at: unknown, withIntermediateDirectories: true)
        try marker.write(to: unknown.appendingPathComponent("keep.txt"))
        try await reject("unknown files prevent automatic partial-save recovery") {
            _ = try await reopened.savePNG(png, projectID: unknownProject, conversationID: conversation, messageID: message, attachmentID: unknownAsset)
        }
        try check(try Data(contentsOf: unknown.appendingPathComponent("keep.txt")) == marker, "unknown files are neither overwritten nor moved")
        let conflictProject = UUID(), conflictAsset = UUID(), conflict = assetFolder(conflictProject, conflictAsset)
        try files.createDirectory(at: conflict, withIntermediateDirectories: true)
        try differentPNG.write(to: conflict.appendingPathComponent("original.png"))
        try await reject("conflicting legacy image bytes cannot be silently reassigned") {
            _ = try await reopened.savePNG(png, projectID: conflictProject, conversationID: conversation, messageID: message, attachmentID: conflictAsset)
        }
        try check(try Data(contentsOf: conflict.appendingPathComponent("original.png")) == differentPNG, "conflicting legacy image remains untouched")
        let corruptProject = UUID(), corruptAsset = UUID(), corrupt = assetFolder(corruptProject, corruptAsset)
        try files.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let broken = Data("{broken".utf8)
        try broken.write(to: corrupt.appendingPathComponent("metadata.json"))
        try await reject("corrupt committed metadata is not treated as an abandoned save") {
            _ = try await reopened.savePNG(png, projectID: corruptProject, conversationID: conversation, messageID: message, attachmentID: corruptAsset)
        }
        try check(try Data(contentsOf: corrupt.appendingPathComponent("metadata.json")) == broken, "corrupt metadata is preserved for recovery")

        let collisionProject = UUID(), collisionAsset = UUID(), collision = assetFolder(collisionProject, collisionAsset)
        let collisionStore = try ScreenshotStore(projectsDirectory: root, saveStep: { step in
            if step == .metadataWritten { try files.createDirectory(at: collision, withIntermediateDirectories: false) }
        })
        try await reject("atomic publication refuses a destination created during the save") {
            _ = try await collisionStore.savePNG(png, projectID: collisionProject, conversationID: conversation, messageID: message, attachmentID: collisionAsset)
        }
        try check(try files.contentsOfDirectory(atPath: collision.path).isEmpty, "publication collision never replaces the competing directory")
        let blockedProject = UUID(), blockedParent = parent(blockedProject)
        try files.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        let lock = Darwin.open(blockedParent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ScreenshotStoreError.unavailable }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        try await reject("another writer's lock produces a retryable failure rather than concurrent mutation") {
            _ = try await reopened.savePNG(png, projectID: blockedProject, conversationID: conversation, messageID: message)
        }
        try check(try files.contentsOfDirectory(atPath: blockedParent.path).isEmpty, "blocked writer leaves no partial asset")
        return count
    }

    static func makePNG(width: Int, height: Int, red: CGFloat) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotStoreError.invalidImage }
        context.setFillColor(red: red, green: 0.3, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = NSMutableData()
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw ScreenshotStoreError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotStoreError.invalidImage }
        return bytes as Data
    }
}
