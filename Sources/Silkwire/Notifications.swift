import AppKit
import UserNotifications

@MainActor final class CompletionNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var permission = "Background alerts have not been enabled."
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    override init() { super.init() }
    func refresh() {
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in Task { @MainActor in
            switch settings.authorizationStatus {
            case .authorized, .provisional: self?.permission = "Background alerts follow your macOS notification and Focus settings."
            case .denied: self?.permission = "Background alerts are off in macOS. In-app chimes still work."
            default: self?.permission = "Enable background alerts to hear completion sounds when Silkwire is not active."
            }
        }}
    }
    func enableBackgroundAlerts() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
    }
    func completed(title: String, enabled: Bool) {
        guard enabled else { return }
        // Jason's four-note chirp (the web app's signature sound), in front or in the
        // background, so a finished turn is audible when he's away from the screen.
        BuilderChimePlayer.shared.play(isolated: false, whenInactive: true)
        if !NSApplication.shared.isActive {
            Task { @MainActor in
                let settings = await center.notificationSettings()
                guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
                let content = UNMutableNotificationContent()
                content.title = "Replies ready"
                content.body = "Your Silkwire team has finished replying."
                content.sound = nil // the chirp already played; no second, plainer tone
                // No conversation content in a lock-screen notification.
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }
}
