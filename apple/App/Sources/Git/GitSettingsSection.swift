import DesignSystem
import SwiftUI

/// Settings ▸ Git: how Merge PR merges, when hosts delete merged worktrees, and the global
/// scripts (repository scripts live in the repository's `.<product>.json`).
struct GitSettingsSection: View {
    @AppStorage(GitSettings.mergeStrategyKey) private var strategy = "merge"
    @AppStorage(GitSettings.autoDeleteDaysKey) private var autoDeleteDays = 7
    @State private var scripts = GitSettings.globalScripts
    @State private var editing: ScriptDef?

    var body: some View {
        Section {
            Picker("Merge Pull Requests With", selection: $strategy) {
                Text("Merge Commit").tag("merge")
                Text("Squash and Merge").tag("squash")
                Text("Rebase and Merge").tag("rebase")
            }
            .accessibilityIdentifier("settings-merge-strategy")
            Picker("Delete Merged Worktrees", selection: $autoDeleteDays) {
                Text("Never").tag(0)
                Text("After 1 Day").tag(1)
                Text("After 3 Days").tag(3)
                Text("After 7 Days").tag(7)
                Text("After 14 Days").tag(14)
                Text("After 30 Days").tag(30)
            }
            .accessibilityIdentifier("settings-auto-delete")
            .onChange(of: autoDeleteDays) {
                NotificationCenter.default.post(name: GitSettings.autoDeleteChanged, object: nil)
            }
        } header: {
            Text("Git")
        } footer: {
            Text("Only worktrees made from this app (New Task, Check Out PR) are deleted, and never one with uncommitted changes. Branches stay. Pull requests come from each host's own gh.")
        }
        Section {
            ForEach(scripts) { script in
                Button { editing = script } label: {
                    HStack(spacing: 6) {
                        Image(systemName: script.systemImage)
                            .foregroundStyle(script.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(script.name)
                            Text(script.command).font(DS.Font.literalSmall).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        if script.isDefault { Text("⌘R").font(.caption).foregroundStyle(.secondary) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                scripts.remove(atOffsets: offsets)
                GitSettings.globalScripts = scripts
            }
            Button("Add Script", systemImage: "plus") {
                editing = ScriptDef(name: "", command: "", icon: "play", tint: "green", isDefault: scripts.isEmpty)
            }
        } header: {
            Text("Scripts")
        } footer: {
            Text("Each runs in its own tab in the focused worktree (Run ▾, ⌘R, the palette). Repositories add their own in .\(Brand.name.lowercased()).json.")
        }
        .sheet(item: $editing) { script in
            ScriptEditor(script: script) { saved in
                if saved.isDefault { for i in scripts.indices { scripts[i].isDefault = false } }
                if let i = scripts.firstIndex(where: { $0.id == saved.id }) { scripts[i] = saved } else { scripts.append(saved) }
                GitSettings.globalScripts = scripts
            }
        }
    }
}

/// Name, command, symbol and tint of one global script.
private struct ScriptEditor: View {
    @State var script: ScriptDef
    let save: (ScriptDef) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let symbols = ["play", "play.diamond", "hammer", "testtube.2", "arrowshape.turn.up.forward", "exclamationmark.triangle", "circle.dotted.circle", "text.alignleft", "shippingbox", "globe"]
    private static let tints = ["green", "yellow", "red", "blue", "purple", "gray"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $script.name)
                TextField("Command", text: $script.command)
                    .font(DS.Font.literal)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Picker("Symbol", selection: Binding(get: { script.icon ?? "play" }, set: { script.icon = $0 })) {
                    ForEach(Self.symbols, id: \.self) { Label($0, systemImage: $0).tag($0) }
                }
                Picker("Tint", selection: Binding(get: { script.tint ?? "gray" }, set: { script.tint = $0 })) {
                    ForEach(Self.tints, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Toggle("Run with ⌘R", isOn: $script.isDefault)
            }
            .formStyle(.grouped)
            .navigationTitle(script.name.isEmpty ? "New Script" : script.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(script)
                        dismiss()
                    }
                    .disabled(script.name.trimmingCharacters(in: .whitespaces).isEmpty || script.command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 300)
        #endif
    }
}
