import SwiftUI

/// One teammate's background job: who, what, state, elapsed time, Stop, and the
/// verification-only Release when the host says the work may still be running.
/// It shows only what the host last reported, never a guessed "done".
struct BackgroundJobCardView: View {
    let card: BackgroundJobCard
    var stop: () -> Void
    var release: () -> Void
    var hide: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(names[card.agent] ?? card.agent) · \(card.title)").font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(card.stateLabel).font(.caption).foregroundStyle(attention ? Color.orange : Color.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text((card.phase == .queued ? "waiting " : "") + ComputerTaskRow.elapsed(card.elapsed(at: context.date))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                if let hold = card.physicalHold { Text("May still be running · " + hold).font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled) }
                if let note = card.releaseNote { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
                if let error = card.stopError { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            }
            Spacer(minLength: 4)
            if card.mayStop || card.stopRequested && !card.isEnded {
                Button("Stop", action: stop).buttonStyle(SoftAccentButtonStyle(small: true)).tint(.purple).disabled(!card.mayStop)
                    .help(card.stopRequested ? "Stop requested. The card says Stopped once the work host records that the work ended." : "Stop this job. The rest of the room keeps going.")
            } else if card.physicalHold != nil {
                Button(card.releasing ? "Checking…" : "Release", action: release).buttonStyle(SoftAccentButtonStyle(small: true)).tint(.purple).disabled(!card.mayRelease)
                    .help("Ask the work host to verify that this work really ended. If it can't prove that, the slot stays held and the card says why.")
            } else if card.isEnded && !card.holdsWorkspace {
                Button("Hide", action: hide).buttonStyle(.borderless).font(.caption).help("Hide this card. Any result stays in the conversation.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(names[card.agent] ?? card.agent)'s background job, \(card.title), \(card.stateLabel)")
    }
    private var detail: String? {
        // The command bridge's plain refusal says more than the host's generic review note.
        let line = card.isEnded ? (card.refusal ?? card.note) : card.phase == .queued ? (card.waiting ?? card.progress) : card.progress
        return line.isEmpty ? nil : line
    }
    private var attention: Bool { [.failed, .needsReview, .notAccepted, .unknown].contains(card.phase) && !(card.phase == .failed && card.stopRequested) }
    private var dot: Color {
        if card.physicalHold != nil || card.stopRequested && !card.isEnded { return .orange }
        switch card.phase {
        case .submitting, .queued: return .secondary
        case .running, .stopping: return .purple
        case .completed: return .green
        case .failed: return card.stopRequested ? .secondary : .orange
        case .needsReview, .notAccepted, .unknown: return .orange
        }
    }
}

/// Above the composer, so Stop and Release stay in reach while the room keeps talking.
/// Hidden when this conversation has no visible job cards.
struct BackgroundJobStrip: View {
    @ObservedObject var store: ConversationStore
    var body: some View {
        let cards = store.visibleBackgroundJobs
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cards.suffix(4)) { card in
                    BackgroundJobCardView(card: card, stop: { store.stopBackgroundJob(card.id) }, release: { store.releaseBackgroundJob(card.id) }, hide: { store.hideBackgroundJob(card.id) })
                }
                if cards.count > 4 { Text("\(cards.count - 4) earlier job\(cards.count == 5 ? "" : "s") not shown").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(10)
            .background(SilkwireTheme.wash(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SilkwireTheme.line))
        }
    }
}
