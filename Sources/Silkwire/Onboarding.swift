import SwiftUI
import AppKit

/// First-run setup, built from Claude.app's design handoff (handoffs/onboarding-design).
/// One decision at a time on the left; "Your project" on the right fills up as the
/// room comes together. Every step can be skipped and "Set up later" closes setup
/// from any step. Progress is saved in this app's own library (Setup/setup-state.json),
/// so setup can be resumed from the sidebar card or Help › Set Up Silkwire….
///
/// The person's name is saved as "Preferred name" in About You (the same field the
/// About You page edits), so there is one place for it. Stored messages keep their
/// internal author key; only what's shown on screen uses the chosen name.
struct SetupState: Codable, Equatable {
    var dismissed = false
    var teammates: [String] = []
    var folderChosen = false
    var firstMessageSent = false
    var completed = false
}

@MainActor final class SetupModel: ObservableObject {
    static let shared = SetupModel()
    /// Tests point this at a temporary folder.
    static var folderOverride: URL?
    static var folder: URL { folderOverride ?? WorkspaceEnvironment.current.library.appendingPathComponent("Setup", isDirectory: true) }
    static var stateURL: URL { folder.appendingPathComponent("setup-state.json") }

    @Published private(set) var state = SetupState()
    @Published private(set) var userName = ""
    @Published var presented = false

    init() { reload() }

    func reload() {
        if let data = try? Data(contentsOf: Self.stateURL), let saved = try? JSONDecoder().decode(SetupState.self, from: data) { state = saved } else { state = SetupState() }
        userName = AgentBriefing.loadProfile().preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the app calls the person on screen. Never a hardcoded developer name.
    var displayName: String { userName.isEmpty ? "You" : userName }
    /// Label for a message author: the person's own messages show their chosen name.
    func label(for author: String) -> String { author == ReplyScroll.userAuthor ? displayName : author }

    /// Unfinished items for the sidebar reminder ("Finish setting up · N left").
    var remaining: Int {
        guard !state.completed else { return 0 }
        return [userName.isEmpty, state.teammates.isEmpty, !state.folderChosen, !state.firstMessageSent].filter { $0 }.count
    }
    var showsReminder: Bool { remaining > 0 }

    /// Saves first and only then shows the change, so progress on screen always matches
    /// what will be there after a restart (Trace/Eve review). Returns false if saving failed.
    @discardableResult func update(_ change: (inout SetupState) -> Void) -> Bool {
        var next = state; change(&next)
        guard next != state else { return true }
        do { try Self.persist(next); state = next; return true } catch { return false }
    }
    static func persist(_ value: SetupState) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: stateURL, options: .atomic)
    }

    /// Saves the name into About You. Sharing changes only through the visible
    /// "Let my teammates use this name" choice, never as a side effect (Trace/Eve review).
    func setName(_ raw: String, share: Bool) throws {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        var profile = AgentBriefing.loadProfile()
        profile.preferredName = name
        profile.shareIntroduction = share
        try AgentBriefing.save(profile)
        userName = name
    }
    var sharesIntroduction: Bool { AgentBriefing.loadProfile().shareIntroduction }
    /// Suggested starting point for the choice: keep an existing decision; a brand-new
    /// profile (nothing written yet) starts on, and the person can turn it off right there.
    var suggestedShare: Bool {
        let p = AgentBriefing.loadProfile()
        return p == UserProfile() ? true : p.shareIntroduction
    }

    /// A brand-new library: no messages anywhere and setup never finished or dismissed.
    func shouldAutoPresent(_ store: ConversationStore) -> Bool {
        guard !state.completed, !state.dismissed, !store.environment.agentTest,
              ProcessInfo.processInfo.environment["SILKWIRE_ACCEPTANCE"] == nil else { return false }
        return store.conversation.messages.isEmpty && store.conversations.allSatisfy { $0.messages.isEmpty }
    }
}

// MARK: - Design tokens (handoff section c)

enum SetupColors {
    static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    static let window = dyn(0x1C1C1F, 0xFAFAFA)
    static let panel = dyn(0x151518, 0xF1F0F4)
    static let card = dyn(0x242428, 0xFFFFFF)
    static let cardSelected = dyn(0x2A2638, 0xF4F1FE)
    static let line = dyn(0x2E2E34, 0xE6E5EA)
    static let line2 = dyn(0x45454D, 0xCFCED6)
    static let text = dyn(0xF4F4F6, 0x1B1B1F)
    static let text2 = dyn(0xB4B4BC, 0x52525B)
    static let text3 = dyn(0x8E8E98, 0x6B6B75)
    static let accent = dyn(0xA891FA, 0x6447DB)
    static let onAccent = dyn(0x17121F, 0xFFFFFF)
    static let accentText = dyn(0xB9A6FF, 0x5B3FD0)
    static let accentSoft = dyn(0x2C2640, 0xEEEAFD)
    static let success = dyn(0x5BD08A, 0x1E7F46)
    static let successSoft = dyn(0x1D3326, 0xE1F4E8)
    static let warn = dyn(0xF2B65A, 0x9A5600)
    static let folder = dyn(0x7CC0FF, 0x1F6FB8)
    static let folderSoft = dyn(0x1E2E40, 0xE3F0FD)
    static func teammate(_ agent: String) -> (fg: Color, bg: Color) {
        switch agent {
        case "claude": return (dyn(0xF0A877, 0xA3501A), dyn(0x3A2A21, 0xFBE8DA))
        case "codex": return (dyn(0x6FD6C4, 0x0F6F64), dyn(0x1D3632, 0xDCF2EE))
        default: return (dyn(0xBBA8FF, 0x5B3FD0), dyn(0x2E2846, 0xECE7FD))
        }
    }
}

struct SetupTeammate: Identifiable, Equatable {
    let id: String
    let name: String
    let maker: String
    static let all = [
        SetupTeammate(id: "claude", name: "Claude", maker: "Made by Anthropic"),
        SetupTeammate(id: "codex", name: "ChatGPT & Codex", maker: "Made by OpenAI"),
        SetupTeammate(id: "eve", name: "OpenClaw", maker: "An agent you set up yourself")
    ]
    var short: String { id == "codex" ? "Codex" : id == "eve" ? "OpenClaw" : name }
}

enum SetupStep: Int, CaseIterable {
    case welcome, name, team, folder, hello
    var label: String { ["Welcome", "Your name", "Your team", "Project folder", "Say hello"][rawValue] }
}

/// Pure helpers, kept separate so tests can check them without UI.
enum SetupCopy {
    static func opener(name: String, folder: String?) -> String {
        let hi = name.isEmpty ? "Hi team!" : "Hi team, I'm \(name)!"
        if let folder { return "\(hi) Let's start with quick intros: tell me your name and one thing you're great at. Then look around \(folder) and tell me, in plain words, what you think we're making." }
        return "\(hi) Let's start with quick intros: tell me your name and one thing you're great at. Then help me pick something fun we could make together this week."
    }
    static func caption(teammates: [String], folder: String?) -> String {
        let names = teammates.compactMap { id in SetupTeammate.all.first { $0.id == id }?.short }
        let open = 3 - names.count
        let who: String
        switch names.count {
        case 0: return "Just you for now. There's room for three teammates. Let's fill it."
        case 1: who = "You and \(names[0])."
        case 2: who = "You, \(names[0]) and \(names[1])."
        default: who = "You, \(names[0]), \(names[1]) and \(names[2])."
        }
        let seats = open == 0 ? " A full room!" : open == 1 ? " One seat open." : " Two seats open."
        return who + seats + (folder.map { " Working in \($0)." } ?? "")
    }
    static func cleanName(_ raw: String) -> String { String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
}

// MARK: - Setup window

struct OnboardingView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var setup: SetupModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: SetupStep = .welcome
    @State private var name = ""
    @State private var shareName = true
    @State private var team: Set<String> = []
    @State private var folderURL: URL?
    @State private var folderBookmark: Data?
    @State private var opener = ""
    @State private var openerEdited = false
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView { content.padding(.horizontal, 56).padding(.top, 44).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading) }
                Rectangle().fill(SetupColors.line).frame(height: 1)
                footer.frame(height: 76).padding(.horizontal, 24)
            }
            .frame(width: 580).background(SetupColors.window)
            Rectangle().fill(SetupColors.line).frame(width: 1)
            projectPane.frame(width: 379).background(SetupColors.panel)
        }
        .frame(width: 960, height: 640)
        .foregroundStyle(SetupColors.text)
        .onAppear(perform: begin)
        .onExitCommand { secondary() }
    }

    private func begin() {
        setup.reload()
        name = setup.userName
        shareName = setup.suggestedShare
        let signedIn = Set(store.connectionDetails.filter(\.signedIn).map(\.agent))
        team = setup.state.teammates.isEmpty ? signedIn.intersection(SetupTeammate.all.map(\.id)) : Set(setup.state.teammates)
        if team.isEmpty { team = ["claude"] }
        if store.connectionDetails.isEmpty { store.refreshConnections() }
        step = setup.userName.isEmpty ? .welcome : setup.state.teammates.isEmpty ? .team : !setup.state.folderChosen ? .folder : .hello
        refreshOpener()
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        Group {
            switch step {
            case .welcome: welcome
            case .name: nameStep
            case .team: teamStep
            case .folder: folderStep
            case .hello: helloStep
            }
        }
        .id(step)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 8)))
    }

    private func heading(_ text: String, size: CGFloat = 30) -> some View {
        Text(text).font(.system(size: size, weight: .medium, design: .serif)).fixedSize(horizontal: false, vertical: true)
    }
    private func body(_ text: String) -> some View {
        Text(text).font(.system(size: 14.5)).lineSpacing(5).foregroundStyle(SetupColors.text2).fixedSize(horizontal: false, vertical: true)
    }
    private var stepper: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STEP \(step.rawValue + 1) OF \(SetupStep.allCases.count) · \(step.label.uppercased())").font(.system(size: 11, weight: .semibold)).tracking(0.9).foregroundStyle(SetupColors.text3)
            HStack(spacing: 6) { ForEach(SetupStep.allCases, id: \.self) { s in Capsule().fill(s.rawValue <= step.rawValue ? SetupColors.accent : SetupColors.line2).frame(height: 4) } }
        }.padding(.bottom, 26).accessibilityElement(children: .combine)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("SILKWIRE").font(.system(size: 13, weight: .light)).tracking(5).foregroundStyle(SetupColors.text2)
            heading("All your SI teammates.\nOne room.", size: 40)
            body("Silkwire brings the super-intelligent teammates you already use, like Claude and ChatGPT, into one room, so they can make things with you and with each other.")
            VStack(alignment: .leading, spacing: 12) {
                promise("person.crop.circle.badge.checkmark", "Sign in with accounts you already have")
                promise("hand.raised", "Nothing changes on your Mac without your OK")
                promise("clock", "About two minutes to set up")
            }.padding(.top, 4)
            Text("Created by Jason Armstrong · Open source").font(.system(size: 12)).foregroundStyle(SetupColors.text3).padding(.top, 8)
        }
    }
    private func promise(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 30, height: 30).background(SetupColors.accentSoft, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(SetupColors.accentText).accessibilityHidden(true)
            Text(text).font(.system(size: 14))
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepper
            heading("What should we call you?")
            body("This is how Silkwire will greet you. You can change it any time in Settings › About You.")
            TextField("Type it here", text: $name)
                .textFieldStyle(.plain).font(.system(size: 18)).padding(.horizontal, 14).frame(height: 46)
                .background(SetupColors.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(SetupColors.line2))
                .onSubmit(primary)
                .accessibilityLabel("Your name")
            Text("Your real name, a nickname or your hacker handle. Your call.").font(.system(size: 12.5)).foregroundStyle(SetupColors.text2)
            Toggle("Let my teammates use this name", isOn: $shareName).toggleStyle(.checkbox).font(.system(size: 13))
            Text(shareName ? "Your teammates will see this name in the room." : "Only you will see this name. Teammates won't be told it.").font(.system(size: 12)).foregroundStyle(SetupColors.text3)
            if let problem { Text(problem).font(.system(size: 12.5)).foregroundStyle(SetupColors.warn) }
        }
    }

    private var teamStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepper
            heading(team.count >= 3 ? "Everyone's in!" : "Who's joining you?")
            body("Pick the teammates you already have an account with. Teammates do more together: one can draft while another double-checks. You can change this any time.")
            VStack(spacing: 10) { ForEach(SetupTeammate.all) { teammateRow($0) } }
            HStack(spacing: 8) {
                Text("Coming soon:").font(.system(size: 12)).foregroundStyle(SetupColors.text3)
                ForEach(["Grok", "OpenRouter"], id: \.self) { Text($0).font(.system(size: 11.5)).padding(.horizontal, 9).padding(.vertical, 3).background(SetupColors.card, in: Capsule()).foregroundStyle(SetupColors.text3) }
            }
            Text("Not signed in yet? That's fine. Pick them anyway and sign in from Connections whenever you're ready. Silkwire never sees your password.").font(.system(size: 12.5)).foregroundStyle(SetupColors.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func signedIn(_ id: String) -> Bool? { store.connectionDetails.first { $0.agent == id }.map(\.signedIn) }
    private func teammateRow(_ t: SetupTeammate) -> some View {
        let on = team.contains(t.id), colors = SetupColors.teammate(t.id)
        return Button { if on { team.remove(t.id) } else { team.insert(t.id) } } label: {
            HStack(spacing: 12) {
                Text(String(t.name.prefix(1))).font(.system(size: 15, weight: .semibold)).foregroundStyle(colors.fg).frame(width: 36, height: 36).background(colors.bg, in: Circle()).overlay(Circle().stroke(colors.fg.opacity(0.5), lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 2) { Text(t.name).font(.system(size: 14, weight: .semibold)); Text(t.maker).font(.system(size: 12.5)).foregroundStyle(SetupColors.text2) }
                Spacer()
                switch signedIn(t.id) {
                case true?: pill("✓ Signed in", fg: SetupColors.success, bg: SetupColors.successSoft)
                case false?: pill("Not signed in yet", fg: SetupColors.warn, bg: SetupColors.card)
                case nil: EmptyView()
                }
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 18)).foregroundStyle(on ? SetupColors.accent : SetupColors.line2)
            }
            .padding(12).background(on ? SetupColors.cardSelected : SetupColors.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? SetupColors.accent : SetupColors.line, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(t.name), \(t.maker)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
    private func pill(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 3).background(bg, in: Capsule()).foregroundStyle(fg)
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepper
            heading("Which folder is this project in?")
            body("Your teammates can look through it so they know what you're making. Pick just the project's folder, not your whole Documents.")
            if let folderURL {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").foregroundStyle(SetupColors.folder).frame(width: 36, height: 36).background(SetupColors.folderSoft, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) { Text(folderURL.lastPathComponent).font(.system(size: 14, weight: .semibold)); Text(folderURL.deletingLastPathComponent().lastPathComponent + " › " + folderURL.lastPathComponent).font(.system(size: 12.5)).foregroundStyle(SetupColors.text2) }
                    Spacer()
                    Button("Change…", action: chooseFolder)
                }.padding(12).background(SetupColors.card, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Button(action: chooseFolder) {
                    VStack(spacing: 6) { Image(systemName: "folder.badge.plus").font(.system(size: 22)); Text("Choose a folder…").font(.system(size: 14, weight: .semibold)) }
                        .frame(maxWidth: .infinity).frame(height: 96).foregroundStyle(SetupColors.accentText)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SetupColors.line2, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 0) {
                Label("Nothing gets edited, installed or sent without your OK.", systemImage: "checkmark.shield").font(.system(size: 13, weight: .semibold)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(SetupColors.accentSoft)
                HStack(alignment: .top, spacing: 20) {
                    rules("THEY CAN, ANY TIME", icon: "checkmark", ["Read the files in this folder", "Suggest changes for you to look over"])
                    rules("ONLY AFTER YOU SAY OK", icon: "lock", ["Change, add or delete files", "Install anything", "Send, post or upload anything"])
                }.padding(12)
            }.background(SetupColors.card).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(SetupColors.line))
            Text("Good to know: when a teammate reads a file, what's in it goes to the company behind them (like Anthropic or OpenAI) so it can think about it, the same as pasting it into their app.").font(.system(size: 12)).foregroundStyle(SetupColors.text3).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(problem).font(.system(size: 12.5)).foregroundStyle(SetupColors.warn) }
        }
    }
    private func rules(_ title: String, icon: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(SetupColors.text3)
            ForEach(lines, id: \.self) { line in Label(line, systemImage: icon).font(.system(size: 12.5)) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var helloStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepper
            heading("Say hello to your team")
            body("Your first message goes to everyone in the room. Here's a good opener. Use it as is, tweak it, or write your own.")
            TextEditor(text: Binding(get: { opener }, set: { opener = $0; openerEdited = true }))
                .font(.system(size: 14)).scrollContentBackground(.hidden).padding(10).frame(height: 130)
                .background(SetupColors.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(SetupColors.line2))
                .accessibilityLabel("First message")
            HStack(spacing: 8) {
                chip("Introduce yourselves") { opener = SetupCopy.opener(name: SetupCopy.cleanName(name), folder: folderURL?.lastPathComponent) }
                chip("Give me a tour") { opener = folderURL.map { "Could you look through \($0.lastPathComponent) and give me a short, plain-English tour? What is here, what looks unfinished, and one small thing we could finish together today." } ?? "Could you each tell me, in plain words, what kinds of projects you are best at helping with? Give me one example each." }
                chip("Brainstorm ideas") { opener = "I'd love some ideas. Each of you, suggest one fun thing we could make together this week. Keep it small enough to finish in an afternoon." }
            }
            Text("It'll be waiting in the message box. Press Send when you're ready. Nothing in your folder changes unless you OK it.").font(.system(size: 12)).foregroundStyle(SetupColors.text3)
            if let problem { Text(problem).font(.system(size: 12.5)).foregroundStyle(SetupColors.warn) }
        }
    }
    private func chip(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button { action(); openerEdited = true } label: { Text(title).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 6).background(SetupColors.accentSoft, in: Capsule()).foregroundStyle(SetupColors.accentText) }.buttonStyle(.plain)
    }
    private func refreshOpener() { if !openerEdited { opener = SetupCopy.opener(name: SetupCopy.cleanName(name), folder: folderURL?.lastPathComponent) } }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Set up later", action: later).buttonStyle(.borderless).foregroundStyle(SetupColors.text2).keyboardShortcut("w", modifiers: .command)
            Spacer()
            if let title = secondaryTitle {
                Button(title, action: secondary).buttonStyle(SetupButton(primary: false))
            }
            Button(action: primary) { HStack(spacing: 6) { Text(primaryTitle); Image(systemName: "arrow.right") } }
                .buttonStyle(SetupButton(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(step == .name && SetupCopy.cleanName(name).isEmpty)
        }
    }
    private var primaryTitle: String {
        switch step {
        case .welcome: return "Let's set up your room"
        case .name: return "Continue"
        case .team: return team.isEmpty ? "Pick at least one" : team.count == 1 ? "Continue with \(SetupTeammate.all.first { team.contains($0.id) }?.short ?? "1 teammate")" : "Continue with \(team.count) teammates"
        case .folder: return folderURL == nil ? "Choose a folder…" : "Use this folder"
        case .hello: return "Open my room"
        }
    }
    private var secondaryTitle: String? {
        switch step {
        case .welcome: return nil
        case .name: return "Back"
        case .team: return "Back"
        case .folder, .hello: return "Skip for now"
        }
    }
    private func go(_ next: SetupStep) { problem = nil; withAnimation(.easeOut(duration: 0.2)) { step = next } }

    private func primary() {
        switch step {
        case .welcome: go(.name)
        case .name:
            let clean = SetupCopy.cleanName(name)
            guard !clean.isEmpty else { return }
            do { try setup.setName(clean, share: shareName); refreshOpener(); go(.team) }
            catch { problem = "Couldn't save your name. Nothing else changed. Try again." }
        case .team:
            guard !team.isEmpty else { return }
            guard setup.update({ $0.teammates = SetupTeammate.all.map(\.id).filter(team.contains) }) else { problem = saveProblem; return }
            go(.folder)
        case .folder:
            if folderURL == nil { chooseFolder(); return }
            guard setup.update({ $0.folderChosen = true }) else { problem = saveProblem; return }
            refreshOpener(); go(.hello)
        case .hello: finish()
        }
    }
    private func secondary() {
        switch step {
        case .welcome: later()
        case .name: go(.welcome)
        case .team: go(.name)
        case .folder: folderURL = nil; folderBookmark = nil; refreshOpener(); go(.hello)
        case .hello: finish(withMessage: false)
        }
    }
    private var saveProblem: String { "Couldn't save your progress, so nothing moved on. Try again, or choose Set up later." }
    private func later() {
        setup.update { $0.dismissed = true }
        store.status = "No problem. Finish setting up any time from the sidebar or Help › Set Up Silkwire…."
        dismiss()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose your project's folder"; panel.prompt = "Use this folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Pick just the project's folder. Your teammates can read it, but can't change anything without your OK."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path != "/", canonical.path != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path else { problem = "Choose a specific project folder, not your whole Mac or home folder."; return }
        guard store.environment.permitsReading(canonical) else { problem = "That folder is protected or unavailable. Choose an ordinary folder for this project."; return }
        do {
            folderBookmark = try canonical.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            folderURL = canonical; problem = nil; refreshOpener()
        } catch { problem = "Couldn't keep read-only access to that folder. Try another one." }
    }

    /// Creates the first Project (read-only folder if chosen) and leaves the opener in
    /// the message box. Nothing is sent until the person presses Send.
    private func finish(withMessage: Bool = true) {
        let participants = SetupTeammate.all.map(\.id).filter { team.contains($0) }
        var project = Project()
        project.name = folderURL?.lastPathComponent ?? "My first project"
        project.participants = participants.isEmpty ? ["claude"] : participants
        if let folderURL, let folderBookmark { project.folders = [ProjectFolder(name: folderURL.lastPathComponent, path: folderURL.path, bookmark: folderBookmark)] }
        guard store.createProject(project, conversationTitle: "Say hello") else {
            problem = "Couldn't create your room right now. Your answers are saved. Try again, or choose Set up later."
            return
        }
        if !setup.userName.isEmpty, setup.sharesIntroduction { try? AgentBriefing.setShared(true, project: project.id) }
        if withMessage { store.setDraft(opener, for: store.conversation.id) }
        if !setup.update({ $0.completed = true; $0.dismissed = false }) { store.status = "Your room is ready, but setup progress couldn't be saved, so the setup reminder may come back." }
        dismiss()
    }

    // MARK: Right pane: "Your project"

    private var projectPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("YOUR PROJECT").font(.system(size: 11, weight: .semibold)).tracking(0.9).foregroundStyle(SetupColors.text3)
            Text(folderURL?.lastPathComponent ?? "My first project").font(.system(size: 20, weight: .medium, design: .serif))
            Spacer(minLength: 0)
            SetupWeb(you: SetupCopy.cleanName(name).isEmpty ? "You" : SetupCopy.cleanName(name), teammates: SetupTeammate.all.map(\.id).filter(team.contains), showsTeam: step.rawValue >= SetupStep.team.rawValue, folder: folderURL?.lastPathComponent)
                .frame(width: 300, height: 320).frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Text(SetupCopy.caption(teammates: step.rawValue >= SetupStep.team.rawValue ? SetupTeammate.all.map(\.id).filter(team.contains) : [], folder: folderURL?.lastPathComponent))
                .font(.system(size: 13)).foregroundStyle(SetupColors.text2).fixedSize(horizontal: false, vertical: true)
        }.padding(28)
    }
}

struct SetupButton: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13.5, weight: .semibold)).padding(.horizontal, 16).frame(height: 38)
            .background(primary ? SetupColors.accent : SetupColors.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(primary ? Color.clear : SetupColors.line2))
            .foregroundStyle(primary ? SetupColors.onAccent : SetupColors.text)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// The little web: you in the middle, three seats, a folder below. Threads are solid
/// in a teammate's color once they're in, dotted grey while a seat is open.
struct SetupWeb: View {
    let you: String
    let teammates: [String]
    let showsTeam: Bool
    let folder: String?
    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.46)
            let seats = [CGPoint(x: c.x, y: c.y - 118), CGPoint(x: c.x - 112, y: c.y + 62), CGPoint(x: c.x + 112, y: c.y + 62)]
            let folderPoint = CGPoint(x: c.x, y: c.y + 140)
            ZStack {
                ForEach(1..<4) { ring in Circle().stroke(SetupColors.line, lineWidth: 1).frame(width: CGFloat(ring) * 88, height: CGFloat(ring) * 88).position(c) }
                ForEach(0..<3) { i in
                    let agent = showsTeam && i < teammates.count ? teammates[i] : nil
                    Path { p in p.move(to: c); p.addLine(to: seats[i]) }
                        .stroke(agent.map { SetupColors.teammate($0).fg } ?? SetupColors.line2, style: StrokeStyle(lineWidth: agent == nil ? 1.2 : 2, dash: agent == nil ? [2, 4] : []))
                    node(agent.flatMap { a in SetupTeammate.all.first { $0.id == a }?.short } ?? "", agent: agent, size: 52).position(seats[i])
                }
                Path { p in p.move(to: c); p.addLine(to: folderPoint) }.stroke(folder == nil ? SetupColors.line2 : SetupColors.folder, style: StrokeStyle(lineWidth: folder == nil ? 1.2 : 2, dash: folder == nil ? [2, 4] : []))
                ZStack {
                    Circle().fill(folder == nil ? SetupColors.card : SetupColors.folderSoft).frame(width: 40, height: 40)
                    Image(systemName: "folder").foregroundStyle(folder == nil ? SetupColors.text3 : SetupColors.folder)
                }.position(folderPoint)
                if let folder { Text("\(folder) · read only").font(.system(size: 11)).foregroundStyle(SetupColors.text2).position(x: folderPoint.x, y: folderPoint.y + 32) }
                ZStack {
                    Circle().fill(SetupColors.accentSoft).frame(width: 64, height: 64).overlay(Circle().stroke(SetupColors.accent, lineWidth: 1.5))
                    Text(String(you.prefix(1)).uppercased()).font(.system(size: 22, weight: .semibold)).foregroundStyle(SetupColors.accentText)
                }.position(c)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SetupCopy.caption(teammates: showsTeam ? teammates : [], folder: folder))
    }
    private func node(_ label: String, agent: String?, size: CGFloat) -> some View {
        ZStack {
            if let agent {
                let colors = SetupColors.teammate(agent)
                Circle().fill(colors.bg).frame(width: size, height: size).overlay(Circle().stroke(colors.fg.opacity(0.6), lineWidth: 1.5))
                Text(String(label.prefix(1))).font(.system(size: 18, weight: .semibold)).foregroundStyle(colors.fg)
            } else {
                Circle().fill(SetupColors.card).frame(width: size, height: size).overlay(Circle().stroke(SetupColors.line2, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])))
                Image(systemName: "plus").foregroundStyle(SetupColors.text3)
            }
        }
    }
}

/// Sidebar reminder: "Finish setting up · N left".
struct SetupReminderCard: View {
    @ObservedObject var setup: SetupModel
    var body: some View {
        if setup.showsReminder {
            Button { setup.presented = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(SilkwireTheme.accent)
                    Text("Finish setting up · \(setup.remaining) left").font(.system(size: 11.5, weight: .medium))
                    Spacer()
                }.padding(9).background(SilkwireTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Finish setting up, \(setup.remaining) left")
        }
    }
}
