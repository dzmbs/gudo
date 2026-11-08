#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI

struct PaneChatView<Terminal: View>: View {
    let pane: Pane
    @Bindable var state: PaneChatState
    let hub: DaemonWorkspace
    var approval: SharedApproval? = nil
    var permitsSending = false
    var working = false
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder var terminal: (Bool) -> Terminal
    @State private var selectedDetail: ChatDetail?

    private var nativePresentations: some View {
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
    }

    var body: some View {
        nativePresentations
        .overlay(alignment: .top) { fallbackNote }
        .onAppear { state.activate(in: hub) }
        .onDisappear { state.deactivate() }
        .onChange(of: state.draft) { _, draft in state.composer.draftChanged(draft) }
        .onChange(of: state.actionContext) { _, _ in state.cancelPreparedActions() }
        .onChange(of: working) { _, working in if !working { state.interrupt.reset() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { state.invalidateActions() } }
        .onChange(of: state.composer.confirmedText) { _, text in
            if let text, state.draft == text { state.draft = "" }
        }
        .alert(unsentWarning, isPresented: Binding(
            get: { state.composer.needsConfirmation || state.interrupt.needsConfirmation }, set: { _ in }
        )) {
            Button(state.interrupt.needsConfirmation ? "Interrupt anyway" : "Send anyway", action: confirmAction)
            Button("Cancel", role: .cancel) { state.cancelPreparedActions() }
        }
        .onChange(of: state.agent) { _, agent in if agent != nil { state.activate(in: hub) } }
        .onChange(of: state.model?.error) { _, error in
            if error != nil { state.show(.terminal, terminal: pane, persistence: .transient) }
        }
        .sheet(item: $selectedDetail, content: detailSheet)
    }

    @ViewBuilder private func detailSheet(_ detail: ChatDetail) -> some View {
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

    @ViewBuilder private var fallbackNote: some View {
        if let message = state.error ?? state.terminalNotice?.message ?? state.model?.error {
            Text(verbatim: message).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                .padding(DS.Space.s).frame(maxWidth: .infinity).background(DS.Palette.raised)
                .accessibilityIdentifier("chat-unavailable-note")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let approval { approval.frame(maxWidth: .infinity) }
            TextField("Message", text: $state.draft, axis: .vertical)
                .font(DS.Font.prose).lineLimit(1...6)
                .accessibilityIdentifier("chat-draft")
            if let message = composerStatus {
                Text(message).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityIdentifier("chat-send-status")
            }
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                Button { state.show(.terminal, terminal: pane) } label: {
                    Label("Open Terminal", systemImage: "terminal").font(DS.Font.caption)
                        .frame(minHeight: DS.Size.touchTarget)
                }
                .buttonStyle(.quiet)
                if working, state.agent == .claude {
                    Button(action: interrupt) {
                        Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
                            .frame(minWidth: DS.Size.touchTarget, minHeight: DS.Size.touchTarget)
                    }
                        .buttonStyle(.quiet)
                        .keyboardShortcut(.escape, modifiers: [])
                        .disabled(state.presentation != .chat || !permitsSending || !state.interrupt.canBegin)
                        .accessibilityIdentifier("chat-stop")
                }
                Button(action: send) {
                    Label("Send", systemImage: "arrow.up").labelStyle(.iconOnly)
                        .frame(minWidth: DS.Size.touchTarget, minHeight: DS.Size.touchTarget)
                }
                    .buttonStyle(.quietProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.presentation != .chat || !permitsSending || state.interrupt.isBusy
                          || approval?.hasBlockedRequest == true || !state.composer.canSend(state.draft))
                .accessibilityIdentifier("chat-send")
            }
        }
        .padding(DS.Space.l).foregroundStyle(DS.Palette.text).background(DS.Palette.sidebar)
    }

    private var composerStatus: String? {
        if state.composer.needsConfirmation || state.interrupt.needsConfirmation { return "Waiting for confirmation…" }
        if let message = state.interrupt.message { return message }
        if state.interrupt.isBusy { return "Requesting interrupt…" }
        return state.composer.message ?? (state.composer.isBusy ? "Waiting for confirmation…" : nil)
    }

    private var unsentWarning: String {
        let agent = state.agent == .codex ? "Codex" : "Claude Code"
        return "\(agent) on the Mac may have unsent text."
    }

    func send() {
        let context = state.actionContext
        guard !state.interrupt.isBusy, prepareAction(context), state.composer.canSend(state.draft) else { return }
        let draft = state.draft
        let generation = state.composer.requestGeneration
        Task {
            guard generation == state.composer.requestGeneration,
                  !state.interrupt.isBusy, prepareAction(context) else { return }
            if state.interrupt.phase == .finished { state.interrupt.reset() }
            await state.composer.begin(draft) { command in
                guard !state.interrupt.isBusy, prepareAction(context) else { throw CancellationError() }
                let client = try hub.timelineClient()
                let json: String
                switch command {
                case .prepare: json = try await client.chatPrepare(paneId: pane.id.rawValue)
                case .send(let ticket, let text, let revision):
                    json = try await client.chatSend(paneId: pane.id.rawValue, ticket: ticket,
                                                     text: text, confirmedRevision: revision)
                }
                return try ChatSendStatus.decode(json)
            }
        }
    }

    func interrupt() {
        let context = state.actionContext
        guard working, state.agent == .claude, state.interrupt.canBegin, prepareAction(context) else { return }
        state.composer.cancelBeforeSend()
        let generation = state.interrupt.requestGeneration
        Task {
            guard generation == state.interrupt.requestGeneration,
                  working, state.agent == .claude, state.interrupt.canBegin, prepareAction(context) else { return }
            state.composer.cancelBeforeSend()
            await state.interrupt.begin { command in
                guard working, state.agent == .claude, prepareAction(context) else { throw CancellationError() }
                let client = try hub.timelineClient()
                let json: String
                switch command {
                case .prepare: json = try await client.chatInterruptPrepare(paneId: pane.id.rawValue)
                case .interrupt(let ticket, let revision):
                    json = try await client.chatInterrupt(paneId: pane.id.rawValue, ticket: ticket, confirmedRevision: revision)
                }
                return try ChatSendStatus.decode(json)
            }
        }
    }

    func confirmAction() {
        let interrupting = state.interrupt.needsConfirmation
        let context = state.actionContext
        let generation = interrupting ? state.interrupt.requestGeneration : state.composer.requestGeneration
        let offered = interrupting ? state.interrupt.confirmationRevision : state.composer.confirmationRevision
        guard let revision = offered else { return }
        Task {
            let current = interrupting ? state.interrupt.requestGeneration : state.composer.requestGeneration
            let currentRevision = interrupting
                ? state.interrupt.confirmationRevision : state.composer.confirmationRevision
            guard generation == current, revision == currentRevision, prepareAction(context) else { return }
            if interrupting { await state.interrupt.confirm() } else { await state.composer.confirm() }
        }
    }

    private func prepareAction(_ context: PaneChatState.ActionContext) -> Bool {
        state.actionContext == context && state.presentation == .chat && permitsSending
            && approval?.hasBlockedRequest != true && pane.view.markedTextRange == nil && state.controller?.prepareToPark() != false
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
