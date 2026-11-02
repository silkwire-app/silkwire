import Foundation

// About You + USER.md + AGENTBRIEF.md: what agents receive on the way in.
// Uses a temporary folder; never touches the real ~/Silkwire.
@main struct AboutYouTests {
    static var failures = 0
    static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS: " + name) } else { failures += 1; print("FAIL: " + name) }
    }
    static func main() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aboutyou-\(UUID().uuidString)", isDirectory: true)
        AgentBriefing.folderOverride = temp
        defer { try? FileManager.default.removeItem(at: temp) }
        let projectA = UUID(), projectB = UUID()

        // Private by default
        var p = UserProfile()
        check(!p.shareIntroduction && !p.shareStory && !p.shareKnowledge && !p.shareWorkingTogether && !p.shareRhythm, "every section starts private")
        p.preferredName = "Jason"; p.about = "Founder of Silkwire."; p.background = "Army satellite communications."; p.timezone = "America/Chicago"
        check(!p.hasSharedContent && p.markdown().isEmpty, "filled but unshared profile produces no USER.md text")
        let legacy = try! JSONDecoder().decode(UserProfile.self, from: Data("{\"preferredName\":\"Old\"}".utf8))
        check(legacy.preferredName == "Old" && !legacy.shareIntroduction, "older files missing share flags decode as private")

        // Unshared name never leaks
        p.shareStory = true
        let storyOnly = p.markdown()
        check(storyOnly.contains("Army satellite"), "a shared section is included")
        check(!storyOnly.contains("Jason"), "the name is not sent when the introduction is unshared")
        check(storyOnly.contains("What the user chose"), "the header uses a neutral label instead")
        check(!storyOnly.contains("America/Chicago"), "an unshared section is not sent")
        p.shareIntroduction = true
        check(p.markdown().contains("What Jason chose") && p.markdown().contains("**Preferred name:** Jason"), "the name appears once the introduction is shared")
        check(p.markdown().contains("never grants"), "USER.md says it never grants permission")

        // Per-Project: nothing reaches a Project that wasn't chosen
        try! AgentBriefing.save(p)
        check(!AgentBriefing.currentContext(project: projectA).contains("ABOUT THE USER"), "no Project receives the profile until chosen")
        check(!AgentBriefing.currentContext(project: nil).contains("ABOUT THE USER"), "a room without a Project never receives it")
        try! AgentBriefing.setShared(true, project: projectA)
        check(AgentBriefing.currentContext(project: projectA).contains("Army satellite"), "the chosen Project receives the shared sections")
        check(!AgentBriefing.currentContext(project: projectB).contains("ABOUT THE USER"), "other Projects still receive nothing")
        try! AgentBriefing.setShared(false, project: projectA)
        check(!AgentBriefing.currentContext(project: projectA).contains("ABOUT THE USER"), "turning a Project off stops sharing at once")
        try! AgentBriefing.setShared(true, project: projectA)

        // Revoking: USER.md is removed, and agents read the saved form, not the file
        check(FileManager.default.fileExists(atPath: AgentBriefing.userURL.path), "USER.md copy exists while something is shared")
        var revoked = p; revoked.shareIntroduction = false; revoked.shareStory = false
        try! AgentBriefing.save(revoked)
        check(!FileManager.default.fileExists(atPath: AgentBriefing.userURL.path), "USER.md is deleted when nothing is shared")
        check(!AgentBriefing.currentContext(project: projectA).contains("ABOUT THE USER"), "revoked sharing reaches no one")
        try! Data(p.markdown().utf8).write(to: AgentBriefing.userURL)
        check(!AgentBriefing.currentContext(project: projectA).contains("Army satellite"), "a stale USER.md file is never sent")
        try? FileManager.default.removeItem(at: AgentBriefing.userURL)

        // A failed save fails closed
        try! AgentBriefing.save(p)
        check(AgentBriefing.currentContext(project: projectA).contains("Army satellite"), "sharing restored after a good save")
        try! FileManager.default.removeItem(at: AgentBriefing.profileURL)
        try! FileManager.default.createDirectory(at: AgentBriefing.profileURL, withIntermediateDirectories: true)
        var failed = false
        do { try AgentBriefing.save(revoked) } catch { failed = true }
        check(failed, "the blocked save reports failure")
        check(AgentBriefing.failedClosed, "a failed save is remembered")
        check(!AgentBriefing.currentContext(project: projectA).contains("ABOUT THE USER"), "after a failed save nothing about the user is sent")
        check(!FileManager.default.fileExists(atPath: AgentBriefing.userURL.path), "after a failed save no USER.md copy remains")
        AgentBriefing.simulateRestart()
        check(AgentBriefing.failedClosed, "the failure is still remembered after a restart")
        check(!AgentBriefing.currentContext(project: projectA).contains("ABOUT THE USER"), "after a restart nothing about the user is sent")
        check(AgentBriefing.sharedProjects().isEmpty, "a failed save also clears the Project list")
        try! FileManager.default.removeItem(at: AgentBriefing.profileURL)
        try! AgentBriefing.save(p)
        check(!AgentBriefing.failedClosed, "a later good save clears the failure")
        check(AgentBriefing.sharedProjects().isEmpty, "Projects must be turned on again after a failure")
        let realHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Silkwire/System").path
        AgentBriefing.folderOverride = nil
        check(!AgentBriefing.systemFolder.path.hasPrefix(realHome), "storage is not the shared ~/Silkwire folder")
        check(AgentBriefing.systemFolder.path.hasPrefix(WorkspaceEnvironment.current.library.path), "storage lives in this app's own library")
        AgentBriefing.folderOverride = temp

        // A failed Project revocation stays off even after an unrelated good save (Eve's case)
        try! AgentBriefing.setShared(true, project: projectB)
        let priorConsent = try! Data(contentsOf: AgentBriefing.sharingURL)
        try! FileManager.default.removeItem(at: AgentBriefing.sharingURL)
        try! FileManager.default.createDirectory(at: AgentBriefing.sharingURL, withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: AgentBriefing.sharingURL.appendingPathComponent("blocker"))
        var revokeFailed = false
        do { try AgentBriefing.setShared(false, project: projectB) } catch { revokeFailed = true }
        check(revokeFailed, "a blocked Project revocation reports failure")
        if FileManager.default.fileExists(atPath: AgentBriefing.sharingURL.path) { try! FileManager.default.removeItem(at: AgentBriefing.sharingURL) }
        try! priorConsent.write(to: AgentBriefing.sharingURL)
        AgentBriefing.simulateRestart()
        check(!AgentBriefing.currentContext(project: projectB).contains("ABOUT THE USER"), "the revoked Project stays off after a restart, even with stale consent")
        try! AgentBriefing.save(p)
        check(!AgentBriefing.currentContext(project: projectB).contains("ABOUT THE USER"), "an unrelated profile save doesn't turn the revoked Project back on")
        try! AgentBriefing.setShared(false, project: projectB)
        check(AgentBriefing.pendingRevocations().isEmpty, "a successful switch settles the pending revocation")
        try! AgentBriefing.setShared(true, project: projectB)
        check(AgentBriefing.currentContext(project: projectB).contains("ABOUT THE USER"), "turning it back on works after that")

        // Folder rejects all writes: revocation is still remembered after a restart
        try! AgentBriefing.save(p); try! AgentBriefing.setShared(true, project: projectA)
        try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temp.path)
        var lockedFailed = false
        do { try AgentBriefing.setShared(false, project: projectA) } catch { lockedFailed = true }
        var lockedSave = false
        var revokedAll = p; revokedAll.shareIntroduction = false; revokedAll.shareStory = false
        do { try AgentBriefing.save(revokedAll) } catch { lockedSave = true }
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)
        AgentBriefing.simulateRestart()
        check(lockedFailed && lockedSave, "a locked folder makes both revocations fail")
        check(!AgentBriefing.currentContext(project: projectA).contains("ABOUT THE USER"), "after a restart, a revocation that couldn't be saved in the locked folder still holds")
        try! AgentBriefing.save(p)
        check(!AgentBriefing.currentContext(project: projectA).contains("ABOUT THE USER"), "the Project stays off until its own switch saves")
        try! AgentBriefing.setShared(false, project: projectA); try! AgentBriefing.setShared(true, project: projectA)
        check(AgentBriefing.currentContext(project: projectA).contains("ABOUT THE USER"), "sharing works again once the folder is writable and the switch saves")

        // Same locked-folder case with the preferences backup unavailable: the side file alone holds
        AgentBriefing.usePreferencesBackstop = false
        let projectC = UUID()
        try! AgentBriefing.save(p); try! AgentBriefing.setShared(true, project: projectC)
        try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temp.path)
        var sideFailed = false
        do { try AgentBriefing.setShared(false, project: projectC) } catch { sideFailed = true }
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)
        AgentBriefing.simulateRestart()
        check(sideFailed && FileManager.default.fileExists(atPath: AgentBriefing.sideURL.path), "without preferences, the side file records the failed revocation")
        check(!AgentBriefing.currentContext(project: projectC).contains("ABOUT THE USER"), "without preferences, the revocation still holds after a restart")
        try! AgentBriefing.save(p)
        check(!AgentBriefing.currentContext(project: projectC).contains("ABOUT THE USER"), "without preferences, a good profile save alone doesn't re-share the revoked Project")
        try! AgentBriefing.setShared(false, project: projectC)
        check(!FileManager.default.fileExists(atPath: AgentBriefing.sideURL.path), "the side file is cleaned up once everything is settled")
        AgentBriefing.usePreferencesBackstop = true

        // Web parity
        check(UserProfile.groups.map(\.title) == ["Your introduction", "Your story", "What you know", "Working together", "Your rhythm"], "same sections as the web page")
        check(UserProfile.groups.flatMap(\.fields).count == 13, "same 13 fields as the web page")
        check(p.totalCharacters == "Jason".count + "Founder of Silkwire.".count + "Army satellite communications.".count + "America/Chicago".count, "total counts every field")

        // Emoji-heavy profiles: counted like the web page and never shortened when within limits
        var emoji = UserProfile(); emoji.shareIntroduction = true; emoji.shareStory = true; emoji.shareKnowledge = true; emoji.shareWorkingTogether = true; emoji.shareRhythm = true
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        for field in UserProfile.groups.flatMap(\.fields) {
            let room = max(0, min(field.limit, UserProfile.totalLimit - emoji.totalCharacters))
            emoji[keyPath: field.key] = ContextBudget.clipUTF16(String(repeating: family, count: 300), to: room)
        }
        check(emoji.totalCharacters <= UserProfile.totalLimit && emoji.totalCharacters > UserProfile.totalLimit - 20, "an emoji profile can fill the limit")
        check(UserProfile.length("\u{1F600}") == 2, "an emoji counts as 2, like the web page")
        let emojiSent = AgentBriefing.compose(userMarkdown: emoji.markdown(), brief: nil)
        check(emojiSent.hasSuffix(emoji.markdown()), "a full emoji profile reaches agents unshortened, matching the preview")
        check(ContextBudget.clipUTF16(family + family, to: 9) == family, "field limits never split an emoji")
        var tooBig = emoji; tooBig.about = String(repeating: family, count: 1500); tooBig.background = "END_MARK"
        let tooBigSent = AgentBriefing.compose(userMarkdown: tooBig.markdown(), brief: nil)
        check(!tooBigSent.contains("END_MARK") && tooBigSent.contains("left out because"), "an over-limit profile is left out with a note, never silently cut")

        // Team brief + provenance
        let brief = AgentBriefing.defaultBrief
        check(brief.contains("Read your teammates' replies") && brief.contains("PASS"), "the team brief carries the read-teammates-first rule")
        check(brief.contains("NEW folder") && brief.contains("Always ask Jason first"), "the team brief carries the build-folder rule and ask-first list")
        let context = AgentBriefing.compose(userMarkdown: p.markdown(), brief: brief)
        check(context.hasPrefix("TEAM BRIEF"), "agents read the team brief first")
        check(context.contains("not yet edited by Jason"), "the default brief is labeled as an agent draft")
        check(AgentBriefing.compose(userMarkdown: nil, brief: brief + "\n- Jason's own rule.").contains("edited on this Mac"), "an edited brief is labeled as edited")
        check(context.contains("ABOUT THE USER") && context.contains("never permission"), "agents read USER.md as context, never permission")
        check(AgentBriefing.compose(userMarkdown: nil, brief: String(repeating: "x", count: 50_000)).utf16.count < 9_000, "an oversized brief is clipped")

        // Scroll: first reply stops at the top of the view
        check(TranscriptFlow.firstReplyScroll(replyHeight: 200, viewport: 700, startAtTop: true) == .bottom, "a short reply is shown whole without passing its top")
        check(TranscriptFlow.firstReplyScroll(replyHeight: 1400, viewport: 700, startAtTop: true) == .top, "a tall reply stops with its top at the top of the view")
        check(TranscriptFlow.firstReplyScroll(replyHeight: 1400, viewport: 700, startAtTop: false) == .bottom, "the setting off keeps the old follow")
        check(TranscriptFlow.firstReplyScroll(replyHeight: nil, viewport: 700, startAtTop: true) == .bottom, "unknown height falls back safely")
        check(TranscriptFlow.revealDuration >= 0.4 && TranscriptFlow.revealDuration <= 0.6, "the reveal is a little slower than before")

        print(failures == 0 ? "PASS: AboutYouTests all checks" : "FAIL: \(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
