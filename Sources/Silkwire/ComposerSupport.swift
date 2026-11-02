import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    var enabled: Bool
    var textCompletion = true
    var automaticCorrection = false
    var focusRequest: UUID? = nil
    var addURLs: ([URL]) -> Void
    var addImage: (NSImage) -> Void
    var send: () -> Void
    /// Typing performance: when set, keystrokes stay inside the text field and are
    /// committed to the conversation (`owner`) after a short pause, on Send, or when
    /// switching conversations, instead of redrawing the whole window on every key.
    var owner: UUID? = nil
    var commitDraft: ((String, UUID) -> Void)? = nil
    var onTyping: (() -> Void)? = nil
    var registerFlush: (((() -> Void)?) -> Void)? = nil
    /// Called when this writing space is clicked (a second column becomes the main one).
    var onActivate: (() -> Void)? = nil
    static let commitDelay: TimeInterval = 0.15
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let field = AttachmentTextView(); field.delegate = context.coordinator
        field.isRichText = false; field.drawsBackground = false; field.textColor = SilkwireTheme.inkNSColor
        field.font = SilkwireReadingType.nsBody(14); field.textContainerInset = NSSize(width: 10, height: 12)
        field.isContinuousSpellCheckingEnabled = true; field.isGrammarCheckingEnabled = true
        field.isAutomaticSpellingCorrectionEnabled = false; field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false; field.isAutomaticTextReplacementEnabled = false
        field.isVerticallyResizable = true; field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]; field.textContainer?.widthTracksTextView = true
        field.setAccessibilityLabel("Message your team")
        field.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = field
        updateNSView(scroll, context: context); return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let previousOwner = context.coordinator.parent.owner
        context.coordinator.parent = self
        guard let field = scroll.documentView as? AttachmentTextView else { return }
        field.identifier = NSUserInterfaceItemIdentifier("silkwire-composer-" + (owner?.uuidString ?? "main"))
        if previousOwner != owner, let typed = context.coordinator.takePending() {
            // Conversation changed with typing not yet committed: it belongs to the old one.
            let commit = commitDraft
            DispatchQueue.main.async { commit?(typed.text, typed.owner) }
        }
        if !context.coordinator.registered, let registerFlush {
            context.coordinator.registered = true
            let coordinator = context.coordinator
            DispatchQueue.main.async { registerFlush({ [weak coordinator] in coordinator?.commitNow() }) }
        }
        context.coordinator.synchronizeText(in: field)
        if field.isAutomaticTextCompletionEnabled != textCompletion { field.isAutomaticTextCompletionEnabled = textCompletion }
        let prediction: NSTextInputTraitType = textCompletion ? .yes : .no
        if field.inlinePredictionType != prediction { field.inlinePredictionType = prediction }
        if field.isAutomaticSpellingCorrectionEnabled != automaticCorrection { field.isAutomaticSpellingCorrectionEnabled = automaticCorrection }
        if let focusRequest, context.coordinator.lastFocus != focusRequest { context.coordinator.lastFocus = focusRequest; field.requestComposerFocus() }
        if field.isEditable != enabled { field.isEditable = enabled }; field.addURLs = addURLs; field.addImage = addImage; field.send = send; field.onActivate = onActivate
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        var lastFocus: UUID?
        var registered = false
        private var lastModelText: String?
        /// Typed text not yet written to the conversation, and which conversation it's for.
        private(set) var pending: (text: String, owner: UUID)?
        private var commitWork: DispatchWorkItem?
        init(_ parent: NativeComposer) { self.parent = parent }
        func takePending() -> (text: String, owner: UUID)? {
            commitWork?.cancel(); commitWork = nil
            defer { pending = nil }
            return pending
        }
        func commitNow() {
            guard let typed = takePending() else { return }
            lastModelText = typed.text
            parent.commitDraft?(typed.text, typed.owner)
        }
        func synchronizeText(in field: NSTextView) {
            // While typing is uncommitted, the field is the source of truth.
            guard pending == nil else { return }
            let requested = parent.text
            // AppKit owns provisional prediction/IME text. A reply/timer render
            // must not treat that temporary difference as a new external draft.
            guard lastModelText != requested, !field.hasMarkedText() else { return }
            lastModelText = requested
            guard field.string != requested else { return }
            let selection = field.selectedRanges.map(\.rangeValue)
            field.string = requested
            let count = (requested as NSString).length
            field.selectedRanges = selection.map { range in
                let location = min(range.location, count)
                return NSValue(range: NSRange(location: location, length: min(range.length, count - location)))
            }
        }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView {
                lastModelText = view.string
                guard let owner = parent.owner, parent.commitDraft != nil else { parent.text = view.string; return }
                pending = (view.string, owner)
                parent.onTyping?()
                commitWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.commitNow() }
                commitWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NativeComposer.commitDelay, execute: work)
            }
        }
    }
}
protocol NativeTextPasteboard {
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType: NSPasteboard.PasteboardType) -> Bool
}
protocol NativeAttachmentPasteboard: NativeTextPasteboard {
    func availableType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType?
    var attachmentURLs: [URL] { get }
    var attachmentImage: NSImage? { get }
}
extension NSPasteboard: NativeAttachmentPasteboard {
    var attachmentURLs: [URL] { readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [] }
    var attachmentImage: NSImage? { NSImage(pasteboard: self) }
}
final class AttachmentTextView: NSTextView {
    var attachmentPasteboard: any NativeAttachmentPasteboard = NSPasteboard.general
    private var pendingComposerFocus = false
    func requestComposerFocus() { pendingComposerFocus = true; applyComposerFocus() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyComposerFocus() }
    private func applyComposerFocus() { if let window, pendingComposerFocus, window.makeFirstResponder(self) { pendingComposerFocus = false } }
    var addURLs: (([URL]) -> Void)?
    var addImage: ((NSImage) -> Void)?
    var send: (() -> Void)?
    var onActivate: (() -> Void)?
    // Only a real click activates (never keyboard focus at launch), so a second
    // column can't take over the window by itself.
    override func mouseDown(with event: NSEvent) { onActivate?(); super.mouseDown(with: event) }
    // NSTextView's plain-text Paste validation otherwise rejects image-only clipboard data
    // before our paste override is called. Advertise formats and accept them in the responder chain.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.fileURL, .png, .tiff] + super.readablePasteboardTypes }
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        consume(pasteboard) || super.readSelection(from: pasteboard, type: type)
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if [#selector(paste(_:)), #selector(pasteAsPlainText(_:))].contains(item.action), isEditable, attachmentPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil { return true }
        return super.validateUserInterfaceItem(item)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command, event.charactersIgnoringModifiers?.lowercased() == "v", consume(attachmentPasteboard) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { send?(); return }
        super.keyDown(with: event)
    }
    func consume(_ pasteboard: any NativeAttachmentPasteboard) -> Bool {
        guard isEditable else { return false }
        let urls = pasteboard.attachmentURLs
        if !urls.isEmpty { addURLs?(urls); return true }
        if pasteboard.availableType(from: [.png, .tiff]) != nil, let image = pasteboard.attachmentImage { addImage?(image); return true }
        return false
    }
    override func pasteAsPlainText(_ sender: Any?) { if !consume(attachmentPasteboard) { super.pasteAsPlainText(sender) } }
    override func paste(_ sender: Any?) { if !consume(attachmentPasteboard) { super.paste(sender) } }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil ? .copy : super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { consume(sender.draggingPasteboard) || super.performDragOperation(sender) }
}
private enum AttachmentImages {
    static let cache = NSCache<NSUUID, NSImage>()
    static func image(_ attachment: Attachment) -> NSImage? {
        if let image = cache.object(forKey: attachment.id as NSUUID) { return image }
        guard let image = NSImage(data: attachment.data) else { return nil }
        cache.setObject(image, forKey: attachment.id as NSUUID, cost: max(attachment.data.count, Int(image.size.width * image.size.height * 4))); cache.totalCostLimit = 32 * 1024 * 1024
        return image
    }
}
struct AttachmentPreview: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.attachment.id == rhs.attachment.id && (lhs.remove == nil) == (rhs.remove == nil) }
    let attachment: Attachment
    var remove: (() -> Void)? = nil
    var body: some View {
        if attachment.isImage, let image = AttachmentImages.image(attachment) {
            // Images show as just the picture with a thin outline (Jason); the repeated
            // label is gone, but the name stays on hover and for VoiceOver.
            Image(nsImage: image).resizable().scaledToFill().frame(width: 56, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if let remove {
                        Button(action: remove) { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.65)) }
                            .buttonStyle(.plain).offset(x: 5, y: -5).accessibilityLabel("Remove \(attachment.name)")
                    }
                }
                .padding(.top, remove == nil ? 0 : 5).padding(.trailing, remove == nil ? 0 : 5)
                .help(attachment.name).accessibilityElement(children: .contain).accessibilityLabel("Image: \(attachment.name)")
        } else {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(SilkwireTheme.accent)
                Text(attachment.name).lineLimit(1)
                if let remove { Button(action: remove) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Remove \(attachment.name)") }
            }.font(.caption).padding(.horizontal, 8).padding(.vertical, 6).background(SilkwireTheme.wash(0.04), in: RoundedRectangle(cornerRadius: 7))
            .help("Text file: " + attachment.name)
        }
    }
}
final class PassThroughView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
struct ScrollIntentObserver: NSViewRepresentable {
    var pause: () -> Void
    func makeNSView(context: Context) -> NSView { let view = PassThroughView(); context.coordinator.view = view; return view }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.pause = pause }
    func makeCoordinator() -> Coordinator { Coordinator(pause) }
    class Coordinator {
        weak var view: NSView?
        var pause: () -> Void
        var monitor: Any?
        init(_ pause: @escaping () -> Void) {
            self.pause = pause
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                guard let self, let view = self.view, event.window == view.window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(point), event.type == .scrollWheel, event.scrollingDeltaY > 0 { self.pause() }
                if event.type == .keyDown, [116, 115, 126].contains(Int(event.keyCode)), view.window?.firstResponder is NSTextView == false { self.pause() }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
struct SearchHit: Identifiable {
    var messageID: UUID
    var line: Int
    var range: NSRange
    var id: String { "\(messageID)-\(line)-\(range.location)" }
    var anchor: String { "\(messageID)-line-\(line)" }
    static func find(in messages: [Message], query: String) -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        return messages.flatMap { message in message.text.components(separatedBy: "\n").enumerated().flatMap { line, text in
            ranges(text, query).map { SearchHit(messageID: message.id, line: line, range: $0) }
        } }
    }
    static func ranges(_ text: String, _ query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let value = text as NSString; var cursor = 0; var result: [NSRange] = []
        while cursor < value.length {
            let range = value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: cursor, length: value.length - cursor))
            if range.location == NSNotFound { break }; result.append(range); cursor = range.location + max(1, range.length)
        }
        return result
    }
}
struct SearchMessage: View {
    let message: Message
    let query: String
    var selected: SearchHit?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(message.text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                Text(highlight(line, index)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id("\(message.id)-line-\(index)")
            }
        }
    }
    private func highlight(_ text: String, _ line: Int) -> AttributedString {
        let value = NSMutableAttributedString(string: text)
        for range in SearchHit.ranges(text, query) {
            let current = selected?.messageID == message.id && selected?.line == line && selected?.range == range
            value.addAttributes([.backgroundColor: current ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.6), .foregroundColor: NSColor.black], range: range)
        }
        return AttributedString(value)
    }
}

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { apply(view) }; return view }
    func updateNSView(_ view: NSView, context: Context) { DispatchQueue.main.async { apply(view) } }
    private func apply(_ view: NSView) {
        guard let window = view.window else { return }
        window.titlebarAppearsTransparent = true; window.backgroundColor = SilkwireTheme.windowNSColor
        window.titleVisibility = .hidden; window.toolbarStyle = .unifiedCompact
        window.appearance = nil  // follows the chosen theme (Midnight, Parchment or Match System)
    }
}

struct InspectionImagePreview: View {
    let attachment: Attachment
    @State private var expanded = false
    var body: some View {
        if let image = AttachmentImages.image(attachment) {
            Button { expanded = true } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 640, maxHeight: 360)
                    Label("Open inspection image", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption)
                }
            }.buttonStyle(.plain).accessibilityLabel("Open web inspection image")
            .sheet(isPresented: $expanded) {
                VStack { HStack { Text(attachment.name).font(.caption); Spacer(); Button("Done") { expanded = false }.keyboardShortcut(.cancelAction) }
                    Image(nsImage: image).resizable().scaledToFit()
                }.padding().frame(minWidth: 640, idealWidth: 1100, minHeight: 480, idealHeight: 800)
            }
        } else { Text("The inspection image could not be decoded.").foregroundStyle(.secondary) }
    }
}

struct TranscriptFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { _, new in new } }
}
// Observe this transcript's window only. Retain the logical reading anchor before
// SwiftUI reflows variable-height rows, then restore it after the new layout.
struct TranscriptResizeObserver: NSViewRepresentable {
    var resized: () -> Void
    func makeNSView(context: Context) -> NSView { let view = PassThroughView(); context.coordinator.view = view; return view }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.resized = resized }
    func makeCoordinator() -> Coordinator { Coordinator(resized) }
    class Coordinator {
        weak var view: NSView?
        var resized: () -> Void
        var observation: NSObjectProtocol?
        init(_ resized: @escaping () -> Void) {
            self.resized = resized
            observation = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.view?.window else { return }
                self.resized()
            }
        }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
