#if os(iOS)
import DesignSystem
import HostKit
import GudoCore
import PhotosUI
import SwiftUI

struct PaneChatView<Terminal: View>: View {
    let pane: Pane
    @Bindable var state: PaneChatState
    let hub: DaemonWorkspace
    var approval: SharedApproval? = nil
    var permitsSending = false
    /// A tool's full output and recorded changes need the right to prompt; a viewer sees the row only.
    var readsToolDetails = true
    var working = false
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder var terminal: (Bool) -> Terminal
    private var selectedDetail: ChatDetail? {
        get { state.detail }
        nonmutating set { state.detail = newValue }
    }
    @State private var photoPickerPresented = false
    @State private var confirmationPresented = false
    @FocusState private var draftFocused: Bool
    @State private var selectedPhoto: PhotosPickerItem?

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
        .onChange(of: state.actionContext) { _, _ in
            state.cancelPreparedActions()
            state.dictation.cancelIfStale()
            state.photos.cancelIfStale(in: state)
            if !state.photos.isBusy { photoPickerPresented = false }
            if case .commands(let offer) = selectedDetail?.content, offer.context != state.actionContext { selectedDetail = nil }
        }
        .onChange(of: permitsSending) { _, permits in if !permits { state.invalidateActions() } }
        .onChange(of: working) { _, working in if !working { state.interrupt.reset() } }
        .onChange(of: scenePhase) { _, phase in sceneChanged(phase) }
        .onChange(of: state.composer.confirmedText) { _, text in
            if let text, state.draft == text { state.draft = "" }
        }
        .onChange(of: pendingConfirmation, initial: true) { _, pending in confirmationPresented = pending != nil }
        .alert(unsentWarning, isPresented: $confirmationPresented) {
            Button(state.interrupt.needsConfirmation ? "Interrupt anyway" : "Send anyway", action: confirmAction)
            Button("Cancel", role: .cancel) { state.cancelPreparedActions() }
        }
        .onChange(of: state.agent) { _, agent in if agent != nil { state.activate(in: hub) } }
        .onChange(of: state.model?.error) { _, error in
            if error != nil { state.show(.terminal, terminal: pane, persistence: .transient) }
        }
        .sheet(item: $state.detail, content: detailSheet)
        .photosPicker(isPresented: $photoPickerPresented, selection: $selectedPhoto, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            receivePhoto(item)
        }
        .onChange(of: photoPickerPresented) { _, presented in
            guard !presented else { return }
            let generation = state.photos.generation
            Task {
                await Task.yield()
                if state.photos.generation == generation, state.photos.phase == .picking, selectedPhoto == nil {
                    state.photos.cancel()
                }
            }
        }
    }

    @ViewBuilder private func detailSheet(_ detail: ChatDetail) -> some View {
        switch detail.content {
        case .commands(let offer):
            ChatCommandSheet(offer: offer) { command in
                if !state.photos.isBusy, canEditDraft(offer.context), ChatCommands.apply(command, offer: offer, to: state) {
                    selectedDetail = nil
                }
            }
        case .text(let selection):
            ChatSelectedTextSheet(selection: selection, openTerminal: openTerminalFromDetail)
        case .tool(let tool):
            ChatToolDetailSheet(tool: tool, source: { offset, length in
                guard let output = tool.output else { throw ChatOutputError.invalidPage }
                return try await hub.timelineClient().timelineToolOutput(
                    paneId: pane.id.rawValue, handle: output.handle, offset: offset, len: length)
            }, openTerminal: { openTerminalFromDetail(commandMark: tool.commandMark) })
        case .longText(let longText):
            ChatLongTextSheet(longText: longText, source: { offset, length in
                try await hub.timelineClient().timelineToolOutput(
                    paneId: pane.id.rawValue, handle: longText.content.handle, offset: offset, len: length)
            }, openTerminal: openTerminalFromDetail)
        case .diff(let groups):
            ChatDiffSheet(groups: groups, source: { handle in
                try await hub.timelineClient().timelineToolDiff(paneId: pane.id.rawValue, handle: handle)
            }, openTerminal: openTerminalFromDetail)
        }
    }

    @ViewBuilder private var fallbackNote: some View {
        if let message = state.error ?? state.terminalNotice?.message ?? state.model?.error ?? state.model?.historyError {
            Text(verbatim: message).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                .padding(DS.Space.s).frame(maxWidth: .infinity).background(DS.Palette.raised)
                .accessibilityIdentifier("chat-unavailable-note")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if state.capabilities.contains(.approvals), let approval { approval.frame(maxWidth: .infinity) }
            if state.capabilities.contains(.send) {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Message", text: $state.draft, axis: .vertical)
                        .font(DS.Font.prose).lineLimit(1...6)
                        .focused($draftFocused)
                        .disabled(state.dictation.isActive)
                        .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.m).padding(.bottom, DS.Space.xs)
                        .accessibilityIdentifier("chat-draft")
                    if state.draft.hasPrefix("/"), ChatCommands.query(state.draft) != nil {
                        Button("Choose command…", systemImage: "slash.circle", action: openCommands)
                            .font(DS.Font.caption).frame(minHeight: DS.Size.touchTarget)
                            .padding(.horizontal, DS.Space.l)
                            .disabled(!permitsSending || state.dictation.isActive || state.composer.isBusy || state.interrupt.isBusy)
                    }
                    composerBar.padding(.horizontal, DS.Space.xs).padding(.bottom, DS.Space.xs)
                }
                .surface(.tile, in: RoundedRectangle.rounded(DS.Radius.card), fill: DS.Palette.raised)
                .contentShape(.rect)
                .onTapGesture { if !state.dictation.isActive { draftFocused = true } }
            } else {
                if state.capabilities.contains(.read) {
                    Text("Reply in Terminal. Chat sends only to agents started in \(Brand.name).")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                        .accessibilityIdentifier("chat-read-only")
                }
                if trailingAction != nil { composerBar }
            }
        }
        .padding(.horizontal, DS.Space.m).padding(.top, DS.Space.xs).padding(.bottom, DS.Space.s)
        .frame(maxWidth: ChatReadingColumn.maximumWidth).frame(maxWidth: .infinity)
        .foregroundStyle(DS.Palette.text)
    }

    private var composerBar: some View {
        HStack(spacing: DS.Space.xs) {
            if state.dictation.isActive {
                Button { state.dictation.cancel() } label: {
                    Label("Cancel dictation", systemImage: "xmark").labelStyle(.iconOnly)
                        .frame(minWidth: DS.Size.touchTarget, minHeight: DS.Size.touchTarget)
                }
                .buttonStyle(.quiet).keyboardShortcut(.escape, modifiers: [])
                .accessibilityIdentifier("chat-cancel-dictation")
            } else if state.capabilities.contains(.send) {
                Menu {
                    Button("Commands", systemImage: "slash.circle", action: openCommands)
                        .keyboardShortcut("/", modifiers: .command)
                        .disabled(ChatCommands.query(state.draft) == nil)
                    Button("Upload photo to host…", systemImage: "photo", action: choosePhoto)
                } label: {
                    Label("Add to message", systemImage: "plus").labelStyle(.iconOnly)
                        .frame(minWidth: DS.Size.touchTarget, minHeight: DS.Size.touchTarget)
                }
                .buttonStyle(.quiet)
                .disabled(!permitsSending || state.photos.isBusy || state.composer.isBusy || state.interrupt.isBusy)
                .accessibilityIdentifier("chat-add")
            }
            composerStatusLine
            Spacer(minLength: 0)
            if draftFocused {
                Button { draftFocused = false } label: {
                    Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down").labelStyle(.iconOnly)
                        .frame(minWidth: DS.Size.touchTarget, minHeight: DS.Size.touchTarget)
                }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("chat-hide-keyboard")
            }
            trailingButton
        }
        .frame(height: DS.Size.touchTarget)
    }

    @ViewBuilder private var composerStatusLine: some View {
        if let message = composerStatus {
            HStack(spacing: DS.Space.xs) {
                Text(message).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("chat-send-status")
                if state.photos.isBusy {
                    Button("Cancel") { state.photos.cancel(); photoPickerPresented = false }
                        .font(DS.Font.caption).frame(minHeight: DS.Size.touchTarget)
                } else if state.photos.phase == .ready {
                    Button("Add photo") {
                        if canEditDraft(state.actionContext) { state.photos.append(to: state) }
                    }
                    .font(DS.Font.caption).frame(minHeight: DS.Size.touchTarget)
                }
            }
            .motionTransition(.fade)
        }
    }

    private var trailingAction: ChatComposer.TrailingAction? {
        ChatComposer.trailingAction(draft: state.draft, isDictating: state.dictation.isActive,
                                    canStop: working && state.capabilities.contains(.stop),
                                    canSend: state.capabilities.contains(.send))
    }

    @ViewBuilder private var trailingButton: some View {
        if let action = trailingAction {
            Button { perform(action) } label: {
                Label(trailingTitle(action), systemImage: trailingSymbol(action)).labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: DS.Size.touchTarget, height: DS.Size.touchTarget)
            }
            .buttonStyle(QuietButtonStyle(prominent: action == .send))
            .keyboardShortcut(trailingShortcut(action))
            .disabled(isDisabled(action))
            .animation(DS.Motion.micro, value: action)
            .accessibilityIdentifier(trailingIdentifier(action))
        }
    }

    private func perform(_ action: ChatComposer.TrailingAction) {
        switch action {
        case .send: send()
        case .stop: interrupt()
        case .dictate, .finishDictation: dictate()
        }
    }

    private func trailingShortcut(_ action: ChatComposer.TrailingAction) -> KeyboardShortcut? {
        switch action {
        case .send: KeyboardShortcut(.return, modifiers: .command)
        case .stop: KeyboardShortcut(.escape, modifiers: [])
        case .dictate, .finishDictation: nil
        }
    }

    private func trailingTitle(_ action: ChatComposer.TrailingAction) -> String {
        switch action {
        case .send: "Send"
        case .stop: "Stop"
        case .dictate: "Dictate"
        case .finishDictation: "Use dictation"
        }
    }

    private func trailingSymbol(_ action: ChatComposer.TrailingAction) -> String {
        switch action {
        case .send: "arrow.up"
        case .stop: "stop.fill"
        case .dictate: "mic.fill"
        case .finishDictation: "checkmark"
        }
    }

    private func trailingIdentifier(_ action: ChatComposer.TrailingAction) -> String {
        switch action {
        case .send: "chat-send"
        case .stop: "chat-stop"
        case .dictate, .finishDictation: "chat-dictate"
        }
    }

    private func isDisabled(_ action: ChatComposer.TrailingAction) -> Bool {
        let blocked = state.presentation != .chat || !permitsSending || state.photos.isBusy
        switch action {
        case .send:
            return blocked || state.dictation.isActive || state.interrupt.isBusy
                || approval?.hasBlockedRequest == true || !state.composer.canSend(state.draft)
        case .stop:
            return blocked || !state.interrupt.canBegin
        case .dictate, .finishDictation:
            return blocked || state.composer.isBusy || state.interrupt.isBusy
                || (state.dictation.isActive && !state.dictation.canFinish)
        }
    }

    func choosePhoto() {
        guard state.capabilities.contains(.send), prepareAction(state.actionContext), !state.composer.isBusy, !state.interrupt.isBusy else { return }
        state.invalidateActions()
        state.photos.begin(in: state)
        photoPickerPresented = true
    }

    private func receivePhoto(_ item: PhotosPickerItem) {
        let context = state.actionContext
        guard canEditDraft(context) else { state.photos.cancel(); return }
        state.photos.load(in: state, photo: {
            guard let file = try await item.loadTransferable(type: ChatPhotoFile.self) else { throw ChatPhotoError.invalidImage }
            return file
        }, source: { file in try await uploadPhoto(file, context: context) })
    }

    static var attachmentsFolder: String {
        "Downloads/" + Brand.name.replacingOccurrences(of: " ", with: "-") + "-Attachments/"
    }

    func uploadPhoto(_ file: ChatPhotoFile, context: PaneChatState.ActionContext) async throws -> String {
        guard isCurrentPhotoContext(context), let client = hub.api else { throw CancellationError() }
        let home = try await client.fsStat(path: "~")
        guard isCurrentPhotoContext(context), home.kind == .dir else { throw CancellationError() }
        let path = (home.path as NSString).appendingPathComponent(Self.attachmentsFolder + UUID().uuidString + ".jpg")
        _ = try ChatPhotos.reference(path)
        let result = try await client.uploadFile(localPath: file.url.path,
            target: WriteTarget(path: path, ifMatch: nil, createNew: true, mkdirs: true, mode: 0o600), progress: nil)
        guard isCurrentPhotoContext(context), result.size == UInt64(file.bytes) else { throw CancellationError() }
        return result.path
    }

    private func isCurrentPhotoContext(_ context: PaneChatState.ActionContext) -> Bool {
        !Task.isCancelled && state.capabilities.contains(.send) && permitsSending && state.actionContext == context && state.presentation == .chat
            && state.photos.isBusy && !state.composer.isBusy && !state.interrupt.isBusy && !state.dictation.isActive
    }

    func openCommands() {
        guard state.capabilities.contains(.send), prepareAction(state.actionContext), ChatCommands.query(state.draft) != nil,
              !state.composer.isBusy, !state.interrupt.isBusy else { return }
        state.presentDetail { .commands(ChatCommandOffer(state: $0)) }
    }

    func dictate() {
        if state.dictation.isActive { state.dictation.finish(); return }
        guard state.capabilities.contains(.send), prepareAction(state.actionContext), !state.composer.isBusy, !state.interrupt.isBusy else { return }
        state.invalidateActions()
        state.dictation.start(in: state)
    }

    func sceneChanged(_ phase: ScenePhase) {
        guard phase != .active else { return }
        // System microphone/speech permission dialogs make the scene inactive. This target only
        // edits a local draft; host controls remain vetoed while it starts. Background always cancels.
        if phase == .inactive, state.dictation.isStarting || state.photos.phase == .picking { state.cancelPreparedActions() }
        else { state.invalidateActions() }
    }

    private var composerStatus: String? {
        if state.composer.needsConfirmation || state.interrupt.needsConfirmation { return "Waiting for confirmation…" }
        if let message = state.photos.status { return message }
        if let message = state.dictation.status { return message }
        if let message = state.interrupt.message { return message }
        if state.interrupt.isBusy { return "Requesting interrupt…" }
        return state.composer.message ?? (state.composer.isBusy ? "Waiting for confirmation…" : nil)
    }

    private struct PendingConfirmation: Equatable {
        let generation: UUID
        let revision: UInt64
    }

    private var pendingConfirmation: PendingConfirmation? {
        if let revision = state.interrupt.confirmationRevision {
            return PendingConfirmation(generation: state.interrupt.requestGeneration, revision: revision)
        }
        if let revision = state.composer.confirmationRevision {
            return PendingConfirmation(generation: state.composer.requestGeneration, revision: revision)
        }
        return nil
    }

    private var unsentWarning: String {
        "The agent in Terminal may have unsent text."
    }

    func send() {
        let context = state.actionContext
        guard state.capabilities.contains(.send), !state.interrupt.isBusy, prepareAction(context), state.composer.canSend(state.draft) else { return }
        state.dictation.cancel()
        state.photos.cancel()
        let draft = state.draft
        let generation = state.composer.requestGeneration
        Task {
            guard generation == state.composer.requestGeneration,
                  state.capabilities.contains(.send), !state.interrupt.isBusy, prepareAction(context) else { return }
            if state.interrupt.phase == .finished { state.interrupt.reset() }
            await state.composer.begin(draft) { command in
                guard state.capabilities.contains(.send), !state.interrupt.isBusy, prepareAction(context) else { throw CancellationError() }
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
        guard working, state.capabilities.contains(.stop), state.interrupt.canBegin, prepareAction(context) else { return }
        state.dictation.cancel()
        state.photos.cancel()
        state.composer.cancelBeforeSend()
        let generation = state.interrupt.requestGeneration
        Task {
            guard generation == state.interrupt.requestGeneration,
                  working, state.capabilities.contains(.stop), state.interrupt.canBegin, prepareAction(context) else { return }
            state.composer.cancelBeforeSend()
            await state.interrupt.begin { command in
                guard working, state.capabilities.contains(.stop), prepareAction(context) else { throw CancellationError() }
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
        selectedDetail == nil && !state.photos.isBusy && canEditDraft(context)
    }

    private func canEditDraft(_ context: PaneChatState.ActionContext) -> Bool {
        state.actionContext == context && state.presentation == .chat && permitsSending && !state.dictation.isActive
            && approval?.hasBlockedRequest != true && pane.view.markedTextRange == nil && state.controller?.hasMarkedText != true
    }

    private var actions: ChatRowActions {
        ChatRowActions(supportsDiffs: state.capabilities.contains(.diffs), readsToolDetails: readsToolDetails, showTerminal: { state.showTerminal(commandMark: $0, terminal: pane) }, selectText: { text in
            state.presentDetail { _ in .text(ChatSelectedText(title: "Select Text", text: text)) }
        }, showTool: { item in
            guard case .tool(let tool) = item.body else { return }
            state.presentDetail { _ in .tool(tool) }
        }, showLongText: { longText in
            state.presentDetail { _ in .longText(longText) }
        }, showDiff: { selectDiffPreview($0) })
    }

    private func selectDiffPreview(_ target: ChatDiffTarget) {
        guard state.capabilities.contains(.diffs) else { return }
        let groups = ChatDiffPreview.groups(for: target, rows: state.model?.frame.rows ?? [])
        state.presentDetail { _ in .diff(groups) }
    }

    private func openTerminalFromDetail() { openTerminalFromDetail(commandMark: nil) }

    private func openTerminalFromDetail(commandMark: UInt64?) {
        if state.showTerminal(commandMark: commandMark, terminal: pane) { selectedDetail = nil }
    }
}

struct ChatDetail: Identifiable {
    enum Content {
        case text(ChatSelectedText), tool(TimelineTool), longText(TimelineLongText), diff([ChatToolDiff])
        case commands(ChatCommandOffer)
    }
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

/// The iPhone bar's Chat switch: filled while Chat shows, as the pane header lights its toggles.
struct PaneChatButton: View {
    let pane: Pane
    @Bindable var state: PaneChatState

    var body: some View {
        let showsChat = state.presentation == .chat
        Button {
            withAnimation(DS.Motion.structural) { _ = state.show(showsChat ? .terminal : .chat, terminal: pane) }
        } label: {
            Label("Chat", systemImage: showsChat ? "text.bubble.fill" : "text.bubble")
                .foregroundStyle(showsChat ? DS.Palette.text : DS.Palette.textSecondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .help(showsChat ? "Show Terminal" : "Show Chat")
        .accessibilityAddTraits(showsChat ? .isSelected : [])
        .accessibilityIdentifier("pane-presentation")
    }
}
#endif
