import AppKit
import SwiftUI

/// The top banner ("Claude is driving · move the mouse to take over · Stop") and
/// the visible agent pointer. Both float over every app and Space, never take
/// focus, and are kept out of the agents' screenshots.
@MainActor final class DrivingOverlay {
    private weak var center: ComputerControlCenter?
    private let banner: NSPanel
    private let pointer: NSPanel
    private var hidden = false
    var windowNumbers: [Int] { [banner.windowNumber, pointer.windowNumber] }

    init(center: ComputerControlCenter) {
        self.center = center
        func panel(_ size: NSSize) -> NSPanel {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .statusBar; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.sharingType = .none
            return panel
        }
        banner = panel(NSSize(width: 760, height: 120))
        banner.becomesKeyOnlyIfNeeded = true
        banner.contentView = NSHostingView(rootView: DriveBannerView(center: center))
        pointer = panel(NSSize(width: 150, height: 44))
        pointer.level = .screenSaver; pointer.ignoresMouseEvents = true
        pointer.contentView = NSHostingView(rootView: AgentPointerView(center: center))
    }
    func setHidden(_ value: Bool) { hidden = value; update() }
    func update() {
        guard let center else { return }
        let showBanner = !hidden && (center.wheel != .none || !center.pending.isEmpty)
        if showBanner {
            if let screen = NSScreen.screens.first {
                let size = banner.contentView?.fittingSize ?? NSSize(width: 760, height: 60)
                let width = min(max(size.width, 360), screen.visibleFrame.width - 40)
                banner.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.maxY - size.height - 8, width: width, height: size.height), display: true)
            }
            banner.orderFrontRegardless()
        } else { banner.orderOut(nil) }
        // The pointer marks where the driving teammate last put the mouse.
        if !hidden, case .driving = center.wheel, let point = center.pointer, let screen = NSScreen.screens.first {
            pointer.setFrameOrigin(NSPoint(x: point.x - 2, y: screen.frame.maxY - point.y - pointer.frame.height + 2))
            pointer.orderFrontRegardless()
        } else { pointer.orderOut(nil) }
    }
    func close() { banner.orderOut(nil); pointer.orderOut(nil); banner.close(); pointer.close() }
}

struct DriveBannerView: View {
    @ObservedObject var center: ComputerControlCenter
    private func name(_ agent: String) -> String { names[agent] ?? agent }
    var body: some View {
        VStack(spacing: 6) {
            if center.wheel != .none { wheelRow }
            ForEach(center.pending) { approval in
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(name(approval.agent)) asks first: \(approval.summary)").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(approval.ruleTitle + " · " + approval.reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("Deny") { center.resolve(approval.id, allow: false) }
                    Button("Allow once") { center.resolve(approval.id, allow: true) }.buttonStyle(.borderedProminent).tint(.orange)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minWidth: 360, maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.purple.opacity(0.55), lineWidth: 1.5))
        .padding(4)
        .fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var wheelRow: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.purple).frame(width: 9, height: 9)
            switch center.wheel {
            case .driving(let agent):
                Text("\(name(agent)) is driving · move the mouse to take over").font(.system(size: 13, weight: .semibold))
            case .waiting(let agent, let remaining):
                Text("\(name(agent)) wants to drive · starts when you're idle \(remaining) s").font(.system(size: 13, weight: .semibold))
            case .paused(let agent, let remaining):
                Text("You have the wheel · \(name(agent)) resumes after \(remaining) s idle").font(.system(size: 13, weight: .semibold))
            case .none: EmptyView()
            }
            if !center.queue.isEmpty { Text("· next: " + center.queue.map(name).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            if case .driving = center.wheel {} else { Button("Let them drive") { center.letThemDrive() } }
            Button("Stop") { center.stopDriving() }.buttonStyle(.borderedProminent).tint(.red)
        }
    }
}

struct AgentPointerView: View {
    @ObservedObject var center: ComputerControlCenter
    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            Image(systemName: "cursorarrow").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.purple).shadow(color: .white, radius: 1)
            Text(center.wheel.agent.flatMap { names[$0] } ?? "Agent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.purple, in: Capsule()).padding(.top, 14)
        }.frame(width: 150, height: 44, alignment: .topLeading)
    }
}
