import Foundation

/// Navigation and source-wiring regression checks for the Settings foundation.
/// These are not GUI automation or tests of an implemented vault connector.
@main struct MemorySettingsTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
            print("PASS: \(message)")
        }
        let sections = AppSettingsSection.allCases
        check(sections.map(\.rawValue) == ["general", "appearance", "agents", "projects", "memory", "development"], "six stable Settings destinations in the agreed order")
        check(Set(sections.map(\.id)).count == sections.count, "unique navigation identifiers")
        check(sections.map(\.title) == ["General", "Appearance", "Agents", "Projects", "Memory", "Development"], "human-readable tab labels")
        check(sections.allSatisfy { !$0.symbol.isEmpty }, "every destination has an icon")
        check(AppSettingsSection(rawValue: "vault-access-granted") == nil, "navigation has no grant state")

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/Silkwire/MemorySettings.swift"), encoding: .utf8)
        let panels = try String(contentsOf: root.appendingPathComponent("Sources/Silkwire/WorkspacePanels.swift"), encoding: .utf8)
        check(panels.contains("UnifiedSettingsView(store: store, notifications: notifications)"), "existing Settings scene routes to the new view")
        check(settings.contains("TabView(selection: $selected)") && settings.contains("ForEach(AppSettingsSection.allCases)"), "all six sections are rendered by the tab view")
        check(settings.contains("@AppStorage(\"composer.sidePanel\")") && settings.contains("@AppStorage(\"composer.sideHeight\")"), "existing composer preference keys are retained")
        for setter in ["setChime", "setAutoScroll", "setTextCompletion", "setAutomaticCorrection", "setReduceMotion"] {
            check(settings.contains("store.\(setter)($0)"), "existing \(setter) binding is retained")
        }
        check(settings.contains("notifications.enableBackgroundAlerts()") && settings.contains("notifications.refresh()"), "notification controls and status refresh are retained")
        check(settings.contains("ConnectionsView(store: store)") && settings.contains("ProjectEditor(project: project, isNew: false, store: store)"), "Settings reuses existing connection and Project editors")
        check(settings.contains(".disabled(!store.canChangeConversation || store.storageError != nil)"), "Project editing keeps conversation and storage guards")
        check(settings.contains(".disabled(store.storageError != nil)"), "editable preferences remain guarded on storage failure")

        let memory = String(settings.components(separatedBy: "struct MemorySettingsView: View {").last ?? "")
        check(memory.contains("not available yet") && memory.contains("does not link, search or write"), "Memory availability is explicitly unfinished")
        check(memory.contains("planned choices, not enabled permissions"), "planned access choices cannot masquerade as current grants")
        check(memory.contains("never an instruction or a new grant"), "memory content is not authority")
        for forbidden in ["NSOpenPanel", "bookmarkData(", "startAccessingSecurityScopedResource", "FileManager", "@AppStorage", "UserDefaults", "URLSession", "Button(", "Toggle("] {
            check(!memory.contains(forbidden), "Memory preview has no \(forbidden) operation")
        }
        check(!settings.contains("store.updateProject(") && !settings.contains("store.createProject("), "tab navigation does not mutate Project grants")
        print("PASS: \(checks) Settings navigation and source-wiring checks; no live vault or GUI exercised")
    }
}
