import Foundation
import Combine
import AppKit
import ImageIO
import Darwin
import UniformTypeIdentifiers

struct UsageWindow: Codable, Identifiable {
    var label: String
    var remainingPercent: Double
    var resetsAt: Double?
    var id: String { label }
}
struct ConnectionModel: Codable, Identifiable { var id: String; var name: String; var efforts: [String] }
struct ConnectionDetail: Codable, Identifiable {
    var agent: String
    var installed: Bool
    var signedIn: Bool
    var account: String
    var model: String
    var effort: String
    var speed: String
    var permissions: String
    var usage: [UsageWindow]
    var models: [ConnectionModel]
    var note: String?
    var checkedAt: Date? = nil
    var id: String { agent }
}
struct Attachment: Codable, Identifiable {
    var id = UUID()
    var name: String
    var mimeType: String
    var data: Data
    var isImage: Bool { mimeType.hasPrefix("image/") }
    var text: String { String(data: data, encoding: .utf8) ?? "" }
    static func failure(_ message: String) -> NSError { NSError(domain: "Silkwire", code: 4, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func load(_ url: URL) throws -> Attachment {
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("Folders and aliases can't be attached. Choose the file itself.") }
        let isImageFile = imageExtensions.contains(url.pathExtension.lowercased())
        guard (values.fileSize ?? Int.max) <= (isImageFile ? imageFileByteLimit : 10 * 1024 * 1024) else { throw failure(isImageFile ? "This photo is over 100 MB, which is too big to attach." : "This file is over 10 MB, which is too big to attach.") }
        if isImageFile { return try fromImageFile(url) }
        let data = try Data(contentsOf: url)
        let supported = ["txt", "md", "csv", "json", "log", "swift", "js", "mjs", "ts", "tsx", "py", "html", "css", "xml", "yaml", "yml"]
        guard supported.contains(url.pathExtension.lowercased()), let text = String(data: data, encoding: .utf8), !text.contains("\0"), text.utf16.count <= 12000 else { throw failure("Unsupported file: \(url.lastPathComponent). Use an image or UTF-8 text/code file up to 12,000 characters. PDF, Office, audio, video and archives are not supported by this preview.") }
        return Attachment(name: url.lastPathComponent, mimeType: "text/plain", data: data)
    }
    /// Image files are shrunk before attaching, so the original may be much larger than the attachment.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp"]
    static let imageFileByteLimit = 100 * 1024 * 1024
    static let imageByteLimit = 2 * 1024 * 1024
    static let minimumImageSide: CGFloat = 480
    /// Decodes a downsized copy straight from the file, so a very large photo is never fully
    /// decoded in memory before it is shrunk. It also honours the photo's saved rotation.
    static let imagePixelLimit = 100_000_000
    static func fromImageFile(_ url: URL, maxPixels: Int = imagePixelLimit) throws -> Attachment {
        let unreadable = failure("This image can't be read. Try exporting it as a PNG or JPEG first.")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0 else { throw unreadable }
        // Read the image's stated size from its header before decoding any pixels, so an
        // enormous image is refused cheaply. Not every format decodes a small preview cheaply.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0, pixelHeight > 0 else { throw unreadable }
        guard pixelWidth <= 30000, pixelHeight <= 30000, pixelWidth * pixelHeight <= maxPixels else { throw failure("This image is too large to open safely. Try exporting a smaller copy first.") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw unreadable }
        return try fromImage(NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)), name: url.lastPathComponent)
    }
    static func fromImage(_ image: NSImage, name: String = "Pasted image.png") throws -> Attachment {
        guard image.size.width > 0, image.size.height > 0, image.size.width <= 30000, image.size.height <= 30000 else { throw failure("This image can't be read. Try exporting it as a PNG or JPEG first.") }
        // Camera photos compress poorly as PNG, so a 1600-pixel photo is often over the limit.
        // Shrink step by step until it fits, instead of asking Jason to make a smaller copy.
        let longestSide = max(image.size.width, image.size.height)
        var target = min(1600, longestSide)
        while true {
            let scale = target / longestSide
            let width = max(1, Int((image.size.width * scale).rounded())), height = max(1, Int((image.size.height * scale).rounded()))
            let png = try pngData(image, width: width, height: height)
            if png.count <= imageByteLimit { return Attachment(name: name, mimeType: "image/png", data: png) }
            guard target > minimumImageSide else { break }
            target = max(minimumImageSide, (target * 0.8).rounded(.down))
        }
        throw failure("This image is still over 2 MB after shrinking it, so it can't be attached. Try a screenshot of it instead.")
    }
    private static func pngData(_ image: NSImage, width: Int, height: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw failure("Image conversion failed.") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height)); context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("Image conversion failed.") }
        return png
    }
}
struct Message: Codable, Identifiable {
    var id = UUID()
    var author: String
    var text: String
    var state: String
    var requestId: String?
    var detail: String?
    var createdAt: Date? = Date()
    var attachments: [Attachment]? = nil
    /// Jason's read marker for teammate replies (ReadMarks). nil = no marker (older messages).
    var unread: Bool? = nil
    /// Keep protocol bytes for terminal processing, but filter every transcript,
    /// search highlight and Copy surface, including old completed replies.
    var forDisplay: Message {
        guard agents.contains(where: { names[$0] == author }) else { return self }
        var result = self
        result.text = TeamMemory.visibleText(text, streaming: state == "streaming")
        return result
    }
}
struct ProviderIdentity: Codable {
    var id: String
    var started: Bool?
    var model: String?
    var runId: String?
    var requestId: String?
    var turnId: String?
}
struct HistoryContextSnapshot: Codable {
    var supplied: Int
    var total: Int
    var shortened: Bool
    var requestID: String
    var recordedAt = Date()
    var capabilityHash: String?
    var folderCount: Int?
    var components: [String: Int]?
    var promptCharacters: Int?
    var imageAttachmentBytes: Int?
}
struct Conversation: Codable, Identifiable {
    var id = UUID()
    var projectID: UUID?
    var archived = false
    var draftAttachments: [Attachment] = []
    var unread = false
    var title = "Team conversation"
    var createdAt = Date()
    var updatedAt = Date()
    var draft = ""
    var recipient = "team"
    var messages: [Message] = []
    var identities: [String: ProviderIdentity] = [:]
    var historyContext: [String: HistoryContextSnapshot]?
    /// An addition Jason sent while the team was working, saved until it is delivered.
    var queuedText: String?
    var queuedAttachments: [Attachment]?
    /// Set for a one-on-one chat: only this teammate is connected and gets focused instructions.
    var focusedAgent: String?
    /// Teammates' background job cards (BackgroundJobDesk). The host owns the work.
    var backgroundJobs: [BackgroundJobCard]?
    enum CodingKeys: String, CodingKey { case id, projectID, archived, draftAttachments, unread, title, createdAt, updatedAt, draft, recipient, messages, identities, historyContext, threadID, queuedText, queuedAttachments, focusedAgent, backgroundJobs }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        draftAttachments = try c.decodeIfPresent([Attachment].self, forKey: .draftAttachments) ?? []
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Team conversation"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        draft = try c.decodeIfPresent(String.self, forKey: .draft) ?? ""
        recipient = try c.decodeIfPresent(String.self, forKey: .recipient) ?? "team"
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        identities = try c.decodeIfPresent([String: ProviderIdentity].self, forKey: .identities) ?? [:]
        historyContext = try c.decodeIfPresent([String: HistoryContextSnapshot].self, forKey: .historyContext)
        queuedText = try c.decodeIfPresent(String.self, forKey: .queuedText)
        queuedAttachments = try c.decodeIfPresent([Attachment].self, forKey: .queuedAttachments)
        focusedAgent = try c.decodeIfPresent(String.self, forKey: .focusedAgent)
        // Cards are a view of the host's work: an unreadable card must never keep
        // the library from opening.
        backgroundJobs = (try? c.decodeIfPresent([BackgroundJobCard].self, forKey: .backgroundJobs)) ?? nil
        if identities["codex"] == nil, let old = try c.decodeIfPresent(String.self, forKey: .threadID) {
            identities["codex"] = ProviderIdentity(id: old, started: messages.contains { $0.author == "Codex" && !$0.text.isEmpty })
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(archived, forKey: .archived); try c.encode(draftAttachments, forKey: .draftAttachments)
        try c.encodeIfPresent(projectID, forKey: .projectID); try c.encode(unread, forKey: .unread)
        try c.encode(title, forKey: .title); try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(id, forKey: .id); try c.encode(draft, forKey: .draft); try c.encode(recipient, forKey: .recipient)
        try c.encode(messages, forKey: .messages); try c.encode(identities, forKey: .identities)
        try c.encodeIfPresent(historyContext, forKey: .historyContext)
        try c.encodeIfPresent(queuedText, forKey: .queuedText); try c.encodeIfPresent(queuedAttachments, forKey: .queuedAttachments)
        try c.encodeIfPresent(focusedAgent, forKey: .focusedAgent)
        try c.encodeIfPresent(backgroundJobs, forKey: .backgroundJobs)
    }
}
func limitedUTF16(_ text: String, to limit: Int) -> String {
    var used = 0
    return String(text.prefix { character in
        let size = String(character).utf16.count
        guard used + size <= limit else { return false }
        used += size; return true
    })
}
struct ProjectFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var bookmark: Data
    var builderAllowed: Bool?
}
struct ProjectAccessVerification: Codable, Equatable {
    var folder: ProjectFolder
    var operation: String
    var verifiedAt: Date
    var detail: String
    var description: String {
        let kind = operation == "read" ? "file read" : operation == "list" ? "listing" : operation
        return "Last verified \(kind) · \(verifiedAt.formatted(date: .abbreviated, time: .shortened)) · historical evidence; current access not checked" + (detail.isEmpty ? "" : " · " + detail)
    }
}
struct Project: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New Project"
    var icon = "spider"
    var color = "violet"
    var participants = ["eve", "claude", "codex"]
    var expanded = true
    var folderPath: String?
    var folderBookmark: Data?
    var folders: [ProjectFolder]?
    var brief: String?
    var trustedStaging: Bool?
    var replyOrder: String?
    var accessVerifications: [String: ProjectAccessVerification]?
    /// Saved team notes delivered to every agent each turn (see TeamMemory).
    var memory: [MemoryNote]?
    /// Alexandria pages for this Project (see Alexandria.swift). Shared, never private.
    var library: [LibraryPage]?
    var connectedFolders: [ProjectFolder] {
        if let folders { return folders }
        if let path = folderPath, let bookmark = folderBookmark { return [ProjectFolder(id: id, name: "Project files", path: path, bookmark: bookmark)] }
        return []
    }
}
struct MemoryNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: String
    var text: String
    var author: String
    var createdAt = Date()
}
func validFolderGrant(_ project: Project) -> Bool {
    guard (project.brief?.utf16.count ?? 0) <= 2000 else { return false }
    if project.folders == nil, (project.folderPath == nil) != (project.folderBookmark == nil) { return false }
    let folders = project.connectedFolders
    return folders.count <= 8 && Set(folders.map(\.id)).count == folders.count && Set(folders.map(\.path)).count == folders.count && folders.allSatisfy { folder in
        folder.path.hasPrefix("/") && folder.path != "/" && folder.path.count <= 4096 && !folder.bookmark.isEmpty && !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && folder.name.utf16.count <= 80
    }
}
struct WorkspacePreferences: Codable, Equatable {
    var completionChime = true
    var sidebarVisible = true
    var reduceMotion = false
    var autoScrollReplies = true
    var textCompletion = true
    var automaticCorrection = false
    /// After Send, hold your message at the top while replies arrive (ReplyScroll).
    var startRepliesAtPrompt = true
    /// Real conversation (open floor): everyone in a room replies at once. Off by default.
    var openFloor = false
    /// After an open-floor round, teammates may respond to each other once (OpenFloor chime-in).
    var chimeIn = true
    enum CodingKeys: String, CodingKey { case completionChime, sidebarVisible, reduceMotion, autoScrollReplies, textCompletion, automaticCorrection, startRepliesAtPrompt, openFloor, chimeIn }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completionChime = try c.decodeIfPresent(Bool.self, forKey: .completionChime) ?? true
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        autoScrollReplies = try c.decodeIfPresent(Bool.self, forKey: .autoScrollReplies) ?? true
        textCompletion = try c.decodeIfPresent(Bool.self, forKey: .textCompletion) ?? true
        automaticCorrection = try c.decodeIfPresent(Bool.self, forKey: .automaticCorrection) ?? false
        startRepliesAtPrompt = try c.decodeIfPresent(Bool.self, forKey: .startRepliesAtPrompt) ?? true
        openFloor = try c.decodeIfPresent(Bool.self, forKey: .openFloor) ?? false
        chimeIn = try c.decodeIfPresent(Bool.self, forKey: .chimeIn) ?? true
    }
}
struct ConversationWorkspace: Codable {
    var version = 5
    var environment: String?
    var activeID: UUID
    var conversations: [Conversation]
    var projects: [Project] = []
    var preferences = WorkspacePreferences()
    enum CodingKeys: String, CodingKey { case version, environment, activeID, conversations, projects, preferences }
    init(activeID: UUID, conversations: [Conversation], projects: [Project] = [], preferences: WorkspacePreferences = WorkspacePreferences()) {
        self.activeID = activeID; self.conversations = conversations; self.projects = projects; self.preferences = preferences
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        activeID = try c.decode(UUID.self, forKey: .activeID)
        conversations = try c.decode([Conversation].self, forKey: .conversations)
        // Only the older format may omit Projects. Missing version-2 data is corrupt, not a new library.
        projects = version == 1 ? [] : try c.decode([Project].self, forKey: .projects)
        preferences = version == 1 ? (try c.decodeIfPresent(WorkspacePreferences.self, forKey: .preferences) ?? WorkspacePreferences()) : try c.decode(WorkspacePreferences.self, forKey: .preferences)
    }
    func validate() throws {
        guard [1, 2, 3, 4, 5].contains(version), !conversations.isEmpty,
              Set(conversations.map(\.id)).count == conversations.count,
              conversations.contains(where: { $0.id == activeID }) else { throw invalid() }
        if version >= 2 {
            guard !projects.isEmpty, Set(projects.map(\.id)).count == projects.count,
                  projects.allSatisfy({ validFolderGrant($0) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.participants.isEmpty && Set($0.participants).count == $0.participants.count && $0.participants.allSatisfy { agents.contains($0) } }),
                  conversations.allSatisfy({ room in projects.contains { $0.id == room.projectID } }) else { throw invalid() }
        }
    }
    private func invalid() -> NSError { NSError(domain: "Silkwire", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid or unsupported Project library."]) }
}
extension Conversation {
    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedStandardContains(query) || messages.contains { $0.text.localizedStandardContains(query) }
    }
    var markdown: String {
        var lines = ["# \(title)", "", "Exported from Silkwire · \(Date().formatted(date: .abbreviated, time: .shortened))", ""]
        for message in messages {
            lines += ["## \(message.author) · \(message.state)", ""]
            if let date = message.createdAt { lines += [date.formatted(date: .abbreviated, time: .shortened), ""] }
            lines += [message.text, ""]
            for attachment in message.attachments ?? [] { lines += ["Attachment: \(attachment.name) (\(attachment.mimeType))", ""] }
            if let detail = message.detail, !detail.isEmpty { lines += ["> \(detail)", ""] }
        }
        return lines.joined(separator: "\n")
    }
}
struct Seat {
    var state = "disconnected"
    var message = "Not connected"
    var model = ""
    var active = false
    var activity = ""
    var startedAt: Date?
    var lastEventAt: Date?
}
let agents = ["eve", "claude", "codex"]
let names = ["eve": "Eve", "claude": "Claude", "codex": "Codex"]
