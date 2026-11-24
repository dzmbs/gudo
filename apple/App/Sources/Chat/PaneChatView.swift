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
    /// The host's reason the agent waits on a screen only its terminal answers (`ChatEmptyState.terminalWait`).
    var terminalWait: String?
    /// The agent's folder: tool rows show paths inside it relative to it.
    var workingDirectory: String?
    /// Set when the helper offers agent controls (`DaemonWorkspace.offersAgentControls`).
    var agentControls: ChatAgentControlsContext?
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder var terminal: (Bool) -> Terminal
    private var selectedDetail: ChatDetail? {
        get { state.detail }
        nonmutating set { state.detail = newValue }
    }
    @State private var photoPickerPresented = false
    @State private var fileImporterPresented = false
    @State private var confirmationPresented = false
    @State private var draftSelection: TextSelection?
    @FocusState private var draftFocused: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private let isCompact = false
    #endif
    @AppStorage(ChatPreferences.Key.sendWhileWorking) private var sendWhileWorkingSetting = ChatPreferences.SendWhileWorking.queue.rawValue
    @AppStorage(ChatPreferences.Key.collapsesTurns) private var collapsesTurns = true
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var dismissedNote: String?

    private var nativePresentations: some View {
        ZStack {
            terminal(state.presentation == .terminal)
                .opacity(state.presentation == .terminal ? 1 : 0)
                .allowsHitTesting(state.presentation == .terminal)
                .accessibilityHidden(state.presentation != .terminal)
            if let model = state.model {
                transcript(model)
                .opacity(state.presentation == .chat ? 1 : 0)
                .allowsHitTesting(state.presentation == .chat)
                .accessibilityHidden(state.presentation != .chat)
            }
            if state.presentation == .chat, state.model?.frame.rows.isEmpty != false {
                emptyState(ChatEmptyState(isLoading: state.model?.isLoading ?? true, session: state.model?.frame.session,
                                          agent: state.agent, terminalWait: terminalWait))
            }
        }
    }

    private func transcript(_ model: TimelineModel) -> some View {
        NativeChatView(model: model, frame: model.frame, expanded: model.expanded, actions: actions,
                       isActive: state.presentation == .chat, isWorking: working,
                       onControllerReady: { state.controller = $0 }) {
            composer
        }
    }

    @ViewBuilder private func emptyState(_ empty: ChatEmptyState) -> some View {
        Group {
            if let detail = empty.detail {
                EmptyState(empty.title, systemImage: empty.symbol, message: detail) {
                    if empty.offersTerminal {
                        Button("Open Terminal") { state.show(.terminal, terminal: pane) }
                            .accessibilityIdentifier("chat-empty-terminal")
                            .buttonStyle(.quiet)
                            .hairlineBorder(RoundedRectangle.rounded(DS.Radius.field), style: DS.Palette.border)
                            .frame(minHeight: DS.Size.touchTarget)
                    }
                }
            } else {
                Text(empty.title).font(ChatFont.subtitle).foregroundStyle(DS.Palette.textSecondary)
                    .modifier(ChatDelayedAppearance())
            }
        }
        .frame(maxWidth: ChatReadingColumn.maximumWidth)
        .allowsHitTesting(empty.offersTerminal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-empty")
    }

    var body: some View {
        nativePresentations
        .overlay(alignment: .top) { fallbackNote.animation(DS.Motion.standard, value: noteMessage) }
        .onAppear {
            state.images.read = { [hub] path in try await ChatImageReader.read(path, from: hub) }
            state.activate(in: hub)
            state.model?.collapsesTurns = collapsesTurns
            drainQueue()
        }
        .onDisappear { state.deactivate() }
        .onChange(of: state.draft) { _, _ in
            state.composer.draftChanged(outgoingMessage)
            updateAutocomplete()
        }
        .onChange(of: draftSelection) { _, _ in updateAutocomplete() }
        .onChange(of: collapsesTurns) { _, collapses in state.model?.collapsesTurns = collapses }
        .onChange(of: state.model?.frame.session?.title, initial: true) { _, title in
            if let title, !title.isEmpty { state.sessionTitle = title }
        }
        .onChange(of: state.presentation) { _, presentation in
            if presentation == .chat { drainQueue() }
            #if os(macOS)
            draftFocused = presentation == .chat && composerTakesText
            #endif
        }
        .onChange(of: state.actionContext) { _, _ in
            state.cancelPreparedActions()
            state.dictation.cancelIfStale()
            state.photos.cancelIfStale(in: state)
            state.photos.discardIfStale(session: state.actionContext.session)
            if !state.photos.isBusy { photoPickerPresented = false; fileImporterPresented = false }
            if case .commands(let offer) = selectedDetail?.content, offer.context != state.actionContext { selectedDetail = nil }
        }
        .onChange(of: permitsSending) { _, permits in if !permits { state.invalidateActions() } }
        .onChange(of: working) { _, working in
            guard !working else { return }
            state.interrupt.reset()
            drainQueue()
        }
        .onChange(of: scenePhase) { _, phase in sceneChanged(phase) }
        .onChange(of: state.composer.phase) { _, phase in queuedSendMoved(to: phase) }
        .onChange(of: state.composer.confirmedText) { _, text in
            guard let text, outgoingMessage == text else { return }
            state.draft = ""
            state.photos.discardAttachments()
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
        .sheet(item: $state.detail) { detail in
            detailSheet(detail)
                #if os(macOS)
                .frame(minWidth: DS.Size.proseReadingWidth, minHeight: Self.detailSheetHeight)
                #endif
        }
        .photosPicker(isPresented: $photoPickerPresented, selection: $selectedPhoto, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            receivePhoto(item)
        }
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.item]) { result in receiveFile(result) }
        .onChange(of: fileImporterPresented) { _, presented in
            guard !presented else { return }
            let generation = state.photos.generation
            Task {
                await Task.yield()
                if state.photos.generation == generation, state.photos.phase == .picking { state.photos.cancel() }
            }
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

    private var noteMessage: String? {
        state.error ?? state.terminalNotice?.message ?? state.model?.error ?? state.model?.historyError
    }

    /// Why Chat cannot do something, on a card at the top with the one way forward.
    @ViewBuilder private var fallbackNote: some View {
        if let message = noteMessage, message != dismissedNote {
            let offersTerminal = state.presentation == .chat
            Banner(Toast(message, systemImage: "exclamationmark.circle", style: .failure,
                         action: offersTerminal ? Toast.Action("Terminal") { [state, pane] in _ = state.show(.terminal, terminal: pane) } : nil),
                   edge: .top, alignment: .center) { dismissedNote = message }
                .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.s)
                .motionTransition(.toast(from: .top))
                .accessibilityIdentifier("chat-unavailable-note")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if state.capabilities.contains(.approvals), let approval { approval.frame(maxWidth: .infinity) }
            if state.capabilities.contains(.send) {
                if !state.queue.messages.isEmpty {
                    ChatQueueStrip(messages: state.queue.messages, edit: editQueued, sendNow: sendQueuedNow,
                                   remove: { state.queue.take($0.id) })
                        .motionTransition(.fade)
                }
                if state.autocomplete.isPresented {
                    ChatAutocompleteList(autocomplete: state.autocomplete, accept: acceptSuggestion)
                        .motionTransition(.fade)
                }
                composerBox
            } else {
                if state.capabilities.contains(.read) {
                    Text("Reply in Terminal. Chat sends only to agents started in \(Brand.name).")
                        .font(ChatFont.caption).foregroundStyle(DS.Palette.textSecondary)
                        .accessibilityIdentifier("chat-read-only")
                }
                if let action = primaryAction, action == .stop {
                    HStack(spacing: 0) {
                        composerStatusLine
                        Spacer(minLength: 0)
                        primaryButton(action)
                    }
                }
            }
        }
        .animation(DS.Motion.standard, value: state.queue.messages)
        .animation(DS.Motion.standard, value: state.autocomplete.isPresented)
        .padding(.horizontal, DS.Space.m).padding(.top, DS.Space.xs).padding(.bottom, DS.Space.s)
        .frame(maxWidth: ChatReadingColumn.maximumWidth).frame(maxWidth: .infinity)
        .foregroundStyle(DS.Palette.text)
    }

    /// One rounded box: pills for attachments, the field, and under it the row with attach,
    /// the agent's controls, the context meter, dictation and Send.
    private var composerBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.photos.attachments.isEmpty || state.photos.pendingName != nil {
                ChatAttachmentPills(attachments: state.photos.attachments,
                                    pending: state.photos.pendingName.map { name in state.photos.status.map { $0 + " " + name } ?? name },
                                    remove: { state.photos.remove($0) })
                    .padding(.top, DS.Space.s)
                    .motionTransition(.fade)
            }
            composerNotes
            draftField
            bottomRow
        }
        .padding(DS.Space.xs)
        .surface(.tile, in: RoundedRectangle.rounded(DS.Radius.card), fill: DS.Palette.raised)
        // Nothing can be sent: the composer says so by looking it, not only by ignoring taps.
        .opacity(composerTakesText ? 1 : DS.Opacity.mutedGlyph)
        .contentShape(.rect)
        .onTapGesture { if !state.dictation.isActive, composerTakesText { draftFocused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-composer")
    }

    private var draftField: some View {
        TextField("Message", text: $state.draft, selection: $draftSelection, prompt: Text(composerPrompt), axis: .vertical)
            .font(ChatFont.prose).lineLimit(1...8)
            .textFieldStyle(.plain)
            .focused($draftFocused)
            .disabled(state.dictation.isActive || !composerTakesText)
            .padding(.horizontal, DS.Space.m).padding(.top, DS.Space.gap10).padding(.bottom, DS.Space.xs)
            .frame(maxWidth: .infinity, minHeight: DS.Size.touchTarget, alignment: .leading)
            .onKeyPress(keys: [.upArrow, .downArrow, .tab, .return, .escape], phases: .down, action: suggestionKey)
            .accessibilityIdentifier("chat-draft")
    }

    private var bottomRow: some View {
        HStack(spacing: 0) {
            leadingControl
            #if os(iOS)
            if draftFocused, isCompact {
                Button { draftFocused = false } label: {
                    Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down").labelStyle(.iconOnly)
                }
                .buttonStyle(ChatComposerButtonStyle(.glyph))
                .accessibilityIdentifier("chat-hide-keyboard")
            }
            #endif
            ChatAgentControls(context: agentControls, session: state.model?.frame.session)
            Spacer(minLength: 0)
            if let usage = ChatContextUsage(reported: hub.agentControls[pane.id.rawValue]?.config.context,
                                            rows: state.model?.frame.rows ?? [], session: state.model?.frame.session) {
                ChatContextMeter(usage: usage)
            }
            dictationButton
            if let action = primaryAction { primaryButton(action) }
        }
    }

    /// Whether a message typed now could go: this device may prompt, and the agent is not stopped
    /// on a screen only its terminal answers.
    private var composerTakesText: Bool { permitsSending && terminalWait == nil }

    private var composerPrompt: String {
        if terminalWait != nil { return "Answer in Terminal first" }
        guard permitsSending else { return "You can watch, not send" }
        return isCompact ? "Message, @files, /commands"
            : "Message the agent, tag @files, or use /commands and /skills"
    }

    /// What the composer is doing on a line above the field, so the row with the buttons never moves.
    @ViewBuilder private var composerNotes: some View {
        if composerStatus != nil {
            HStack(spacing: DS.Space.s) {
                composerStatusLine
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m)
            .motionTransition(.fade)
        }
    }

    @ViewBuilder private var leadingControl: some View {
        if state.dictation.isActive {
            Button { state.dictation.cancel() } label: {
                Label("Cancel dictation", systemImage: "xmark").labelStyle(.iconOnly)
            }
            .buttonStyle(ChatComposerButtonStyle(.glyph)).keyboardShortcut(.escape, modifiers: [])
            .accessibilityIdentifier("chat-cancel-dictation")
        } else {
            Menu {
                Button("Photo Library", systemImage: "photo.on.rectangle", action: choosePhoto)
                Button("Choose File", systemImage: "folder", action: chooseFile)
                Button("Paste Image", systemImage: "doc.on.clipboard", action: pasteImage)
                    .disabled(!Pasteboard.hasImage)
                Divider()
                Button("Commands", systemImage: "slash.circle", action: openCommands)
                    .keyboardShortcut("/", modifiers: .command)
                    .disabled(ChatCommands.query(state.draft) == nil)
            } label: {
                Label("Attach", systemImage: "paperclip").labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(ChatComposerButtonStyle(.glyph))
            .disabled(!permitsSending || state.photos.isBusy || state.photos.isFull || state.composer.isBusy || state.interrupt.isBusy)
            .accessibilityIdentifier("chat-add")
        }
    }

    func resend(_ text: String) {
        guard state.capabilities.contains(.send), state.draft.isEmpty || state.draft == text,
              canEditDraft(state.actionContext) else { return }
        state.draft = text
        send()
    }

    @ViewBuilder private var composerStatusLine: some View {
        if let message = composerStatus {
            HStack(spacing: DS.Space.xs) {
                Text(message).font(ChatFont.caption).foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("chat-send-status")
                if state.photos.isBusy {
                    Button("Cancel") { state.photos.cancel(); photoPickerPresented = false }
                        .font(ChatFont.caption).frame(minHeight: DS.Size.touchTarget)
                }
            }
            .motionTransition(.fade)
        }
    }

    // MARK: Send, queue and stop

    /// What the message would be: the text, then the attachments' mentions.
    var outgoingMessage: String { state.photos.message(with: state.draft, session: state.actionContext.session) }

    /// Images that go with the message itself, for an agent that takes them.
    private var outgoingImages: [Data] { state.photos.images(for: state.actionContext.session) }

    /// Codex and pi take images with the message; Claude reads files uploaded to the host.
    private var keepsImages: Bool {
        state.agent != .claude && ((try? hub.timelineClient())?.sendsChatImages() ?? false)
    }

    private var hasMessage: Bool {
        !outgoingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var primaryAction: ChatComposer.PrimaryAction? {
        ChatComposer.primaryAction(hasMessage: hasMessage, isWorking: working,
                                   canStop: working && state.capabilities.contains(.stop),
                                   canSend: state.capabilities.contains(.send),
                                   whileWorking: sendWhileWorking)
    }

    private var sendWhileWorking: ChatPreferences.SendWhileWorking {
        ChatPreferences.SendWhileWorking(rawValue: sendWhileWorkingSetting) ?? .queue
    }

    private func primaryButton(_ action: ChatComposer.PrimaryAction) -> some View {
        Button { perform(action) } label: {
            Label(primaryTitle(action), systemImage: primarySymbol(action)).labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ChatComposerButtonStyle(action: action))
        .keyboardShortcut(primaryShortcut(action))
        .disabled(isDisabled(action))
        .animation(DS.Motion.micro, value: action)
        .contextMenu {
            if working, action != .stop, !isDisabled(action) {
                Button(action == .queue ? "Send Now" : "Queue Until the Turn Ends",
                       systemImage: action == .queue ? "arrow.up" : "text.append") { submit(alternate: true) }
            }
        }
        .background {
            Button("Send the other way") { submit(alternate: true) }
                .keyboardShortcut(.return, modifiers: .option)
                .disabled(!working || action == .stop || isDisabled(action))
                .hidden()
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier(primaryIdentifier(action))
    }

    @ViewBuilder private var dictationButton: some View {
        if state.capabilities.contains(.send) {
            let finishing = state.dictation.isActive
            Button(action: dictate) {
                Label(finishing ? "Use dictation" : "Dictate", systemImage: finishing ? "checkmark" : "mic").labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ChatComposerButtonStyle(.glyph))
            .disabled(isDictationDisabled)
            .accessibilityIdentifier("chat-dictate")
        }
    }

    private var isDictationDisabled: Bool {
        state.presentation != .chat || !permitsSending || state.photos.isBusy || state.composer.isBusy || state.interrupt.isBusy
            || (state.dictation.isActive && !state.dictation.canFinish)
    }

    private func perform(_ action: ChatComposer.PrimaryAction) {
        switch action {
        case .send, .queue: send()
        case .stop: interrupt()
        }
    }

    private func primaryShortcut(_ action: ChatComposer.PrimaryAction) -> KeyboardShortcut? {
        switch action {
        case .send, .queue: KeyboardShortcut(.return, modifiers: .command)
        case .stop: state.autocomplete.isPresented ? nil : KeyboardShortcut(.escape, modifiers: [])
        }
    }

    private func primaryTitle(_ action: ChatComposer.PrimaryAction) -> String {
        switch action {
        case .send: "Send"
        case .queue: "Queue"
        case .stop: "Stop"
        }
    }

    private func primarySymbol(_ action: ChatComposer.PrimaryAction) -> String {
        switch action {
        case .send: "arrow.up"
        case .queue: "text.append"
        case .stop: "stop.fill"
        }
    }

    private func primaryIdentifier(_ action: ChatComposer.PrimaryAction) -> String {
        switch action {
        case .send: "chat-send"
        case .queue: "chat-queue-send"
        case .stop: "chat-stop"
        }
    }

    private func isDisabled(_ action: ChatComposer.PrimaryAction) -> Bool {
        let blocked = state.presentation != .chat || !permitsSending || state.photos.isBusy
        switch action {
        case .send:
            return blocked || state.dictation.isActive || state.interrupt.isBusy
                || approval?.hasBlockedRequest == true || !state.composer.canSend(outgoingMessage)
        case .queue:
            return blocked || state.dictation.isActive || state.queue.isFull || !hasMessage
                || outgoingMessage.utf8.count > ChatComposer.maximumDraftBytes
        case .stop:
            return blocked || !state.interrupt.canBegin
        }
    }

    /// Send by the setting: while the agent works, queue (or send now, if the setting says so);
    /// `alternate` does the other.
    func submit(alternate: Bool) {
        let queues = working && (sendWhileWorking == .queue) != alternate
        if queues { queueDraft() } else { deliver(outgoingMessage, queued: nil, images: outgoingImages) }
    }

    func queueDraft() {
        let message = outgoingMessage
        guard state.capabilities.contains(.send), working, canEditDraft(state.actionContext),
              state.queue.enqueue(message, images: outgoingImages) else { return }
        state.draft = ""
        state.photos.discardAttachments()
        state.autocomplete.close()
    }

    private func editQueued(_ message: ChatQueuedMessage) {
        guard canEditDraft(state.actionContext), let taken = state.queue.take(message.id) else { return }
        let draft = state.draft.isEmpty ? taken.text : state.draft + "\n" + taken.text
        guard draft.utf8.count <= ChatComposer.maximumDraftBytes else { state.queue.restore(taken); return }
        state.draft = draft
        draftFocused = true
    }

    private func sendQueuedNow(_ message: ChatQueuedMessage) {
        guard !state.composer.isBusy, let taken = state.queue.take(message.id) else { return }
        deliver(taken.text, queued: taken, images: taken.images)
    }

    /// When the turn ends, the oldest queued message goes, through the same once-only send.
    func drainQueue() {
        guard !working, let next = state.queue.messages.first, state.capabilities.contains(.send),
              !state.composer.isBusy, !state.interrupt.isBusy, prepareAction(state.actionContext),
              state.composer.canSend(next.text), let taken = state.queue.take(next.id) else { return }
        deliver(taken.text, queued: taken, images: taken.images)
    }

    /// A queued message that was cancelled before it went, or did not go through, returns to
    /// the front of the queue.
    private func queuedSendMoved(to phase: ChatComposer.Phase) {
        guard let queued = state.queueInFlight else { return }
        switch phase {
        case .idle:
            state.queue.restore(queued)
            state.queueInFlight = nil
        case .finished:
            if state.composer.outcome == .notConfirmed { state.queue.restore(queued) }
            state.queueInFlight = nil
        case .preparing, .confirming, .sending: break
        }
    }

    private func acceptSuggestion(_ index: Int) {
        guard canEditDraft(state.actionContext),
              let accepted = state.autocomplete.accept(index, in: state.draft) else { return }
        state.draft = accepted.draft
        draftSelection = TextSelection(insertionPoint: accepted.cursor)
        draftFocused = true
        updateAutocomplete()
    }

    private func suggestionKey(_ press: KeyPress) -> KeyPress.Result {
        guard state.autocomplete.isPresented else { return .ignored }
        switch press.key {
        case .upArrow: state.autocomplete.moveSelection(by: -1)
        case .downArrow: state.autocomplete.moveSelection(by: 1)
        case .escape: state.autocomplete.dismiss()
        case .tab, .return:
            guard press.modifiers.isEmpty, !state.autocomplete.suggestions.isEmpty else { return .ignored }
            acceptSuggestion(state.autocomplete.selection)
        default: return .ignored
        }
        return .handled
    }

    func updateAutocomplete() {
        guard state.capabilities.contains(.send), permitsSending, !state.dictation.isActive else {
            state.autocomplete.close()
            return
        }
        state.autocomplete.update(draft: state.draft, cursor: draftCursor,
                                  commands: state.model?.frame.session?.commands ?? [], files: fileSource)
    }

    /// Where the cursor is in the draft; its end when the field is not being typed in.
    private var draftCursor: String.Index? {
        let draft = state.draft
        // The field reports its selection after the text changes; an index from the text before
        // may lie past this one's end or inside a character.
        guard draftFocused, case .selection(let range) = draftSelection?.indices, range.upperBound < draft.endIndex,
              draft.indices.contains(range.upperBound) else { return draft.endIndex }
        return range.upperBound
    }

    private var fileSource: ChatAutocomplete.FileSource? {
        guard let client = try? hub.timelineClient(), client.offersChatFileSearch() else { return nil }
        let paneId = pane.id.rawValue
        return { query in
            try await client.chatFileSearch(paneId: paneId, query: query, limit: 30).matches.map { file in
                ChatFileSuggestion(path: file.path, isDirectory: file.kind == .dir, positions: file.positions)
            }
        }
    }

    // MARK: Attachments

    func choosePhoto() {
        guard beginAttaching() else { return }
        photoPickerPresented = true
    }

    func chooseFile() {
        guard beginAttaching() else { return }
        fileImporterPresented = true
    }

    func pasteImage() {
        guard let data = Pasteboard.imagePNG(), beginAttaching() else { return }
        let context = state.actionContext
        state.photos.load(in: state, keepsImages: keepsImages, photo: {
            try await Task.detached(priority: .userInitiated) { try ChatPhotoFile.prepare(data: data) }.value
        }, source: { file in try await uploadPhoto(file, context: context) })
    }

    private func beginAttaching() -> Bool {
        guard state.capabilities.contains(.send), prepareAction(state.actionContext), !state.composer.isBusy,
              !state.interrupt.isBusy, !state.photos.isFull else { return false }
        state.invalidateActions()
        state.photos.begin(in: state)
        return true
    }

    private func receivePhoto(_ item: PhotosPickerItem) {
        let context = state.actionContext
        guard canEditDraft(context) else { state.photos.cancel(); return }
        state.photos.load(in: state, keepsImages: keepsImages, photo: {
            guard let file = try await item.loadTransferable(type: ChatPhotoFile.self) else { throw ChatPhotoError.invalidImage }
            return file
        }, source: { file in try await uploadPhoto(file, context: context) })
    }

    private func receiveFile(_ result: Result<URL, Error>) {
        let context = state.actionContext
        guard case .success(let url) = result, canEditDraft(context) else { state.photos.cancel(); return }
        state.photos.load(in: state, keepsImages: keepsImages, photo: {
            try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try ChatPhotoFile.prepareFile(url)
            }.value
        }, source: { file in try await uploadPhoto(file, context: context) })
    }

    #if os(macOS)
    private static var detailSheetHeight: CGFloat { DS.Size.proseReadingWidth * 0.75 }
    #endif

    static var attachmentsFolder: String {
        "Downloads/" + Brand.name.replacingOccurrences(of: " ", with: "-") + "-Attachments/"
    }

    /// A unique name in the attachments folder that keeps the file's own extension.
    static func attachmentName(for file: ChatPhotoFile) -> String {
        let pathExtension = file.url.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(12)
        return UUID().uuidString + (pathExtension.isEmpty ? "" : "." + pathExtension)
    }

    func uploadPhoto(_ file: ChatPhotoFile, context: PaneChatState.ActionContext) async throws -> String {
        guard isCurrentPhotoContext(context), let client = hub.api else { throw CancellationError() }
        let home = try await client.fsStat(path: "~")
        guard isCurrentPhotoContext(context), home.kind == .dir else { throw CancellationError() }
        let path = (home.path as NSString).appendingPathComponent(Self.attachmentsFolder + Self.attachmentName(for: file))
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

    func send() { submit(alternate: false) }

    /// Sends `text` through the once-only prepare and send; a queued message whose send did not
    /// go through goes back to the front of the queue.
    private func deliver(_ text: String, queued: ChatQueuedMessage?, images: [Data]) {
        let context = state.actionContext
        guard state.capabilities.contains(.send), !state.interrupt.isBusy, prepareAction(context), state.composer.canSend(text) else {
            if let queued { state.queue.restore(queued) }
            return
        }
        state.dictation.cancel()
        state.photos.cancel()
        state.autocomplete.close()
        let generation = state.composer.requestGeneration
        Task {
            guard generation == state.composer.requestGeneration,
                  state.capabilities.contains(.send), !state.interrupt.isBusy, prepareAction(context) else {
                if let queued { state.queue.restore(queued) }
                return
            }
            if state.interrupt.phase == .finished { state.interrupt.reset() }
            state.queueInFlight = queued
            await state.composer.begin(text) { command in
                guard state.capabilities.contains(.send), !state.interrupt.isBusy, prepareAction(context) else { throw CancellationError() }
                let client = try hub.timelineClient()
                let json: String
                switch command {
                case .prepare: json = try await client.chatPrepare(paneId: pane.id.rawValue)
                case .send(let ticket, let text, let revision) where images.isEmpty:
                    json = try await client.chatSend(paneId: pane.id.rawValue, ticket: ticket,
                                                     text: text, confirmedRevision: revision)
                case .send(let ticket, let text, let revision):
                    json = try await client.chatSendImages(paneId: pane.id.rawValue, ticket: ticket, text: text,
                                                           confirmedRevision: revision, images: images)
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
            && approval?.hasBlockedRequest != true && !pane.isComposingText && state.controller?.hasMarkedText != true
    }

    private var actions: ChatRowActions {
        ChatRowActions(supportsDiffs: state.capabilities.contains(.diffs), readsToolDetails: readsToolDetails, showTerminal: { state.showTerminal(commandMark: $0, terminal: pane) }, selectText: { text in
            state.presentDetail { _ in .text(ChatSelectedText(title: "Select Text", text: text)) }
        }, showTool: { item in
            guard case .tool(let tool) = item.body else { return }
            state.presentDetail { _ in .tool(tool) }
        }, showLongText: { longText in
            state.presentDetail { _ in .longText(longText) }
        }, showDiff: { selectDiffPreview($0) },
        resend: state.capabilities.contains(.send) && permitsSending ? { resend($0) } : nil,
        loadImage: readsToolDetails ? state.images : nil, workingDirectory: workingDirectory)
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

/// Nothing under the feedback delay, then the words.
private struct ChatDelayedAppearance: ViewModifier {
    @State private var isShown = false

    func body(content: Content) -> some View {
        content.opacity(isShown ? 1 : 0)
            .task {
                try? await Task.sleep(for: DS.Motion.feedbackDelay)
                withAnimation(DS.Motion.standard) { isShown = true }
            }
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
