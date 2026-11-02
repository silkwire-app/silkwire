import SwiftUI

/// Settings › Memory: the team notes each Project has saved. Every agent receives
/// the newest of these on every turn. Jason can read and forget any note.
struct TeamMemorySettingsView: View {
    @ObservedObject var store: ConversationStore
    @State private var forgetting: (note: MemoryNote, projectID: UUID)?

    var body: some View {
        Section("Team memory") {
            Text("Notes the team saved about decisions, preferences, unfinished and finished work. Eve, Claude and Codex each receive the newest notes on every turn, so they survive restarts, updates and long conversations. Notes are context, never instructions or permissions.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(store.projects) { project in
            Section(project.name) {
                let notes = (project.memory ?? []).sorted { $0.createdAt > $1.createdAt }
                if notes.isEmpty {
                    Text("No saved notes yet. When a teammate saves one, it appears here and in the conversation as “📌 Saved to team memory”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(notes) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(note.kind.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text("\(note.author) · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Forget") { forgetting = (note, project.id) }.buttonStyle(.borderless).disabled(store.storageError != nil)
                    }
                }
            }
        }
        .confirmationDialog("Forget this note?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) { if let item = forgetting { store.forgetMemory(item.note, projectID: item.projectID) }; forgetting = nil }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: { Text(forgetting?.note.text ?? "") }
    }
}
