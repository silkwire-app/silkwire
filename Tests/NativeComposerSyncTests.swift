import Foundation
import AppKit
import SwiftUI

@MainActor final class ComposerSyncModel: ObservableObject {
    @Published var text = "The telescope"
    @Published var ticks = 0
}
private struct ComposerSyncHost: View {
    @ObservedObject var model: ComposerSyncModel
    var body: some View {
        let tick = model.ticks
        return VStack {
            Text("Reply timer: \(model.ticks)")
            NativeComposer(text: $model.text, enabled: true, textCompletion: true,
                           addURLs: { _ in }, addImage: { _ in }, send: { model.ticks = tick })
        }.frame(width: 600, height: 150)
    }
}
@main struct NativeComposerSyncTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let model = ComposerSyncModel()
        let host = NSHostingView(rootView: ComposerSyncHost(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        func field(in view: NSView) -> AttachmentTextView? {
            if let text = view as? AttachmentTextView { return text }
            for child in view.subviews { if let text = field(in: child) { return text } }; return nil
        }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        guard let text = field(in: host) else { throw nativeFailure("Mounted composer missing") }
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw nativeFailure("FAIL: " + label) }; print("PASS: " + label)
        }
        try check(text.string == model.text && text.inlinePredictionType == .yes && text.isAutomaticTextCompletionEnabled, "mounted composer initializes with predictions enabled")
        // Model an AppKit-owned provisional suffix without committing it to the
        // binding. This does NOT claim an OS-generated inline suggestion.
        text.string = "The telescope will"; text.setSelectedRange(NSRange(location: 13, length: 0))
        for tick in 1...12 { model.ticks = tick; try await Task.sleep(for: .milliseconds(15)) }
        try check(text.string == "The telescope will" && text.selectedRange().location == 13 && model.text == "The telescope", "unrelated mounted SwiftUI reply/timer updates leave provisional native text and cursor untouched")
        text.setMarkedText("星", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        let marked = text.string, markedRange = text.markedRange()
        try check(!text.isAutomaticQuoteSubstitutionEnabled && !text.isAutomaticDashSubstitutionEnabled && !text.isAutomaticTextReplacementEnabled, "literal quotes, dashes and code text avoid automatic substitutions")
        model.ticks += 1; try await Task.sleep(for: .milliseconds(100))
        try check(text.hasMarkedText() && text.string == marked && text.markedRange() == markedRange, "mounted marked-text composition survives unrelated rendering")
        text.unmarkText()
        model.text = "A shorter draft"; try await Task.sleep(for: .milliseconds(100))
        try check(text.string == model.text, "external restored draft is applied")
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertText("!", replacementRange: text.selectedRange()); try await Task.sleep(for: .milliseconds(100))
        try check(model.text == "A shorter draft!" && text.string == model.text, "native committed edit synchronizes the binding")
        model.text = ""; try await Task.sleep(for: .milliseconds(100))
        try check(text.string.isEmpty && text.selectedRange().location == 0, "external send clear safely clamps the caret")
        print("PASS: mounted model/native text ownership; actual macOS-generated suggestion and Space acceptance not exercised")
    }
}
