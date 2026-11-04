import SwiftUI
import AppKit

struct ConversationView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject private var setup = SetupModel.shared
    @ObservedObject var notifications: CompletionNotifications
    @State private var followPaused = false
    @State private var newReplies = false
    /// Your just-sent message, held at the top while replies arrive (ReplyScroll).
    @State private var pinnedPrompt: UUID?
    /// Rows on screen when this conversation opened (TranscriptFlow.displayOrder).
    @State private var revealBaseline: Set<UUID>?
    /// Order in which later rows first appeared.
    @State private var revealSeq: [UUID: Int] = [:]
    /// Latest row frames, kept outside SwiftUI state so reading them never redraws.
    @State private var rowFrames = TranscriptFrameBox()
    /// Jason's first prompt of the current set: the "stopper". Replies rise into view until
    /// it reaches the top of the window; after that the view stays put and later replies
    /// stack below it (everything below it is what's left to read).
    @State private var roundPrompt: UUID?
    @State private var transcriptEndY: CGFloat?
    @State private var followGlide = false
    @State private var readingAnchor: UUID?
    @State private var stableReadingAnchor: UUID?
    @State private var anchorSettlement: Task<Void, Never>?
    @State private var resizeAnchor: UUID?
    @State private var resizeRestore: Task<Void, Never>?
    @State private var hitIndex = 0
    @State private var showArchived = false
    @State private var newProjectID: UUID?
    @State private var renameID: UUID?
    @State private var deleteID: UUID?
    @State private var confirmingDeletion = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var projectSearch = ""
    @State private var messageSearch = ""
    @State private var showFind = false
    @State private var showContext = false
    @State private var showOptions = false
    @State private var showBrief = false
    @State private var editingProject: Project?
    @State private var renaming = false
    @State private var proposedTitle = ""
    @FocusState private var findFocused: Bool
    @FocusState private var projectSearchFocused: Bool
    @State private var composerFocusRequest = UUID()
    @AppStorage("composer.sidePanel") private var sideComposer = false
    @AppStorage("composer.sideHeight") private var sideHeight = 420.0
    @State private var sideWidth: CGFloat = 450
    @State private var sideDragStart: CGFloat?
    @State private var sideLayoutActive = false
    @StateObject private var library = AlexandriaState()
    @StateObject private var future = FutureStore()
    @AppStorage("alexandria.mode") private var libraryMode = AlexandriaMode.below.rawValue
    @State private var siteQuery = ""
    @State private var showSiteResults = false
    @FocusState private var siteFocused: Bool
    @State private var returnConversation: UUID?
    /// How many of the newest messages the transcript draws (see TranscriptWindow).
    @State private var shownLimit = TranscriptWindow.initial
    /// Conversations open as silos, slid between with ‹ › (Codex's ConversationDeck).
    @AppStorage("silo.deck.v1") private var savedDeck = ""
    @State private var deck = ConversationDeck()
    private var availableSilos: Set<UUID> { Set(store.conversations.filter { !$0.archived }.map(\.id)) }
    private func syncDeck() {
        let updated = SiloNavigator.synced(deck, current: store.conversation.id, available: availableSilos)
        if updated != deck { deck = updated; savedDeck = SiloNavigator.encode(updated) }
    }
    private func slide(_ step: SiloNavigator.Step) {
        guard let target = SiloNavigator.target(deck, step) else { return }
        let switched = store.selectConversation(target)
        if !switched { store.status = "Finish or stop the current reply before sliding to another conversation."; return }
        SiloNavigator.commit(&deck, to: target, switched: true); savedDeck = SiloNavigator.encode(deck)
    }
    private func closeSilo() {
        guard let next = SiloNavigator.closing(deck, current: store.conversation.id) else { return }
        guard store.selectConversation(next.show) else { store.status = "Finish or stop the current reply before closing this conversation's silo."; return }
        deck = next.deck; savedDeck = SiloNavigator.encode(deck)
    }
    /// ‹ 2 of 4 › beside the name pills, shown once more than one silo is open.
    @ViewBuilder private var siloControls: some View {
        if let label = SiloNavigator.label(deck) {
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Button { slide(.previous) } label: {
                        Image(systemName: "chevron.left").frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(deck.previousID == nil || !store.canChangeConversation)
                    .help("Slide to the conversation on the left").accessibilityLabel("Previous conversation")
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    Text(label).font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        .accessibilityLabel("Conversation \(label)")
                    Button { slide(.next) } label: {
                        Image(systemName: "chevron.right").frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(deck.nextID == nil || !store.canChangeConversation)
                    .help("Slide to the conversation on the right").accessibilityLabel("Next conversation")
                    .keyboardShortcut("]", modifiers: [.command, .option])
                }.padding(.horizontal, 4).background(SilkwireTheme.wash(0.04), in: RoundedRectangle(cornerRadius: 7))
                Button { closeSilo() } label: {
                    Image(systemName: "xmark").font(.caption2).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!store.canChangeConversation)
                .help("Close this silo. The conversation stays in the sidebar; nothing is archived or deleted.")
                .accessibilityLabel("Close this conversation's silo")
            }
        }
    }
    private var siteTrimmed: String { siteQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var following: Bool { store.preferences.autoScrollReplies && !followPaused && messageSearch.isEmpty }
    private var searchHits: [SearchHit] { SearchHit.find(in: store.conversation.messages, query: messageSearch) }
    private var replyRevision: UInt64 { store.transcriptRevision }
    private var currentHit: SearchHit? { searchHits.indices.contains(hitIndex) ? searchHits[hitIndex] : nil }
    private var visibleProjects: [Project] { store.projects.filter { project in
        projectSearch.isEmpty || project.name.localizedStandardContains(projectSearch) || store.conversations.contains { $0.projectID == project.id && $0.matches(projectSearch) }
    } }
    #if SILKWIRE_TESTING
    // Keep fixture setup outside the large SwiftUI expression so the verification
    // build type-checks this ordinary state mutation separately from the view tree.
    private func prepareAcceptanceView() {
        switch ProcessInfo.processInfo.environment["SILKWIRE_ACCEPTANCE"] {
        case "design-search": showFind = true; messageSearch = "conversation"; followPaused = true; hitIndex = 1
        case "design-paused": followPaused = true; newReplies = true
        case "design-connections": store.connectionsPresented = true
        case "design-builder": store.builderPresented = true
        case "design-project": editingProject = store.activeProject
        case "design-new": store.newConversationPresented = true
        default: break
        }
    }
    #endif
    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { store.preferences.sidebarVisible ? .all : .detailOnly }, set: { store.setSidebarVisible($0 != .detailOnly) })) {
            sidebar.navigationSplitViewColumnWidth(min: 245, ideal: 278, max: 350)
        } detail: { conversationPane }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            if #available(macOS 26.0, *) { ToolbarItem(placement: .principal) { Text(WorkspaceEnvironment.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(store.environment.staging ? SilkwireTheme.stagingTint : SilkwireTheme.ink) }.sharedBackgroundVisibility(.hidden) }
            else { ToolbarItem(placement: .principal) { Text(WorkspaceEnvironment.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(store.environment.staging ? SilkwireTheme.stagingTint : SilkwireTheme.ink) } }
        }
        .background(WindowChrome())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 840, minHeight: 650)
        .overlay { PaperGrain() }.silkwireAppearance().tint(store.environment.staging ? SilkwireTheme.stagingTint : SilkwireTheme.accent)
        .sheet(item: $editingProject) { proposal in ProjectEditor(project: proposal, isNew: !store.projects.contains { $0.id == proposal.id }, store: store) }
        .sheet(isPresented: $store.connectionsPresented) { ConnectionsView(store: store) }
        .sheet(isPresented: $store.builderPresented) { BuilderView(store: store) }
        .sheet(isPresented: $store.helpPresented) { NativeHelpView() }
        .sheet(isPresented: $setup.presented) { OnboardingView(store: store, setup: setup) }
        .task { try? await Task.sleep(nanoseconds: 1_500_000_000); if setup.shouldAutoPresent(store) { setup.presented = true } }
        .sheet(isPresented: $store.stagingInstallPresented) { StagingInstallView(store: store) }
        .alert("Rename conversation", isPresented: $renaming) {
            TextField("Conversation name", text: $proposedTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.renameConversation(proposedTitle, id: renameID) }
        }
        .sheet(isPresented: $store.newConversationPresented, onDismiss: { newProjectID = nil }) {
            ConversationNameSheet { title in
                if let id = newProjectID { _ = store.newConversation(in: id, title: title) }
                else { _ = store.newConversation(title: title) }
                newProjectID = nil
            }
        }
        .alert("Permanently delete conversation?", isPresented: $confirmingDeletion, presenting: deleteID) { id in
            Button("Cancel", role: .cancel) {}
            Button("Delete permanently", role: .destructive) { _ = store.deleteConversation(id) }
        } message: { _ in Text("This removes the saved transcript, draft and session references from this Mac’s library. It does not delete provider-side sessions. Archive instead if you may want to return.") }
        .onChange(of: messageSearch) { _, _ in hitIndex = 0; if !messageSearch.isEmpty { followPaused = true } }
        .onAppear {
            followPaused = false; composerFocusRequest = UUID(); if NSApplication.shared.isActive { store.markRead() }
            #if SILKWIRE_TESTING
            prepareAcceptanceView()
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SilkwireDismissEditors"))) { _ in editingProject = nil; store.newConversationPresented = false; store.connectionsPresented = false; store.helpPresented = false; store.builderPresented = false; store.stagingInstallPresented = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.markRead() }
        .onAppear { deck = SiloNavigator.decode(savedDeck); syncDeck() }
        .onChange(of: store.conversations.map(\.archived)) { _, _ in syncDeck() }
        .onChange(of: store.conversation.id) { _, _ in syncDeck(); shownLimit = TranscriptWindow.initial; messageSearch = ""; showFind = false; showContext = false; showOptions = false; followPaused = false; newReplies = false; composerFocusRequest = UUID(); resizeRestore?.cancel(); resizeRestore = nil; resizeAnchor = nil; readingAnchor = nil; stableReadingAnchor = nil; anchorSettlement?.cancel() }
        #if SILKWIRE_TESTING
        .onChange(of: store.status) { _, _ in
            if store.status == "Visual fixture · native rendering, no live agents" {
                if ProcessInfo.processInfo.environment["SILKWIRE_ACCEPTANCE"] == "design-context" { showContext = true }
                if ProcessInfo.processInfo.environment["SILKWIRE_ACCEPTANCE"] == "design-options" { showOptions = true }
            }
        }
        #endif
        .onChange(of: store.conversation.messages.last?.text) { _, _ in if hitIndex >= searchHits.count { hitIndex = 0 } }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Ari on her strand (brand kit by Claude.app), name centred quietly beneath.
            // Walking Ari (Claude.app, Ari Walking 2): a short walk on launch, then still;
            // hover to walk again. Gentle skitter (Jason: 0.60 s a stride). She stops redrawing
            // once settled, and never moves with Reduce Motion on.
            AriWalkingMark(behavior: .intro(strides: AriSidebar.introStrides), skitterCadence: AriSidebar.skitterCadence, reduceMotion: store.preferences.reduceMotion)
                // Scale the complete mark together; her strand follows the search field's width.
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 18)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
                TextField("Find a Project or conversation…", text: $projectSearch).focused($projectSearchFocused).textFieldStyle(.plain).accessibilityLabel("Search Projects and conversations")
                if !projectSearch.isEmpty { Button { projectSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).accessibilityLabel("Clear Project search") }
            }.padding(10).background(SilkwireTheme.wash(0.035), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SilkwireTheme.line)).padding(.horizontal, 14)
            Text("Find words inside a conversation with ⌘F").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 17).padding(.top, 8)
            HStack {
                Text("PROJECTS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                Spacer()
                Button { editingProject = Project() } label: { Label("Create", systemImage: "plus") }.buttonStyle(.borderless).font(.system(size: 11)).disabled(!store.canChangeConversation).help("Create Project")
            }.padding(.horizontal, 18).padding(.top, 23).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleProjects) { project in projectCard(project) }
                    if visibleProjects.isEmpty { Text("No matching Projects.").font(.callout).foregroundStyle(.secondary).padding(18) }
                }.padding(.horizontal, 10).padding(.bottom, 16)
            }
            Toggle("Show archived conversations", isOn: $showArchived).toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 12)
            sidebarFooter
        }.background(LinearGradient(colors: [SilkwireTheme.sidebar, SilkwireTheme.sidebarFloor], startPoint: .top, endPoint: .bottom))
    }
    private func rooms(_ project: Project) -> [Conversation] {
        store.conversations.filter { $0.projectID == project.id && (showArchived || !$0.archived) && (projectSearch.isEmpty || project.name.localizedStandardContains(projectSearch) || $0.matches(projectSearch)) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func projectCard(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { store.toggleProject(project.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: project.expanded || !projectSearch.isEmpty ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                        ProjectIcon(project: project, size: 19)
                        Text(project.name).font(.system(size: 13, weight: .regular)).foregroundStyle(SilkwireTheme.project(project.color)).lineLimit(1)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(project.expanded ? "Collapse" : "Expand") \(project.name)")
                Spacer(minLength: 2)
                Menu {
                    Button("New conversation") { openNewConversation(in: project) }.disabled(!store.canChangeConversation)
                    Button("Edit Project…") { editingProject = project }.disabled(!store.canChangeConversation)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("Project actions")
            }.padding(.horizontal, 10).padding(.vertical, 13)
            if project.expanded || !projectSearch.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PARTICIPANTS").font(.system(size: 9, weight: .medium)).tracking(1.1).foregroundStyle(.tertiary).padding(.leading, 30).padding(.bottom, 8)
                    ForEach(project.participants, id: \.self) { agent in
                        HStack(alignment: .center, spacing: 8) {
                            treeBranch
                            InitialCircle(name: names[agent]!, size: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(names[agent]!).font(.system(size: 12, weight: .medium)).foregroundStyle(SilkwireTheme.identity(names[agent]!))
                                if project.id == store.conversation.projectID, store.currentAgent != agent, let job = store.runningBackgroundJob(for: agent) {
                                    BackgroundJobBadge(card: job, reduceMotion: store.preferences.reduceMotion)
                                } else if project.id == store.conversation.projectID { AgentStatus(seat: store.seats[agent] ?? Seat(), reduceMotion: store.preferences.reduceMotion, compact: true) }
                                else { Text("Not connected").font(.system(size: 10)).foregroundStyle(.tertiary) }
                            }
                            Spacer(minLength: 0)
                            if project.id == store.conversation.projectID {
                                Menu { connectionActions(agent) } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).fixedSize().help("\(names[agent]!) connection actions")
                                    .accessibilityLabel("\(names[agent]!) connection actions")
                            }
                        }.contextMenu { if project.id == store.conversation.projectID { connectionActions(agent) } }.padding(.vertical, 4).padding(.leading, 25).padding(.trailing, 10)
                    }
                    HStack {
                        Text("CONVERSATIONS").font(.system(size: 9, weight: .medium)).tracking(1.1).foregroundStyle(.tertiary)
                        Spacer()
                        Button { openNewConversation(in: project) } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New conversation in \(project.name)").disabled(!store.canChangeConversation)
                    }.padding(.leading, 30).padding(.trailing, 12).padding(.top, 14).padding(.bottom, 5)
                    ForEach(rooms(project)) { room in conversationRow(room) }
                }.padding(.bottom, 10)
            }
        }.background(project.id == store.conversation.projectID ? SilkwireTheme.panel : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(project.id == store.conversation.projectID ? SilkwireTheme.midnightEdge : Color.clear, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SilkwireTheme.line))
    }
    private var treeBranch: some View { Path { p in p.move(to: CGPoint(x: 5, y: 0)); p.addLine(to: CGPoint(x: 5, y: 15)); p.addLine(to: CGPoint(x: 13, y: 15)) }.stroke(SilkwireTheme.wash(0.12), lineWidth: 1).frame(width: 14, height: 30).accessibilityHidden(true) }
    private func openNewConversation(in project: Project) {
        newProjectID = project.id; store.newConversationPresented = true
    }
    @ViewBuilder private func conversationActions(_ room: Conversation) -> some View {
        Button("Rename…") { renameID = room.id; proposedTitle = room.title; renaming = true }
        Button(room.archived ? "Restore conversation" : "Archive conversation") { _ = store.archiveConversation(room.id, archived: !room.archived) }
        Divider()
        Button("Delete permanently…", role: .destructive) { deleteID = room.id; confirmingDeletion = true }
    }
    private func conversationRow(_ room: Conversation) -> some View {
        Button { store.selectConversation(room.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text((room.archived ? "Archived · " : "") + room.title).font(.system(size: 12, weight: room.id == store.conversation.id ? .semibold : .regular)).foregroundStyle(room.id == store.conversation.id ? SilkwireTheme.ink : SilkwireTheme.ink.opacity(0.76)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if room.id == store.conversation.id, let agent = store.currentAgent {
                        AgentStatus(seat: store.seats[agent]!, reduceMotion: store.preferences.reduceMotion, compact: true)
                    } else {
                        HStack(spacing: 5) {
                            if room.unread { Circle().fill(SilkwireTheme.accent).frame(width: 5, height: 5) }
                            Text(room.id == store.conversation.id && store.connecting ? "Connecting agents…" : room.messages.last?.state == "unconfirmed" || room.messages.last?.state == "failed" ? "Needs attention" : room.unread ? "Replies ready" : room.messages.isEmpty ? "New conversation" : "Saved on this Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                            if !room.draft.isEmpty { Text("· Draft").font(.system(size: 10)).foregroundStyle(SilkwireTheme.accent) }
                        }
                    }
                }
            }.padding(.vertical, 10).padding(.horizontal, 10).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.leading, 20).padding(.trailing, 6)
        .background(room.id == store.conversation.id ? SilkwireTheme.selectedRow : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 6)  // a little margin so the selection doesn't touch the panel walls
        .disabled(room.id != store.conversation.id && !store.canChangeConversation)
        .contextMenu { conversationActions(room).disabled(!store.canChangeConversation) }
        .accessibilityLabel(room.title + (room.id == store.conversation.id ? ", selected" : ""))
    }
    private var sidebarFooter: some View {
        VStack(spacing: 13) {
            Rectangle().fill(SilkwireTheme.line).frame(height: 1)
            SetupReminderCard(setup: setup)
            HStack(spacing: 9) {
                InitialCircle(name: setup.displayName, size: 30)
                VStack(alignment: .leading, spacing: 3) { Text(setup.displayName).font(.system(size: 12, weight: .semibold)); Text("Your workspace").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Button { store.setChime(!store.preferences.completionChime) } label: { Image(systemName: store.preferences.completionChime ? "bell" : "bell.slash").foregroundStyle(store.preferences.completionChime ? SilkwireTheme.accent : Color.secondary) }.buttonStyle(.borderless).help(store.preferences.completionChime ? "Completion chime on · click to mute" : "Completion chime off · click to enable").accessibilityLabel(store.preferences.completionChime ? "Mute completion chime" : "Enable completion chime").disabled(store.storageError != nil)
            }
            Button { store.connectionsPresented = true } label: { Label("Connections", systemImage: "slider.horizontal.3") }.buttonStyle(.borderless).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            SubscriptionHUD(store: store)
            HStack(spacing: 17) {
                SettingsLink { HStack(spacing: 4) { Image(systemName: "gearshape"); Text("Settings") } }.buttonStyle(.borderless).font(.system(size: 11))
                Spacer()
                Button { store.stagingInstallPresented = true } label: { HStack(spacing: 4) { Image(systemName: "arrow.down.circle"); Text("Update") } }.buttonStyle(.borderless).font(.system(size: 11)).disabled(!store.environment.staging || store.storageError != nil).help(store.environment.staging ? "Review and install a prepared Silkwire update (backup and confirmation first)" : "Updates are not available in this app yet").accessibilityLabel("Update Silkwire")
                Spacer()
                Button { store.helpPresented = true } label: { HStack(spacing: 4) { Image(systemName: "questionmark.circle"); Text("Help") } }.buttonStyle(.borderless).font(.system(size: 11))
            }.foregroundStyle(.secondary)
        }.padding(.horizontal, 17).padding(.bottom, 17)
    }
    // The chat column, Alexandria (docked when wide enough) and the right-side tab rail.
    private var conversationPane: some View {
        GeometryReader { outer in
            let dockAvailable = outer.size.width >= 1060
            let mode = libraryMode == AlexandriaMode.dock.rawValue && !dockAvailable ? AlexandriaMode.drawer.rawValue : libraryMode
            // On a wide window an open page sits beside chat instead of covering it
            // (Jason); the 70-point rail stays at the far right.
            let companion = companionConversation()
            // Two chats and a page fit together when there's room (Jason): the page no
            // longer pushes the second chat away on a wide window.
            let pairSplit = library.open && library.reading && !readerSlidesOver && companion != nil ? SiloLayout.pairSideBySide(total: outer.size.width - 70, preferred: CGFloat(siloPreferredWidth), preferredReader: CGFloat(readerPreferredWidth)) : nil
            let split = pairSplit ?? (library.open && library.reading && !readerSlidesOver ? SiloLayout.sideBySide(total: outer.size.width - 70, preferred: CGFloat(siloPreferredWidth), preferredReader: CGFloat(readerPreferredWidth)) : nil)
            HStack(spacing: 0) {
                conversationColumn(mode: mode, dockAvailable: dockAvailable, readerBeside: split != nil, companion: split == nil || pairSplit != nil ? companion : nil)
                    // A conversation never squeezes narrower than this (Jason: a minimum
                    // to match the maximum), so the composer and replies are never crushed;
                    // side-by-side columns use the same minimum.
                    .frame(minWidth: SiloLayout.minimumColumnWidth)
                    .frame(width: split?.chat)
                    // Narrow windows: the page still opens over the conversation.
                    .overlay {
                        if library.open && library.reading && split == nil && !readerSlidesOver {
                            ZStack(alignment: .top) {
                                SilkwireTheme.canvas
                                // Its own sheet, like Safari's window edge: rounded corners and a soft
                                // shadow instead of a drawn border, so the reader reads as one object.
                                readerPanel(dockAvailable: dockAvailable)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
                                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                    .frame(maxWidth: 1180).padding(.horizontal, 20).padding(.vertical, 14)
                                    .frame(maxWidth: .infinity)
                            }
                            .onExitCommand { withAnimation(.easeOut(duration: 0.2)) { library.closeReader() } }
                            .transition(.opacity)
                        }
                    }
                    // Three or four rooms: the page slides in over the rooms from the right as
                    // its own sheet (Jason); the rooms underneath keep their places and drafts.
                    .overlay(alignment: .trailing) {
                        if readerSlidesOver {
                            readerPanel(dockAvailable: dockAvailable)
                                .frame(width: SiloLayout.slideOverReaderWidth(available: outer.size.width - 70, preferred: CGFloat(readerPreferredWidth)))
                                .background(SilkwireTheme.reading)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                .overlay(alignment: .leading) {
                                    ResizeGrip().offset(x: -6).gesture(readerResizeGesture)
                                        .accessibilityLabel("Resize Alexandria")
                                }
                                .padding(.vertical, 14).padding(.trailing, 14)
                                .onExitCommand { withAnimation(.easeOut(duration: 0.2)) { library.closeReader() } }
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.22), value: readerSlidesOver)
                if let split {
                    // Open space between chat and the page (Jason): Alexandria stays anchored
                    // to the right rail at its own width instead of stretching toward chat.
                    Color.clear.frame(width: split.gap + SiloLayout.dividerWidth)
                    readerPanel(dockAvailable: dockAvailable)
                        .frame(width: split.reader)
                        .overlay(alignment: .leading) { Rectangle().fill(SilkwireTheme.line).frame(width: 1) }
                        // Drag the page's left edge to make it wider or narrower; remembered.
                        .overlay(alignment: .leading) {
                            ResizeGrip().offset(x: -6).gesture(readerResizeGesture)
                                .accessibilityLabel("Resize Alexandria")
                        }
                        .background(SilkwireTheme.reading)
                        // Finished like the chat panel (Jason): respects the title bar, with
                        // rounded upper corners and a thin outline around contents and page.
                        .clipShape(PanelTop.shape)
                        .overlay(PanelTop.shape.strokeBorder(SilkwireTheme.line, lineWidth: 1))
                        .onExitCommand { withAnimation(.easeOut(duration: 0.2)) { library.closeReader() } }
                }
                // While a page is open beside chat, its contents list is the library
                // browser, so the Welcome dock steps aside instead of showing twice.
                if library.open && mode == AlexandriaMode.dock.rawValue && split == nil {
                    // The docked Welcome panel gets the same finished top as the chat panel.
                    VStack(spacing: 0) {
                        AlexandriaPanel(store: store, state: library, mode: $libraryMode, dockAvailable: dockAvailable)
                            .frame(maxHeight: .infinity)
                    }.frame(width: 380)
                        .background(SilkwireTheme.reading)
                        .clipShape(PanelTop.shape)
                        .overlay(PanelTop.shape.strokeBorder(SilkwireTheme.line, lineWidth: 1))
                }
                AlexandriaRail(state: library)
            }
            // Future slides out from the rail over whatever is open, like a drawer (Jason).
            .overlay(alignment: .trailing) { futureDrawer }
            .animation(.easeOut(duration: 0.2), value: library.futureOpen)
        }
    }
    @State private var siloComposerHeight: CGFloat = 0
    @ViewBuilder private var futureDrawer: some View {
        if library.futureOpen {
            FutureDrawer(future: future, store: store, openInAlexandria: { id in
                withAnimation(.easeOut(duration: 0.18)) { library.futureOpen = false; library.show(page: id) }
            }, close: { withAnimation(.easeOut(duration: 0.18)) { library.futureOpen = false } })
            .frame(width: 400)
            .background(SilkwireTheme.reading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SilkwireTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
            .padding(.vertical, 14).padding(.trailing, 70 + 10)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
    /// Chat column width Jason chose by dragging (remembered between launches).
    @AppStorage("silo.width") private var siloPreferredWidth = Double(SiloLayout.defaultSiloWidth)
    @AppStorage("room.width.v1") private var roomPreferredWidth = Double(SiloLayout.defaultRoomWidth)
    @State private var siloDragStart: Double?
    /// Alexandria's width beside chat, chosen by dragging its left edge (remembered).
    @AppStorage("alexandria.readerWidth") private var readerPreferredWidth = Double(SiloLayout.defaultReaderWidth)
    @State private var readerDragStart: Double?
    /// Every open room keeps its position; narrow windows can scroll sideways instead of hiding rooms.
    private var openSiloConversations: [Conversation] {
        let ids = deck.openIDs.isEmpty ? [store.conversation.id] : deck.openIDs
        return ids.compactMap { id in store.conversations.first { $0.id == id && !$0.archived } }
    }
    /// With more than two rooms open, an Alexandria page slides over the rooms from the right
    /// instead of pushing rooms away (Jason); closing it reveals every room exactly as it was.
    private var readerSlidesOver: Bool {
        library.open && library.reading && openSiloConversations.count > 2
    }
    private func visibleSilos(companion: Conversation?) -> [Conversation] {
        // A side-by-side Alexandria reader keeps the existing one/two-room layout.
        if library.open && library.reading && !readerSlidesOver {
            return openSiloConversations.filter { $0.id == store.conversation.id || $0.id == companion?.id }
        }
        return openSiloConversations
    }
    /// The other open conversation shown beside this one, if any (never while a page sits beside chat).
    private func companionConversation() -> Conversation? {
        guard let id = SiloNavigator.companion(deck, current: store.conversation.id) else { return nil }
        return store.conversations.first { $0.id == id && !$0.archived }
    }
    /// A second silo: its conversation to read, and a writing space that switches to it.
    /// One composer at a time for now; clicking here moves typing to this conversation.
    /// The room you're writing in gets the same header row as every other open room
    /// (Jason, Nov 2: the team room was the only one without one).
    private var activeRoomHeader: some View {
        let faces = store.targets.compactMap { names[$0] }.sorted()
        return HStack(spacing: 8) {
            Text(store.conversation.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).foregroundStyle(ReadMarks.roomTint(store.conversation))
            HStack(spacing: -5) { ForEach(faces, id: \.self) { InitialCircle(name: $0, size: 20) } }
                .accessibilityElement().accessibilityLabel(faces.isEmpty ? "No one selected" : "Writing to " + faces.joined(separator: ", "))
            Spacer(minLength: 8)
            Text(faces.count > 1 && faces.count == names.count ? "Everyone" : "Writing here").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
    private func companionSilo(_ other: Conversation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(other.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).foregroundStyle(ReadMarks.roomTint(other))
                Spacer(minLength: 8)
                UnreadCountBadge(count: ReadMarks.unreadCount(other.messages))
                Button("Write here") { switchToSilo(other.id) }.buttonStyle(.borderless).font(.caption)
                    .disabled(!store.canChangeConversation).help("Move typing to this conversation")
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Rectangle().fill(SilkwireTheme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(other.messages.suffix(25))) { message in
                        TranscriptMessageRow(message: message.forDisplay, query: "", selectedHit: nil, seat: nil, reduceMotion: store.preferences.reduceMotion, canBuild: false, build: {}, canStop: false, stop: {}).equatable()
                    }
                }.padding(16)
            }.defaultScrollAnchor(.bottom)
            Rectangle().fill(SilkwireTheme.line).frame(height: 1)
            // Its own live writing space (Jason): type here any time, even while the
            // other conversation is replying. Send moves you here and sends it.
            let draft = other.draft
            NativeComposer(text: Binding(get: { store.conversations.first { $0.id == other.id }?.draft ?? "" }, set: { store.setDraft($0, for: other.id) }),
                           enabled: store.storageError == nil && !other.archived, textCompletion: store.preferences.textCompletion, automaticCorrection: store.preferences.automaticCorrection,
                           addURLs: { store.addAttachments($0, to: other.id) },
                           addImage: { image in
                               do { try store.addAttachment(Attachment.fromImage(image), to: other.id) } catch { store.status = error.localizedDescription }
                           },
                           send: { sendFromCompanion(other.id) }, owner: other.id,
                           commitDraft: { [weak store] text, id in store?.setDraft(text, for: id) },
                           registerFlush: { [companionFlush] flush in companionFlush.flushes[other.id] = flush },
                           // Clicking here makes this the main conversation when nothing is
                           // replying (Jason: no arrows). Mid-reply it stays a draft space.
                           onActivate: { activateCompanion(other.id) })
                .frame(height: CGFloat(composerFieldHeight))
                .accessibilityLabel("Write in \(other.title)")
            // Its own screenshots, kept with this conversation (same thumbnails as the main one).
            if !other.draftAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(other.draftAttachments) { item in AttachmentPreview(attachment: item, remove: { store.removeAttachment(item.id, from: other.id) }).equatable() } }
                        .padding(.horizontal, 12).padding(.top, 8)
                }
            }
            HStack(spacing: 12) {
                Text(store.canChangeConversation ? "Saved on this Mac" : "Draft saved. Send when the current reply finishes.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                let ready = (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !other.draftAttachments.isEmpty) && store.canChangeConversation
                Button { sendFromCompanion(other.id) } label: {
                    Text("Send").font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize().foregroundStyle(ready ? .white : Color.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(ready ? SilkwireTheme.sendFill : SilkwireTheme.wash(0.065), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).disabled(!ready).help("Send to \(other.title)")
            }.padding(.horizontal, 12).padding(.bottom, 9).padding(.top, 4)
        }
        .frame(maxHeight: .infinity)
        .background(SilkwireTheme.columnFill)
        .clipShape(RoundedRectangle(cornerRadius: SiloLayout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SiloLayout.cornerRadius, style: .continuous).strokeBorder(SilkwireTheme.line, lineWidth: 1))
        .accessibilityElement(children: .contain).accessibilityLabel("Conversation: \(other.title)")
        .onDisappear {
            companionFlush.flushes[other.id]?()
            companionFlush.flushes.removeValue(forKey: other.id)
        }
    }
    /// Holds the second writing space's pending-text flush (not view state).
    final class CompanionFlush {
        var flushes: [UUID: () -> Void] = [:]
        func flush() { for pending in Array(flushes.values) { pending() } }
    }
    @State private var companionFlush = CompanionFlush()
    /// Send from the second column: keep its words, move typing there, then send
    /// (waiting briefly if that conversation's team is still reconnecting).
    private func sendFromCompanion(_ id: UUID) {
        companionFlush.flush()
        guard store.canChangeConversation else { store.status = "Your draft is saved. Send it when the current reply finishes."; return }
        switchToSilo(id)
        guard store.conversation.id == id else { return }
        Task { @MainActor in
            for _ in 0..<40 where !store.canSend && store.conversation.id == id { try? await Task.sleep(for: .milliseconds(250)) }
            if store.conversation.id == id && store.canSend { store.send() }
        }
    }
    private func activateCompanion(_ id: UUID) {
        guard store.canChangeConversation, store.conversation.id != id else { return }
        switchToSilo(id)
    }
    private func switchToSilo(_ id: UUID) {
        companionFlush.flush()
        guard store.selectConversation(id) else { store.status = "Finish or stop the current reply before switching conversations."; return }
        SiloNavigator.commit(&deck, to: id, switched: true); savedDeck = SiloNavigator.encode(deck)
    }
    /// Height of the writing space, chosen by dragging its top edge (remembered).
    @AppStorage("composer.fieldHeight") private var composerFieldHeight = Double(SiloLayout.defaultComposerHeight)
    @State private var composerDragStart: Double?
    private var composerResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if composerDragStart == nil { composerDragStart = composerFieldHeight }
                // Dragging the top edge upward makes the writing space taller.
                composerFieldHeight = Double(SiloLayout.clampedComposer(CGFloat(composerDragStart ?? composerFieldHeight) - value.translation.height))
            }
            .onEnded { _ in composerDragStart = nil }
    }
    private var readerResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if readerDragStart == nil { readerDragStart = readerPreferredWidth }
                // Dragging the left edge leftward widens the page.
                readerPreferredWidth = Double(SiloLayout.clampedReader(CGFloat(readerDragStart ?? readerPreferredWidth) - value.translation.width))
            }
            .onEnded { _ in readerDragStart = nil }
    }
    /// The one full-size page reader. It is shown in exactly one place at a time:
    /// beside chat when the window has room, otherwise over the conversation.
    private func readerPanel(dockAvailable: Bool) -> some View {
        AlexandriaPanel(store: store, state: library, mode: $libraryMode, dockAvailable: dockAvailable, surface: .reader)
    }
    private var siloResizeGesture: some Gesture {
        // Global space: the edge moves while dragging, so local translation would jitter.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if siloDragStart == nil { siloDragStart = roomPreferredWidth }
                roomPreferredWidth = Double(SiloLayout.clampedRoomWidth(CGFloat(siloDragStart ?? roomPreferredWidth) + value.translation.width))
            }
            .onEnded { _ in siloDragStart = nil }
    }
    private func conversationColumn(mode: String, dockAvailable: Bool, readerBeside: Bool = false, companion: Conversation? = nil) -> some View {
        // While a page is open beside chat it is the only library surface: no drawer,
        // Below or Peek panel appears as well (Codex review).
        VStack(spacing: 0) {
            conversationHeader
            if let error = store.storageError { Label(error, systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange).font(.callout).textSelection(.enabled).padding() }
            GeometryReader { geometry in
                let rooms = visibleSilos(companion: companion)
                let count = max(1, rooms.count)
                let columnWidth = SiloLayout.roomWidth(available: geometry.size.width, columns: count, preferred: CGFloat(roomPreferredWidth))
                ScrollViewReader { scroller in
                    ScrollView(.horizontal) {
                        HStack(spacing: SiloLayout.outerMargin) {
                            ForEach(rooms) { room in
                                Group {
                                if room.id == store.conversation.id {
                VStack(spacing: 0) {
                    activeRoomHeader
                    Rectangle().fill(SilkwireTheme.line).frame(height: 1)
                    transcript.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(SilkwireTheme.line).frame(height: 1)
                    composer.fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { measured in
                                Color.clear.onChange(of: measured.size.height, initial: true) { _, height in
                                    if height.isFinite && height >= 0 && siloComposerHeight != height { siloComposerHeight = height }
                                }
                            }
                        }
                }
                .frame(width: columnWidth)
                .clipShape(RoundedRectangle(cornerRadius: SiloLayout.cornerRadius, style: .continuous))
                // The border warms to the accent while this silo is replying.
                .overlay(RoundedRectangle(cornerRadius: SiloLayout.cornerRadius, style: .continuous)
                    .strokeBorder(store.busy ? SilkwireTheme.accent.opacity(0.55) : SilkwireTheme.line, lineWidth: 1))
                // Drag the column's right edge to make chat wider or narrower, within limits.
                .overlay(alignment: .trailing) {
                    ResizeGrip().offset(x: 6)
                        .gesture(siloResizeGesture)
                        .accessibilityLabel("Resize chat column")
                }
                                } else {
                                    companionSilo(room).frame(width: columnWidth)
                                }
                                }.id(room.id)
                            }
                        }
                        .frame(height: max(0, geometry.size.height - SiloLayout.outerMargin * 2 - 12))
                        .padding(SiloLayout.outerMargin)
                    }
                    .onAppear { scroller.scrollTo(store.conversation.id, anchor: .center) }
                    .onChange(of: store.conversation.id) { _, id in scroller.scrollTo(id, anchor: .center) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                // The drawer uses the open space to the right, or overlays the transcript
                // on narrow windows. Its measured bottom boundary leaves the composer usable.
                .overlay(alignment: .topTrailing) {
                    let drawerHeight = SiloLayout.drawerHeight(available: geometry.size.height, composerHeight: siloComposerHeight)
                    if library.open && !readerBeside && mode == AlexandriaMode.drawer.rawValue && drawerHeight > 0 {
                        AlexandriaPanel(store: store, state: library, mode: $libraryMode, dockAvailable: dockAvailable)
                            .frame(maxWidth: 420)
                            .frame(height: drawerHeight)
                            .clipped()
                            .overlay(alignment: .leading) { Rectangle().fill(SilkwireTheme.line).frame(width: 1) }
                            .shadow(color: .black.opacity(0.2), radius: 18, x: -4)
                            .padding(.top, SiloLayout.outerMargin)
                            .transition(.move(edge: .trailing))
                    }
                }
                .onAppear { sideLayoutActive = false }
            }
            .overlay(alignment: .topTrailing) { siteResults.padding(.top, 6).padding(.trailing, 24) }
            if library.open && !readerBeside && mode == AlexandriaMode.below.rawValue && !sideLayoutActive {
                Rectangle().fill(SilkwireTheme.line).frame(height: 1)
                AlexandriaPanel(store: store, state: library, mode: $libraryMode, dockAvailable: dockAvailable).frame(height: 360)
            }
            if library.open && !readerBeside && mode == AlexandriaMode.peek.rawValue {
                Rectangle().fill(SilkwireTheme.line).frame(height: 1)
                AlexandriaPanel(store: store, state: library, mode: $libraryMode, dockAvailable: dockAvailable, compact: true).frame(height: 240)
            }
        }.background {
            if reduceTransparency { SilkwireTheme.canvas }
            else { LinearGradient(stops: [.init(color: SilkwireTheme.canvasGlowLeading, location: 0), .init(color: SilkwireTheme.canvas, location: 0.18), .init(color: SilkwireTheme.canvas, location: 0.82), .init(color: SilkwireTheme.canvasGlowTrailing, location: 1)], startPoint: .leading, endPoint: .trailing) }
        }
    }
    @ViewBuilder private func connectionActions(_ agent: String) -> some View {
        let seat = store.seats[agent] ?? Seat()
        if seat.state == "needsStop" {
            Button("Stop previous reply") { store.stopPrevious(agent) }.disabled(store.busy || store.connecting)
        } else if seat.state == "connected" && !seat.active {
            Button("Disconnect \(names[agent]!)") { store.disconnectAgent(agent) }.disabled(!store.canChangeConversation)
        } else if seat.state == "disconnected" {
            Button("Connect \(names[agent]!)") { store.recoverAgent(agent) }.disabled(store.busy || store.connecting || store.storageError != nil)
        } else {
            Text(seat.activity.isEmpty ? "Connection in progress" : seat.activity)
        }
        Button("Chat with \(names[agent] ?? agent) one on one") { store.newFocusedChat(with: agent) }
            .disabled(!store.canChangeConversation).help("Opens a separate conversation with just this teammate. The team conversation stays as it is.")
        Divider()
        Button("Connection details…") { store.connectionsPresented = true }
    }
    private var conversationHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { renameID = store.conversation.id; proposedTitle = store.conversation.title; renaming = true } label: {
                    HStack(spacing: 8) { Text(store.conversation.title).font(.system(size: 19, weight: .semibold)).lineLimit(1).foregroundStyle(ReadMarks.roomTint(store.conversation)); Image(systemName: "pencil").font(.caption).foregroundStyle(SilkwireTheme.accent) }
                }.buttonStyle(.plain).help("Rename conversation").accessibilityLabel("Rename \(store.conversation.title)").disabled(store.storageError != nil)
                if store.trustedStagingAvailable {
                    Button { editingProject = store.activeProject } label: { Text("Trusted Staging").font(.system(size: 10, weight: .semibold)).foregroundStyle(SilkwireTheme.stagingTint).padding(.horizontal, 7).padding(.vertical, 4).background(SilkwireTheme.stagingTint.opacity(0.12), in: Capsule()) }
                        .buttonStyle(.plain).help("Review or revoke standing Staging access, including while work runs.")
                }
                Spacer(minLength: 8)
                if store.unreadCount > 0 {
                    UnreadCountBadge(count: store.unreadCount)
                    Button("Mark all read") { store.markAllRead() }.buttonStyle(.borderless).font(.system(size: 10))
                }
                HStack(spacing: 6) {
                    if let agent = store.currentAgent { WorkingSpider(reduceMotion: store.preferences.reduceMotion); Text(SeatPhase.isConversational(store.seats[agent]?.activity ?? "") ? "Replying" : (store.seats[agent]?.activity ?? "Working")).foregroundStyle(SilkwireTheme.accent) }
                    else if !store.runningBackgroundJobs.isEmpty { BackgroundJobSummary(cards: store.runningBackgroundJobs, reduceMotion: store.preferences.reduceMotion) }
                    else { Text(store.status).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true) }
                }.font(.system(size: 10)).lineLimit(1).frame(maxWidth: 240, alignment: .trailing).help(store.status)
                if let brief = store.activeProject?.brief, !brief.isEmpty {
                    Button { showBrief.toggle() } label: { Image(systemName: "pin") }.buttonStyle(.borderless).help("Project brief · supplied each turn").accessibilityLabel("Show Project brief")
                        .popover(isPresented: $showBrief) { ScrollView { VStack(alignment: .leading, spacing: 12) { Text("Project brief").font(.headline); Text(brief).font(.callout).textSelection(.enabled); Text("Supplied to each selected agent on every turn.").font(.caption).foregroundStyle(.secondary) }.padding(20) }.frame(width: 400, height: 280) }
                }
                if let back = returnConversation, back != store.conversation.id {
                    Button { if store.selectConversation(back) { returnConversation = nil } } label: { Label("Back", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).font(.system(size: 11)).help("Back to where I was").disabled(!store.canChangeConversation)
                }
                siteSearchField
                Menu {
                    conversationActions(store.conversation).disabled(!store.canChangeConversation)
                    Divider()
                    Button("Export Markdown…") { store.exportConversation() }.disabled(store.storageError != nil)
                    Button("Install in Staging…") { store.stagingInstallPresented = true }.disabled(store.storageError != nil)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("Conversation actions & export").accessibilityLabel("Conversation actions and export")
            }.frame(minHeight: SiloLayout.headerRowHeight)
            if showFind { searchBar }
        }.padding(.horizontal, 24).padding(.vertical, SiloLayout.headerVerticalPadding).overlay(alignment: .bottom) { Rectangle().fill(SilkwireTheme.line).frame(height: 1) }
    }
    // Site-wide search: a permanent field in the bar beneath the title bar.
    private var siteSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(library.open && libraryMode == AlexandriaMode.dock.rawValue ? "Search…" : "Search conversations and Alexandria…", text: $siteQuery).textFieldStyle(.plain).focused($siteFocused)
                .onSubmit { openFirstSiteResult() }.onExitCommand { closeSiteSearch() }
                .accessibilityLabel("Search conversations and Alexandria")
            if !siteQuery.isEmpty { Button { siteQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).accessibilityLabel("Clear search") }
        }
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 170, idealWidth: 280, maxWidth: 300)
        .background(SilkwireTheme.wash(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(siteFocused ? SilkwireTheme.accent.opacity(0.9) : SilkwireTheme.line))
        .onChange(of: siteFocused) { _, focused in if focused { showSiteResults = true } else if siteTrimmed.isEmpty { showSiteResults = false } }
        .onChange(of: siteQuery) { _, _ in showSiteResults = true }
        .background(Button("") { siteFocused = true; showSiteResults = true }.keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true))
        .help("Search every conversation and Alexandria · ⌘F")
    }
    @ViewBuilder private var siteResults: some View {
        if showSiteResults && (siteFocused || !siteTrimmed.isEmpty) {
            SiteSearchResults(query: siteQuery,
                              currentMatches: siteTrimmed.isEmpty ? 0 : SearchHit.find(in: store.conversation.messages, query: siteTrimmed).count,
                              conversations: Alexandria.conversations(store.conversations, query: siteTrimmed, excluding: store.conversation.id),
                              pages: Alexandria.search(store.libraryPages, query: siteTrimmed),
                              pick: { siteQuery = $0; siteFocused = true },
                              openCurrent: { openCurrentMatches() },
                              openConversation: { openConversationResult($0) },
                              openPage: { openPageResult($0) },
                              close: { closeSiteSearch() })
        }
    }
    private func closeSiteSearch() { siteQuery = ""; showSiteResults = false; siteFocused = false }
    private func openCurrentMatches() {
        let q = siteTrimmed; showSiteResults = false; siteFocused = false
        showFind = true; messageSearch = q; hitIndex = 0
    }
    private func openConversationResult(_ hit: ConversationSearchHit) {
        let from = store.conversation.id, q = siteTrimmed
        guard store.selectConversation(hit.conversationID) else { store.status = "Finish or stop the current reply before opening another conversation."; return }
        returnConversation = from; showSiteResults = false; siteFocused = false
        // After the switch settles (switching clears find), reveal and highlight the match.
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); showFind = true; messageSearch = q; hitIndex = 0 }
    }
    private func openPageResult(_ hit: LibraryHit) {
        showSiteResults = false; siteFocused = false
        withAnimation(.easeOut(duration: 0.18)) { library.show(page: hit.pageID, highlight: siteTrimmed) }
    }
    private func openFirstSiteResult() {
        let q = siteTrimmed; guard !q.isEmpty else { return }
        if !SearchHit.find(in: store.conversation.messages, query: q).isEmpty { openCurrentMatches() }
        else if let first = Alexandria.conversations(store.conversations, query: q, excluding: store.conversation.id).first { openConversationResult(first) }
        else if let page = Alexandria.search(store.libraryPages, query: q).first { openPageResult(page) }
    }
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Find in this conversation…", text: $messageSearch).focused($findFocused).textFieldStyle(.plain).accessibilityLabel("Find in this conversation").onExitCommand { messageSearch = ""; showFind = false; composerFocusRequest = UUID() }
            if !messageSearch.isEmpty {
                Text(searchHits.isEmpty ? "0 matches" : "\(hitIndex + 1) of \(searchHits.count)").font(.caption).monospacedDigit()
                Button { moveHit(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).help("Previous match").accessibilityLabel("Previous match").disabled(searchHits.isEmpty)
                Button { moveHit(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("Next match").accessibilityLabel("Next match").disabled(searchHits.isEmpty)
            }
            Button { messageSearch = ""; showFind = false; composerFocusRequest = UUID() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Close find").accessibilityLabel("Close find")
        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 11).padding(.vertical, 8)
        .background(SilkwireTheme.wash(0.035), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(findFocused ? SilkwireTheme.accent.opacity(0.9) : SilkwireTheme.line))
    }
    /// Jumping to the bottom in the same moment new rows appear can leave the lazy
    /// list unpainted (blank until the next scroll). Jump now, then again once the
    /// new rows have been laid out, so the conversation always shows.
    private func followBottom(_ proxy: ScrollViewProxy) {
        scrollToFollowTarget(proxy)
        Task { @MainActor in
            for delay in [40, 160] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard following, messageSearch.isEmpty else { return }
                scrollToFollowTarget(proxy)
            }
        }
    }
    /// While following: hold your just-sent message at the top (so long replies start on
    /// screen), otherwise keep the newest text in view as before.
    private func scrollToFollowTarget(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottom", anchor: .bottom)
    }
    /// Records the order teammates start speaking (their first words), so the transcript
    /// can give one of them the floor at a time. Replies already there when the view opens
    /// are the baseline and simply show.
    private func noteSpeakers() {
        let agentNames = Set(names.values)
        let speaking = store.conversation.messages.filter { agentNames.contains($0.author) && !TranscriptFlow.isHeld($0.author, state: $0.state, agentNames: agentNames, text: $0.text) }.map(\.id)
        guard let baseline = revealBaseline else { revealBaseline = Set(speaking); return }
        let fresh = TranscriptFlow.newlyVisible(speaking, baseline: baseline, revealed: revealSeq)
        guard !fresh.isEmpty else { return }
        var next = revealSeq, n = revealSeq.values.max() ?? 0
        for id in fresh { n += 1; next[id] = n }
        revealSeq = next
    }
    /// Auto-scroll as a gentle glide: a few nudges a second, each easing toward the newest
    /// words, so arriving text drifts up instead of flying. Scrolling up stops it.
    private func glideToLatest(_ proxy: ScrollViewProxy) {
        guard following, !followGlide else { return }
        followGlide = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(TranscriptFlow.glideInterval))
            followGlide = false
            guard following else { return }
            withAnimation(store.preferences.reduceMotion ? nil : .easeInOut(duration: TranscriptFlow.glideDuration)) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    /// Where "Last read" points: the start of the replies to Jason's latest message
    /// (his prompt). -1 = it's above the window, +1 = below, nil = on screen or none.
    private func lastReadDirection() -> Int? {
        guard messageSearch.isEmpty, let target = roundPrompt else { return nil }
        if let frame = rowFrames.frames[target], frame.maxY > 0, frame.minY < rowFrames.viewport { return nil }
        let all = store.conversation.messages
        guard let targetIndex = all.firstIndex(where: { $0.id == target }), let anchor = readingAnchor,
              let anchorIndex = all.firstIndex(where: { $0.id == anchor }), anchorIndex != targetIndex else { return nil }
        return anchorIndex > targetIndex ? -1 : 1
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.conversation.messages.isEmpty { VStack(spacing: 15) {
                        SilkwireSpider().fill(SilkwireTheme.accent.opacity(0.7)).frame(width: 55, height: 55)
                        Text("A place to think together").font(.title3.weight(.medium))
                        Text("Message your Project’s team, or choose one participant below.").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 80) }
                    // Computed once per redraw (not once per row), and only the newest
                    // messages are drawn; Find shows everything so every match is reachable.
                    let hit = currentHit
                    let all = store.conversation.messages
                    let limit = messageSearch.isEmpty ? shownLimit : all.count
                    let shown = TranscriptWindow.visible(all, limit: limit)
                    let hidden = TranscriptWindow.hiddenCount(count: all.count, limit: limit)
                    if hidden > 0 {
                        Button {
                            let firstID = shown.first?.id
                            shownLimit = TranscriptWindow.earlier(limit: shownLimit, count: all.count)
                            if let firstID { Task { @MainActor in try? await Task.sleep(for: .milliseconds(40)); proxy.scrollTo(firstID, anchor: .top) } }
                        } label: { Label("Show \(min(hidden, TranscriptWindow.step)) earlier messages", systemImage: "arrow.up") }
                        .buttonStyle(.bordered).help("Older messages stay saved on this Mac. They're only drawn when you ask, which keeps typing smooth.")
                        .frame(maxWidth: .infinity)
                    }
                    // No empty reserved cards: a teammate's card appears once its first words
                    // arrive. Until then they're named once in the quiet "thinking…" line.
                    let agentNames = Set(names.values)
                    // One speaker at a time: the first reply to start talking has the floor; the
                    // others wait (buffered) and appear in turn, like people in a room.
                    let typingIDs = Set(shown.filter { $0.state == "streaming" }.map(\.id))
                    let floor = TranscriptFlow.floorHolders(revealSeq.sorted { $0.value < $1.value }.map(\.key), typing: typingIDs)
                    let waitingIDs = Set(floor.waiting)
                    let waitingAuthors = floor.waiting.compactMap { id in shown.first { $0.id == id }?.author }
                    let pendingAuthors = shown.filter { TranscriptFlow.isHeld($0.author, state: $0.state, agentNames: agentNames, text: $0.text) }.map(\.author) + waitingAuthors
                    let ready = shown.filter { !TranscriptFlow.isHeld($0.author, state: $0.state, agentNames: agentNames, text: $0.text) && !waitingIDs.contains($0.id) }
                    ForEach(TranscriptFlow.speakingOrder(ready, id: \.id, seq: revealSeq, group: { $0.requestId })) { message in TranscriptMessageRow(message: message.forDisplay, query: messageSearch, selectedHit: hit, seat: message.state == "streaming" ? names.first(where: { $0.value == message.author }).flatMap { store.seats[$0.key] } : nil, reduceMotion: store.preferences.reduceMotion, canBuild: store.canChangeConversation, build: { store.prepareBuilder(message.text) }, canStop: store.canStopBuilderMessage(message), stop: { store.stopBuilderMessage(message) }, toggleRead: { store.toggleRead(message.id) }).equatable().frame(maxWidth: 820).frame(maxWidth: .infinity).id(message.id)
                        .background(GeometryReader { geometry in Color.clear.preference(key: TranscriptFrames.self, value: [message.id: geometry.frame(in: .named("transcript-viewport"))]) }) }
                    if !pendingAuthors.isEmpty {
                        ThinkingLine(names: pendingAuthors, reduceMotion: store.preferences.reduceMotion)
                            .frame(maxWidth: 820).frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { geometry in Color.clear.preference(key: TranscriptEndY.self, value: geometry.frame(in: .named("transcript-viewport")).minY) })
                }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 18)
            }
            .background(GeometryReader { geometry in Color.clear
                .onAppear { rowFrames.viewport = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in rowFrames.viewport = height } })
            .coordinateSpace(name: "transcript-viewport")
            .onPreferenceChange(TranscriptEndY.self) { y in
                transcriptEndY = y
                // Scrolling back down to the very end picks following up again, like Messages.
                if followPaused, messageSearch.isEmpty, let y, rowFrames.viewport > 0, TranscriptFlow.isAtEnd(contentEnd: y, viewport: rowFrames.viewport) { followPaused = false }
            }
            .onPreferenceChange(TranscriptFrames.self) { frames in
                rowFrames.frames = frames
                let visible = frames.filter { $0.value.maxY > 0 }.min { $0.value.minY < $1.value.minY }?.key
                if readingAnchor != visible {
                    readingAnchor = visible; recordDiagnosticTranscriptAnchor(visible)
                    anchorSettlement?.cancel()
                    anchorSettlement = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled, resizeRestore == nil else { return }; stableReadingAnchor = visible
                    }
                }
            }
            .background(TranscriptResizeObserver {
                guard !following, let current = readingAnchor else { return }
                if resizeRestore == nil { resizeAnchor = stableReadingAnchor ?? current }
                let anchor = resizeAnchor ?? current, conversationID = store.conversation.id
                resizeRestore?.cancel()
                resizeRestore = Task { @MainActor in
                    // Lazy variable-height rows can need a second layout after a
                    // width change. Hold the original anchor through that reflow.
                    for delay in [50, 100, 150] {
                        try? await Task.sleep(for: .milliseconds(delay))
                        guard !Task.isCancelled, store.conversation.id == conversationID, !following else { return }
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                    resizeRestore = nil; resizeAnchor = nil
                }
            })
            .transcriptDiagnosticProbe()
            .overlay { ScrollIntentObserver { followPaused = true; resizeRestore?.cancel(); resizeRestore = nil; resizeAnchor = nil } }
            // Two quiet ways back, floating so they never shift the conversation:
            // Last read (start of the replies to your latest message) and Latest.
            .overlay(alignment: .bottomTrailing) {
                let lastRead = lastReadDirection()
                let paused = followPaused && messageSearch.isEmpty
                if lastRead != nil || paused {
                    HStack(spacing: 8) {
                        if let lastRead, let target = roundPrompt {
                            Button(lastRead < 0 ? "Last read ↑" : "Last read ↓") { followPaused = true; withAnimation(store.preferences.reduceMotion ? nil : .easeOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) } }
                                .buttonStyle(SoftAccentButtonStyle()).background(SilkwireTheme.canvas, in: Capsule()).shadow(color: .black.opacity(0.22), radius: 6, y: 2).help("Back to the start of the replies to your latest message")
                        }
                        if paused {
                            Button("Latest ↓") { messageSearch = ""; pinnedPrompt = nil; followPaused = false; newReplies = false; withAnimation(store.preferences.reduceMotion ? nil : .easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                                .buttonStyle(SoftAccentButtonStyle()).background(SilkwireTheme.canvas, in: Capsule()).shadow(color: .black.opacity(0.22), radius: 6, y: 2).help("Jump to the newest words and keep following")
                        }
                    }
                    .padding(.trailing, 24).padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
             .onChange(of: currentHit?.id) { _, _ in if let hit = currentHit {
                proxy.scrollTo(hit.messageID, anchor: .center)
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(50)); if currentHit?.id == hit.id { proxy.scrollTo(hit.anchor, anchor: .center) } }
            } }
            .onChange(of: following) { _, enabled in if enabled { newReplies = false } }
            // Opening a conversation shows its end. After that, glideToLatest is the only
            // thing that follows new words, so nothing snaps on its own.
            .defaultScrollAnchor(roundPrompt == nil ? .bottom : .top)
            .onChange(of: replyRevision) { _, _ in noteSpeakers(); glideToLatest(proxy) }
            .onChange(of: store.conversation.messages.count) { _, _ in noteSpeakers() }
            .onAppear { noteSpeakers() }
            .onChange(of: store.conversation.id) { _, _ in pinnedPrompt = nil; roundPrompt = nil; revealBaseline = nil; revealSeq = [:]; noteSpeakers(); if following { followBottom(proxy) } }
            .onChange(of: store.conversation.messages.count) { old, new in
                let all = store.conversation.messages
                pinnedPrompt = ReplyScroll.pinAfterAppend(oldCount: old, messages: all, enabled: store.preferences.startRepliesAtPrompt, current: pinnedPrompt)
                let sent = ReplyScroll.sendResumesFollowing(oldCount: old, messages: all, autoScroll: store.preferences.autoScrollReplies)
                if sent {
                    followPaused = false; newReplies = false
                    // Stacked prompts form one set: keep the first while it's still on screen.
                    let currentTop = roundPrompt.flatMap { rowFrames.frames[$0]?.minY }
                    if !TranscriptFlow.keepsRoundPrompt(currentTop: currentTop, viewport: rowFrames.viewport),
                       let mine = all.last(where: { $0.author == ReplyScroll.userAuthor }) {
                        roundPrompt = mine.id
                    }
                    // Sending takes you to the live end, like any chat.
                    if store.preferences.autoScrollReplies && messageSearch.isEmpty { followBottom(proxy) }
                } else { shownLimit = TranscriptWindow.grown(limit: shownLimit, oldCount: old, newCount: new, following: following) }
            }
        }
    }
    private var recipientPills: some View {
            PillFlowLayout(spacing: 8) {
                ForEach(SiloIdentity.pills(participants: store.participants, focusedAgent: store.conversation.focusedAgent), id: \.self) { agent in
                    Button { store.toggleRecipient(agent) } label: {
                        HStack(spacing: 5) { InitialCircle(name: names[agent]!, size: 20); Text(names[agent]!).font(.system(size: 11)); if store.targets.contains(agent) { Image(systemName: "checkmark").font(.caption2) } }.fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 5).background(store.targets.contains(agent) ? SilkwireTheme.chipFill(names[agent]!) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityLabel("Send to \(names[agent]!)").accessibilityAddTraits(store.targets.contains(agent) ? .isSelected : []).disabled(store.conversation.archived)
                    // Talk any time: each working teammate can be stopped alone.
                    if store.isWorking(agent) {
                        Button { store.stopTeammate(agent) } label: { Image(systemName: store.stoppingAgents.contains(agent) ? "hourglass" : "stop.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.red).disabled(!store.canStopTeammate(agent))
                            .help("Stop \(names[agent]!) only. Anything waiting for \(names[agent]!) is cancelled; the rest of the team keeps going.")
                            .accessibilityLabel("Stop \(names[agent]!)")
                    }
                }
                if store.preferences.autoScrollReplies && followPaused {
                    Button("Resume ↓") { messageSearch = ""; followPaused = false }.buttonStyle(.borderless).font(.caption).help("Auto-scroll paused while reading · resume following replies")
                }
                Button { store.prepareBuilder() } label: { Label(store.builderRunning ? "Builder working…" : "Builder", systemImage: "hammer") }.buttonStyle(.borderless).font(.caption)
                Button { showOptions.toggle(); showContext = false } label: { Image(systemName: "ellipsis.circle") }
                    .buttonStyle(.borderless).help("Conversation options").accessibilityLabel("Conversation options")
            }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if let center = store.computer { ComputerTaskStrip(center: center, conversationID: store.conversation.id.uuidString.lowercased()) }
            BackgroundJobStrip(store: store)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    recipientPills
                    Spacer(minLength: 0)
                    siloControls.layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    recipientPills
                    HStack { Spacer(minLength: 0); siloControls }
                }
            }
            if showOptions {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Room width", selection: $roomPreferredWidth) {
                        Text("Narrow").tag(460.0)
                        Text("Medium").tag(600.0)
                        Text("Wide").tag(740.0)
                        if ![460.0, 600.0, 740.0].contains(roomPreferredWidth) {
                            Text("Custom (\(Int(roomPreferredWidth)) pt)").tag(roomPreferredWidth)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Applies to open rooms. You can also drag a room's right edge.")
                    HStack { Toggle("Auto-scroll replies", isOn: Binding(get: { store.preferences.autoScrollReplies }, set: { store.setAutoScroll($0); if $0 { followPaused = false } })).toggleStyle(.checkbox); Spacer(); Button { showOptions = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close conversation options") }
                    Toggle("Start new replies at my message", isOn: Binding(get: { store.preferences.startRepliesAtPrompt }, set: { store.setStartRepliesAtPrompt($0); if !$0 { pinnedPrompt = nil } })).toggleStyle(.checkbox)
                        .disabled(!store.preferences.autoScrollReplies)
                        .help("After you press Send, keep your message at the top so long replies start on screen instead of below the fold.")
                    Toggle("Real conversation: everyone replies at once", isOn: Binding(get: { store.preferences.openFloor }, set: { store.setOpenFloor($0) })).toggleStyle(.checkbox)
                    Toggle("Let teammates respond to each other afterwards", isOn: Binding(get: { store.preferences.chimeIn }, set: { store.setChimeIn($0) })).toggleStyle(.checkbox).disabled(!store.preferences.openFloor).padding(.leading, 18)
                        .help("Experimental. Every teammate starts at the same time and replies when ready; anyone with nothing to add stays silent instead of posting Pass. Uses more of your subscriptions. Turn off to take turns again.")
                    Button { showOptions = false; showContext = true } label: { Label("Context & folders", systemImage: "info.circle") }.buttonStyle(.borderless)
                }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(SilkwireTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            if showContext { contextDetails }
            if store.targets.isEmpty { Text("A saved recipient is no longer in this Project. Choose who should receive this message.").font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
            if store.conversation.archived {
                // Search can open an archived conversation (Jason hit this): say plainly that
                // it is read-only, and offer the two ways out instead of a silently locked composer.
                HStack(spacing: 10) {
                    Label("You're viewing an archived conversation. It's read-only.", systemImage: "archivebox").font(.callout)
                    Spacer(minLength: 8)
                    if let back = returnConversation, back != store.conversation.id {
                        Button("Back") { if store.selectConversation(back) { returnConversation = nil } }.disabled(!store.canChangeConversation)
                    }
                    Button("Restore to continue") { _ = store.archiveConversation(store.conversation.id, archived: false) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(10).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(spacing: 0) {
                NativeComposer(text: $store.conversation.draft, enabled: store.storageError == nil && !store.conversation.archived, textCompletion: store.preferences.textCompletion, automaticCorrection: store.preferences.automaticCorrection, focusRequest: composerFocusRequest, addURLs: { store.addAttachments($0) }, addImage: { image in
                    do { try store.addAttachment(Attachment.fromImage(image)) } catch { store.status = error.localizedDescription }
                }, send: { store.send() }, owner: store.conversation.id,
                   commitDraft: { [weak store] text, id in store?.setDraft(text, for: id) },
                   onTyping: { [weak store] in store?.lastKeystroke = Date() },
                   registerFlush: { [weak store] flush in store?.composerFlush = flush }).frame(height: CGFloat(composerFieldHeight)).onChange(of: store.conversation.draft) { _, _ in store.scheduleSave() }
                    // Drag the top edge to make the writing space taller or shorter (Jason); remembered.
                    .overlay(alignment: .top) {
                        HeightGrip().offset(y: -6).gesture(composerResizeGesture).accessibilityLabel("Resize writing space")
                    }
                // Attachments sit inside the composer's border as small thumbnails (Jason),
                // so the composer reads as one object and never grows a second row outside it.
                if !store.conversation.draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(store.conversation.draftAttachments) { item in AttachmentPreview(attachment: item, remove: { store.removeAttachment(item.id) }).equatable() } }
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                }
                HStack(spacing: 12) {
                    Button { browseAttachments() } label: { Image(systemName: "paperclip") }.buttonStyle(.borderless).help("Attach images or UTF-8 text files").accessibilityLabel("Attach files").disabled(store.conversation.archived || store.storageError != nil)
                    Button { NSApp.orderFrontCharacterPalette(nil) } label: { Image(systemName: "face.smiling") }.buttonStyle(.borderless).help("Emoji & Symbols").accessibilityLabel("Emoji and Symbols")
                    // Gives way first when the composer is narrow: the words become a small check.
                    ViewThatFits(in: .horizontal) {
                        Text("Saved on this Mac").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary).help("Saved on this Mac")
                    }.layoutPriority(-1)
                    Button { showContext.toggle(); showOptions = false } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).help("History supplied to each agent · Project folders").accessibilityLabel("Conversation context and folder details")
                    if store.inputCharacterCount > 24000 { Text("Over 24,000 characters").font(.caption2).foregroundStyle(.orange).help("Message and attached text together exceed 24,000 characters.") }
                    Spacer(minLength: 4)
                    let hasInput = !store.conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.conversation.draftAttachments.isEmpty
                    // Smart button: while the team works, an empty composer offers Stop in Send's place;
                    // typing or attaching brings Send back, with a small separate Stop beside it.
                    if store.busy && hasInput { Button { store.stop() } label: { Image(systemName: "stop.circle") }.buttonStyle(.borderless).foregroundStyle(.red).disabled(store.stopping).help("Stop the team").accessibilityLabel("Stop").keyboardShortcut(.escape, modifiers: []) }
                    // Pass: the team keeps going without waiting for Jason (shared pool of replies).
                    if store.relayActive { ViewThatFits(in: .horizontal) { Text("\(store.relayUsed) of \(ConversationStore.relayLimit) replies").lineLimit(1).fixedSize(); Text("\(store.relayUsed)/\(ConversationStore.relayLimit)").lineLimit(1).fixedSize() }.font(.caption).foregroundStyle(.secondary).layoutPriority(-1).help("Replies used in this pass. Passes don't count.") }
                    Button { store.pass() } label: {
                        Text("Pass").font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                            .foregroundStyle(store.canPass ? SilkwireTheme.ink : Color.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(SilkwireTheme.wash(0.065), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SilkwireTheme.line))
                    }.buttonStyle(.plain).disabled(!store.canPass)
                        .help("Nothing to add? Let the team keep going without you: up to \(ConversationStore.relayLimit) replies, shared among whoever has something to say. Stop or Send steps back in.")
                        .accessibilityLabel("Pass: let the team continue")
                    let sendEnabled = store.canSend
                    if store.busy && !hasInput {
                        Button { store.stop() } label: { Text(store.stopping ? "Stopping…" : "Stop").font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize().foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 7).background(Color.red.opacity(store.stopping ? 0.45 : 0.8), in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).disabled(store.stopping).keyboardShortcut(.escape, modifiers: []).help("Stop the whole team. Start typing to talk to them instead, or stop one teammate from their name above.")
                    } else {
                    Button { store.send() } label: { Text("Send").font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize().foregroundStyle(sendEnabled ? .white : Color.secondary).padding(.horizontal, 16).padding(.vertical, 7).background(sendEnabled ? SilkwireTheme.sendFill : SilkwireTheme.wash(0.065), in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).disabled(!sendEnabled).keyboardShortcut(.return, modifiers: .command)
                        .help(store.busy ? "Send now. Teammates who are free get it right away; the rest as soon as they finish." : "Send")
                    }
                }.padding(.horizontal, 12).padding(.bottom, 9).padding(.top, 4)
                if store.hasQueued {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.up").foregroundStyle(SilkwireTheme.stagingTint)
                        Text("A message saved by an earlier version is waiting. Bring it back to send it.").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Edit") { store.unqueue() }.buttonStyle(.borderless).font(.caption).help("Bring the waiting addition back into the composer")
                    }.padding(.horizontal, 12).padding(.bottom, 8)
                }
            }.background(SilkwireTheme.wash(0.025), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SilkwireTheme.line))
        }.padding(.horizontal, 22).padding(.vertical, 10).background(SilkwireTheme.well(0.15)).overlay(alignment: .top) { if !sideLayoutActive { Rectangle().fill(SilkwireTheme.line).frame(height: 1) } }
        // No save on recipient change here: toggleRecipient already saves, and saving
        // again whenever a silo switch changes the recipient wrote the whole workspace twice.
    }
    private var contextDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Conversation context").font(.headline); Spacer(); Button { showContext = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close context details") }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    RevisionStatusView(store: store)
                    WorkspaceTasksView(store: store)
                    Text(store.contextDisclosure).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Last supplied per agent").font(.subheadline.weight(.medium))
                    ForEach(store.participants, id: \.self) { agent in
                        VStack(alignment: .leading, spacing: 3) {
                            if let snapshot = store.conversation.historyContext?[agent] {
                                Text("\(names[agent] ?? agent): \(snapshot.supplied) of \(snapshot.total) history messages" + (snapshot.shortened ? " · shortened" : ""))
                                if let components = snapshot.components, let total = snapshot.promptCharacters {
                                    Text("Prompt: \(total) / 32,000 characters").font(.caption)
                                    ForEach(components.keys.sorted(), id: \.self) { key in
                                        Text("\(contextComponentName(key)): \(components[key] ?? 0)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let bytes = snapshot.imageAttachmentBytes, bytes > 0 { Text("Images: \(bytes) bytes, supplied separately").font(.caption2) }
                                }
                                Text(snapshot.recordedAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                            } else { Text("\(names[agent] ?? agent): no recorded context count yet").foregroundStyle(.secondary) }
                        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Counts cover shared history supplied at that agent’s last dispatch, not its total memory or tokens. Replies earlier in the same team turn can make counts differ. Project brief and current message are supplied separately.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Permission diagnostics") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(store.participants, id: \.self) { agent in
                                if let snapshot = store.conversation.historyContext?[agent], let hash = snapshot.capabilityHash {
                                    Text("\(names[agent] ?? agent): snapshot \(hash.prefix(12)) · \(snapshot.folderCount ?? 0) folders").font(.caption2).textSelection(.enabled)
                                }
                            }
                            Text("Identifies the capability instructions sent with the last acknowledged dispatch. This does not prove the model used them or that a file operation ran.").font(.caption2).foregroundStyle(.secondary)
                        }.padding(.top, 5)
                    }.font(.caption)
                    Divider()
                    let folders = store.activeProject?.connectedFolders ?? []
                    Text(folders.isEmpty ? "No Project folders connected" : "\(folders.count) shared Project \(folders.count == 1 ? "folder" : "folders") · read-only").font(.subheadline.weight(.medium))
                    ForEach(folders) { folder in Text(folder.name).font(.callout).foregroundStyle(.secondary) }
                    Text("Builder editing and execution require a separate grant and an explicitly started task.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 230)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(SilkwireTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private func moveHit(_ offset: Int) { guard !searchHits.isEmpty else { return }; followPaused = true; hitIndex = (hitIndex + offset + searchHits.count) % searchHits.count }
    private func browseAttachments() {
        let panel = NSOpenPanel(); panel.title = "Attach images or text files"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "Images are resized to 1600 px. UTF-8 text/code: 12,000 characters per file. PDF, Office, audio, video and archives are unsupported. Up to six files, 12 MB total."
        if panel.runModal() == .OK { store.addAttachments(panel.urls) }
    }
    private func label(_ state: String) -> String { ["queued":"Queued", "sending":"Sending", "streaming":"Replying", "completed":"Done", "interrupted":"Stopped", "cancelled":"Not sent", "unconfirmed":"Outcome unconfirmed", "failed":"Needs attention", "sent":"Sent"][state] ?? state }
}
struct TranscriptMessageRow: View, Equatable {
    let message: Message
    let query: String
    let selectedHit: SearchHit?
    let seat: Seat?
    let reduceMotion: Bool
    let canBuild: Bool
    var build: () -> Void
    var canStop = false
    var stop: () -> Void = {}
    /// Jason's blue U / green R marker; nil hides it (companion rooms, older messages).
    var toggleRead: (() -> Void)? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message.unread == rhs.message.unread && (lhs.toggleRead == nil) == (rhs.toggleRead == nil) &&
        lhs.message.id == rhs.message.id && lhs.message.text == rhs.message.text && lhs.message.state == rhs.message.state && lhs.message.detail == rhs.message.detail && lhs.message.author == rhs.message.author && lhs.message.createdAt == rhs.message.createdAt && (lhs.message.attachments ?? []).map(\.id) == (rhs.message.attachments ?? []).map(\.id) && lhs.query == rhs.query && lhs.selectedHit?.id == rhs.selectedHit?.id && lhs.reduceMotion == rhs.reduceMotion && lhs.canBuild == rhs.canBuild && lhs.canStop == rhs.canStop && lhs.seat?.state == rhs.seat?.state && lhs.seat?.activity == rhs.seat?.activity && lhs.seat?.lastEventAt == rhs.seat?.lastEventAt
    }
    @State private var expanded = false
    @State private var hovering = false
    /// Keyboard users reveal Copy / Send to Builder by tabbing onto them (not only by pointer hover).
    private enum CardAction: Hashable { case builder, copy }
    @FocusState private var focusedAction: CardAction?
    @AppStorage(BuilderReceiptLine.cardsKey) private var builderReceiptCards = false
    var body: some View {
        // Builder receipts collapse into a compact activity bar; full details stay one click away.
        if message.author == "Builder", query.isEmpty {
            if builderReceiptCards || expanded { BuilderActivityBar(message: message, reduceMotion: reduceMotion, stop: canStop ? stop : nil) }
            else { BuilderReceiptLine(message: message, stop: canStop ? stop : nil, expand: { expanded = true }) }
        }
        // Automatic rounds must never look like another click by Jason.
        else if query.isEmpty, ConversationStore.isPassContinuation(message), message.state == "sent", !expanded { continuationLine }
        // A teammate's pass is a quiet line, not a full card.
        else if query.isEmpty, message.detail == "Passed" { passLine }
        // Everyone passed silently on the open floor: one quiet line, so the room never looks silent.
        else if query.isEmpty, message.author == "Silkwire", message.detail == BackgroundJobText.everyonePassedDetail { everyonePassedLine }
        // Jason already knows what he wrote: his sent messages fold to one line until clicked.
        // Your prompt arrives already collapsed (no full card that then shrinks).
        else if query.isEmpty, message.author == "Jason", ["sending", "sent"].contains(message.state), !expanded { jasonLine }
        else { standardBody }
    }
    private var continuationLine: some View {
        Button { expanded = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.caption)
                Text(message.detail == BackgroundJobText.followUpDetail ? "Silkwire · Asked for an explanation of a background result" : "Silkwire · Continuing your Pass automatically").font(.caption).lineLimit(1)
                Spacer(minLength: 8)
                if let date = message.createdAt { Text(date, format: .dateTime.hour().minute()).font(.system(size: 10)) }
                Image(systemName: "chevron.down").font(.system(size: 10))
            }.foregroundStyle(.secondary).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 5).id(message.id)
        .help("The next round of the same Pass, not another click. Show details.")
        .accessibilityLabel("Silkwire continued your existing Pass automatically. Show details.")
    }
    private var passLine: some View {
        HStack(spacing: 8) {
            InitialCircle(name: message.author, size: 18)
            Text("\(message.author) passed · nothing to add").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let date = message.createdAt { Text(date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 18).padding(.vertical, 3).id(message.id)
        .accessibilityElement(children: .combine)
    }
    private var everyonePassedLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.caption)
            Text(message.text).font(.caption)
            Spacer()
            if let date = message.createdAt { Text(date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 3).id(message.id)
        .accessibilityElement(children: .combine)
    }
    private var jasonSummary: String {
        if message.text.hasPrefix("Pass. Jason is passing") { return "Passed — the team keeps going" }
        let lines = message.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return (message.attachments ?? []).isEmpty ? "" : "Attachments" }
        return lines.count > 1 ? first + " …" : first
    }
    private var jasonLine: some View {
        Button { expanded = true } label: {
            HStack(spacing: 9) {
                InitialCircle(name: message.author, size: 22)
                Text(SetupModel.shared.label(for: message.author)).font(.system(size: 15, weight: .semibold)).foregroundStyle(SilkwireTheme.identity(message.author))
                Text(jasonSummary).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                if let count = message.attachments?.count, count > 0 { Label("\(count)", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                if let date = message.createdAt { Text(date, format: .dateTime.hour().minute()).font(.system(size: 12).monospacedDigit()).foregroundStyle(SilkwireTheme.inkSoft) }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(SilkwireTheme.inkSoft)
            }.font(SilkwireReadingType.body(15)).contentShape(Rectangle())
        }.buttonStyle(.plain).frame(minHeight: 22).silkwireCard(SilkwireTheme.jasonBubble, padding: 9).id(message.id)
        .help("Show your full message").accessibilityLabel("Your message: " + jasonSummary + ". Show full message")
    }
    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                InitialCircle(name: message.author, size: 26)
                Text(SetupModel.shared.label(for: message.author)).font(.system(size: 15, weight: .semibold)).foregroundStyle(SilkwireTheme.identity(message.author))
                // One status per teammate: while replying, the card's footer carries it.
                // Honest problem states keep their word and gain an icon, in the attention color.
                if message.state != "streaming" || seat == nil {
                    if ["failed", "unconfirmed"].contains(message.state) {
                        Label(label(message.state), systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(SilkwireTheme.attention)
                    } else { Text(label(message.state)).font(.system(size: 12)).foregroundStyle(SilkwireTheme.inkSoft) }
                }
                Spacer()
                // Secondary actions appear on hover (they stay reachable for VoiceOver).
                HStack(spacing: 8) {
                    if message.state == "completed", agents.contains(where: { names[$0] == message.author }) {
                        Button("Send to Builder…") { build() }.buttonStyle(.borderless).font(.system(size: 11)).disabled(!canBuild).focused($focusedAction, equals: .builder)
                    }
                    if !message.text.isEmpty { CopyFeedbackButton(text: message.text, title: "Copy message").focused($focusedAction, equals: .copy) }
                }.opacity(TranscriptCardActions.visible(hovering: hovering, keyboardFocused: focusedAction != nil) ? 1 : 0)
                if expanded, message.author == "Jason" || ConversationStore.isPassContinuation(message) { Button("Collapse") { expanded = false }.buttonStyle(.borderless).font(.system(size: 11)) }
                if let unread = message.unread, let toggleRead { ReadMarkBadge(unread: unread, toggle: toggleRead) }
                if let date = message.createdAt { Text(date, format: .dateTime.hour().minute()).font(.system(size: 12).monospacedDigit()).foregroundStyle(SilkwireTheme.inkSoft).help(date.formatted(date: .complete, time: .shortened)) }
            }
            if !message.text.isEmpty {
                if !query.isEmpty { SearchMessage(message: message, query: query, selected: selectedHit) }
                else if message.author == "Jason" { Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                else { MessageMarkdown(source: message.text).equatable() }
            } else if message.state == "queued" { Text("Waiting to start…").foregroundStyle(.secondary).font(.callout) }
            // While streaming, the single status line below (AgentStatus) says what's happening; no duplicate here.
            else if message.state == "streaming", seat == nil { Text("Working on your request…").foregroundStyle(.secondary).font(.callout) }
            ForEach(message.attachments ?? []) { attachment in
                if attachment.isImage, message.author == "Web inspection" { InspectionImagePreview(attachment: attachment) }
                else { AttachmentPreview(attachment: attachment).equatable() }
            }
            if message.state == "streaming", let seat { AgentStatus(seat: seat, reduceMotion: reduceMotion) }
            if let detail = message.detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.font(SilkwireReadingType.body(15)).foregroundStyle(SilkwireTheme.bodyInk).lineSpacing(4)
        .silkwireCard(message.author == "Jason" ? SilkwireTheme.jasonBubble : SilkwireTheme.agentBubble)
        .onHover { hovering = $0 }.id(message.id)
    }
    private func label(_ state: String) -> String { ["queued":"Queued", "sending":"Sending", "streaming":"Replying", "completed":"Done", "interrupted":"Stopped", "cancelled":"Not sent", "unconfirmed":"Outcome unconfirmed", "failed":"Needs attention", "sent":"Sent"][state] ?? state }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); if !WorkspaceEnvironment.current.agentTest && ProcessInfo.processInfo.environment["SILKWIRE_ACCEPTANCE"] == nil { NSApp.activate(ignoringOtherApps: true) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NotificationCenter.default.post(name: Notification.Name("SilkwireDismissEditors"), object: nil)
        for window in sender.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { onQuit?() }
}
@main struct SilkwireNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Background work is on: run steps go to the job host and the room stays free.
    // BackgroundJobBootstrap opens each conversation's host at library bootstrap.
    @StateObject private var store = ConversationStore(backgroundJobs: BackgroundJobBootstrap.application?.wiring)
    @StateObject private var notifications = CompletionNotifications()
    var body: some Scene {
        WindowGroup(WorkspaceEnvironment.title) {
            ConversationView(store: store, notifications: notifications).task {
                delegate.onQuit = { store.shutdown() }
                if store.environment.agentTest {
                    await AgentTestSession.start(store: store)
                    return
                }
                if store.environment.staging { NSApp.dockTile.badgeLabel = "STG" }
                #if SILKWIRE_STAGING
                if store.environment.staging, let check = ProcessInfo.processInfo.environment["SILKWIRE_STAGING_CHECK"], UUID(uuidString: check) != nil { await store.runStagingCheck(); return }
                #endif
                if ProcessInfo.processInfo.environment["SILKWIRE_ACCEPTANCE"] == nil && Bundle.main.bundleIdentifier != "app.silkwire.verification" {
                    notifications.refresh()
                    store.completionHandler = { title in notifications.completed(title: title, enabled: store.preferences.completionChime) }
                }
                // An installer that died mid-install must not keep every job waiting:
                // release its exclusive lane once the kernel proves its whole workload ended,
                // and keep re-checking while something it may have started still runs.
                if await StagingInstallLane.application.recoverInterrupted().contains(where: { if case .retained = $0 { return true }; return false }) {
                    StagingInstallLane.application.keepRecovering()
                }
                await store.start()
            }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1200, height: 900).commands {
            CommandGroup(replacing: .newItem) { Button("New Conversation…") { store.newConversationPresented = true }.keyboardShortcut("n", modifiers: .command).disabled(!store.canChangeConversation) }
            CommandMenu("View") {
                Button(store.preferences.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { store.setSidebarVisible(!store.preferences.sidebarVisible) }.keyboardShortcut("s", modifiers: [.control, .command])
            }
            CommandGroup(replacing: .help) { Button("Silkwire Help") { store.helpPresented = true }; Button("Set Up Silkwire…") { SetupModel.shared.presented = true } }
        }
        Settings { NativeSettingsView(store: store, notifications: notifications) }
    }
}

/// A small visible grip on a draggable edge, so thin borders read as resizable
/// (Jason). The grab area is wider than the grip; the cursor shows left-right arrows.
private struct ResizeGrip: View {
    @State private var hovering = false
    var body: some View {
        ZStack {
            Color.clear.frame(width: 12)
            Capsule().fill(Color.secondary.opacity(hovering ? 0.8 : 0.45)).frame(width: 4, height: 36)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .help("Drag to resize")
    }
}

/// A small horizontal grip on the composer's top edge: drag up for a taller writing space.
private struct HeightGrip: View {
    @State private var hovering = false
    var body: some View {
        ZStack {
            Color.clear.frame(height: 12)
            Capsule().fill(Color.secondary.opacity(hovering ? 0.8 : 0.45)).frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .help("Drag to resize")
    }
}

/// The finished top shared by side panels: rounded upper corners, square bottom.
enum PanelTop {
    static let radius: CGFloat = 12
    static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius, style: .continuous)
    }
}

extension View {
    /// Places another view to this one's right, top-aligned (used for a second silo).
    func alongside<Other: View>(leading: Bool = false, @ViewBuilder _ other: () -> Other) -> some View {
        HStack(alignment: .top, spacing: 0) { if leading { other(); self } else { self; other() } }
    }
}

private func contextComponentName(_ key: String) -> String {
    ["instructionsAndCapabilities": "Instructions and access", "projectBrief": "Project brief", "savedNotes": "Saved notes", "taskBoardsAndReceipts": "Work records", "history": "Conversation history", "currentReplies": "Current team replies", "userMessageAndAttachments": "Your message and text files", "assembly": "Formatting"][key] ?? key
}

/// Where the transcript's content ends (above the reserved room), in the viewport's space.
private struct TranscriptEndY: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}
