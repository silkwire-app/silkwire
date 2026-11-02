import SwiftUI
import AppKit

/// Import from Obsidian: choose a vault, preview what will come in, pick a small
/// batch, import. The vault is only read.
struct VaultImportSheet: View {
    @ObservedObject var store: ConversationStore
    var opened: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scan: VaultScan?
    @State private var chosen: Set<String> = []
    /// Whole vault by default; "Only some folders" reveals the folder list.
    @State private var wholeVault = true
    /// Optional small first batch for people who want to try it out first.
    @State private var trialOnly = false
    @State private var skipDone = true
    @State private var scanning = false
    @State private var error: String?
    @State private var report: VaultImportReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox").font(.title2).foregroundStyle(SilkwireTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from Obsidian").font(.system(size: 18, weight: .semibold, design: .serif))
                    Text("Silkwire only reads your vault. Nothing in it is changed, moved or deleted.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let report { finished(report) }
            else if let scan { preview(scan) }
            else { start }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
        }
        .padding(22).frame(width: 520).frame(minHeight: 260)
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your vault folder. You'll see what's inside before anything is imported.").fixedSize(horizontal: false, vertical: true)
            Text("Notes arrive on the Vaults shelf with their folder path. Links between notes keep working. Images and other attachments are listed but not imported yet. Files whose names suggest passwords, keys or tokens are left out.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { choose() } label: { if scanning { ProgressView().controlSize(.small) } else { Text("Choose vault…") } }
                    .buttonStyle(.borderedProminent).disabled(scanning)
            }
        }
    }

    private func preview(_ scan: VaultScan) -> some View {
        let done = VaultImport.alreadyImported(scan, in: store.libraryPages)
        let skipping = skipDone ? done : []
        let picked = VaultImport.plan(scan, wholeVault: wholeVault, folders: chosen, trialOnly: trialOnly, skipping: skipping)
        let available = VaultImport.remaining(scan, wholeVault: wholeVault, folders: chosen, skipping: skipping)
        return VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey("**\(scan.vaultName)** · \(scan.notes.count) note\(scan.notes.count == 1 ? "" : "s") in \(scan.folders.count) folder\(scan.folders.count == 1 ? "" : "s")" + (scan.partial ? " (first \(VaultImport.maxNotes) only)" : "")))
            if !done.isEmpty {
                Text("\(done.count) already in Alexandria · \(VaultImport.remaining(scan, wholeVault: true, folders: [], skipping: done)) not yet imported").font(.callout).foregroundStyle(.secondary)
            }
            Picker("What to import", selection: $wholeVault) {
                Text("The whole vault").tag(true)
                Text("Only some folders").tag(false)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Text(wholeVault ? "Every note in the vault, including notes that aren't in any folder." : "Only notes inside the folders you tick below.")
                .font(.caption).foregroundStyle(.secondary)
            if !wholeVault {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(scan.folders, id: \.name) { folder in
                        Toggle(isOn: Binding(get: { chosen.contains(folder.name) }, set: { on in if on { chosen.insert(folder.name) } else { chosen.remove(folder.name) } })) {
                            HStack { Text(folder.name); Spacer(); Text("\(folder.count)").foregroundStyle(.secondary).monospacedDigit() }
                        }.toggleStyle(.checkbox)
                    }
                }.padding(.trailing, 6)
            }.frame(maxHeight: 180)
            }
            if available > VaultImport.trialBatch {
                Toggle("Just try \(VaultImport.trialBatch) first", isOn: $trialOnly).toggleStyle(.checkbox)
                    .help("Bring in a small batch to see how it looks. You can import the rest any time; it picks up where it left off.")
            }
            if !done.isEmpty {
                Toggle("Continue where you left off: skip the \(done.count) already in Alexandria", isOn: $skipDone).toggleStyle(.checkbox)
                    .help("Turn off to bring in fresh copies of notes changed in Obsidian. Pages you edited in Alexandria are never overwritten.")
            }
            VStack(alignment: .leading, spacing: 3) {
                if !scan.skippedSensitive.isEmpty { Text("Left out for safety (\(scan.skippedSensitive.count)): " + scan.skippedSensitive.prefix(6).joined(separator: ", ") + (scan.skippedSensitive.count > 6 ? "…" : "")) }
                if scan.otherFiles > 0 { Text("Images and other files not imported yet: \(scan.otherFiles)") }
                if !scan.tooLarge.isEmpty { Text("Too long to import (\(scan.tooLarge.count)): " + scan.tooLarge.prefix(4).joined(separator: ", ")) }
                if scan.skippedLinks > 0 { Text("Links to places outside the vault, not followed: \(scan.skippedLinks)") }
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose a different vault…") { choose() }.buttonStyle(.borderless)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(VaultImport.buttonTitle(count: picked.count, remaining: available, anyDone: !done.isEmpty)) {
                    let result = store.importVaultNotes(picked, vaultName: scan.vaultName, vaultID: scan.vaultID)
                    report = result
                    if result.added + result.updated == 0 && !result.failed.isEmpty { error = "Nothing was imported. The library could not be saved." }
                }.buttonStyle(.borderedProminent).disabled(picked.isEmpty || store.storageError != nil).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finished(_ report: VaultImportReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(report.summary, systemImage: "checkmark.circle").font(.callout)
            if !report.keptLocalEdits.isEmpty {
                Text("These were edited in Alexandria since the last import, so your Alexandria version was kept: " + report.keptLocalEdits.prefix(6).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Importing more later is safe: unchanged notes are skipped and nothing edited here is overwritten.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Open the Vaults shelf") { opened(nil); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Preview vault"
        panel.message = "Choose your Obsidian vault folder. Silkwire only reads it; nothing in the vault is changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanning = true; error = nil; report = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try VaultImport.scan(url) }
            await MainActor.run {
                scanning = false
                switch result {
                case .success(let value):
                    scan = value
                    // Whole vault by default. If someone switches to "Only some
                    // folders", every folder starts ticked so nothing is missed.
                    chosen = Set(value.folders.map(\.name)); wholeVault = true; trialOnly = false
                    if value.notes.isEmpty { error = "No Markdown notes found in that folder." }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }
}
