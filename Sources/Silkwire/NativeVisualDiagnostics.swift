import SwiftUI
import AppKit

#if SILKWIRE_TESTING
@MainActor enum TranscriptDiagnosticLifetime {
    static var mounts = 0
    static var anchor: UUID?
}
private struct TranscriptLifetimeProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TranscriptDiagnosticLifetime.mounts += 1; return NSView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
@MainActor func recordDiagnosticTranscriptAnchor(_ id: UUID?) {
    #if SILKWIRE_TESTING
    TranscriptDiagnosticLifetime.anchor = id
    #endif
}
extension View {
    @ViewBuilder func transcriptDiagnosticProbe() -> some View {
        #if SILKWIRE_TESTING
        background(TranscriptLifetimeProbe().frame(width: 0, height: 0))
        #else
        self
        #endif
    }
}

#if SILKWIRE_TESTING
@MainActor enum NativeVisualDiagnostics {
    static let tableFixture = """
    ## Resize and Markdown fixture

    | Area | Outcome |
    | :--- | :--- |
    | Two columns | Long text must wrap inside the row, use the available width, and stay readable at every supported window size. |
    | Short | A small value |

    ---

    | Task | Owner | Evidence |
    | --- | --- | --- |
    | Layout | Eve | Multiple lines of long text exercise all three columns and continuous backgrounds. |
    | Build | Claude | `--literal` and **formatted** text |

    ```swift
    let value = "-- 'quotes' \\path $() `ticks` | pipe"
    ```
    """
    static func resize(store: ConversationStore) async -> [[String: Any]] {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        store.preferencesForVisualDiagnostics()
        store.conversation.messages = (0..<18).map { index in Message(author: index.isMultiple(of: 2) ? "Eve" : "Codex", text: "Fixture \(index)\n\n" + tableFixture, state: "completed") }
        store.conversation.draft = "Synthetic resize draft -- exact characters"
        let originalIDs = store.conversation.messages.map(\.id), originalText = store.conversation.messages.map(\.text)
        UserDefaults.standard.set(true, forKey: "composer.sidePanel")
        try? await Task.sleep(for: .milliseconds(700))
        guard let window = NSApp.windows.first(where: { $0.title.contains("Silkwire") && $0.contentView != nil }) else { record("native resize window available", false); return checks }
        func transcriptScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, (scroll.documentView?.bounds.height ?? 0) > 5000 { return scroll }
            for child in view.subviews { if let found = transcriptScroll(child) { return found } }
            return nil
        }
        if let view = window.contentView, let scroll = transcriptScroll(view), let document = scroll.documentView {
            let y = min(5000, max(0, document.bounds.height - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(for: .milliseconds(400))
        }
        let initialAnchor = TranscriptDiagnosticLifetime.anchor
        record("paused transcript has a measured visible message anchor", initialAnchor != nil)
        let mounts = TranscriptDiagnosticLifetime.mounts
        record("transcript identity probe mounted", mounts > 0)
        for (index, width) in [1280.0, 1020, 840, 1440, 900, 1280].enumerated() {
            window.setContentSize(NSSize(width: width, height: 900))
            try? await Task.sleep(for: .milliseconds(400))
            record("resize \(index) preserves transcript identity", TranscriptDiagnosticLifetime.mounts == mounts)
            let expectedRow = store.conversation.messages.firstIndex { $0.id == initialAnchor }
            let actualRow = store.conversation.messages.firstIndex { $0.id == TranscriptDiagnosticLifetime.anchor }
            record("resize \(index) preserves paused message anchor (expected \(expectedRow.map(String.init) ?? "none"), actual \(actualRow.map(String.init) ?? "none"))", initialAnchor != nil && TranscriptDiagnosticLifetime.anchor == initialAnchor)
            record("resize \(index) preserves source text and draft", store.conversation.messages.map(\.id) == originalIDs && store.conversation.messages.map(\.text) == originalText && store.conversation.draft == "Synthetic resize draft -- exact characters")
            if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    do { try png.write(to: store.directory.appendingPathComponent("resize-\(index)-\(Int(width)).png")); record("resize \(index) native capture saved (requires visual review)", true) }
                    catch { record("resize \(index) native capture saved", false) }
                }
            }
        }
        // Captures still need human visual inspection; the anchor checks cover
        // logical message position rather than an identical pixel within its text.

        return checks
    }
}
#endif
