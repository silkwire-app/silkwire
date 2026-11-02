import SwiftUI
import AppKit

// Alexandria's Screenshots: each project's images live as files on this Mac
// (<app data>/Projects/<project>/Screenshots), browsed as small thumbnails.
// The full image loads only while it is open. Built on Codex's ScreenshotStore.
enum ScreenshotLibrary {
    private static var stores: [String: ScreenshotStore] = [:]
    private static let lock = NSLock()

    static func projectsDirectory(for appDirectory: URL) -> URL {
        appDirectory.appendingPathComponent("Projects", isDirectory: true)
    }

    /// One store per app data folder. Creates the app-owned Projects folder if needed.
    static func store(for appDirectory: URL) -> ScreenshotStore? {
        let root = projectsDirectory(for: appDirectory)
        lock.lock(); defer { lock.unlock() }
        if let existing = stores[root.path] { return existing }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let made = try? ScreenshotStore(projectsDirectory: root) else { return nil }
        stores[root.path] = made
        return made
    }

    /// Files a copy of each sent PNG in the project's Screenshots folder, off the main thread.
    /// The message keeps its own copy for now; dropping inline images comes with the migration.
    static func file(_ attachments: [Attachment], appDirectory: URL, projectID: UUID?, conversationID: UUID, messageID: UUID) {
        guard let projectID else { return }
        let pngs = attachments.filter { $0.mimeType == "image/png" }.map { ($0.id, $0.name, $0.data) }
        guard !pngs.isEmpty, let store = store(for: appDirectory) else { return }
        Task.detached(priority: .utility) {
            for (id, name, data) in pngs {
                _ = try? await store.savePNG(data, projectID: projectID, conversationID: conversationID, messageID: messageID, attachmentID: id, name: name)
            }
        }
    }
}

struct ScreenshotGallery: View {
    let appDirectory: URL
    let projectID: UUID?
    let open: (UUID) -> Void
    @State private var items: [StoredScreenshot] = []
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Screenshots", systemImage: "photo.on.rectangle").font(.system(size: 18, weight: .semibold, design: .serif))
            Text("Screenshots sent in this project, newest first. Only small previews load here; the full image opens when you choose one.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if failed {
                Text("The Screenshots folder couldn't be opened.").font(.callout).foregroundStyle(.secondary)
            } else if loaded && items.isEmpty {
                Text("No screenshots here yet. Images you send from now on are filed here automatically.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 12) {
                ForEach(items) { item in
                    Button { open(item.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ScreenshotThumbnail(appDirectory: appDirectory, item: item)
                                .frame(height: 80).frame(maxWidth: .infinity)
                                .background(SilkwireTheme.wash(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(item.name).accessibilityLabel("Screenshot from " + item.createdAt.formatted())
                }
            }
        }
        .task(id: projectID) { await load() }
    }

    private func load() async {
        guard let projectID, let store = ScreenshotLibrary.store(for: appDirectory) else { failed = projectID != nil; loaded = true; return }
        var all: [StoredScreenshot] = [], offset: Int? = 0
        while let next = offset, all.count < 2000 {
            guard let page = try? await store.list(projectID: projectID, offset: next, limit: 200) else { break }
            all += page.items; offset = page.nextOffset
        }
        items = all.sorted { $0.createdAt > $1.createdAt }
        loaded = true
    }
}

struct ScreenshotThumbnail: View {
    let appDirectory: URL
    let item: StoredScreenshot
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
        .task(id: item.id) {
            guard let store = ScreenshotLibrary.store(for: appDirectory),
                  let data = try? await store.thumbnail(projectID: item.projectID, attachmentID: item.id) else { return }
            image = NSImage(data: data)
        }
    }
}

/// The full-size image, loaded when opened and released when closed.
struct ScreenshotViewer: View {
    let appDirectory: URL
    let projectID: UUID?
    let id: UUID
    @State private var image: NSImage?
    @State private var missing = false
    var body: some View {
        VStack(spacing: 10) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if missing {
                Text("This screenshot isn't available.").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
        .task(id: id) {
            guard let projectID, let store = ScreenshotLibrary.store(for: appDirectory),
                  let data = try? await store.original(projectID: projectID, attachmentID: id), let made = NSImage(data: data) else { missing = true; return }
            image = made
        }
        .onDisappear { image = nil }
    }
}
