import Foundation
import Darwin
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Metadata only: safe to keep in a conversation or gallery without retaining pixels.
struct StoredScreenshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let conversationID: UUID
    let messageID: UUID
    let createdAt: Date
    let name: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let sha256: String
    let thumbnailByteCount: Int
    let thumbnailSHA256: String
}

struct ScreenshotPage: Sendable {
    let items: [StoredScreenshot]
    let nextOffset: Int?
    let scanTruncated: Bool
    let unavailableIDs: [UUID]
}

enum ScreenshotStoreError: Error {
    case invalidImage, unavailable, incomplete, identityConflict, corrupt, invalidPage
}

/// Pins only the explicitly supplied storage root. Unlike a Project text reader,
/// this does not require directory-listing access to every ancestor of that root.
/// Child access below it is descriptor-relative and never follows symbolic links.
private final class ScreenshotDirectory {
    private let selectedPath: String
    private let canonicalPath: String
    private let descriptor: Int32
    private let identity: stat

    init(_ url: URL) throws {
        var selected = stat()
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/",
              lstat(url.path, &selected) == 0, (selected.st_mode & S_IFMT) == S_IFDIR,
              let resolved = realpath(url.path, nil) else { throw ScreenshotStoreError.unavailable }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        let fd = Darwin.open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScreenshotStoreError.unavailable }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == selected.st_dev,
              opened.st_ino == selected.st_ino else {
            Darwin.close(fd); throw ScreenshotStoreError.unavailable
        }
        selectedPath = url.path
        canonicalPath = canonical
        descriptor = fd
        identity = opened
    }

    deinit { Darwin.close(descriptor) }

    func openPath(_ path: String, directory: Bool) throws -> Int32 {
        // No general path API: the store itself opens UUID/fixed-name children.
        guard path.isEmpty, directory else { throw ScreenshotStoreError.unavailable }
        var selected = stat()
        guard lstat(selectedPath, &selected) == 0, (selected.st_mode & S_IFMT) == S_IFDIR,
              selected.st_dev == identity.st_dev, selected.st_ino == identity.st_ino,
              let resolved = realpath(selectedPath, nil) else { throw ScreenshotStoreError.unavailable }
        defer { free(resolved) }
        guard String(cString: resolved) == canonicalPath else { throw ScreenshotStoreError.unavailable }
        let fresh = Darwin.open(canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fresh >= 0 else { throw ScreenshotStoreError.unavailable }
        defer { Darwin.close(fresh) }
        var current = stat()
        guard fstat(fresh, &current) == 0, current.st_dev == identity.st_dev,
              current.st_ino == identity.st_ino else { throw ScreenshotStoreError.unavailable }
        // Independent directory cursor, still pinned to the selected inode.
        let fd = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScreenshotStoreError.unavailable }
        return fd
    }
}

/// A storage component, not a folder grant or a migration. The caller must supply
/// an existing, app-owned Projects directory for ONE app instance. Never supply a
/// source checkout, vault, stable library or arbitrary discovered user directory.
/// Layout: <project UUID>/Screenshots/<attachment UUID>/{original.png,thumbnail.png,metadata.json}.
/// UUID identity survives display-name changes. No process-wide/default directory,
/// network, deletion, automatic migration or in-memory image cache is provided.
/// Call through await off the UI path; retain only metadata in observable models.
actor ScreenshotStore {
    static let maxImageBytes = 16 * 1024 * 1024
    static let maxPixels = 32_000_000
    static let thumbnailEdge = 320
    static let maxThumbnailBytes = 2 * 1024 * 1024
    /// Internal fault-injection seam: tests interrupt saves at real transaction boundaries.
    enum SaveStep: CaseIterable { case prepared, originalWritten, thumbnailWritten, metadataWritten, published, directoriesFlushed }
    private let scope: ScreenshotDirectory
    private let saveStep: ((SaveStep) throws -> Void)?

    init(projectsDirectory: URL, saveStep: ((SaveStep) throws -> Void)? = nil) throws {
        scope = try ScreenshotDirectory(projectsDirectory)
        self.saveStep = saveStep
    }

    /// The returned reference is published only after all files have been flushed.
    /// The caller must also durably save this reference before dropping inline data.
    /// Reusing an attachment ID is idempotent only for the same ownership and bytes.
    func savePNG(_ data: Data, projectID: UUID, conversationID: UUID, messageID: UUID,
                 attachmentID: UUID = UUID(), name: String = "Screenshot.png",
                 createdAt: Date = Date()) throws -> StoredScreenshot {
        guard !data.isEmpty, data.count <= Self.maxImageBytes,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw ScreenshotStoreError.invalidImage }
        let width = w.intValue, height = h.intValue
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= Self.maxPixels / height, createdAt.timeIntervalSince1970.isFinite else { throw ScreenshotStoreError.invalidImage }
        let digest = Self.hash(data)
        let project = projectID.uuidString.lowercased(), asset = attachmentID.uuidString.lowercased()
        let parent = try directory([project, "Screenshots"], create: true)
        defer { Darwin.close(parent) }
        // Serialize writers across store instances without blocking a thread on a lock.
        guard flock(parent, LOCK_EX | LOCK_NB) == 0 else { throw ScreenshotStoreError.unavailable }
        defer { flock(parent, LOCK_UN) }
        if let prior = try existing(projectID: projectID, attachmentID: attachmentID,
            conversationID: conversationID, messageID: messageID, data: data, digest: digest, parent: parent) {
            try flushDirectories(project: project, asset: asset)
            return prior
        }
        // The public UUID path does not exist until the complete transaction is ready.
        // Interrupted temporary folders are retained, never mistaken for gallery entries.
        let pending = ".pending-" + UUID().uuidString.lowercased()
        guard mkdirat(parent, pending, 0o700) == 0 else { throw ScreenshotStoreError.unavailable }
        let fd = openat(parent, pending, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScreenshotStoreError.unavailable }
        defer { Darwin.close(fd) }
        try saveStep?(.prepared)
        // Downsample directly from ImageIO: never create a full-size NSImage for a thumbnail.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailEdge,
            kCGImageSourceShouldCacheImmediately: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ScreenshotStoreError.invalidImage }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { throw ScreenshotStoreError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= Self.maxThumbnailBytes else { throw ScreenshotStoreError.invalidImage }
        let thumb = encoded as Data
        let display = String((name as NSString).lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(200))
        let item = StoredScreenshot(id: attachmentID, projectID: projectID, conversationID: conversationID,
            messageID: messageID, createdAt: createdAt, name: display.isEmpty ? "Screenshot.png" : display,
            byteCount: data.count, pixelWidth: width, pixelHeight: height, sha256: digest,
            thumbnailByteCount: thumb.count, thumbnailSHA256: Self.hash(thumb))
        try writeNew(data, name: "original.png", in: fd)
        try saveStep?(.originalWritten)
        try writeNew(thumb, name: "thumbnail.png", in: fd)
        try saveStep?(.thumbnailWritten)
        try writeNew(JSONEncoder().encode(item), name: "metadata.json", in: fd)
        try saveStep?(.metadataWritten)
        try syncDirectory(fd)
        try verifyDirectory(pending, in: parent, descriptor: fd)
        // Exclusive atomic publication: never replace an existing screenshot or link.
        guard renameatx_np(parent, pending, parent, asset, UInt32(RENAME_EXCL)) == 0 else { throw ScreenshotStoreError.identityConflict }
        try saveStep?(.published)
        try flushDirectories(project: project, asset: asset)
        try saveStep?(.directoriesFlushed)
        return item
    }

    /// Bounded metadata-only scan. No originals or thumbnails are opened by this call.
    /// A capped scan is explicitly reported, never presented as a complete library.
    func list(projectID: UUID, conversationID: UUID? = nil, offset: Int = 0, limit: Int = 100) throws -> ScreenshotPage {
        guard offset >= 0, offset <= 10_000, limit > 0, limit <= 500 else { throw ScreenshotStoreError.invalidPage }
        let project = projectID.uuidString.lowercased()
        // An absent project is an empty gallery, but a link/unreadable existing path is an error.
        let root = try scope.openPath("", directory: true)
        defer { Darwin.close(root) }
        var info = stat()
        if fstatat(root, project, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ScreenshotStoreError.unavailable }
            return ScreenshotPage(items: [], nextOffset: nil, scanTruncated: false, unavailableIDs: [])
        }
        let projectFD = try directory([project], create: false)
        defer { Darwin.close(projectFD) }
        if fstatat(projectFD, "Screenshots", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ScreenshotStoreError.unavailable }
            return ScreenshotPage(items: [], nextOffset: nil, scanTruncated: false, unavailableIDs: [])
        }
        let fd = try directory([project, "Screenshots"], create: false)
        defer { Darwin.close(fd) }
        let copy = dup(fd)
        guard copy >= 0 else { throw ScreenshotStoreError.unavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw ScreenshotStoreError.unavailable }
        defer { closedir(stream) }
        var items: [StoredScreenshot] = [], unavailable: [UUID] = [], scanned = 0, truncated = false
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ScreenshotStoreError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            scanned += 1
            if scanned > 10_000 { truncated = true; break }
            guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name else { continue }
            do {
                let item = try metadata(projectID: projectID, attachmentID: id)
                if conversationID == nil || item.conversationID == conversationID { items.append(item) }
            } catch { unavailable.append(id) }
        }
        items.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        return ScreenshotPage(items: Array(items.dropFirst(offset).prefix(limit)),
            nextOffset: offset + limit < items.count ? offset + limit : nil,
            scanTruncated: truncated, unavailableIDs: unavailable)
    }

    func original(projectID: UUID, attachmentID: UUID) throws -> Data {
        let item = try metadata(projectID: projectID, attachmentID: attachmentID)
        return try imageData(item, thumbnail: false)
    }

    func thumbnail(projectID: UUID, attachmentID: UUID) throws -> Data {
        let item = try metadata(projectID: projectID, attachmentID: attachmentID)
        return try imageData(item, thumbnail: true)
    }

    private func metadata(projectID: UUID, attachmentID: UUID) throws -> StoredScreenshot {
        let fd = try directory([projectID.uuidString.lowercased(), "Screenshots", attachmentID.uuidString.lowercased()], create: false)
        defer { Darwin.close(fd) }
        let bytes = try read("metadata.json", in: fd, limit: 16_384)
        let item = try JSONDecoder().decode(StoredScreenshot.self, from: bytes)
        guard item.id == attachmentID, item.projectID == projectID,
              item.byteCount > 0, item.byteCount <= Self.maxImageBytes,
              item.thumbnailByteCount > 0, item.thumbnailByteCount <= Self.maxThumbnailBytes,
              item.pixelWidth > 0, item.pixelHeight > 0, item.pixelWidth <= 16_384, item.pixelHeight <= 16_384,
              item.pixelWidth <= Self.maxPixels / item.pixelHeight, item.name.count <= 200,
              item.createdAt.timeIntervalSince1970.isFinite,
              item.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              item.thumbnailSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ScreenshotStoreError.corrupt }
        return item
    }

    private func imageData(_ item: StoredScreenshot, thumbnail: Bool) throws -> Data {
        let fd = try directory([item.projectID.uuidString.lowercased(), "Screenshots", item.id.uuidString.lowercased()], create: false)
        defer { Darwin.close(fd) }
        let bytes = try read(thumbnail ? "thumbnail.png" : "original.png", in: fd,
            limit: thumbnail ? Self.maxThumbnailBytes : Self.maxImageBytes)
        guard bytes.count == (thumbnail ? item.thumbnailByteCount : item.byteCount),
              Self.hash(bytes) == (thumbnail ? item.thumbnailSHA256 : item.sha256) else { throw ScreenshotStoreError.corrupt }
        return bytes
    }

    private func childExists(_ name: String, in fd: Int32) throws -> Bool {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw ScreenshotStoreError.unavailable }
        return false
    }

    private func verifyDirectory(_ name: String, in parent: Int32, descriptor: Int32) throws {
        var path = stat(), opened = stat()
        guard fstatat(parent, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              (path.st_mode & S_IFMT) == S_IFDIR, fstat(descriptor, &opened) == 0,
              path.st_dev == opened.st_dev, path.st_ino == opened.st_ino else { throw ScreenshotStoreError.unavailable }
    }

    /// Existing committed images are immutable. A legacy partial save can be
    /// moved aside, without deleting any bytes, only when it has no metadata and
    /// contains exclusively the old writer's two fixed image filenames.
    private func existing(projectID: UUID, attachmentID: UUID, conversationID: UUID,
                          messageID: UUID, data: Data, digest: String, parent: Int32) throws -> StoredScreenshot? {
        let asset = attachmentID.uuidString.lowercased()
        guard try childExists(asset, in: parent) else { return nil }
        let fd = openat(parent, asset, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScreenshotStoreError.unavailable }
        defer { Darwin.close(fd) }
        if try childExists("metadata.json", in: fd) {
            let prior = try metadata(projectID: projectID, attachmentID: attachmentID)
            guard prior.conversationID == conversationID, prior.messageID == messageID,
                  prior.sha256 == digest else { throw ScreenshotStoreError.identityConflict }
            _ = try original(projectID: projectID, attachmentID: attachmentID)
            _ = try thumbnail(projectID: projectID, attachmentID: attachmentID)
            return prior
        }
        let copy = dup(fd)
        guard copy >= 0 else { throw ScreenshotStoreError.unavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw ScreenshotStoreError.unavailable }
        defer { closedir(stream) }
        var names = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ScreenshotStoreError.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard ["original.png", "thumbnail.png"].contains(name) else { throw ScreenshotStoreError.incomplete }
            names.insert(name)
        }
        if names.contains("original.png") {
            let partial = try read("original.png", in: fd, limit: Self.maxImageBytes)
            guard data.starts(with: partial) else { throw ScreenshotStoreError.identityConflict }
        } else if !names.isEmpty { throw ScreenshotStoreError.incomplete }
        if names.contains("thumbnail.png") { _ = try read("thumbnail.png", in: fd, limit: Self.maxThumbnailBytes) }
        try verifyDirectory(asset, in: parent, descriptor: fd)
        let retained = ".incomplete-" + UUID().uuidString.lowercased()
        guard renameatx_np(parent, asset, parent, retained, UInt32(RENAME_EXCL)) == 0 else { throw ScreenshotStoreError.incomplete }
        try syncDirectory(parent)
        return nil
    }

    private func syncDirectory(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw ScreenshotStoreError.incomplete }
    }

    /// Flush from the image directory back through every containing directory.
    /// A save error never authorizes callers to discard their inline original.
    private func flushDirectories(project: String, asset: String) throws {
        for parts in [[project, "Screenshots", asset], [project, "Screenshots"], [project], []] {
            let fd = try directory(parts, create: false)
            defer { Darwin.close(fd) }
            try syncDirectory(fd)
        }
    }

    private func directory(_ components: [String], create: Bool) throws -> Int32 {
        var fd = try scope.openPath("", directory: true)
        do {
            for part in components {
                if create, mkdirat(fd, part, 0o700) != 0, errno != EEXIST { throw ScreenshotStoreError.unavailable }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ScreenshotStoreError.unavailable }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func writeNew(_ data: Data, name: String, in directory: Int32) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ScreenshotStoreError.incomplete }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: done), bytes.count - done)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ScreenshotStoreError.incomplete }; done += count
            }
        }
        guard fsync(fd) == 0 else { throw ScreenshotStoreError.incomplete }
    }

    private func read(_ name: String, in directory: Int32, limit: Int) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ScreenshotStoreError.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else { throw ScreenshotStoreError.corrupt }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ScreenshotStoreError.unavailable }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= limit else { throw ScreenshotStoreError.corrupt }
        }
        return result
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
