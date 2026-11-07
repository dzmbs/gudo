#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI

struct PaneChatView<Terminal: View>: View {
    let pane: Pane
    @Bindable var state: PaneChatState
    let hub: DaemonWorkspace
    @ViewBuilder var terminal: (Bool) -> Terminal
    @State private var selectedDetail: ChatDetail?

    var body: some View {
        ZStack {
            terminal(state.presentation == .terminal)
                .opacity(state.presentation == .terminal ? 1 : 0)
                .allowsHitTesting(state.presentation == .terminal)
                .accessibilityHidden(state.presentation != .terminal)
            if let model = state.model {
                NativeChatView(model: model, frame: model.frame, expanded: model.expanded, actions: actions,
                               isActive: state.presentation == .chat, onControllerReady: { state.controller = $0 }) {
                    composer
                }
                .opacity(state.presentation == .chat ? 1 : 0)
                .allowsHitTesting(state.presentation == .chat)
                .accessibilityHidden(state.presentation != .chat)
            }
            if state.presentation == .chat, state.model?.frame.rows.isEmpty != false {
                Text(state.model?.isLoading == true ? "Opening Chat…" : "No messages yet")
                    .font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { fallbackNote }
        .onAppear { state.activate(in: hub) }
        .onDisappear { state.deactivate() }
        .onChange(of: state.agent) { _, agent in if agent != nil { state.activate(in: hub) } }
        .onChange(of: state.model?.error) { _, error in
            if error != nil { state.show(.terminal, terminal: pane, persistence: .transient) }
        }
        .sheet(item: $selectedDetail) { detail in
            switch detail.content {
            case .text(let selection):
                ChatSelectedTextSheet(selection: selection, openTerminal: openTerminalFromDetail)
            case .tool(let tool):
                ChatToolDetailSheet(tool: tool, source: { offset, length in
                    guard let output = tool.output else { throw ChatOutputError.invalidPage }
                    return try await hub.timelineClient().timelineToolOutput(
                        paneId: pane.id.rawValue, handle: output.handle, offset: offset, len: length)
                }, openTerminal: { openTerminalFromDetail(commandMark: tool.commandMark) })
            case .diff(let groups):
                ChatDiffSheet(groups: groups, source: { handle in
                    try await hub.timelineClient().timelineToolDiff(paneId: pane.id.rawValue, handle: handle)
                }, openTerminal: openTerminalFromDetail)
            }
        }
    }

    @ViewBuilder private var fallbackNote: some View {
        if let message = state.error ?? state.terminalNotice?.message ?? state.model?.error {
            Text(verbatim: message).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                .padding(DS.Space.s).frame(maxWidth: .infinity).background(DS.Palette.raised)
                .accessibilityIdentifier("chat-unavailable-note")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            TextField("Draft (not sent)", text: $state.draft, axis: .vertical)
                .font(DS.Font.prose).lineLimit(1...6)
                .accessibilityIdentifier("chat-draft")
            HStack(spacing: DS.Space.s) {
                Text("Chat sending is unavailable.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                Spacer(minLength: 0)
                Button("Open Terminal", systemImage: "terminal") { state.show(.terminal, terminal: pane) }
                    .font(DS.Font.caption).frame(minHeight: DS.Size.touchTarget)
                Button("Send", systemImage: "arrow.up") {}
                    .labelStyle(.iconOnly).frame(minWidth: DS.Size.touchTarget, minHeight: DS.Size.touchTarget)
                    .disabled(true).accessibilityIdentifier("chat-send-disabled")
            }
        }
        .padding(DS.Space.l).foregroundStyle(DS.Palette.text).background(DS.Palette.sidebar)
    }

    private var actions: ChatRowActions {
        ChatRowActions(showTerminal: { state.showTerminal(commandMark: $0, terminal: pane) }, selectText: { text in
            selectedDetail = ChatDetail(content: .text(ChatSelectedText(title: "Select Text", text: text)))
        }, showTool: { item in
            guard case .tool(let tool) = item.body else { return }
            selectedDetail = ChatDetail(content: .tool(tool))
        }, showDiff: { selectDiffPreview($0) })
    }

    private func selectDiffPreview(_ target: ChatDiffTarget) {
        let groups = ChatDiffPreview.groups(for: target, rows: state.model?.frame.rows ?? [])
        selectedDetail = ChatDetail(content: .diff(groups))
    }

    private func openTerminalFromDetail() { openTerminalFromDetail(commandMark: nil) }

    private func openTerminalFromDetail(commandMark: UInt64?) {
        if state.showTerminal(commandMark: commandMark, terminal: pane) { selectedDetail = nil }
    }
}

private struct ChatDetail: Identifiable {
    enum Content { case text(ChatSelectedText), tool(TimelineTool), diff([ChatToolDiff]) }
    let id = UUID()
    let content: Content
}

private struct ChatSelectedText: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

private struct ChatSelectedTextSheet: View {
    let selection: ChatSelectedText
    let openTerminal: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: selection.text).font(DS.Font.literal).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.l)
            }
            .background(DS.Palette.base).foregroundStyle(DS.Palette.text)
            .navigationTitle(selection.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Terminal", systemImage: "terminal", action: openTerminal)
                        .frame(minHeight: DS.Size.touchTarget)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.frame(minHeight: DS.Size.touchTarget)
                }
            }
        }
    }
}

struct PaneChatToggle: View {
    let pane: Pane
    @Bindable var state: PaneChatState

    var body: some View {
        Picker("Presentation", selection: Binding(
            get: { state.presentation }, set: { state.show($0, terminal: pane) }
        )) {
            Text("Chat").tag(PanePresentation.chat)
            Text("Terminal").tag(PanePresentation.terminal)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: DS.Size.touchTarget)
        .accessibilityIdentifier("pane-presentation")
    }
}
#endif
