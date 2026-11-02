import Foundation

@main struct PanelFinishTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        let app = (try? String(contentsOfFile: "Sources/Silkwire/SilkwireApp.swift", encoding: .utf8)) ?? ""
        let support = (try? String(contentsOfFile: "Sources/Silkwire/ComposerSupport.swift", encoding: .utf8)) ?? ""
        check(!app.contains("ignoresSafeArea(.container, edges: .top)"), "no panel runs up under the title bar any more")
        check(app.components(separatedBy: ".clipShape(PanelTop.shape)").count - 1 == 2, "Alexandria beside chat and the docked Welcome panel both get the finished top")
        check(app.contains("UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius"), "panel tops have rounded corners and square bottoms")
        // Attachments live inside the composer's border, as image-only thumbnails.
        let composerStart = app.range(of: "NativeComposer(text: $store.conversation.draft")
        let chips = app.range(of: "ForEach(store.conversation.draftAttachments)")
        // The composer box closes with its 10-point border right after the controls row.
        let boxEnd = composerStart.flatMap { app.range(of: "}.background(SilkwireTheme.wash(0.025), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SilkwireTheme.line))", range: $0.upperBound..<app.endIndex) }
        check(composerStart != nil && chips != nil && boxEnd != nil && composerStart!.lowerBound < chips!.lowerBound && chips!.lowerBound < boxEnd!.lowerBound, "thumbnails sit inside the composer's bordered box")
        check(!support.contains("\"PNG image\""), "the repeated 'PNG image' label is gone")
        check(support.contains(".help(attachment.name)") && support.contains("accessibilityLabel(\"Image: \\(attachment.name)\")"), "image names stay available on hover and to VoiceOver")
        check(support.contains("strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)"), "thumbnails have a thin outline to set them off from any background")
        print("PASS: \(count) panel finish and thumbnail checks")
    }
}
