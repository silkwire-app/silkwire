import Foundation

// Jason's short ask-first list. Everything else proceeds; these ask first.
@main struct AskFirstPolicyTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var failures = 0, checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if value { print("PASS " + label) } else { failures += 1; print("FAIL: " + label) }
        }
        let settings = ComputerAccessSettings()
        let home = "/Users/alex"
        func request(_ json: String) -> ComputerRequest { try! ComputerRequest.parse("<<COMPUTER " + json + ">>")! }
        func request(_ args: [String: Any]) -> ComputerRequest { try! ComputerRequest.validate(args) }
        func decide(_ json: String, app: String? = nil, bundle: String? = nil, window: String? = nil, exists: Bool = false, settings custom: ComputerAccessSettings? = nil) -> AskFirstDecision {
            let context = ComputerActionContext(request: request(json), appName: app, bundleID: bundle, windowTitle: window, projectFolders: (custom ?? settings).projectFolders, home: home, destinationExists: exists, defaultDirectory: home + "/Projects")
            return AskFirstPolicy.evaluate(context, settings: custom ?? settings)
        }
        func rule(_ decision: AskFirstDecision) -> String? { if case .ask(let id, _, _) = decision { return id }; return nil }
        func shell(_ command: String, cwd: String? = nil) -> AskFirstDecision {
            let payload: [String: Any] = cwd.map { ["action": "shell", "command": command, "cwd": $0] } ?? ["action": "shell", "command": command]
            return decide(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)
        }

        // The defaults are exactly Jason's five, all on.
        check(settings.rules.map(\.id) == [AskFirstPolicy.credentials, AskFirstPolicy.stableSilkwire, AskFirstPolicy.messages, AskFirstPolicy.purchases, AskFirstPolicy.deleting, AskFirstPolicy.githubProtected, AskFirstPolicy.serverOps] && settings.rules.allSatisfy(\.enabled), "the default list has the seven built-in rules, all on")
        check(settings.enabled("claude") && settings.enabled("codex") && settings.enabled("eve") && settings.idleSeconds == 20, "every teammate is on by default with a 20-second idle wait")

        // Everything else proceeds.
        check(shell("swift Scripts/build.swift --staging", cwd: "~/Projects/silkwire") == .proceed, "builds proceed")
        check(shell("git status && git log --oneline -5", cwd: "/Users/alex/Projects/silkwire") == .proceed, "git inspection proceeds")
        check(shell("curl -s https://api.github.com/repos/example-org/example-app") == .proceed, "network reads proceed")
        check(shell("brew install jq") == .proceed, "installing a tool proceeds")
        check(decide(#"{"action":"click","x":10,"y":10}"#, app: "Xcode", bundle: "com.apple.dt.Xcode", window: "Silkwire — ConversationStore.swift") == .proceed, "clicking in Xcode proceeds")
        check(decide(#"{"action":"type","text":"swift test"}"#, app: "Terminal", bundle: "com.apple.Terminal") == .proceed, "typing in Terminal proceeds")
        check(decide(#"{"action":"screenshot"}"#) == .proceed, "a whole-screen screenshot proceeds")
        check(decide(#"{"action":"task","state":"start","title":"Mail-merge cleanup"}"#) == .proceed, "task bookkeeping never asks")
        check(decide(#"{"action":"write","path":"~/Projects/silkwire/notes.md","content":"x"}"#, exists: true) == .proceed, "replacing a file inside a project proceeds")
        check(decide(#"{"action":"write","path":"/tmp/new-file.txt","content":"x"}"#, exists: false) == .proceed, "creating a new file anywhere proceeds")
        check(decide(#"{"action":"open","app":"Silkwire Staging"}"#, app: "Silkwire Staging", bundle: "app.silkwire.staging") == .proceed, "driving Silkwire Staging itself proceeds")
        check(decide(#"{"action":"focus","app":"app.silkwire.agent-test.fixture"}"#, app: "Silkwire Agent Test", bundle: "app.silkwire.agent-test.fixture") == .proceed, "private candidate identity is outside the stable app namespace")

        // 1. Keychain and password managers.
        check(rule(shell("security find-generic-password -s github -w")) == AskFirstPolicy.credentials, "security find-generic-password asks")
        check(rule(shell("/usr/bin/security dump-keychain")) == AskFirstPolicy.credentials, "dump-keychain by full path asks")
        check(rule(shell("op item get 'Hostinger' --fields password")) == AskFirstPolicy.credentials, "1Password CLI asks")
        check(rule(shell("bw unlock")) == AskFirstPolicy.credentials, "Bitwarden CLI asks")
        check(rule(shell("cat ~/.openclaw/workspace/secrets/vps_key")) == AskFirstPolicy.credentials, "reading Jason's secrets folder asks")
        check(rule(shell("ls ~/Library/Keychains")) == AskFirstPolicy.credentials, "the Keychains folder asks")
        check(rule(decide(#"{"action":"read","path":"~/.ssh/id_ed25519"}"#)) == AskFirstPolicy.credentials, "reading an SSH private key asks")
        check(rule(decide(#"{"action":"open","app":"1Password"}"#)) == AskFirstPolicy.credentials, "opening 1Password asks")
        check(rule(decide(#"{"action":"screenshot","app":"Passwords"}"#)) == AskFirstPolicy.credentials, "capturing the Passwords app asks")
        check(rule(decide(#"{"action":"click","x":1,"y":1}"#, app: "Keychain Access", bundle: "com.apple.keychainaccess")) == AskFirstPolicy.credentials, "clicking inside Keychain Access asks")
        check(shell("echo 'security review notes' > ~/Projects/notes.txt") == .proceed, "the word security alone does not ask")

        // 2. The stable Silkwire app and its library.
        check(rule(decide(#"{"action":"open","app":"Silkwire Dev"}"#)) == AskFirstPolicy.stableSilkwire, "opening Silkwire Dev asks")
        check(rule(decide(#"{"action":"click","x":5,"y":5}"#, app: "Silkwire", bundle: "app.silkwire.native.ready.preview")) == AskFirstPolicy.stableSilkwire, "clicking in the stable app asks")
        check(rule(decide(#"{"action":"screenshot","app":"Silkwire Preview"}"#)) == AskFirstPolicy.stableSilkwire, "the legacy Preview on the working library asks")
        check(rule(shell("ls ~/Library/Application\\ Support/Silkwire\\ Native\\ Development")) == AskFirstPolicy.stableSilkwire, "backslash-escaped spaces still match the stable library")
        check(rule(shell("ls \"$HOME/Library/Application Support/Silkwire Native Development\"")) == AskFirstPolicy.stableSilkwire, "listing the stable library asks")
        check(rule(decide(#"{"action":"read","path":"~/Library/Application Support/Silkwire Native Development/workspace.json"}"#)) == AskFirstPolicy.stableSilkwire, "reading the stable library asks")
        check(rule(shell("swift Scripts/install.swift", cwd: "~/Projects/silkwire")) == AskFirstPolicy.stableSilkwire, "a stable install asks")
        check(rule(shell("swift Scripts/promote-working.swift --candidate x")) == AskFirstPolicy.stableSilkwire, "promotion into the working app asks")
        check(shell("swift Scripts/install.swift --staging", cwd: "~/Projects/silkwire") == .proceed, "installing Staging proceeds")
        check(shell("ls \"$HOME/Library/Application Support/Silkwire Staging\"") == .proceed, "the Staging library proceeds")
        check(rule(shell("defaults read app.silkwire.native.ready.preview")) == AskFirstPolicy.stableSilkwire, "the stable bundle's defaults ask")

        // 3. Sending email or messages.
        check(rule(decide(#"{"action":"key","keys":"cmd+return"}"#, app: "Mail", bundle: "com.apple.mail")) == AskFirstPolicy.messages, "keys in Mail ask")
        check(rule(decide(#"{"action":"type","text":"On my way"}"#, app: "Messages", bundle: "com.apple.MobileSMS")) == AskFirstPolicy.messages, "typing in Messages asks")
        check(rule(decide(#"{"action":"click","x":9,"y":9}"#, app: "Slack", bundle: "com.tinyspeck.slackmacgap")) == AskFirstPolicy.messages, "clicking in Slack asks")
        check(rule(decide(#"{"action":"click","x":9,"y":9}"#, app: "Safari", bundle: "com.apple.Safari", window: "Inbox (3) - jason@example.com - Gmail")) == AskFirstPolicy.messages, "clicking in a Gmail tab asks")
        check(decide(#"{"action":"screenshot","app":"Mail"}"#) == .proceed, "looking at Mail does not ask")
        check(rule(shell("echo hi | mail -s test someone@example.com")) == AskFirstPolicy.messages, "the mail command asks")
        check(rule(shell("osascript -e 'tell application \"Messages\" to send \"hi\" to buddy \"x\"'")) == AskFirstPolicy.messages, "AppleScript to Messages asks")
        check(rule(shell("curl -X POST https://hooks.slack.com/services/T000/B000/XXX -d '{}'")) == AskFirstPolicy.messages, "Slack webhooks ask")
        check(rule(shell("curl --url smtps://smtp.gmail.com:465 --mail-rcpt a@b.c")) == AskFirstPolicy.messages, "SMTP asks")
        check(shell("grep -rn mailto: src/") == .proceed, "searching code for mail links proceeds")

        // 4. Purchases.
        check(rule(decide(#"{"action":"click","x":3,"y":3}"#, app: "Safari", bundle: "com.apple.Safari", window: "Checkout – Amazon.com")) == AskFirstPolicy.purchases, "clicking on a checkout page asks")
        check(rule(decide(#"{"action":"click","x":3,"y":3}"#, app: "App Store", bundle: "com.apple.AppStore")) == AskFirstPolicy.purchases, "clicking in the App Store asks")
        check(rule(decide(#"{"action":"type","text":"4111 1111 1111 1111"}"#, app: "Safari", bundle: "com.apple.Safari", window: "Account")) == AskFirstPolicy.purchases, "typing a card number asks")
        check(decide(#"{"action":"type","text":"Order 1234 5678 9012 shipped"}"#, app: "Notes") == .proceed, "digits that fail the card check proceed")
        check(rule(shell("mas purchase 497799835")) == AskFirstPolicy.purchases, "mas purchase asks")
        check(rule(shell("curl https://api.stripe.com/v1/payment_intents -d amount=500")) == AskFirstPolicy.purchases, "creating a Stripe payment asks")
        check(AskFirstPolicy.containsCardNumber("5555-5555-5555-4444") && !AskFirstPolicy.containsCardNumber("1234567890123"), "card detection uses the Luhn check")

        // 5. Deleting outside project folders.
        check(shell("rm -rf .build output/tests", cwd: "~/Projects/silkwire") == .proceed, "deleting build output inside a project proceeds")
        check(shell("rm ~/Projects/silkwire/tmp.log") == .proceed, "deleting a project file by home path proceeds")
        check(shell("find . -name '*.o' -delete", cwd: "/Users/alex/Projects/example-app") == .proceed, "find -delete inside a project proceeds")
        check(shell("git clean -fdx", cwd: "/Users/alex/Projects/silkwire-worktrees/agent-control") == .proceed, "git clean inside a project proceeds")
        check(rule(shell("rm -rf ~/Documents/old")) == AskFirstPolicy.deleting, "deleting in Documents asks")
        check(rule(shell("rm -rf /")) == AskFirstPolicy.deleting, "deleting the root asks")
        check(rule(shell("rm -rf ~/Projects")) == AskFirstPolicy.deleting, "deleting the project folder itself asks")
        check(rule(shell("rm -rf ../../Desktop/x", cwd: "~/Projects/silkwire")) == AskFirstPolicy.deleting, "climbing out of a project asks")
        check(rule(shell("rm -rf $TARGET")) == AskFirstPolicy.deleting, "deleting an unresolved variable asks")
        check(rule(shell("cd /tmp && rm stale.txt", cwd: "~/Projects/silkwire")) == AskFirstPolicy.deleting, "a cd out of the project inside one command is followed")
        check(shell("cd ~/Projects/silkwire && rm -rf .build") == .proceed, "a cd into a project inside one command is followed")
        check(rule(shell("cd \"$WORK\" && rm -rf build")) == AskFirstPolicy.deleting, "a cd to an unresolved folder makes relative deletes ask")
        check(rule(shell("sudo rm /etc/hosts.bak")) == AskFirstPolicy.deleting, "sudo deletion outside projects asks")
        check(rule(shell("echo ok; trash ~/Desktop/screenshot.png")) == AskFirstPolicy.deleting, "a second command that trashes outside projects asks")
        check(rule(shell("rsync -av --delete src/ dst/", cwd: "~/Projects/silkwire")) == AskFirstPolicy.deleting, "rsync --delete always asks")
        check(rule(shell("find ~/Downloads -mtime +30 -delete")) == AskFirstPolicy.deleting, "find -delete outside projects asks")
        check(rule(shell("ls ~/Downloads | xargs rm")) == AskFirstPolicy.deleting, "xargs rm cannot be resolved and asks")
        check(rule(shell("mv ~/Desktop/a.txt ~/.Trash/")) == AskFirstPolicy.deleting, "moving to the Trash outside projects asks")
        check(rule(shell("diskutil eraseDisk APFS Blank disk4")) == AskFirstPolicy.deleting, "erasing a disk asks")
        check(rule(decide(#"{"action":"key","keys":"cmd+delete"}"#, app: "Finder", bundle: "com.apple.finder")) == AskFirstPolicy.deleting, "Finder's Move to Trash asks")
        check(rule(decide(#"{"action":"write","path":"~/.zshrc","content":"x"}"#, exists: true)) == AskFirstPolicy.deleting, "replacing a file outside projects asks")
        check(shell("rm -f build.log 2>/dev/null", cwd: "~/Projects/silkwire") == .proceed, "redirections are not delete targets")
        check(shell("echo \"rm -rf /\" > ~/Projects/notes.txt") == .proceed, "quoted text is not a command")

        // Independent review cases: ordinary commands that must ask, and must not.
        check(rule(shell("killall Silkwire")) == AskFirstPolicy.stableSilkwire && rule(shell("pkill -x Silkwire")) == AskFirstPolicy.stableSilkwire, "killing Silkwire processes asks")
        check(rule(shell("osascript -e 'quit app \"Silkwire\"'")) == AskFirstPolicy.stableSilkwire, "quitting the stable app by AppleScript asks")
        check(rule(shell("open -a \"Silkwire Dev\"")) == AskFirstPolicy.stableSilkwire, "launching the stable app asks")
        check(shell("open -a \"Silkwire Staging\"") == .proceed, "launching Staging proceeds")
        check(shell("cat Scripts/install.swift", cwd: "~/Projects/silkwire") == .proceed, "reading the install script proceeds")
        check(shell("grep -rn \"Silkwire Preview\" Sources", cwd: "~/Projects/silkwire") == .proceed, "searching source for stable app names proceeds")
        check(shell("codesign --verify --deep --strict \"output/release/Silkwire Dev.app\"", cwd: "~/Projects/silkwire") == .proceed, "verifying a build output named like the stable app proceeds")
        check(rule(shell("cp -R output/staging/x \"$HOME/Applications/Silkwire Dev.app\"", cwd: "~/Projects/silkwire")) == AskFirstPolicy.stableSilkwire, "writing into the installed stable app asks")
        check(shell("git commit -m \"fix mail parsing\"", cwd: "~/Projects/silkwire") == .proceed, "a commit message that mentions mail proceeds")
        check(rule(shell("osascript -e 'tell app \"Mail\" to send (make new outgoing message)'")) == AskFirstPolicy.messages, "AppleScript tell app Mail asks")
        check(rule(shell("osascript -l JavaScript -e 'Application(\"Messages\").send(\"hi\", {to: buddy})'")) == AskFirstPolicy.messages, "JavaScript for Automation to Messages asks")
        check(rule(shell("bash -c \"echo hi | mail -s x a@b.c\"")) == AskFirstPolicy.messages, "mail inside bash -c asks")
        check(shell("git commit -m \"document security find-generic-password usage\"", cwd: "~/Projects/silkwire") == .proceed, "a commit message that mentions the security tool proceeds")
        check(rule(shell("zsh -lc 'security find-generic-password -s x -w'")) == AskFirstPolicy.credentials, "the security tool inside zsh -lc asks")
        check(rule(shell("TOKEN=$(security find-generic-password -s x -w) && echo ok")) == AskFirstPolicy.credentials, "the security tool inside a substitution asks")
        check(rule(shell("git -C ~/Documents/repo clean -fdx", cwd: "~/Projects/silkwire")) == AskFirstPolicy.deleting, "git -C clean outside projects asks")
        check(shell("git -C ~/Projects/silkwire clean -fdx") == .proceed, "git -C clean inside a project proceeds")
        check(shell("rm -rf silkwire/.build") == .proceed, "relative deletes resolve where the shell runs (~/Projects)")
        check(rule(decide(#"{"action":"key","keys":"cmd+backspace"}"#, app: "Finder", bundle: "com.apple.finder")) == AskFirstPolicy.deleting, "Finder's Move to Trash asks under either key name")

        // GitHub: ordinary work proceeds; protected operations ask.
        check(settings.rules.contains { $0.id == AskFirstPolicy.githubProtected } && settings.rules.contains { $0.id == AskFirstPolicy.serverOps }, "the GitHub and server rules ship on by default")
        check(shell("git clone https://github.com/example-org/example-app", cwd: "~/Projects") == .proceed, "cloning proceeds")
        check(shell("git checkout -b feature/x && git commit -am wip && git push -u origin feature/x", cwd: "~/Projects/silkwire") == .proceed, "branch, commit and push to an own branch proceed")
        check(shell("gh pr create --fill", cwd: "~/Projects/silkwire") == .proceed, "opening a pull request proceeds")
        check(rule(shell("git push origin main", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "pushing to main asks")
        check(rule(shell("git push origin HEAD:master", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "pushing to master by refspec asks")
        check(rule(shell("git push --force origin feature/x", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "force-pushing asks")
        check(rule(shell("git push --force-with-lease", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "force-with-lease asks")
        check(rule(shell("git push origin --delete feature/old", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "deleting a remote branch asks")
        check(rule(shell("git push origin :feature/old", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "deleting a remote branch by colon refspec asks")
        check(rule(shell("git branch -D feature/old", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "force-deleting a local branch asks")
        check(rule(shell("git push origin +feature/x", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "a +refspec force-push to any branch asks")
        check(rule(shell("git push origin +HEAD:feature/y", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "a +HEAD:branch force-push asks")
        check(rule(shell("gh pr merge 42 --squash", cwd: "~/Projects/silkwire")) == AskFirstPolicy.githubProtected, "merging a pull request asks")
        check(rule(shell("gh repo delete example-org/x --yes")) == AskFirstPolicy.githubProtected, "deleting a GitHub repo asks")
        check(shell("git -C ~/Projects/silkwire push origin feature/y") == .proceed, "git -C push to an own branch proceeds")

        // Finding 1: using the dedicated key with -i (its real Keys/ path) does not ask under credentials.
        let keyPath = "/Users/alex/Library/Application Support/Silkwire Staging/Computer Control/Keys/silkwire-agents"
        check(keyPath.range(of: AskFirstPolicy.credentialPath, options: .regularExpression) != nil, "the agent key path is still a known credential path for file reads")
        check(shell("ssh -i '\(keyPath)' deploy@vps 'tail -n 200 /var/log/nginx/access.log'") == .proceed, "reading a log with the dedicated key via -i proceeds, not asks")
        check(rule(decide(#"{"action":"read","path":"\#(keyPath)"}"#)) == AskFirstPolicy.credentials, "reading the key file itself still asks under credentials")
        check(rule(shell("cat '\(keyPath)'")) == AskFirstPolicy.credentials, "cat of the key file still asks under credentials")

        // Server: reads proceed; deploys, restarts, config and databases ask (local or over ssh).
        check(shell("ssh -i ~/.ssh/silkwire-agents deploy@vps 'tail -n 200 /var/log/nginx/access.log'") == .proceed, "reading a server log proceeds")
        check(shell("ssh vps 'systemctl status silkwire'") == .proceed, "checking service status proceeds")
        check(shell("ssh vps 'journalctl -u app -n 100 --no-pager'") == .proceed, "reading the journal proceeds")
        check(rule(shell("ssh vps 'systemctl restart nginx'")) == AskFirstPolicy.serverOps, "restarting a service over ssh asks")
        check(rule(shell("ssh -i ~/.ssh/silkwire-agents deploy@vps 'sudo service nginx reload'")) == AskFirstPolicy.serverOps, "reloading a service over ssh asks")
        check(rule(shell("ssh vps 'pm2 restart app'")) == AskFirstPolicy.serverOps, "pm2 restart over ssh asks")
        check(rule(shell("ssh vps 'docker compose up -d'")) == AskFirstPolicy.serverOps, "docker compose up over ssh asks")
        check(rule(shell("ssh vps 'npm run deploy'")) == AskFirstPolicy.serverOps, "a deploy over ssh asks")
        check(rule(shell("ssh vps 'mysql -u root app -e \"DELETE FROM sessions\"'")) == AskFirstPolicy.serverOps, "a database client over ssh asks")
        check(rule(shell("ssh vps 'pg_dump app > backup.sql'")) == AskFirstPolicy.serverOps, "a database dump over ssh asks")
        check(rule(shell("ssh vps 'sudo -u postgres psql -c \"DROP TABLE sessions\"'")) == AskFirstPolicy.serverOps, "sudo -u postgres psql still asks (the -u value is not mistaken for the command)")
        check(rule(shell("ssh vps 'docker-compose -f /srv/app/compose.yml up -d'")) == AskFirstPolicy.serverOps, "docker-compose with a -f file before the action asks")
        check(rule(shell("ssh vps 'systemctl -H other restart app'")) == AskFirstPolicy.serverOps, "systemctl with a value-flag before the action asks")
        check(rule(shell("ssh vps 'git -C /srv/app push --force origin main'")) == AskFirstPolicy.githubProtected, "a protected git push run on the server asks")
        check(rule(shell("ssh vps 'sudo sed -i s/x/y/ /etc/nginx/nginx.conf'")) == AskFirstPolicy.serverOps, "editing /etc config over ssh asks")
        check(rule(shell("ssh vps 'echo cfg | sudo tee /etc/app/config.toml'")) == AskFirstPolicy.serverOps, "writing /etc config over ssh asks")
        check(rule(shell("systemctl restart app")) == AskFirstPolicy.serverOps, "restarting a service locally also asks")
        check(shell("ssh vps 'ls -la /var/www && cat /var/www/app/version.txt'") == .proceed, "listing and reading files over ssh proceeds")

        // Disconnecting a connection refuses its commands (hard block, not a prompt).
        check(AskFirstPolicy.blockedConnection(ComputerActionContext(request: request(["action":"shell","command":"git push origin feature/x"])), settings: settings) == nil, "GitHub commands are allowed while connected")
        var offGitHub = ComputerAccessSettings(); offGitHub.disabledConnections = [AskFirstPolicy.github]
        check(AskFirstPolicy.blockedConnection(ComputerActionContext(request: request(["action":"shell","command":"gh pr create"])), settings: offGitHub)?.id == AskFirstPolicy.github, "a disconnected GitHub refuses gh")
        check(AskFirstPolicy.blockedConnection(ComputerActionContext(request: request(["action":"shell","command":"git commit -am wip"])), settings: offGitHub) == nil, "a disconnected GitHub still allows local git")
        var offServer = ComputerAccessSettings(); offServer.disabledConnections = [AskFirstPolicy.server]
        check(AskFirstPolicy.blockedConnection(ComputerActionContext(request: request(["action":"shell","command":"ssh vps uptime"])), settings: offServer)?.id == AskFirstPolicy.server, "a disconnected server refuses ssh")
        check(AskFirstPolicy.blockedConnection(ComputerActionContext(request: request(["action":"shell","command":"rsync -a ./x deploy@vps:/srv/x"])), settings: offServer)?.id == AskFirstPolicy.server, "a disconnected server refuses remote rsync")
        check(AskFirstPolicy.blockedConnection(ComputerActionContext(request: request(["action":"shell","command":"rsync -a ./x ./y"])), settings: offServer) == nil, "a disconnected server still allows local rsync")
        let savedConn = try JSONDecoder().decode(ComputerAccessSettings.self, from: JSONEncoder().encode(offServer))
        check(savedConn.disabledConnections == [AskFirstPolicy.server], "disconnected connections are saved")

        // Editable: rules turn off, folders extend, custom phrases add rules.
        var edited = ComputerAccessSettings()
        edited.rules[4].enabled = false
        check(decide(#"{"action":"shell","command":"rm -rf ~/Documents/old"}"#, settings: edited) == .proceed, "a rule Jason turns off no longer asks")
        edited = ComputerAccessSettings(); edited.projectFolders.append("~/Documents/Scratch")
        check(decide(#"{"action":"shell","command":"rm -rf ~/Documents/Scratch/run-1"}"#, settings: edited) == .proceed, "an added project folder allows deleting inside it")
        edited = ComputerAccessSettings()
        edited.rules.append(AskFirstRule(id: "custom-iac", title: "Infrastructure changes", phrases: ["terraform apply", "pulumi up"]))
        check(rule(decide(#"{"action":"shell","command":"terraform apply -auto-approve"}"#, settings: edited)) == "custom-iac", "a custom phrase asks")
        check(decide(#"{"action":"shell","command":"terraform plan"}"#, settings: edited) == .proceed, "a custom rule does not over-match")
        if case .ask(_, let title, let reason) = decide(#"{"action":"shell","command":"pulumi up --yes"}"#, settings: edited) {
            check(title == "Infrastructure changes" && reason.contains("pulumi up"), "approval prompts name the rule and the match")
        } else { check(false, "approval prompts name the rule and the match") }

        // Saved settings keep Jason's edits and gain new built-in rules.
        var saved = ComputerAccessSettings(); saved.rules.removeAll { $0.id == AskFirstPolicy.purchases }; saved.rules[0].enabled = false; saved.enabledAgents["codex"] = false; saved.idleSeconds = 1
        let decoded = try JSONDecoder().decode(ComputerAccessSettings.self, from: JSONEncoder().encode(saved))
        check(decoded.rules.contains { $0.id == AskFirstPolicy.purchases } && !decoded.rules[0].enabled, "decoding restores missing built-ins and keeps turned-off rules")
        check(!decoded.enabled("codex") && decoded.enabled("claude"), "per-teammate switches are saved")
        check(decoded.idleSeconds == 5, "the idle period is clamped to at least five seconds")

        // Shell word splitting used by the delete check.
        check(AskFirstPolicy.segments("FOO=1 sudo -n rm -rf 'a b' && echo \"x;y\" | tee c") == [["rm", "-rf", "a b"], ["echo", "x;y"], ["tee", "c"]], "commands split on operators with quotes honored")
        check(AskFirstPolicy.segments("sudo -u postgres psql -c x") == [["psql", "-c", "x"]], "a sudo value-flag consumes its argument")
        check(AskFirstPolicy.segments("sudo -H -u deploy systemctl restart app") == [["systemctl", "restart", "app"]], "mixed sudo flags are stripped to the real command")

        print("AskFirstPolicyTests: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
