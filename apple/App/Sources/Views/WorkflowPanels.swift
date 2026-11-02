import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import GudoCore

/// The workflow panels, in the palette's place and glass: the argument form and New Workflow.
struct WorkflowPanelHost: View {
    let panel: WorkflowPanel
    @Environment(WindowModel.self) private var model

    var body: some View {
        switch panel {
        case .arguments(let workflow, let pane):
            WorkflowArgumentsForm(workflow: workflow, pane: pane)
        case .new(let seed):
            NewWorkflowForm(seed: seed)
        }
    }
}

/// A workflow's arguments as a form, one field per placeholder, with the final command
/// previewed live. ↩ types it at the pane's prompt without running it; ⌘↩ runs it.
struct WorkflowArgumentsForm: View {
    let workflow: Workflow
    let pane: PaneId
    @Environment(WindowModel.self) private var model
    @State private var values: [String: String]
    /// The argument field being edited.
    @State private var current: Int? = 0
    #if os(macOS)
    @FocusState private var focused: Int?
    #endif

    init(workflow: Workflow, pane: PaneId) {
        self.workflow = workflow
        self.pane = pane
        _values = State(initialValue: Dictionary(
            workflow.arguments.map { ($0.name, $0.defaultValue ?? "") }, uniquingKeysWith: { first, _ in first }))
    }

    private var command: String { workflow.rendered(values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(Array(workflow.arguments.enumerated()), id: \.element.name) { index, argument in
                    field(argument, index: index)
                }
            }
            .padding(DS.Space.l)
            Hairline()
            preview
            Hairline()
            footer
        }
        .chromeContent()
        .frame(maxWidth: DS.Size.paletteWidth)
        .floatingPanel(cornerRadius: DS.Radius.panel, elevated: true)
        .padding(.horizontal, DS.Space.l)
        #if os(macOS)
        .onAppear { Task { focused = 0 } }
        .onChange(of: focused) { if let focused { current = focused } }
        .onChange(of: current) { focused = current }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-form")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: workflow.scope == .repo ? "folder" : "globe")
                .foregroundStyle(DS.Palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name).font(DS.Font.title)
                if let description = workflow.description {
                    Text(description).font(DS.Font.rowSubtitle).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: DS.Space.s)
            Text(workflow.sourceLabel)
                .font(DS.Font.badge)
                .padding(.horizontal, DS.Space.badgeH)
                .padding(.vertical, DS.Space.badgeV)
                .background(DS.Palette.selectedFill, in: .capsule)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private func field(_ argument: WorkflowArgument, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.row) {
                Text(argument.name).font(DS.Font.literalSmall).foregroundStyle(DS.Palette.textSecondary)
                if argument.raw {
                    Text("raw").font(DS.Font.badge).foregroundStyle(DS.Palette.textTertiary)
                }
            }
            input(argument, index: index)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.row)
                .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field).strokeBorder(
                    current == index ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.hairline)))
                .accessibilityIdentifier("workflow-arg-\(argument.name)")
            if let description = argument.description {
                Text(description).font(.caption).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
            }
        }
    }

    #if os(iOS)
    /// UIKit's field, so its key commands get ⌘↩ and ⇥ ahead of text input.
    private func input(_ argument: WorkflowArgument, index: Int) -> some View {
        WorkflowField(
            placeholder: argument.description ?? argument.name, text: binding(argument.name), isFocused: current == index,
            onFocus: { current = index }, onSubmit: { finish(run: false) }, onRun: { finish(run: true) },
            onMove: { move($0) }, onCancel: { model.workflowPanel = nil })
            .fixedSize(horizontal: false, vertical: true)
    }
    #else
    private func input(_ argument: WorkflowArgument, index: Int) -> some View {
        TextField(argument.description ?? argument.name, text: binding(argument.name))
                .textFieldStyle(.plain)
                .font(DS.Font.literal)
                .autocorrectionDisabled()
                .focused($focused, equals: index)
                .onSubmit { finish(run: false) }
                .onKeyPress(.tab, phases: .down) { press in
                    move(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    finish(run: true)
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.workflowPanel = nil
                    return .handled
                }
    }
    #endif

    private var preview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(command)
                .font(DS.Font.literal)
                .textSelection(.enabled)
                .fixedSize()
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
        }
        .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field))
        .padding(DS.Space.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Command")
        .accessibilityValue(command)
        .accessibilityIdentifier("workflow-preview")
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            Button("Cancel", role: .cancel) { model.workflowPanel = nil }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(DS.Palette.textSecondary)
            Spacer()
            Button { finish(run: true) } label: {
                HStack(spacing: DS.Space.row) {
                    Text("Run")
                    ShortcutLabel(["⌘", "↩"]).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.glass)
            .accessibilityIdentifier("workflow-run")
            Button { finish(run: false) } label: {
                HStack(spacing: DS.Space.row) {
                    Text("Insert")
                    ShortcutLabel(["↩"])
                }
            }
            .buttonStyle(.primaryGlass)
            .accessibilityIdentifier("workflow-insert")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func move(_ delta: Int) {
        let count = workflow.arguments.count
        guard count > 0 else { return }
        current = ((current ?? 0) + delta + count) % count
    }

    private func finish(run: Bool) {
        let text = command
        model.workflowPanel = nil
        model.type(text, into: pane, run: run)
    }
}

/// New Workflow from Last Command, saved to the pane's repository or the user's global workflows.
struct NewWorkflowForm: View {
    let seed: NewWorkflowSeed
    @Environment(WindowModel.self) private var model
    @State private var name = ""
    @State private var command: String
    @State private var description = ""
    @State private var scope: WorkflowScope
    @State private var isSaving = false
    @FocusState private var focused: Field?

    private enum Field { case name, command, description }

    init(seed: NewWorkflowSeed) {
        self.seed = seed
        _command = State(initialValue: seed.command)
        _scope = State(initialValue: seed.repoName == nil ? .global : .repo)
    }

    private var placeholders: [String] { workflowPlaceholders(command: command) }
    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespaces).isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Workflow").font(DS.Font.title)
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
            Hairline()
            VStack(alignment: .leading, spacing: DS.Space.m) {
                labelled("Name") {
                    input("Deploy preview", text: $name, field: .name, mono: false)
                        .accessibilityIdentifier("new-workflow-name")
                }
                labelled("Command") {
                    input("git checkout {{branch}}", text: $command, field: .command, mono: true)
                        .accessibilityIdentifier("new-workflow-command")
                    Text(placeholders.isEmpty
                         ? "Write {{name}} where an argument goes."
                         : "Arguments: \(placeholders.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(DS.Palette.textTertiary)
                }
                labelled("Description") {
                    input("Optional", text: $description, field: .description, mono: false)
                        .accessibilityIdentifier("new-workflow-description")
                }
                Picker("Save to", selection: $scope) {
                    Text(seed.repoName.map { "Repository · \($0)" } ?? "Repository").tag(WorkflowScope.repo)
                    Text("My Workflows").tag(WorkflowScope.global)
                }
                .pickerStyle(.segmented)
                .disabled(seed.repoName == nil)
                .accessibilityIdentifier("new-workflow-scope")
                Text(scope == .repo
                     ? "Saved in the repository's .\(Brand.name.lowercased())/workflows, for everyone who clones it."
                     : "Saved in ~/.config/\(Brand.name.lowercased())/workflows on the host, for every repository.")
                    .font(.caption).foregroundStyle(DS.Palette.textTertiary)
            }
            .padding(DS.Space.l)
            Hairline()
            HStack {
                Button("Cancel", role: .cancel) { model.workflowPanel = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button("Save Workflow") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.primaryGlass)
                    .disabled(!canSave)
                    .accessibilityIdentifier("new-workflow-save")
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
        }
        .chromeContent()
        .frame(maxWidth: DS.Size.paletteWidth)
        .floatingPanel(cornerRadius: DS.Radius.panel, elevated: true)
        .padding(.horizontal, DS.Space.l)
        .onAppear { Task { focused = .name } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-workflow-form")
    }

    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(DS.Palette.textSecondary)
            content()
        }
    }

    private func input(_ prompt: String, text: Binding<String>, field: Field, mono: Bool) -> some View {
        TextField(prompt, text: text, axis: mono ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .font(mono ? DS.Font.literal : DS.Font.rowTitle)
            .lineLimit(mono ? 1...6 : 1...1)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(mono ? .never : .sentences)
            #endif
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.row)
            .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field).strokeBorder(
                focused == field ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.hairline)))
            .focused($focused, equals: field)
            .onKeyPress(.escape) {
                model.workflowPanel = nil
                return .handled
            }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let draft = WorkflowDraft(
            name: name.trimmingCharacters(in: .whitespaces), command: command,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description,
            tags: [], arguments: [], shells: [])
        Task {
            if await model.saveWorkflow(draft, scope: scope, pane: seed.pane) {
                model.workflowPanel = nil
            }
            isSaving = false
        }
    }
}
