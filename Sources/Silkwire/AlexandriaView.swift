import SwiftUI

// Alexandria's views: the right-side rail tab, the library panel (shown as a
// Peek under the composer, docked beside the chat, or as a drawer over it) and
// the site-wide search results. One shared state object keeps the selected
// page and any unsaved drafts while Jason switches between the three views.

@MainActor final class AlexandriaState: ObservableObject {
    struct Draft: Equatable, Codable {
        var projectID: UUID?
        var title: String
        var body: String
        var section: String
        var baseRevision: Int?
    }
    enum Screen: Equatable { case home, section(LibrarySection), page(UUID), history(UUID), screenshots, screenshot(UUID) }
    static let draftsKey = "alexandria.drafts"
    private let defaults: UserDefaults
    /// Unsaved drafts are written to this Mac's app preferences on every change,
    /// so quitting or a crash never loses an edit in progress. Saving or
    /// discarding a draft removes it.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.draftsKey), let saved = try? JSONDecoder().decode([UUID: Draft].self, from: data) { drafts = saved }
    }
    @Published var open = false
    /// The Future drawer, opened from the rail beneath Alexandria.
    @Published var futureOpen = false
    /// Full-size reading view over the conversation; the draft and chat position stay as they were.
    @Published var reading = false
    /// True when the full-size reader opened because a page was chosen in a small view;
    /// going back to a list then returns to that small view.
    var readerOpenedForPage = false
    /// The last list (home, shelf, vault) shown, so closing the reader returns to it.
    var lastList: Screen = .home
    @Published var screen: Screen = .home
    /// A page, revision or image is owned by the main reader, never mirrored in its browser.
    func screen(for surface: AlexandriaSurface) -> Screen {
        surface == .browser && reading ? .home : screen
    }
    @Published var drafts: [UUID: Draft] = [:] {
        didSet {
            guard drafts != oldValue else { return }
            if drafts.isEmpty { defaults.removeObject(forKey: Self.draftsKey) }
            else if let data = try? JSONEncoder().encode(drafts) { defaults.set(data, forKey: Self.draftsKey) }
        }
    }
    @Published var editing: UUID?
    @Published var highlight = ""
    @Published var notice: String?
    @Published var conflict: LibraryPage?
    @Published var viewingRevision: UUID?

    func show(page: UUID, highlight: String = "") {
        self.highlight = highlight; viewingRevision = nil; notice = nil
        screen = .page(page); open = true; openReader()
    }
    /// Small views (Below, Dock, Drawer, Peek) are for finding; pages always read full size.
    func openReader() { if !reading { reading = true; readerOpenedForPage = true } }
    /// Leaves the full-size reader; a page chosen from a small view goes back to its list.
    func closeReader() {
        reading = false
        if readerOpenedForPage { switch screen { case .page, .history, .screenshot: screen = lastList; highlight = ""; notice = nil; viewingRevision = nil; default: break } }
        readerOpenedForPage = false
    }
    func go(_ next: Screen) {
        notice = nil; viewingRevision = nil
        switch next {
        case .page, .history, .screenshot: openReader()
        default:
            highlight = ""; lastList = next
            if readerOpenedForPage { reading = false; readerOpenedForPage = false }
        }
        screen = next
    }
    func startNew(in section: LibrarySection, projectID: UUID?) {
        let id = UUID()
        drafts[id] = Draft(projectID: projectID, title: "", body: "", section: section == .home ? LibrarySection.shared.rawValue : section.rawValue, baseRevision: nil)
        editing = id; highlight = ""; notice = nil; screen = .page(id); openReader()
    }
    func edit(_ page: LibraryPage, projectID: UUID?) {
        if drafts[page.id] == nil { drafts[page.id] = Draft(projectID: projectID, title: page.title, body: page.body, section: page.section, baseRevision: page.revision) }
        editing = page.id; highlight = ""; notice = nil
    }
    func drafts(for projectID: UUID?) -> [(UUID, Draft)] { drafts.filter { $0.value.projectID == projectID }.map { ($0.key, $0.value) } }
}

enum AlexandriaMode: String, CaseIterable {
    case peek, dock, below, drawer
    var label: String { switch self { case .peek: return "Peek"; case .dock: return "Dock"; case .below: return "Below"; case .drawer: return "Drawer" } }
    var symbol: String { switch self { case .peek: return "rectangle.bottomthird.inset.filled"; case .dock: return "sidebar.right"; case .below: return "rectangle.bottomhalf.inset.filled"; case .drawer: return "square.rightthird.inset.filled" } }
    var help: String {
        switch self {
        case .peek: return "Peek: a short reading strip under the composer"
        case .dock: return "Dock: beside the chat on wide windows"
        case .below: return "Below: the full library under the composer"
        case .drawer: return "Drawer: slides over the chat from the right"
        }
    }
}

/// The tab rail on the right edge. Tabs appear only once they do something real.
struct AlexandriaRail: View {
    @ObservedObject var state: AlexandriaState
    var body: some View {
        VStack(spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.18)) { state.open.toggle() } } label: {
                VStack(spacing: 4) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "building.columns").font(.system(size: 17))
                        if !state.drafts.isEmpty { Circle().fill(SilkwireTheme.accent).frame(width: 6, height: 6).offset(x: 5, y: -2) }
                    }
                    Text(Alexandria.name).font(.system(size: 9.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                }
                .frame(width: 62, height: 54)
                .background(state.open ? SilkwireTheme.wash(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(state.open ? SilkwireTheme.accent : Color.secondary)
            .help("Alexandria, the team library · ⇧⌘L")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .accessibilityLabel(state.open ? "Close Alexandria" : "Open Alexandria")
            Button { withAnimation(.easeOut(duration: 0.18)) { state.futureOpen.toggle() } } label: {
                VStack(spacing: 4) {
                    Image(systemName: "star.circle").font(.system(size: 17))
                    Text("Future").font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                }
                .frame(width: 62, height: 54)
                .background(state.futureOpen ? SilkwireTheme.wash(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(state.futureOpen ? SilkwireTheme.accent : Color.secondary)
            .help("Future: North Stars and what comes next · ⌥⌘F")
            .keyboardShortcut("f", modifiers: [.command, .option])
            .accessibilityLabel(state.futureOpen ? "Close Future" : "Open Future")
            Spacer(minLength: 0)
        }
        .padding(.top, 12).frame(width: 70)
        .background(SilkwireTheme.wash(0.02))
        .overlay(alignment: .leading) { Rectangle().fill(SilkwireTheme.line).frame(width: 1) }
    }
}

/// One disclosure owner per contents list: opening a folder replaces the previous
/// one. This is view state only; browsing never changes a page or its saved folder.
struct AlexandriaFolderDisclosure: Equatable {
    private(set) var expandedFolder: String?

    func isExpanded(_ folder: String) -> Bool {
        folder.isEmpty || expandedFolder == folder
    }

    mutating func toggle(_ folder: String) {
        guard !folder.isEmpty else { return }
        expandedFolder = expandedFolder == folder ? nil : folder
    }

    mutating func reveal(pageID: UUID, in pages: [LibraryPage]) {
        let folder = Alexandria.contentsGroups(pages).first { group in
            group.pages.contains { $0.id == pageID }
        }?.folder
        expandedFolder = folder?.isEmpty == false ? folder : nil
    }

    mutating func reconcile(in pages: [LibraryPage]) {
        guard let expandedFolder else { return }
        if !Alexandria.contentsGroups(pages).contains(where: { $0.folder == expandedFolder }) {
            self.expandedFolder = nil
        }
    }
}

/// A folder is a disclosure control, never a page. Top-level pages have no
/// artificial folder; contained pages sit one clear step inside their folder.
/// Expansion comes from the list owner, never independent state in each row.
struct AlexandriaContentsGroup: View {
    let folder: String
    let pages: [LibraryPage]
    let currentID: UUID
    let expanded: Bool
    var toggle: () -> Void
    var open: (UUID) -> Void

    init(folder: String, pages: [LibraryPage], currentID: UUID, expanded: Bool = false, toggle: @escaping () -> Void = {}, open: @escaping (UUID) -> Void) {
        self.folder = folder; self.pages = pages; self.currentID = currentID
        self.expanded = expanded; self.toggle = toggle; self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !folder.isEmpty {
                Button { toggle() } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 10, height: 14)
                        Image(systemName: expanded ? "folder.fill" : "folder")
                            .foregroundStyle(SilkwireTheme.accent).frame(width: 14)
                        Text(folder).font(.system(size: 11, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        Spacer(minLength: 2)
                        Text("\(pages.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 6)
                .help((expanded ? "Collapse folder: " : "Expand folder: ") + folder)
                .accessibilityLabel("Folder: " + folder)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide this folder's pages. Opening it closes the other folder.")
            }
            if folder.isEmpty || expanded {
                ForEach(pages) { page in
                    Button { open(page.id) } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "doc.text").font(.system(size: 11)).frame(width: 14, height: 16)
                            Text(page.title).font(.system(size: 12, weight: page.id == currentID ? .medium : .regular))
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(page.id == currentID ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).padding(.horizontal, 8)
                        .background(page.id == currentID ? SilkwireTheme.wash(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.leading, folder.isEmpty ? 0 : 22)
                    .id(page.id).help(page.sourcePath ?? page.title)
                    .accessibilityLabel("Page: " + page.title)
                    .accessibilityValue(page.id == currentID ? "Current page" : "")
                }
            }
        }
    }
}

/// A fresh list starts with every folder closed, including the selected page's
/// folder. Later navigation reveals only the destination folder. The caller gives
/// the whole list a Project/vault identity so disclosure cannot leak across them.
struct AlexandriaContentsList: View {
    let title: String
    let pages: [LibraryPage]
    let currentID: UUID
    var open: (UUID) -> Void
    @State private var disclosure = AlexandriaFolderDisclosure()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .serif)).padding(.horizontal, 8).padding(.bottom, 4)
                    ForEach(Alexandria.contentsGroups(pages), id: \.folder) { group in
                        AlexandriaContentsGroup(folder: group.folder, pages: group.pages, currentID: currentID,
                                                expanded: disclosure.isExpanded(group.folder),
                                                toggle: { disclosure.toggle(group.folder) }) { id in
                            open(id)
                        }
                    }
                }.padding(10)
            }
            .onAppear { proxy.scrollTo(currentID, anchor: .center) }
            .onChange(of: currentID) { _, id in disclosure.reveal(pageID: id, in: pages) }
            .onChange(of: pages) { _, updated in disclosure.reconcile(in: updated) }
        }
    }
}

/// The browser finds pages; only the explicitly hosted reader draws their contents.
enum AlexandriaSurface { case browser, reader }

enum AlexandriaReaderLayout {
    static let contentsWidth: CGFloat = 220
    static let minimumPageWidth: CGFloat = 460
    static func showsContents(availableWidth: CGFloat) -> Bool {
        availableWidth.isFinite && availableWidth >= contentsWidth + 1 + minimumPageWidth
    }
}

struct AlexandriaPanel: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var state: AlexandriaState
    @Binding var mode: String
    var dockAvailable: Bool
    var compact = false
    var surface: AlexandriaSurface = .browser
    @State private var contentsVisible = true
    @State private var contentsPopover = false
    private var displayScreen: AlexandriaState.Screen { state.screen(for: surface) }
    @State private var confirmDiscard: UUID?
    @State private var showImport = false
    @AppStorage("alexandria.readerSerif") private var readerSerif = false
    @AppStorage("alexandria.readerSize") private var readerSize = 17.0
    @State private var removingVault: ImportedVaultGroup?
    @State private var vaultNotice: String?

    private var pages: [LibraryPage] { store.libraryPages }
    private var projectID: UUID? { store.conversation.projectID }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(SilkwireTheme.line).frame(height: 1)
            if surface == .browser && state.reading {
                // Keep the dock on Welcome while the sole reader owns the page/editor/image.
                ScrollView { homeView.padding(16) }
            }
            else if compact { peekBody }
            else if surface == .reader, state.reading, case .page(let id) = displayScreen, let current = pages.first(where: { $0.id == id }), state.editing != id {
                GeometryReader { geometry in
                    let fits = AlexandriaReaderLayout.showsContents(availableWidth: geometry.size.width)
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Button {
                                if fits { contentsVisible.toggle() } else { contentsPopover.toggle() }
                            } label: { Label("Contents", systemImage: "sidebar.left") }
                            .buttonStyle(.borderless).accessibilityLabel("Show or hide contents sidebar")
                            .popover(isPresented: $contentsPopover, arrowEdge: .leading) {
                                contentsSidebar(current).frame(height: 480)
                            }
                            Spacer()
                            if !fits { contentsMenu(current) }
                        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
                        HStack(spacing: 0) {
                            if fits && contentsVisible {
                                contentsSidebar(current)
                                Rectangle().fill(SilkwireTheme.line).frame(width: 1)
                            }
                            content.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            else { content }
        }
        .background(SilkwireTheme.reading)
        .confirmationDialog("Discard your unsaved changes?", isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } })) {
            Button("Discard changes", role: .destructive) { if let id = confirmDiscard { discard(id) }; confirmDiscard = nil }
            Button("Keep editing", role: .cancel) { confirmDiscard = nil }
        } message: { Text("The saved page stays as it was.") }
        .alert("Remove \(removingVault?.name ?? "vault") from Alexandria?", isPresented: Binding(get: { removingVault != nil }, set: { if !$0 { removingVault = nil } }), presenting: removingVault) { vault in
            Button("Remove \(vault.pageIDs.count) page" + (vault.pageIDs.count == 1 ? "" : "s"), role: .destructive) {
                switch store.removeImportedVault(vault.id) {
                case .success(let n): vaultNotice = "Removed \(n) page" + (n == 1 ? "" : "s") + " from \(vault.name). A backup was saved in Silkwire's Removed Pages folder, and your Obsidian vault is unchanged."
                case .failure(.message(let m)): vaultNotice = m
                }
                removingVault = nil
            }
            Button("Cancel", role: .cancel) { removingVault = nil }
        } message: { vault in
            Text("This removes the \(vault.pageIDs.count) imported page" + (vault.pageIDs.count == 1 ? "" : "s") + " from this Project's Alexandria. Your Obsidian vault and the team's own pages stay as they are, and a backup of the removed pages is saved first." + (vault.editedTitles.isEmpty ? "" : "\n\nEdited here since import (kept in the backup): " + vault.editedTitles.prefix(5).joined(separator: ", ") + (vault.editedTitles.count > 5 ? "…" : "")))
        }
        .sheet(isPresented: $showImport) { VaultImportSheet(store: store) { _ in state.go(.section(.vaults)) } }
        // Links between pages (from imported [[wiki links]]) open inside Alexandria.
        .environment(\.openURL, OpenURLAction { url in
            guard let title = Alexandria.linkedTitle(url) else { return .systemAction }
            if let page = Alexandria.page(titled: title, in: pages) { state.show(page: page.id) }
            else { state.notice = "There's no page called “\(title)” in Alexandria yet." }
            return .handled
        })
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 8) {
            if !compact, displayScreen != .home {
                Button { goBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Back").accessibilityLabel("Back")
            }
            Image(systemName: "building.columns").foregroundStyle(SilkwireTheme.accent)
            Text(Alexandria.name).font(.system(size: 15, weight: .semibold, design: .serif)).lineLimit(1).fixedSize()
            if let crumb = breadcrumb { Text("› " + crumb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1) }
            Spacer(minLength: 4)
            // One compact, named menu instead of four segments, so the header never squeezes her name.
            Menu {
                ForEach(AlexandriaMode.allCases, id: \.rawValue) { item in
                    Button { mode = item.rawValue } label: { Label(item.label + (mode == item.rawValue ? " (current)" : ""), systemImage: item.symbol) }.help(item.help)
                }
            } label: { Label((AlexandriaMode(rawValue: mode) ?? .below).label, systemImage: (AlexandriaMode(rawValue: mode) ?? .below).symbol).font(.system(size: 11.5)) }
            .menuStyle(.borderlessButton).fixedSize().help(dockAvailable ? "Peek, Dock or Drawer" : "Peek, Dock or Drawer · the window is too narrow to dock, so Dock shows as a drawer")
            if !compact && (surface == .reader || !state.reading) {
                Button { withAnimation(.easeOut(duration: 0.2)) { if state.reading { state.closeReader() } else { state.reading = true } } } label: { Image(systemName: state.reading ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help(state.reading ? "Back to the conversation (Esc)" : "Read full size").accessibilityLabel(state.reading ? "Back to the conversation" : "Read full size")
            }
            Button { withAnimation(.easeOut(duration: 0.18)) { state.closeReader(); state.open = false } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close Alexandria · unsaved drafts are kept").accessibilityLabel("Close Alexandria")
        }
        // Same row height and padding as the chat header, so the two header bands
        // and their divider lines line up across the window. Peek stays compact.
        .frame(minHeight: compact ? nil : SiloLayout.headerRowHeight)
        .padding(.horizontal, 14).padding(.vertical, compact ? 10 : SiloLayout.headerVerticalPadding)
    }
    private var breadcrumb: String? {
        switch displayScreen {
        case .home: return nil
        case .section(let s): return s.fullTitle
        case .page(let id), .history(let id):
            let title = pages.first { $0.id == id }?.title ?? state.drafts[id].map { $0.title.isEmpty ? "New page" : $0.title } ?? "Page"
            if case .history = state.screen { return title + " › History" }
            return title
        case .screenshots: return "Screenshots"
        case .screenshot: return "Screenshots › Image"
        }
    }
    private func goBack() {
        switch state.screen {
        case .home: break
        case .section: state.go(.home)
        case .page(let id):
            let section = pages.first { $0.id == id }?.librarySection ?? state.drafts[id].flatMap { LibrarySection(rawValue: $0.section) } ?? .home
            state.go(.section(section))
        case .history(let id): state.go(.page(id))
        case .screenshots: state.go(.home)
        case .screenshot: state.go(.screenshots)
        }
    }

    // MARK: Full panel
    @ViewBuilder private var content: some View {
        switch state.screen {
        case .home: ScrollView { homeView.padding(16) }
        case .section(let s): ScrollView { sectionView(s).padding(16) }
        case .page(let id): pageView(id)
        case .history(let id): ScrollView { historyView(id).padding(16) }
        case .screenshots: ScrollView { ScreenshotGallery(appDirectory: store.directory, projectID: projectID) { state.go(.screenshot($0)) }.padding(16) }
        case .screenshot(let id): ScrollView { ScreenshotViewer(appDirectory: store.directory, projectID: projectID, id: id) }
        }
    }

    private var notPrivateNote: some View {
        Label(Alexandria.notPrivate, systemImage: "person.3")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(SilkwireTheme.wash(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var homeView: some View {
        VStack(alignment: .leading, spacing: 14) {
            welcome
            groupLabel("SHELVES")
            sectionRow(.shared)
            Button { state.go(.screenshots) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle").frame(width: 18).foregroundStyle(.secondary)
                    Text("Screenshots").font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(projectID == nil).help("Screenshots sent in this project")
            groupLabel("HOMES")
            ForEach([LibrarySection.jason, .eve, .claude, .codex]) { sectionRow($0) }
            groupLabel("OUTSIDE REVIEWS")
            Text("Reports from outside agents and models, filed by kind.").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach([LibrarySection.reviewDesign, .reviewSecurity, .reviewCode]) { sectionRow($0) }
            groupLabel("VAULTS")
            let vaults = Alexandria.importedVaults(pages)
            if vaults.isEmpty { Text("No vaults imported yet.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 8) }
            ForEach(vaults) { vault in
                Button { state.go(.section(.vaults)) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox").frame(width: 18).foregroundStyle(.secondary)
                        Text(vault.name).font(.system(size: 13))
                        Spacer()
                        Text("\(vault.pageIDs.count) page" + (vault.pageIDs.count == 1 ? "" : "s")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            importButton.padding(.leading, 8)
            let unsaved = state.drafts(for: projectID)
            if !unsaved.isEmpty {
                groupLabel("UNSAVED DRAFTS")
                ForEach(unsaved, id: \.0) { id, draft in
                    pageRow(title: draft.title.isEmpty ? "New page" : draft.title, detail: "Not saved yet · " + (LibrarySection(rawValue: draft.section)?.fullTitle ?? ""), draft: true) { state.editing = id; state.go(.page(id)) }
                }
            }
            notPrivateNote.padding(.top, 8)
        }
    }
    // A front door rather than a form: greeting, one clear action, recent work first.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Welcome to Alexandria").font(.system(size: 20, weight: .semibold, design: .serif))
                Spacer(minLength: 8)
                Button { state.startNew(in: .shared, projectID: projectID) } label: { Label("New page", systemImage: "plus") }
                    .buttonStyle(SoftAccentButtonStyle(small: true)).disabled(store.storageError != nil || projectID == nil)
            }
            Text(pages.isEmpty ? "No pages yet. Write one in Shared, import an Obsidian vault, or ask a teammate to start one. Screenshots you send are already collected under Screenshots." : "The team's shared library: plans, decisions and notes that stay put between conversations.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let recent = pages.sorted { $0.updatedAt > $1.updatedAt }.prefix(5)
            if !recent.isEmpty {
                groupLabel("RECENTLY EDITED")
                ForEach(Array(recent)) { page in pageRow(page) }
            }
        }.padding(.bottom, 4)
    }
    private var importButton: some View {
        Button { showImport = true } label: { Label("Import from Obsidian…", systemImage: "square.and.arrow.down") }
            .buttonStyle(.borderless).disabled(store.storageError != nil || projectID == nil)
    }
    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.top, 6)
    }
    private func sectionRow(_ section: LibrarySection) -> some View {
        let count = pages.filter { $0.librarySection == section }.count
        return Button { state.go(.section(section)) } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(section.title).font(.system(size: 13)).foregroundStyle(count == 0 ? Color.secondary : Color.primary)
                Spacer()
                if count > 0 { Text("\(count) page\(count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func pageRow(_ page: LibraryPage) -> some View {
        pageRow(title: page.title, detail: page.sourcePath.map { "From " + $0 } ?? "\(page.librarySection.fullTitle) · edited by \(page.updatedBy) \(page.updatedAt.formatted(.relative(presentation: .named)))", draft: state.drafts[page.id] != nil) { state.show(page: page.id) }
    }
    private func pageRow(title: String, detail: String, draft: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if draft { Text("Unsaved edits").font(.system(size: 10)).foregroundStyle(SilkwireTheme.accent) }
            }.padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func sectionView(_ section: LibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(section.fullTitle, systemImage: section.symbol).font(.system(size: 16, weight: .semibold, design: .serif))
                Spacer()
                Button { state.startNew(in: section, projectID: projectID) } label: { Label("New page", systemImage: "plus") }
                    .buttonStyle(.bordered).disabled(store.storageError != nil || projectID == nil)
            }
            Text(section.blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if section.isPersonHome || section.isOutsideReview { notPrivateNote }
            if section == .vaults {
                importButton
                ForEach(Alexandria.importedVaults(pages)) { vault in
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox").foregroundStyle(.secondary)
                        Text(vault.name).font(.system(size: 13, weight: .medium))
                        Text("\(vault.pageIDs.count) page" + (vault.pageIDs.count == 1 ? "" : "s")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove from Alexandria…") { removingVault = vault }.buttonStyle(.borderless).font(.system(size: 11))
                            .disabled(store.storageError != nil).help("Removes this vault's imported pages from this Project. Your Obsidian vault is not touched.")
                    }.padding(8).background(SilkwireTheme.wash(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                if let vaultNotice { Text(vaultNotice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            let unsaved = state.drafts(for: projectID).filter { id, draft in draft.section == section.rawValue && !pages.contains { $0.id == id } }
            ForEach(unsaved, id: \.0) { id, draft in
                pageRow(title: draft.title.isEmpty ? "New page" : draft.title, detail: "Not saved yet", draft: true) { state.editing = id; state.go(.page(id)) }
            }
            let list = Alexandria.pages(pages, in: section)
            if list.isEmpty && unsaved.isEmpty { emptyShelf(section) }
            ForEach(list) { page in pageRow(page) }
        }
    }

    /// An empty shelf invites all three ways in: write, import, or ask a teammate.
    private func emptyShelf(_ section: LibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section == .vaults ? "No vaults imported yet." : "Nothing on this shelf yet.").font(.callout).foregroundStyle(.secondary)
            Text(section == .vaults ? "Bring in notes from an Obsidian vault. The vault itself is only read, never changed." : "Write the first page yourself, import notes from Obsidian, or ask a teammate in the conversation to draft one here.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if section != .vaults {
                    Button { state.startNew(in: section, projectID: projectID) } label: { Label("Write a page", systemImage: "square.and.pencil") }
                        .buttonStyle(.bordered).controlSize(.small).disabled(store.storageError != nil || projectID == nil)
                }
                Button { showImport = true } label: { Label("Import from Obsidian…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(store.storageError != nil || projectID == nil)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(SilkwireTheme.wash(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Compact contents for narrow windows: the same shelf or vault, as a menu.
    private func contentsMenu(_ current: LibraryPage) -> some View {
        let key = Alexandria.vaultKey(of: current)
        let siblings = key != nil ? pages.filter { Alexandria.vaultKey(of: $0) == key } : Alexandria.pages(pages, in: current.librarySection)
        return Menu {
            ForEach(Alexandria.contentsGroups(siblings), id: \.folder) { group in
                Section(group.folder.isEmpty ? (key != nil ? Alexandria.vaultName(of: current) : current.librarySection.fullTitle) : group.folder) {
                    ForEach(group.pages) { page in
                        Button { state.go(.page(page.id)) } label: { Label(page.title, systemImage: page.id == current.id ? "checkmark" : "doc.text") }
                    }
                }
            }
        } label: { Label("Contents", systemImage: "list.bullet") }
            .menuStyle(.borderlessButton).fixedSize().help("Other pages in this vault or shelf")
    }

    // MARK: Contents sidebar
    /// The open page's shelf (or vault, grouped by folder), so another page is one click away.
    private func contentsSidebar(_ current: LibraryPage) -> some View {
        let key = Alexandria.vaultKey(of: current)
        let siblings = key != nil ? pages.filter { Alexandria.vaultKey(of: $0) == key } : Alexandria.pages(pages, in: current.librarySection)
        let title = key != nil ? Alexandria.vaultName(of: current) : current.librarySection.fullTitle
        return AlexandriaContentsList(title: title, pages: siblings, currentID: current.id) { id in
            state.go(.page(id)); contentsPopover = false
        }
        // Reset the single open-folder choice when entering another Project or vault/shelf.
        .id("\(projectID?.uuidString ?? "")/\(key ?? current.librarySection.rawValue)")
        .frame(width: AlexandriaReaderLayout.contentsWidth)
        .background(SilkwireTheme.wash(0.02))
    }

    // MARK: Page
    @ViewBuilder private func pageView(_ id: UUID) -> some View {
        if state.editing == id, state.drafts[id] != nil { editor(id) }
        else if let page = pages.first(where: { $0.id == id }) { reader(page).frame(maxWidth: state.reading ? 820 : .infinity).frame(maxWidth: .infinity) }
        else if state.drafts[id] != nil { editor(id) }
        else { VStack(spacing: 10) { Text("This page isn't in this Project's library.").foregroundStyle(.secondary); Button("Library home") { state.go(.home) } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func reader(_ page: LibraryPage) -> some View {
        let query = state.highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        let highlighting = !query.isEmpty && Alexandria.contains(page.body, query)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(page.title).font(.system(size: state.reading ? 28 : 20, weight: .semibold, design: .serif)).textSelection(.enabled)
                    Text("\(page.librarySection.fullTitle) · edited by \(page.updatedBy), \(page.updatedAt.formatted(date: .abbreviated, time: .shortened)) · version \(page.revision)").font(.system(size: 11)).foregroundStyle(.secondary)
                    if let source = page.sourcePath { Label("Imported from " + source, systemImage: "archivebox").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                    HStack(spacing: 8) {
                        Button { state.edit(page, projectID: projectID) } label: { Label(state.drafts[page.id] == nil ? "Edit" : "Continue editing", systemImage: "pencil") }.buttonStyle(.bordered).disabled(store.storageError != nil)
                        Button { state.go(.history(page.id)) } label: { Label("History", systemImage: "clock.arrow.circlepath") }.buttonStyle(.bordered).disabled(page.history.isEmpty)
                        if state.reading {
                            Menu {
                                Picker("Reading font", selection: $readerSerif) { Text("Default").tag(false); Text("Serif").tag(true) }.pickerStyle(.inline)
                                Divider()
                                Button("Larger text") { readerSize = min(readerSize + 1, 24) }.disabled(readerSize >= 24)
                                Button("Smaller text") { readerSize = max(readerSize - 1, 13) }.disabled(readerSize <= 13)
                                Button("Default size") { readerSize = 17 }.disabled(readerSize == 17)
                            } label: { Image(systemName: "textformat.size") }
                                .menuStyle(.borderlessButton).fixedSize().help("Reading font and text size").accessibilityLabel("Reading font and text size")
                        }
                        Spacer()
                    }
                    if let notice = state.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if highlighting {
                        HStack {
                            Image(systemName: "text.magnifyingglass")
                            Text("Matches for “\(query)” are highlighted.")
                            Spacer()
                            Button("Show formatted") { state.highlight = "" }.buttonStyle(.borderless)
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(8).background(SilkwireTheme.wash(0.04), in: RoundedRectangle(cornerRadius: 7))
                        HighlightedLines(text: page.body, query: query)
                    } else if page.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("This page is empty.").foregroundStyle(.tertiary)
                    } else {
                        // Full-size reading gets bigger type and more air between lines.
                        MessageMarkdown(source: AlexandriaReading.displayBody(page.body, title: page.title), libraryLinks: true, bodySize: state.reading ? readerSize : 14.5, serif: state.reading && readerSerif).equatable()
                            .font(state.reading && readerSerif ? .system(size: readerSize, design: .serif) : SilkwireReadingType.body(state.reading ? readerSize : 14.5)).lineSpacing(state.reading ? 6 : 3)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollToMatch(page, query: query, proxy: proxy) }
            .onChange(of: state.highlight) { _, _ in scrollToMatch(page, query: state.highlight, proxy: proxy) }
        }
    }
    private func scrollToMatch(_ page: LibraryPage, query: String, proxy: ScrollViewProxy) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let line = page.body.components(separatedBy: "\n").firstIndex(where: { Alexandria.contains($0, q) }) else { return }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(120)); withAnimation { proxy.scrollTo("hl-\(line)", anchor: .center) } }
    }

    private func draftBinding(_ id: UUID) -> Binding<AlexandriaState.Draft> {
        Binding(get: { state.drafts[id] ?? AlexandriaState.Draft(projectID: projectID, title: "", body: "", section: LibrarySection.shared.rawValue, baseRevision: nil) },
                set: { state.drafts[id] = $0 })
    }
    private func editor(_ id: UUID) -> some View {
        let draft = draftBinding(id)
        let existing = pages.first { $0.id == id }
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Page title", text: draft.title).textFieldStyle(.plain).font(.system(size: 18, weight: .semibold, design: .serif))
            Picker("Section", selection: draft.section) {
                ForEach(LibrarySection.allCases.filter { $0 != .home }) { Text($0.fullTitle).tag($0.rawValue) }
            }.fixedSize()
            if let conflict = state.conflict, conflict.id == id { conflictBanner(id, conflict) }
            if let notice = state.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            TextEditor(text: draft.body)
                .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(6).background(SilkwireTheme.wash(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SilkwireTheme.line))
                .frame(minHeight: 220, maxHeight: .infinity)
            Text("Markdown welcome. Each save keeps the previous version in History (the latest 50). " + Alexandria.notMemory).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let existing { Text("Editing version \(draft.wrappedValue.baseRevision ?? existing.revision)").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                Spacer()
                Button("Cancel") { cancel(id) }.keyboardShortcut(.cancelAction)
                Button("Save") { save(id) }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(store.storageError != nil || draft.wrappedValue.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16)
    }
    private func conflictBanner(_ id: UUID, _ theirs: LibraryPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(theirs.updatedBy) saved this page at \(theirs.updatedAt.formatted(date: .omitted, time: .shortened)) while you were editing. Nothing was overwritten, and your edits are still here.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Save mine as a copy") { saveCopy(id) }
                Button("Save mine anyway") { save(id, overTheirs: true) }.help("Their version stays in History")
            }.buttonStyle(.bordered).font(.system(size: 11))
        }.padding(10).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func save(_ id: UUID, overTheirs: Bool = false) {
        guard var draft = state.drafts[id] else { return }
        guard draft.projectID == projectID else { state.notice = "This draft belongs to another Project. Open a conversation there to save it."; return }
        // Overwrite only the version shown in the warning. If yet another save
        // arrived while the warning was open, the engine refuses and warns again.
        if overTheirs { guard let shown = state.conflict, shown.id == id else { return }; draft.baseRevision = shown.revision }
        switch store.saveLibraryPage(id: id, section: draft.section, title: draft.title, body: draft.body, baseRevision: draft.baseRevision) {
        case .saved, .unchanged:
            state.drafts[id] = nil; state.editing = nil; state.conflict = nil
            state.notice = "Saved."; state.screen = .page(id)
        case .conflict(let theirs): state.conflict = theirs; state.notice = nil
        case .invalid(let message): state.notice = message
        }
    }
    private func saveCopy(_ id: UUID) {
        guard let draft = state.drafts[id], draft.projectID == projectID else { return }
        let copy = UUID()
        let title = String(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Alexandria.titleLimit - 16)) + " (Jason's copy)"
        switch store.saveLibraryPage(id: copy, section: draft.section, title: title, body: draft.body, baseRevision: nil) {
        case .saved:
            state.drafts[id] = nil; state.editing = nil; state.conflict = nil
            state.show(page: copy); state.notice = "Saved as a separate page."
        case .conflict, .unchanged: break
        case .invalid(let message): state.notice = message
        }
    }
    private func cancel(_ id: UUID) {
        guard let draft = state.drafts[id] else { state.editing = nil; return }
        let page = pages.first { $0.id == id }
        let changed = page.map { draft.title != $0.title || draft.body != $0.body || draft.section != $0.section } ?? (!draft.title.isEmpty || !draft.body.isEmpty)
        if changed { confirmDiscard = id } else { discard(id) }
    }
    private func discard(_ id: UUID) {
        let existed = pages.contains { $0.id == id }
        let section = state.drafts[id].flatMap { LibrarySection(rawValue: $0.section) } ?? .home
        state.drafts[id] = nil; state.editing = nil; state.conflict = nil; state.notice = nil
        if !existed { state.go(.section(section)) }
    }

    // MARK: History
    private func historyView(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let page = pages.first(where: { $0.id == id }) {
                Text("The latest \(Alexandria.historyLimit) earlier versions are kept here; older ones drop off. Restoring saves the old text as a new version, so the current text stays in History too.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                historyRow(title: "Version \(page.revision) · current", detail: "\(page.updatedBy) · \(page.updatedAt.formatted(date: .abbreviated, time: .shortened))", selected: state.viewingRevision == nil) { state.viewingRevision = nil }
                ForEach(page.history.reversed()) { old in
                    historyRow(title: "Version \(old.revision)" + (old.title == page.title ? "" : " · “\(old.title)”"), detail: "\(old.author) · \(old.savedAt.formatted(date: .abbreviated, time: .shortened))", selected: state.viewingRevision == old.id) { state.viewingRevision = old.id }
                }
                Rectangle().fill(SilkwireTheme.line).frame(height: 1).padding(.vertical, 4)
                if let rid = state.viewingRevision, let old = page.history.first(where: { $0.id == rid }) {
                    HStack {
                        Text("Version \(old.revision)").font(.headline)
                        Spacer()
                        Button("Restore this version") {
                            switch store.restoreLibraryRevision(pageID: page.id, revisionID: rid) {
                            case .saved: state.notice = "Restored version \(old.revision) as version \(page.revision + 1)."; state.viewingRevision = nil; state.screen = .page(page.id)
                            case .unchanged: state.notice = "That version matches the current page."
                            case .conflict: state.notice = "The page changed just now. Try again."
                            case .invalid(let message): state.notice = message
                            }
                        }.buttonStyle(.bordered).disabled(store.storageError != nil)
                    }
                    MessageMarkdown(source: old.body).equatable()
                } else {
                    MessageMarkdown(source: AlexandriaReading.displayBody(page.body, title: page.title), libraryLinks: true).equatable()
                }
                if let notice = state.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            } else { Text("This page isn't in this Project's library.").foregroundStyle(.secondary) }
        }
    }
    private func historyRow(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 10)).foregroundStyle(selected ? SilkwireTheme.accent : Color.secondary)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: Peek
    @ViewBuilder private var peekBody: some View {
        if case .page(let id) = state.screen, let page = pages.first(where: { $0.id == id }) {
            let query = state.highlight.trimmingCharacters(in: .whitespacesAndNewlines)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(page.title).font(.system(size: 15, weight: .semibold, design: .serif))
                        Spacer()
                        Button(state.drafts[id] == nil ? "Edit" : "Continue editing") { state.edit(page, projectID: projectID); mode = AlexandriaMode.drawer.rawValue }.buttonStyle(.borderless).font(.system(size: 11))
                        Button("Open full") { mode = dockAvailable ? AlexandriaMode.dock.rawValue : AlexandriaMode.drawer.rawValue }.buttonStyle(.borderless).font(.system(size: 11))
                    }
                    if !query.isEmpty && Alexandria.contains(page.body, query) { HighlightedLines(text: page.body, query: query) }
                    else { MessageMarkdown(source: AlexandriaReading.displayBody(page.body, title: page.title), libraryLinks: true).equatable() }
                }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(pages.isEmpty ? "Alexandria" : "\(pages.count) page\(pages.count == 1 ? "" : "s") in this Project's library").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open full") { mode = dockAvailable ? AlexandriaMode.dock.rawValue : AlexandriaMode.drawer.rawValue }.buttonStyle(.borderless).font(.system(size: 11))
                    }
                    if state.editing != nil { Text("A page is being edited. Open full to continue.").font(.system(size: 11)).foregroundStyle(SilkwireTheme.accent) }
                    if pages.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Welcome to Alexandria").font(.system(size: 15, weight: .semibold, design: .serif))
                            Spacer()
                            Button { state.startNew(in: .shared, projectID: projectID); mode = dockAvailable ? AlexandriaMode.dock.rawValue : AlexandriaMode.drawer.rawValue } label: { Label("New page", systemImage: "plus") }
                                .buttonStyle(SoftAccentButtonStyle(small: true)).disabled(store.storageError != nil || projectID == nil)
                        }
                        Text("The shelves are waiting. Start a page in Shared, or import notes from Obsidian.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(pages.sorted { $0.updatedAt > $1.updatedAt }.prefix(6))) { page in pageRow(page) }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }
}

/// Plain text with every match highlighted; each line is a scroll target ("hl-N").
struct HighlightedLines: View {
    let text: String
    let query: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                Text(Self.highlighted(line, query)).font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).id("hl-\(index)")
            }
        }
    }
    static func highlighted(_ line: String, _ query: String) -> AttributedString {
        var value = AttributedString(line)
        for range in SearchHit.ranges(line, query) {
            guard let swiftRange = Range(range, in: line),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: value),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: value) else { continue }
            value[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
        }
        return value
    }
}

/// Site-wide search results, shown under the search bar.
struct SiteSearchResults: View {
    let query: String
    let currentMatches: Int
    let conversations: [ConversationSearchHit]
    let pages: [LibraryHit]
    var pick: (String) -> Void
    var openCurrent: () -> Void
    var openConversation: (ConversationSearchHit) -> Void
    var openPage: (LibraryHit) -> Void
    var close: () -> Void
    static let examples = ["Pass button", "chime", "Outside Reviews", "memory"]
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if trimmed.isEmpty {
                        group("TRY")
                        ForEach(Self.examples, id: \.self) { example in row("magnifyingglass", example, nil) { pick(example) } }
                    } else {
                        if currentMatches > 0 {
                            group("IN THIS CONVERSATION")
                            row("text.magnifyingglass", "\(currentMatches) match\(currentMatches == 1 ? "" : "es") here", "Step through them with the arrows", action: openCurrent)
                        }
                        if !conversations.isEmpty {
                            group("CONVERSATIONS")
                            ForEach(conversations) { hit in
                                row("bubble.left", (hit.archived ? "Archived · " : "") + hit.title, hit.excerpt, trailing: hit.matches > 0 ? "\(hit.matches)" : nil) { openConversation(hit) }
                            }
                        }
                        if !pages.isEmpty {
                            group("ALEXANDRIA")
                            ForEach(pages) { hit in row("doc.text", hit.title, hit.section.fullTitle + (hit.excerpt.isEmpty ? "" : " · " + hit.excerpt)) { openPage(hit) } }
                        }
                        if currentMatches == 0 && conversations.isEmpty && pages.isEmpty {
                            Text("No matches for “\(trimmed)”.").font(.callout).foregroundStyle(.secondary).padding(10)
                        }
                    }
                }.padding(8)
            }
            Rectangle().fill(SilkwireTheme.line).frame(height: 1)
            HStack {
                Text("Searches every conversation and this Project's Alexandria. Files come later.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: close).buttonStyle(.borderless).font(.system(size: 10.5))
            }.padding(.horizontal, 10).padding(.vertical, 7)
        }
        .frame(width: 440).frame(maxHeight: 420)
        .background(SilkwireTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SilkwireTheme.line))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
    private func group(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
    }
    private func row(_ symbol: String, _ title: String, _ detail: String?, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if let detail, !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
                if let trailing { Text(trailing).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary) }
            }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// What the reader shows of a page. Many notes open with a heading that repeats the
/// page's own title; the reader already shows the title, so that first heading is
/// hidden. Presentation only: the stored page is never changed.
enum AlexandriaReading {
    static func displayBody(_ body: String, title: String) -> String {
        let wanted = title.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return body }
        var lines = body.components(separatedBy: "\n")
        // Share the reader's conservative metadata recognition. An ordinary quote
        // is content, so a heading after it must not be mistaken for a repeated title.
        let details = DocumentDetails.split(body)
        var index = details.fields.isEmpty ? 0 : lines.count - details.body.components(separatedBy: "\n").count
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { index += 1; continue }
            for marker in ["# ", "## "] where line.hasPrefix(marker) {
                if line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).lowercased() == wanted {
                    lines.remove(at: index)
                    return lines.joined(separator: "\n")
                }
            }
            return body
        }
        return body
    }
}
