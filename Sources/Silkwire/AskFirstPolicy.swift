import Foundation

/// One entry in Jason's short ask-first list. Built-in rules have fixed ids and
/// host-side detectors; custom rules match their case-insensitive phrases.
struct AskFirstRule: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var enabled = true
    /// Custom rules only: phrases matched against commands, apps, windows, paths, URLs and typed text.
    var phrases: [String] = []
    var builtIn: Bool { AskFirstPolicy.builtInIDs.contains(id) }
}

/// Saved with workspace preferences. Staging turns computer control on for every
/// teammate by default; other builds never offer it.
struct ComputerAccessSettings: Codable, Equatable {
    var enabledAgents: [String: Bool] = ["eve": true, "claude": true, "codex": true]
    var rules: [AskFirstRule] = AskFirstPolicy.defaultRules
    var idleSeconds: Double = 20
    /// Deleting inside these folders needs no approval (plus each Project's granted folders).
    var projectFolders: [String] = ["~/Projects"]
    /// Connections Jason has switched off (e.g. "github", "server"); their network commands are refused.
    var disabledConnections: [String] = []
    func enabled(_ agent: String) -> Bool { enabledAgents[agent] ?? true }
    func connected(_ id: String) -> Bool { !disabledConnections.contains(id) }
    enum CodingKeys: String, CodingKey { case enabledAgents, rules, idleSeconds, projectFolders, disabledConnections }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledAgents = try c.decodeIfPresent([String: Bool].self, forKey: .enabledAgents) ?? enabledAgents
        // Keep Jason's edits; restore any built-in rule a newer build added.
        var saved = try c.decodeIfPresent([AskFirstRule].self, forKey: .rules) ?? AskFirstPolicy.defaultRules
        for rule in AskFirstPolicy.defaultRules where !saved.contains(where: { $0.id == rule.id }) { saved.insert(rule, at: min(saved.count, AskFirstPolicy.defaultRules.firstIndex(of: rule) ?? 0)) }
        rules = saved
        idleSeconds = min(300, max(5, try c.decodeIfPresent(Double.self, forKey: .idleSeconds) ?? 20))
        projectFolders = try c.decodeIfPresent([String].self, forKey: .projectFolders) ?? ["~/Projects"]
        disabledConnections = try c.decodeIfPresent([String].self, forKey: .disabledConnections) ?? []
    }
}

/// What Silkwire knows about a request's target at the moment it would run.
struct ComputerActionContext {
    var request: ComputerRequest
    /// App under the pointer (clicks, drags, scrolls) or frontmost (typing, keys); the named app otherwise.
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    /// Absolute folders where deleting is ordinary project work.
    var projectFolders: [String] = []
    var home = FileManager.default.homeDirectoryForCurrentUser.path
    /// write: whether the destination already exists (replacing it counts as deleting).
    var destinationExists = false
    /// Where a shell command without cwd runs.
    var defaultDirectory: String?
}

enum AskFirstDecision: Equatable {
    case proceed
    case ask(ruleID: String, title: String, reason: String)
    var needsApproval: Bool { if case .ask = self { return true }; return false }
}

/// Host-side ask-first checks. These are conservative pattern detectors, not a
/// proof about what an arbitrary shell command does; the audit log records everything.
enum AskFirstPolicy {
    static let credentials = "credentials", stableSilkwire = "stable-silkwire", messages = "messages", purchases = "purchases", deleting = "delete-outside-projects"
    static let githubProtected = "github-protected", serverOps = "server-ops"
    static let builtInIDs: Set<String> = [credentials, stableSilkwire, messages, purchases, deleting, githubProtected, serverOps]
    static let defaultRules = [
        AskFirstRule(id: credentials, title: "Keychain or password-manager access"),
        AskFirstRule(id: stableSilkwire, title: "Anything touching the stable Silkwire app or its library"),
        AskFirstRule(id: messages, title: "Sending email or messages"),
        AskFirstRule(id: purchases, title: "Purchases"),
        AskFirstRule(id: deleting, title: "Deleting files outside project folders"),
        AskFirstRule(id: githubProtected, title: "Merging to main, force-pushing or deleting branches on GitHub"),
        AskFirstRule(id: serverOps, title: "Server deploys, service restarts, config changes or databases")
    ]

    static let github = "github", server = "server"
    /// A reason to refuse outright because Jason disconnected the connection this command needs.
    static func blockedConnection(_ context: ComputerActionContext, settings: ComputerAccessSettings, hasServerKey: Bool = true) -> (id: String, reason: String)? {
        guard context.request.action == .shell, let command = context.request.command else { return nil }
        if !settings.connected(github), usesGitHubNetwork(command) { return (github, "Jason disconnected GitHub for agents in Settings → Agents → Connections. Local Git still works; reconnect it there to push, pull or use gh.") }
        if usesServer(command) {
            if !settings.connected(server) { return (server, "Jason disconnected the server for agents in Settings → Agents → Connections. Reconnect it there to use ssh, scp or rsync.") }
            // Agents use only the dedicated key, never Jason's personal key, so no key = no server access.
            if !hasServerKey { return (server, "There is no dedicated agent server key yet, and agents never use Jason's personal SSH key. Ask Jason to create one in Settings → Agents → Connections and add it to the server.") }
        }
        return nil
    }
    static func evaluate(_ context: ComputerActionContext, settings: ComputerAccessSettings) -> AskFirstDecision {
        let request = context.request
        guard request.action != .task, request.action != .wait else { return .proceed }
        for rule in settings.rules where rule.enabled {
            if let reason = match(rule, context) { return .ask(ruleID: rule.id, title: rule.title, reason: reason) }
        }
        return .proceed
    }

    private static func match(_ rule: AskFirstRule, _ context: ComputerActionContext) -> String? {
        switch rule.id {
        case credentials: return credentialAccess(context)
        case stableSilkwire: return stableAppAccess(context)
        case messages: return sendingMessage(context)
        case purchases: return purchase(context)
        case deleting: return deletion(context)
        case githubProtected: return gitHubProtected(context)
        case serverOps: return serverOperations(context)
        default:
            let haystack = [context.request.command, context.request.app, context.appName, context.bundleID, context.windowTitle, context.request.path, context.request.url, context.request.text, context.request.cwd].compactMap { $0?.lowercased() }
            for phrase in rule.phrases.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) where !phrase.isEmpty {
                if haystack.contains(where: { $0.contains(phrase) }) { return "Matches “\(phrase)” on your ask-first list." }
            }
            return nil
        }
    }

    // MARK: Targets

    /// Every app name and bundle ID this request touches (named and observed).
    private static func apps(_ context: ComputerActionContext) -> [String] {
        [context.request.app, context.appName, context.bundleID].compactMap { $0?.lowercased() }
    }
    private static func paths(_ context: ComputerActionContext) -> [String] {
        [context.request.path, context.request.cwd].compactMap { $0 }.map { ComputerRequest.expand($0, home: context.home) }
    }
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Pointer and keyboard input into an app, as opposed to looking at it.
    private static func inputs(_ request: ComputerRequest) -> Bool { [.click, .doubleClick, .rightClick, .drag, .type, .key].contains(request.action) }

    // MARK: Built-in detectors

    static let passwordApps = ["keychain access", "passwords", "1password", "1password 7", "bitwarden", "lastpass", "dashlane", "keepassxc", "enpass", "proton pass", "com.apple.keychainaccess", "com.apple.passwords", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.lastpassmacdesktop", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "in.sinew.enpass-desktop", "me.proton.pass.electron"]
    static let credentialPath = #"(Library/Keychains|\.openclaw/workspace/secrets|\.ssh/id_|\.password-store|\.codex/auth\.json|\.claude/(?:\.credentials|credentials\.json)|\.aws/credentials|\.config/(claude|gh|openclaw)/|\.netrc|Computer Control/Keys/|/Keys/silkwire-agents)"#
    static func isCredentialPath(_ path: String) -> Bool { matches(path, credentialPath) }
    /// Password-manager CLIs and the subcommands that read or change secrets ([] = any use).
    static let credentialTools: [String: [String]] = [
        "security": ["find-", "dump-", "export", "unlock-keychain", "delete-", "add-", "set-", "import", "create-keychain", "default-keychain", "list-keychains"],
        "op": ["item", "read", "signin", "vault", "inject", "run", "document", "account", "whoami"],
        "bw": ["get", "list", "unlock", "export", "login", "sync"],
        "pass": ["show", "insert", "edit", "rm", "generate", "git", ""], "lpass": [], "keepassxc-cli": [], "keychain-cli": []
    ]

    /// ssh/scp options whose VALUE is a path (e.g. the `-i` identity key). Passing the
    /// dedicated agent key as `-i <key>` is normal use and must not trip the credential rule.
    static let identityFileFlags: Set<String> = ["-i", "-F", "-o", "--identity", "--identity-file"]
    private static func credentialAccess(_ context: ComputerActionContext) -> String? {
        if apps(context).contains(where: { passwordApps.contains($0) }) { return "Targets a password manager or Keychain Access." }
        if let command = context.request.command {
            for words in allCommands(command) {
                if let tool = words.first.map(executableName), let subcommands = credentialTools[tool] {
                    let sub = words.dropFirst().first { !$0.hasPrefix("-") } ?? ""
                    if subcommands.isEmpty || subcommands.contains(where: { $0.isEmpty ? sub.isEmpty : sub.hasPrefix($0) }) { return "The command reads or changes Keychain or password-manager data." }
                }
                // A credential path appearing as an argument (cat ~/.ssh/id_rsa), but never the
                // identity key handed to ssh via -i, which is how agents are told to use it.
                var index = words.startIndex
                while index < words.endIndex {
                    let word = words[index]
                    if identityFileFlags.contains(word) { index += 2; continue }
                    if identityFileFlags.contains(where: { word.hasPrefix($0 + "=") }) { index += 1; continue }
                    if word.range(of: credentialPath, options: .regularExpression) != nil { return "The command touches a Keychain, password store or saved secret." }
                    index += 1
                }
            }
        }
        if paths(context).contains(where: { isCredentialPath($0) || isCredentialPath(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }) { return "The path is a Keychain, password store or saved secret." }
        return nil
    }

    /// The stable app's bundle IDs share this prefix; Staging and Verification do not count.
    static func isStableSilkwire(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), id.hasPrefix("app.silkwire.") else { return false }
        if id.hasPrefix("app.silkwire.agent-test.") { return false }
        return !["app.silkwire.staging", "app.silkwire.verification"].contains(id)
    }
    static let stableNames = ["Silkwire Dev", "Silkwire Native", "Silkwire Preview", "Silkwire Updated Preview", "Silkwire Working Recovery"]
    /// Installed stable apps, their backups and libraries; never Staging, source folders or build output.
    static let stableLocation = #"(Applications/Silkwire(?! Staging)[^/"'\n]*|Application Support/Silkwire (Native|Runtime|Dev|Preview|Working)|Silkwire\.command|app\.silkwire\.native)"#
    /// Quitting, killing or launching the stable app (every build's process is named Silkwire).
    static let stableProcess = #"(\b(killall|pkill)\b[^;&|\n]*silkwire|\b(quit|tell)\s+app(lication)?\s+"Silkwire(?! Staging)|\bopen\b[^;&|\n]*-a\s+"?Silkwire(?! Staging))"#
    private static func stableAppAccess(_ context: ComputerActionContext) -> String? {
        if isStableSilkwire(bundleID: context.bundleID) || isStableSilkwire(bundleID: context.request.app) { return "Targets the stable Silkwire app." }
        // App names are case-sensitive product names; "Silkwire Staging" and the source folder never match.
        let names = [context.request.app, context.appName].compactMap { $0 }
        if names.contains(where: { name in name == "Silkwire" || stableNames.contains(name) || stableNames.contains { name.hasPrefix($0 + " ") } }) { return "Targets the stable Silkwire app." }
        if paths(context).contains(where: { $0.range(of: stableLocation, options: .regularExpression) != nil }) { return "Touches the stable Silkwire app, its library or its backups." }
        guard let raw = context.request.command else { return nil }
        // Shell commands often escape spaces ("Silkwire\\ Dev.app"); compare the unescaped text.
        let command = raw.replacingOccurrences(of: "\\ ", with: " ")
        if command.range(of: stableLocation, options: .regularExpression) != nil { return "Touches the stable Silkwire app, its library or its backups." }
        if command.range(of: stableProcess, options: [.regularExpression, .caseInsensitive]) != nil { return "Quits, kills or opens the stable Silkwire app." }
        // Running (not reading) the scripts that replace the working app.
        for words in commands(command) {
            let names = words.map(executableName)
            guard let first = names.first, first == "swift" || first.hasSuffix(".swift") else { continue }
            if names.contains("promote-working.swift") { return "Promotes a build into the stable Silkwire app." }
            if names.contains("install.swift"), !words.contains("--staging") { return "Installs over the stable Silkwire app." }
        }
        return nil
    }

    static let messagingApps = ["mail", "messages", "slack", "discord", "whatsapp", "telegram", "signal", "microsoft outlook", "outlook", "spark", "spark desktop", "airmail", "microsoft teams", "superhuman", "mimestream", "facetime", "com.apple.mail", "com.apple.mobilesms", "com.tinyspeck.slackmacgap", "com.hnc.discord", "net.whatsapp.whatsapp", "ru.keepcoder.telegram", "org.whispersystems.signal-desktop", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.readdle.spark", "it.bloop.airmail2", "com.microsoft.teams2", "com.superhuman.electron", "com.mimestream.mimestream", "com.apple.facetime"]
    static let messagingWindow = #"(gmail|inbox|compose|new message|outlook|slack|discord|whatsapp|messenger|telegram|linkedin messaging)"#
    static let mailers: Set<String> = ["mail", "mailx", "sendmail", "msmtp", "mutt", "neomutt", "swaks", "imessage", "imsg"]
    static let messagingCommand = #"(smtps?://|api\.twilio\.com|hooks\.slack\.com|slack\.com/api/chat\.|discord(app)?\.com/api/webhooks|api\.telegram\.org/bot|gmail\.googleapis\.com|graph\.microsoft\.com/.*/(sendmail|messages)|api\.sendgrid\.com|api\.mailgun\.net|api\.postmarkapp\.com|api\.resend\.com|tell\s+app(lication)?\s+(id\s+)?"?(messages|mail|com\.apple\.mail|com\.apple\.mobilesms)\b|Application\(\s*["'](Messages|Mail)["']\s*\))"#
    private static func sendingMessage(_ context: ComputerActionContext) -> String? {
        if inputs(context.request) {
            if apps(context).contains(where: { messagingApps.contains($0) }) { return "Input into a mail or messaging app could send a message." }
            if let title = context.windowTitle, matches(title, messagingWindow) { return "Input into a mail or messaging page could send a message." }
        }
        if let command = context.request.command {
            if commands(command).contains(where: { $0.first.map(executableName).map(mailers.contains) == true }) { return "The command could send an email or message." }
            if matches(command, messagingCommand) { return "The command could send an email or message." }
        }
        return nil
    }

    static let purchaseWindow = #"(checkout|check out|place (your )?order|payment|billing|purchase|buy now|shopping (cart|bag)|your cart|subscribe|upgrade (your )?plan|apple pay)"#
    static let purchaseCommand = #"(mas\s+purchase|api\.stripe\.com/v1/(charges|payment_intents|checkout|subscriptions|invoices)|/v1/payments)"#
    private static func purchase(_ context: ComputerActionContext) -> String? {
        if inputs(context.request) {
            if apps(context).contains(where: { ["app store", "com.apple.appstore"].contains($0) }) { return "Input into the App Store could buy something." }
            if let title = context.windowTitle, matches(title, purchaseWindow) { return "Input into a checkout or payment page." }
        }
        if let text = context.request.text, containsCardNumber(text) { return "The text looks like a payment card number." }
        if let command = context.request.command, matches(command, purchaseCommand) { return "The command could make a purchase." }
        return nil
    }
    /// 13–19 digits (spaces or dashes allowed) passing the Luhn check.
    static func containsCardNumber(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#) else { return false }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let digits = text[range].compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count) else { continue }
            var sum = 0
            for (index, digit) in digits.reversed().enumerated() { let value = index % 2 == 1 ? digit * 2 : digit; sum += value > 9 ? value - 9 : value }
            if sum % 10 == 0 { return true }
        }
        return false
    }

    // MARK: GitHub protected operations

    /// Every simple command, including those run on a server through `ssh host "..."`.
    static func allCommands(_ command: String) -> [[String]] {
        commands(command).flatMap { words -> [[String]] in
            guard let exe = words.first.map(executableName), exe == "ssh" else { return [words] }
            return [words] + sshRemote(words)
        }
    }
    /// The remote command carried by an `ssh [options] host command...` invocation.
    static let sshValueFlags: Set<Character> = ["i", "p", "o", "l", "F", "c", "m", "b", "D", "L", "R", "W", "Q", "J", "e", "I", "O", "S", "E"]
    static func sshRemote(_ words: [String]) -> [[String]] {
        var rest = Array(words.dropFirst())
        while let first = rest.first, first.hasPrefix("-") {
            // -i key  (value flag, value in the next word) or -tt / combined short flags.
            if first.count == 2, let flag = first.dropFirst().first, sshValueFlags.contains(flag) { rest = Array(rest.dropFirst(2)) }
            else if first.count > 2, first.hasPrefix("-"), let flag = first.dropFirst().first, sshValueFlags.contains(flag), !first.contains("=") { rest = Array(rest.dropFirst()) }
            else { rest = Array(rest.dropFirst()) }
        }
        guard rest.count > 1 else { return [] }
        return segments(rest.dropFirst().joined(separator: " "))
    }
    static let protectedBranches: Set<String> = ["main", "master"]
    private static func gitSubcommand(_ words: ArraySlice<String>) -> (sub: String, args: [String])? {
        var rest = words.dropFirst()
        while let first = rest.first, first == "-C" || first == "-c" { rest = rest.dropFirst(2) }
        while let first = rest.first, first.hasPrefix("-") { rest = rest.dropFirst() }
        guard let sub = rest.first else { return nil }
        return (sub, Array(rest.dropFirst()))
    }
    private static func gitHubProtected(_ context: ComputerActionContext) -> String? {
        guard context.request.action == .shell, let command = context.request.command else { return nil }
        for words in allCommands(command) {
            guard let exe = words.first.map(executableName) else { continue }
            if exe == "gh" {
                let args = words.dropFirst().filter { !$0.hasPrefix("-") }
                if args.first == "pr", args.contains("merge") { return "Merges a pull request (usually into main)." }
                if args.first == "repo", args.contains("delete") { return "Deletes a GitHub repository." }
                if args.first == "release", args.contains("delete") { return "Deletes a GitHub release." }
            }
            guard exe == "git", let (sub, args) = gitSubcommand(words[...]) else { continue }
            if sub == "push" {
                if args.contains(where: { ["--force", "-f", "--force-with-lease", "--force-if-includes"].contains($0) || $0.hasPrefix("--force-with-lease=") }) { return "Force-pushes, which can overwrite shared history." }
                if args.contains(where: { !$0.hasPrefix("-") && $0.hasPrefix("+") }) { return "Force-pushes with a +refspec, which can overwrite a shared branch." }
                if args.contains("--delete") || args.contains("-d") || args.contains(where: { $0.hasPrefix(":") && $0.count > 1 }) { return "Deletes a remote branch." }
                let refs = args.filter { !$0.hasPrefix("-") }.dropFirst()  // drop the remote
                if refs.contains(where: { ref in let dest = ref.split(separator: ":").last.map(String.init) ?? ref; return protectedBranches.contains(dest) }) { return "Pushes directly to main/master." }
            }
            if sub == "branch", args.contains(where: { ["-D", "-d", "--delete"].contains($0) }) { return "Deletes a Git branch." }
        }
        return nil
    }

    // MARK: Server operations (deploy, restart, config, database)

    static let dbClients: Set<String> = ["mysql", "mariadb", "psql", "mongo", "mongosh", "redis-cli", "sqlite3", "mysqldump", "mariadb-dump", "pg_dump", "pg_dumpall", "pg_restore", "mongodump", "mongorestore", "influx"]
    static let deployRunners: Set<String> = ["npm", "yarn", "pnpm", "make", "cap", "bundle", "fab", "ansible-playbook"]
    private static func serverOperations(_ context: ComputerActionContext) -> String? {
        guard context.request.action == .shell, let command = context.request.command else { return nil }
        for words in allCommands(command) {
            guard let exe = words.first.map(executableName) else { continue }
            let rest = Array(words.dropFirst())
            let positional = rest.filter { !$0.hasPrefix("-") }
            let first = positional.first ?? ""
            func anyPositional(_ actions: Set<String>) -> String? { positional.first { actions.contains($0) } }
            switch exe {
            case "systemctl": if let act = anyPositional(["restart", "stop", "start", "reload", "enable", "disable", "mask", "unmask", "reload-or-restart"]) { return "Restarts or changes a service (systemctl \(act))." }
            case "service": if positional.contains(where: { ["restart", "stop", "start", "reload", "force-reload"].contains($0) }), positional.count >= 2 { return "Restarts a service (service)." }
            case "supervisorctl", "rcctl": if let act = anyPositional(["restart", "stop", "start", "reload"]) { return "Restarts a service (\(exe) \(act))." }
            case "pm2": if let act = anyPositional(["restart", "reload", "stop", "delete", "deploy", "start", "kill"]) { return "Restarts or deploys a service (pm2 \(act))." }
            case "docker", "podman": if let act = anyPositional(["restart", "stop", "start", "rm", "kill", "compose", "up", "down"]) { return "Restarts or removes a container (\(exe) \(act))." }
            case "docker-compose": if let act = anyPositional(["up", "down", "restart", "stop", "start", "rm"]) { return "Changes running containers (docker-compose \(act))." }
            case "nginx": if rest.contains("-s") || rest.contains(where: { $0.hasPrefix("-s") }) { return "Reloads or stops nginx." }
            case "apachectl", "apache2ctl", "httpd": if ["restart", "graceful", "stop", "start", "graceful-stop"].contains(first) { return "Restarts the web server (\(exe) \(first))." }
            case "launchctl": if ["load", "unload", "kickstart", "bootout", "bootstrap"].contains(first) { return "Loads or restarts a service (launchctl \(first))." }
            case _ where dbClients.contains(exe): return "Runs a database client (\(exe)); it can read or change data."
            case _ where deployRunners.contains(exe): if positional.contains(where: { $0 == "deploy" || $0.hasPrefix("deploy:") || $0.hasPrefix("deploy-") }) { return "Runs a deploy (\(exe) \(first))." }
            default: break
            }
            if exe == "deploy" || exe.hasSuffix("-deploy") || exe.hasSuffix("/deploy.sh") { return "Runs a deploy script." }
            // Editing or overwriting server config under /etc.
            if ["tee", "dd"].contains(exe), positional.contains(where: { $0.hasPrefix("/etc/") }) { return "Writes to server configuration under /etc." }
            if exe == "sed", rest.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }), positional.contains(where: { $0.hasPrefix("/etc/") }) { return "Edits server configuration under /etc in place." }
            if ["cp", "mv", "install"].contains(exe), positional.last?.hasPrefix("/etc/") == true { return "Overwrites server configuration under /etc." }
            if ["vi", "vim", "nano", "emacs"].contains(exe), positional.contains(where: { $0.hasPrefix("/etc/") }) { return "Opens server configuration under /etc for editing." }
        }
        return nil
    }

    // MARK: Connections Jason can disconnect

    /// Git network operations: a disconnected GitHub blocks these (local git still works).
    static func usesGitHubNetwork(_ command: String) -> Bool {
        for words in allCommands(command) {
            guard let exe = words.first.map(executableName) else { continue }
            if exe == "gh" { return true }
            if exe == "git", let (sub, _) = gitSubcommand(words[...]), ["push", "pull", "fetch", "clone", "ls-remote", "remote"].contains(sub) { return true }
        }
        return false
    }
    /// Commands that reach a remote host: a disconnected server connection blocks these.
    static func usesServer(_ command: String) -> Bool {
        for words in commands(command) {
            guard let exe = words.first.map(executableName) else { continue }
            if ["ssh", "sftp", "scp"].contains(exe) { return true }
            if exe == "rsync", words.dropFirst().contains(where: { !$0.hasPrefix("-") && $0.contains(":") && !$0.hasPrefix("/") }) { return true }
        }
        return false
    }

    // MARK: Deleting outside project folders

    static let deleteVerbs: Set<String> = ["rm", "rmdir", "unlink", "trash", "srm", "shred"]
    private static func deletion(_ context: ComputerActionContext) -> String? {
        let request = context.request
        if request.action == .key, apps(context).contains(where: { ["finder", "com.apple.finder"].contains($0) }),
           request.keys.contains(where: { $0.keyCode == 51 && $0.modifiers.contains(.command) }) { return "Moves Finder items to the Trash or empties it." }
        if request.action == .write, context.destinationExists, let path = request.path, !inside(ComputerRequest.expand(path, home: context.home), context) {
            return "Replaces an existing file outside your project folders."
        }
        guard request.action == .shell, let command = request.command else { return nil }
        if matches(command, #"rsync\s[^;&|]*--delete"#) { return "rsync --delete can remove files; it always asks first." }
        if matches(command, #"diskutil\s+(erase|zero|secureErase|reformat|partitionDisk)|newfs_|\bdd\s+[^;&|]*of=/dev/"#) { return "Erases a disk or volume." }
        // Relative paths resolve where the command will actually run (the shell lane's default is ~/Projects).
        var cwd: String? = ComputerRequest.expand(request.cwd ?? context.defaultDirectory ?? context.home, home: context.home)
        func unresolvable(_ word: String) -> Bool { word.contains("$") || word.contains("`") || (word.hasPrefix("~") && !word.hasPrefix("~/") && word != "~") }
        for words in commands(command) {
            guard let first = words.first.map(executableName) else { continue }
            // Follow cd within the command; an unresolvable cd makes later relative paths unknown.
            if first == "cd" || first == "pushd" {
                let target = words.dropFirst().first { !$0.hasPrefix("-") } ?? "~"
                if unresolvable(target) { cwd = nil; continue }
                let expanded = ComputerRequest.expand(target, home: context.home)
                cwd = expanded.hasPrefix("/") ? (expanded as NSString).standardizingPath : cwd.map { (($0 as NSString).appendingPathComponent(expanded) as NSString).standardizingPath }
                continue
            }
            var targets: [String] = []
            if deleteVerbs.contains(first) { targets = words.dropFirst().filter { !$0.hasPrefix("-") && !$0.contains(">") && !$0.contains("<") } }
            else if first == "find", words.contains(where: { ["-delete", "rm", "-exec", "-execdir"].contains($0) }) && (words.contains("-delete") || words.contains("rm")) {
                targets = Array(words.dropFirst().prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" })
                if targets.isEmpty { targets = ["."] }
            } else if first == "git", words.contains("clean") {
                // git -C <dir> clean works in <dir>, not the current folder.
                targets = [words.firstIndex(of: "-C").flatMap { words.indices.contains($0 + 1) ? words[$0 + 1] : nil } ?? "."]
            }
            else if first == "mv", let destination = words.last, destination.contains(".Trash") { targets = words.dropFirst().dropLast().filter { !$0.hasPrefix("-") } }
            else if first == "xargs", let verb = words.dropFirst().first(where: { !$0.hasPrefix("-") }).map(executableName), deleteVerbs.contains(verb) { return "Deletes files chosen at run time; Silkwire cannot tell where they are." }
            else { continue }
            if targets.isEmpty { continue }
            for target in targets {
                // Variables, substitutions and home shortcuts other than ~/ cannot be resolved safely.
                if unresolvable(target) { return "Deletes a path Silkwire cannot resolve before running (\(limitedUTF16(target, to: 80)))." }
                let expanded = ComputerRequest.expand(target, home: context.home)
                guard expanded.hasPrefix("/") || cwd != nil else { return "Deletes \(limitedUTF16(target, to: 120)) after changing to a folder Silkwire cannot resolve." }
                let absolute = expanded.hasPrefix("/") ? expanded : ((cwd ?? "/") as NSString).appendingPathComponent(expanded)
                if !inside(absolute, context) { return "Deletes \(limitedUTF16(target, to: 120)) outside your project folders." }
            }
        }
        return nil
    }
    /// True when the normalized path is strictly inside one of the project folders.
    static func inside(_ path: String, _ context: ComputerActionContext) -> Bool {
        guard let normalized = resolvedDestination(path) else { return false }
        return context.projectFolders.compactMap { resolvedDestination(ComputerRequest.expand($0, home: context.home)) }.contains { root in
            root.count > 1 && normalized.hasPrefix(root + "/") && !normalized.dropFirst(root.count).split(separator: "/").contains("..")
        }
    }
    /// Resolve the deepest existing ancestor before appending new path components.
    /// Permission errors and dangling links are unknown, so deletion asks first.
    private static func resolvedDestination(_ path: String) -> String? {
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        guard errno == ENOENT else { return nil }
        var status = stat()
        if lstat(path, &status) == 0 { return nil } // dangling symlink
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty, let resolved = resolvedDestination(parent) else { return nil }
        let leaf = (path as NSString).lastPathComponent
        if leaf == ".." { return (resolved as NSString).deletingLastPathComponent }
        if leaf == "." { return resolved }
        return (resolved as NSString).appendingPathComponent(leaf)
    }
    private static func executableName(_ word: String) -> String {
        var name = word
        while let first = name.first, first == "`" || first == "\\" || first == "$" { name.removeFirst() }
        return (name as NSString).lastPathComponent
    }
    /// Simple commands, including one level of `sh|bash|zsh -c "…"` payloads.
    static func commands(_ command: String) -> [[String]] {
        segments(command).flatMap { words -> [[String]] in
            guard let shell = words.first.map(executableName), ["sh", "bash", "zsh", "dash"].contains(shell),
                  let flag = words.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }), words.indices.contains(flag + 1) else { return [words] }
            return [words] + segments(words[flag + 1])
        }
    }
    /// Shell words per simple command, splitting on ; && || | & and newlines and
    /// skipping sudo/env/command prefixes and variable assignments. Quotes are honored.
    static func segments(_ command: String) -> [[String]] {
        var result: [[String]] = [], words: [String] = [], word = "", quote: Character?, escaped = false, hasWord = false
        func endWord() { if hasWord { words.append(word) }; word = ""; hasWord = false }
        func endSegment() { endWord(); if !words.isEmpty { result.append(words) }; words = [] }
        var characters = Array(command)[...]
        while let character = characters.popFirst() {
            if escaped { word.append(character); hasWord = true; escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let open = quote { if character == open { quote = nil } else { word.append(character) }; continue }
            switch character {
            case "'", "\"": quote = character; hasWord = true
            case " ", "\t": endWord()
            case ";", "\n", "|", "&", "(", ")", "{", "}": endSegment()
            default: word.append(character); hasWord = true
            }
        }
        endSegment()
        // Value-taking sudo/doas options, so `sudo -u postgres psql` resolves to `psql`, not `postgres`.
        let sudoValueFlags: Set<String> = ["-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "--user", "--group", "--chroot", "--close-from", "--prompt", "--role", "--type", "--host", "--other-user"]
        return result.map { segment in
            var words = Array(segment), inSudo = false
            while let first = words.first {
                if ["sudo", "doas"].contains(executableName(first)) { inSudo = true; words.removeFirst(); continue }
                if ["env", "command", "exec", "nohup", "time", "nice", "builtin", "then", "do", "else", "!"].contains(first) { words.removeFirst(); continue }
                if first.contains("=") && !first.hasPrefix("-") && !first.hasPrefix("/") { words.removeFirst(); continue }  // VAR=value
                if inSudo && first.hasPrefix("-") {
                    if sudoValueFlags.contains(first), words.count > 1 { words.removeFirst(2) } else { words.removeFirst() }
                    continue
                }
                break
            }
            return words
        }.filter { !$0.isEmpty }
    }
}
