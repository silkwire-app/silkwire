import SwiftUI

/// Future: its own slide-out drawer, opened from the rail beneath Alexandria (Jason).
/// North Stars are pinned at the top, then the Future list in priority order, a divider,
/// and Completed. Everything lives in one readable Alexandria page (Shared / Future), so
/// teammates can read it in context and propose edits through UPDATE_FUTURE.
struct FutureDrawer: View {
    @ObservedObject var future: FutureStore
    @ObservedObject var store: ConversationStore
    var openInAlexandria: (UUID) -> Void
    var close: () -> Void
    @State private var expanded: Set<UUID> = []
    @State private var newTitle = ""
    @State private var newNotes = ""
    @State private var addingNotes = false
    @State private var editing: FutureEdit?
    @State private var editingStars = false
    @State private var starsEdit: NorthStarsEdit?
    @AppStorage("future.completedShown") private var completedShown = true
    private var projectID: UUID? { store.activeProject?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = future.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    HStack {
                        Button("Reload saved page") { future.refresh() }
                        if let id = future.currentPageID { Button("Open in Alexandria") { openInAlexandria(id) } }
                    }.font(.caption).buttonStyle(.borderless)
                }.padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
            }
            if let projectID {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        northStars
                        addForm(projectID)
                        sectionLabel("Future", count: future.open.count)
                        if future.open.isEmpty {
                            Text("Nothing queued. Add an idea above, then use the arrows to set its priority.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
                        }
                        ForEach(Array(future.open.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index, count: future.open.count, projectID: projectID)
                        }
                        Divider().padding(.vertical, 6)
                        Button { completedShown.toggle() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: completedShown ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                                sectionLabel("Completed", count: future.done.count)
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityLabel("Completed").accessibilityValue(completedShown ? "Expanded" : "Collapsed")
                        if completedShown {
                            if future.done.isEmpty { Text("Finished items land here.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(Array(future.done.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index, count: future.done.count, projectID: projectID)
                            }
                        }
                    }.padding(14)
                }
            } else {
                Text("Choose a project to see its Future.").foregroundStyle(.secondary).padding(14)
                Spacer()
            }
            if let deleted = future.lastDeleted, let projectID {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text("Deleted “\(deleted.item.title)”").font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Undo") { future.undoDelete(project: projectID) }.keyboardShortcut("z", modifiers: .command)
                    Button { future.dismissUndo() } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss")
                }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .onAppear { future.attach(store); future.migrateLegacyIfNeeded() }
        .onChange(of: store.activeProject?.id) { _, _ in expanded = []; future.attach(store); future.migrateLegacyIfNeeded() }
        .onChange(of: store.libraryPages) { _, _ in future.refresh() }
        .onExitCommand { close() }
        .sheet(item: $editing) { edit in
            FutureEditor(item: edit.item) { updated in future.saveEdit(updated, basedOn: edit) }
        }
        .sheet(isPresented: $editingStars, onDismiss: { starsEdit = nil }) {
            if let edit = starsEdit {
                // The snapshot is fixed when the sheet opens; refreshes and project switches never move it.
                NorthStarsEditor(text: edit.original.isEmpty ? FutureMarkdown.suggestedNorthStars : edit.original) { text in
                    future.saveNorthStars(text, basedOn: edit)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Future", systemImage: "star.circle").font(.headline)
                if let change = future.lastChange {
                    Text("Last changed by \(change.by) · " + Self.relative.localizedString(for: change.at, relativeTo: Date()))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Saved as Shared / Future in Alexandria").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let id = future.currentPageID {
                Button { openInAlexandria(id) } label: { Image(systemName: "building.columns") }
                    .help("Open the Future page in Alexandria").accessibilityLabel("Open in Alexandria")
            }
            Button { close() } label: { Image(systemName: "xmark") }
                .help("Close Future").accessibilityLabel("Close Future")
        }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 12)
    }
    private static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()

    private var northStars: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("North Stars", systemImage: "star.fill").font(.subheadline.weight(.semibold)).foregroundStyle(SilkwireTheme.accent)
                Spacer()
                Button { if let edit = future.beginNorthStarsEdit() { starsEdit = edit; editingStars = true } } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit North Stars").accessibilityLabel("Edit North Stars")
                    .disabled(future.error != nil)
            }
            if let stars = future.northStars, !stars.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(stars.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        if line.trimmingCharacters(in: .whitespaces).isEmpty { Color.clear.frame(height: 2) }
                        else { Text(Self.inline(line)).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    }
                }
            } else {
                Text("The few things every decision should point toward.").font(.callout).foregroundStyle(.secondary)
                Button("Add our North Stars") { if let edit = future.beginNorthStarsEdit() { starsEdit = edit; editingStars = true } }.font(.caption).disabled(future.error != nil)
            }
        }
        .padding(12)
        .background(SilkwireTheme.northStarsFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SilkwireTheme.northStarsEdge, lineWidth: 1))
    }
    /// Inline Markdown only; a leading list dash reads as a bullet.
    static func inline(_ line: String) -> AttributedString {
        var text = line
        if text.hasPrefix("- ") || text.hasPrefix("* ") { text = "• " + text.dropFirst(2) }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func addForm(_ projectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Add to Future…", text: $newTitle).textFieldStyle(.roundedBorder).onSubmit { add(projectID) }
                Button { addingNotes.toggle() } label: { Image(systemName: addingNotes ? "note.text.badge.plus" : "note.text") }
                    .buttonStyle(.borderless).help(addingNotes ? "Hide notes" : "Add notes").accessibilityLabel("Notes for the new item")
                Button { add(projectID) } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless).help("Add to Future").accessibilityLabel("Add to Future")
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || future.error != nil)
            }
            if addingNotes {
                TextEditor(text: $newNotes).font(.callout).frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SilkwireTheme.line, lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if newNotes.isEmpty { Text("Notes (optional)").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 1).allowsHitTesting(false) }
                    }
            }
        }
    }
    private func add(_ projectID: UUID) {
        if future.add(title: newTitle, details: newNotes, project: projectID) { newTitle = ""; newNotes = ""; addingNotes = false }
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
        }
    }

    private func row(_ item: FutureItem, index: Int, count: Int, projectID: UUID) -> some View {
        let isOpen = expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { future.setCompleted(item.id, !item.completed, project: projectID) } label: {
                    Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                }
                .buttonStyle(.plain).foregroundStyle(item.completed ? SilkwireTheme.accent : Color.secondary)
                .help(item.completed ? "Restore to Future" : "Mark done")
                .accessibilityLabel(item.completed ? "Restore " + item.title : "Mark " + item.title + " done")
                Button {
                    if isOpen { expanded.remove(item.id) } else { expanded.insert(item.id) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !item.completed { Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary) }
                        Text(item.title).foregroundStyle(item.completed ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        if !item.details.isEmpty && !isOpen { Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(.tertiary) }
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(item.title).accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                if !item.completed {
                    VStack(spacing: 2) {
                        Button { future.move(item.id, project: projectID, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("Move up").accessibilityLabel("Move " + item.title + " up")
                        Button { future.move(item.id, project: projectID, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == count - 1).help("Move down").accessibilityLabel("Move " + item.title + " down")
                    }.font(.system(size: 9, weight: .semibold)).buttonStyle(.borderless)
                }
            }
            if isOpen {
                Text(item.details.isEmpty ? "No notes yet." : item.details).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.leading, 23)
                HStack {
                    Button("Edit") { editing = future.beginEdit(item) }
                    Spacer()
                    Button(role: .destructive) { expanded.remove(item.id); future.delete(item.id, project: projectID) } label: { Label("Delete", systemImage: "trash") }
                        .foregroundStyle(.red)
                }.font(.caption).buttonStyle(.borderless).padding(.leading, 23)
            }
        }
        .padding(10)
        .background(SilkwireTheme.tile(item.completed ? 0.025 : 0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SilkwireTheme.midnightEdge, lineWidth: 1))
    }
}

private struct FutureEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: FutureItem
    let save: (FutureItem) -> Bool
    @State private var saveFailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Future item").font(.headline)
            TextField("Title", text: $item.title)
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $item.details).frame(minHeight: 160)
            if saveFailed { Text("Not saved. Your text is still here. Copy it before closing, then reload the saved page to resolve the problem.").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines); if save(item) { dismiss() } else { saveFailed = true } }
                    .keyboardShortcut(.defaultAction).disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 420)
    }
}

private struct NorthStarsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let save: (String) -> Bool
    @State private var saveFailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("North Stars", systemImage: "star.fill").font(.headline)
            Text("One per line. Markdown bullets and emphasis are fine. Only this section of the Future page changes; the rest stays exactly as written.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body).frame(minHeight: 200)
            if saveFailed { Text("Not saved. Your text is still here; the page may have changed elsewhere, or a line starts with ‘#’ heading marks.").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { if save(text) { dismiss() } else { saveFailed = true } }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 460)
    }
}
