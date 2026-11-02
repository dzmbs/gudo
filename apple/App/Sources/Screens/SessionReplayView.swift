import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What the Replays sheet opens on: one session, or a page's or an agent pane's sessions.
enum ReplayRequest: Hashable {
    case all
    case session(UUID)
    case page(UUID)
    case pane(hostId: String, paneId: UInt64)
}

extension WindowModel {
    func showReplays(_ request: ReplayRequest) {
        replayRequest = request
        sheet = .replays
    }
}

/// The Replays sheet: recorded sessions, newest first, each opening in Session Replay.
struct SessionReplaysSheet: View {
    let request: ReplayRequest
    @State private var store = ReplayStore.shared
    @State private var path: [UUID] = []
    /// The session open in place (a leaf, the Mac), with a way back to the list.
    @State private var selected: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isToolWindow) private var isToolWindow
    @Environment(\.toolLeaf) private var leaf

    /// A push from a leaf lands in the window's navigation, not the leaf's, and Mac tools have no
    /// back gesture to keep: both show a session in place instead (as Files does).
    private var opensInPlace: Bool {
        #if os(macOS)
        true
        #else
        leaf != nil
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if case .session(let id) = request, let session = store.session(id) {
                    SessionReplayView(session: session)
                } else if opensInPlace, let selected, let session = store.session(selected) {
                    SessionReplayView(session: session)
                        .environment(\.toolNavigation, ToolNavigation(back: { self.selected = nil }))
                        .id(selected)
                } else {
                    list
                }
            }
            .toolbar {
                if !isToolWindow {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("replays-done")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let session = store.session(id) { SessionReplayView(session: session) }
            }
        }
        .toolMinimumSize(width: 900, height: 600)
        .presentationSizing(.page)
        .onAppear {
            // One session of a page or pane opens straight away.
            if case .session = request { return }
            if sessions.count == 1, let only = sessions.first { open(only.id) }
        }
    }

    private func open(_ id: UUID) {
        if opensInPlace { selected = id } else { path = [id] }
    }

    private var sessions: [ReplaySession] {
        switch request {
        case .all, .session: store.sessions
        case .page(let id): store.sessions.filter { $0.page == id }
        case .pane(let host, let pane): store.sessions(hostId: host, paneId: pane)
        }
    }

    private var list: some View {
        List {
            ForEach(sessions) { session in
                Group {
                    if opensInPlace {
                        Button { open(session.id) } label: { ReplaySessionRow(session: session).contentShape(.rect) }
                            .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: session.id) { ReplaySessionRow(session: session) }
                    }
                }
                .accessibilityIdentifier("replay-session-\(session.id.uuidString.prefix(8))")
                .chromeRows()
            }
            .onDelete { offsets in
                for index in offsets { store.delete(sessions[index].id) }
            }
        }
        .chromeGrouped()
        .overlay {
            if sessions.isEmpty {
                EmptyState("No Replays Yet", systemImage: "play.rectangle.on.rectangle", message: "When an agent uses a browser page, what it does is kept here to play back.") {}
            }
        }
        .toolChrome("Replays")
    }
}

private struct ReplaySessionRow: View {
    let session: ReplaySession

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ReplayThumbnail(session: session.id, name: session.actions.last(where: { $0.keyframe != nil })?.keyframe)
                .frame(width: 72, height: 45)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(DS.Font.rowTitleEmphasis)
                    .lineLimit(1)
                Text("\(session.actions.count) steps · \(session.started.formatted(date: .abbreviated, time: .shortened))")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

// MARK: - Session Replay

/// One session: the agent's steps beside the page as it changed. Scrub, play at a speed, or
/// step from action to action; the step list follows the playhead.
struct SessionReplayView: View {
    let session: ReplaySession
    @State private var player: ReplayPlayer?
    @State private var selected: Int?
    @State private var exported: ExportedTest?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.toolNavigation) private var navigation
    @Environment(WindowModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// The step at the playhead (its result is what the page shows).
    private var currentAction: Int? {
        guard let player, player.isReady, !player.isEmpty else { return selected }
        return session.actions.last { player.offset(of: $0) <= player.current + 1 }?.id ?? selected
    }

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 0) {
                    stage.frame(maxHeight: .infinity)
                    Hairline()
                    steps.frame(maxHeight: 280)
                }
            } else {
                HStack(spacing: 0) {
                    steps.frame(width: 320)
                    Hairline(.vertical)
                    stage
                }
            }
        }
        .background(DS.Palette.base)
        .toolChrome(session.displayTitle) { actions }
        .task(id: session.id) { await load() }
        .onDisappear { player?.stop() }
        .sheet(item: $exported) { test in PlaywrightTestSheet(test: test) }
        .confirmationDialog("Delete this replay?", isPresented: $confirmDelete) {
            Button("Delete Replay", role: .destructive) {
                ReplayStore.shared.delete(session.id)
                // Back to the list where it opened in place; else close the pushed screen.
                if let back = navigation?.back { back() } else { dismiss() }
            }
        }
    }

    private func load() async {
        guard player == nil else { return }
        let made = await ReplayPlayer(offline: session.imported)
        player = made
        let lines = ReplayStore.shared.eventLines(session.id)
        await made.load(events: "[" + lines.joined(separator: ",") + "]", size: CGSize(width: 800, height: 600))
        if made.isEmpty { selected = session.actions.first?.id }
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 0) {
            ZStack {
                if let player, player.isReady, !player.isEmpty {
                    GeometryReader { geo in
                        WebView(player.page)
                            .webViewBackForwardNavigationGestures(.disabled)
                            .webViewContentBackground(.hidden)
                            .allowsHitTesting(false)
                            .onChange(of: geo.size, initial: true) { _, size in player.resize(size) }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Recorded page")
                    .accessibilityIdentifier("replay-player")
                } else if let player, player.isEmpty {
                    keyframe
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            transport
        }
    }

    /// Sessions without page events show the picture taken after the step.
    private var keyframe: some View {
        let action = session.actions.first { $0.id == currentAction }
        return ReplayThumbnail(session: session.id, name: action?.keyframe, contentMode: .fit)
            .accessibilityIdentifier("replay-player")
    }

    private var transport: some View {
        HStack(spacing: DS.Space.m) {
            Button("Previous Step", systemImage: "backward.end.fill") { step(-1) }
                .toolShortcut(.leftArrow, modifiers: [])
                .accessibilityIdentifier("replay-step-back")
            Button(player?.isPlaying == true ? "Pause" : "Play", systemImage: player?.isPlaying == true ? "pause.fill" : "play.fill") {
                guard let player else { return }
                if player.isPlaying { player.pause() } else { player.play() }
            }
            .toolShortcut(.space, modifiers: [])
            .contentTransition(.symbolEffect(.replace))
            .disabled(player?.isEmpty != false)
            .accessibilityIdentifier("replay-play")
            Button("Next Step", systemImage: "forward.end.fill") { step(1) }
                .toolShortcut(.rightArrow, modifiers: [])
                .accessibilityIdentifier("replay-step-forward")
            scrubber
            Text(timeLabel)
                .font(DS.Font.meta)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize()
                .accessibilityIdentifier("replay-time")
            Menu {
                Picker("Speed", selection: Binding(get: { player?.speed ?? 1 }, set: { player?.speed = $0 })) {
                    ForEach([0.5, 1, 2, 4, 8], id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                }
            } label: {
                Text(Self.speedLabel(player?.speed ?? 1))
                    .font(DS.Font.meta.weight(.semibold))
                    .frame(minWidth: 28)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Speed")
            .accessibilityIdentifier("replay-speed")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bar)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .floatingCapsule(interactive: true)
        .padding([.horizontal, .bottom], DS.Space.l)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replay-transport")
        .accessibilityValue(currentAction.map { "step \($0 + 1)" } ?? "")
    }

    /// The playhead over the recording, with a tick at each step.
    private var scrubber: some View {
        let duration = max(player?.duration ?? 0, 1)
        return ZStack {
            GeometryReader { geo in
                ForEach(session.actions) { action in
                    Capsule()
                        .fill(action.succeeded ? DS.Palette.textTertiary : DS.Palette.error)
                        .frame(width: 2, height: 8)
                        .position(x: geo.size.width * (player?.offset(of: action) ?? 0) / duration, y: geo.size.height / 2)
                }
            }
            .allowsHitTesting(false)
            Slider(
                value: Binding(get: { player?.current ?? 0 }, set: { player?.seek($0) }),
                in: 0...duration)
                .accessibilityLabel("Playhead")
                .accessibilityIdentifier("replay-scrubber")
        }
        .frame(minWidth: 120, maxWidth: .infinity)
        .frame(height: 28)
        .disabled(player?.isEmpty != false)
    }

    private var timeLabel: String {
        guard let player, !player.isEmpty else { return "" }
        return "\(Self.clock(player.current)) / \(Self.clock(player.duration))"
    }

    static func clock(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func speedLabel(_ speed: Double) -> String {
        speed == 0.5 ? "½×" : "\(Int(speed))×"
    }

    // MARK: Steps

    private var steps: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(session.actions) { action in
                    Button { go(to: action) } label: {
                        ReplayStepRow(session: session.id, action: action, offset: player.map { $0.offset(of: action) })
                    }
                    .buttonStyle(.row(selected: action.id == currentAction))
                    .listRowInsets(EdgeInsets(top: 1, leading: DS.Space.s, bottom: 1, trailing: DS.Space.s))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .id(action.id)
                    .accessibilityIdentifier("replay-action-\(action.id)")
                    .accessibilityValue(action.id == currentAction ? "current" : "")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DS.Palette.sidebar)
            .onChange(of: currentAction) { _, id in
                guard let id else { return }
                withAnimation(DS.Motion.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func go(to action: ReplayAction) {
        selected = action.id
        player?.seek(player?.offset(of: action) ?? 0)
    }

    private func step(_ delta: Int) {
        let actions = session.actions
        guard !actions.isEmpty else { return }
        let index = currentAction.flatMap { id in actions.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + delta, 0), actions.count - 1) } ?? (delta > 0 ? 0 : actions.count - 1)
        player?.pause()
        go(to: actions[next])
    }

    // MARK: Toolbar

    @ViewBuilder private var actions: some View {
        ShareLink(
            item: ReplayFile(session: session.id),
            preview: SharePreview(session.displayTitle + "." + ReplayStore.fileExtension, image: Image(systemName: "play.rectangle"))
        ) {
            Label("Share Replay", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("replay-share")
        Menu("More", systemImage: "ellipsis") {
            Button("Export as Playwright Test", systemImage: "chevron.left.forwardslash.chevron.right") {
                exported = ExportedTest(name: ReplayPlaywright.fileName(for: session), text: ReplayPlaywright.test(for: session))
            }
            .accessibilityIdentifier("replay-export-playwright")
            if session.hostId != nil {
                Button("Replay in Browser", systemImage: "arrow.clockwise.circle") { replayInBrowser() }
                    .accessibilityIdentifier("replay-in-browser")
            }
            Divider()
            Button("Delete Replay", systemImage: "trash", role: .destructive) { confirmDelete = true }
        }
        .menuIndicator(.hidden)
        .accessibilityIdentifier("replay-more")
    }

    private func replayInBrowser() {
        dismiss()
        BrowserReplayRunner.run(session, in: model)
    }
}

/// One step: its picture, what it did and to what, and how it went.
private struct ReplayStepRow: View {
    let session: UUID
    let action: ReplayAction
    let offset: Double?

    var body: some View {
        HStack(spacing: DS.Space.gap10) {
            ReplayThumbnail(session: session, name: action.keyframe)
                .frame(width: 56, height: 35)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: Self.symbol(action.kind))
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 14)
                    Text(Self.title(action.kind))
                        .font(DS.Font.rowTitleEmphasis)
                    Spacer(minLength: 0)
                    if let offset {
                        Text("+" + SessionReplayView.clock(offset))
                            .font(DS.Font.meta)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: action.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(action.succeeded ? DS.Palette.done : DS.Palette.error)
                        .frame(width: 14)
                        .accessibilityLabel(action.succeeded ? "Done" : action.verdict)
                    Text(action.target.isEmpty ? action.verdict : action.target)
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
        .padding(.horizontal, DS.Space.xs)
        .contentShape(.rect)
        .help(action.verdict)
    }

    static func title(_ kind: String) -> String {
        switch kind {
        case "navigate": "Open"
        case "double_click": "Double-Click"
        case "scroll_to": "Scroll To"
        default: kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "navigate": "globe"
        case "click", "double_click": "cursorarrow.click"
        case "hover": "cursorarrow"
        case "type", "fill": "character.cursor.ibeam"
        case "press": "keyboard"
        case "scroll", "scroll_to": "arrow.up.and.down"
        case "drag": "hand.draw"
        default: "circle"
        }
    }
}

/// A step's picture, from the session's folder.
struct ReplayThumbnail: View {
    let session: UUID
    let name: String?
    var contentMode = ContentMode.fill
    @State private var image: Image?

    var body: some View {
        Rectangle()
            .fill(DS.Palette.raised)
            .overlay {
                if let image {
                    // Pages read from the top.
                    image.resizable().aspectRatio(contentMode: contentMode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentMode == .fill ? .top : .center)
                } else {
                    Image(systemName: "photo").foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .clipShape(.rect(cornerRadius: DS.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
            .task(id: name) {
                guard let name, let data = ReplayStore.shared.keyframe(name, session: session) else { image = nil; return }
                #if os(iOS)
                image = UIImage(data: data).map(Image.init(uiImage:))
                #else
                image = NSImage(data: data).map(Image.init(nsImage:))
                #endif
            }
    }
}

/// The exported test, to read, copy or share.
private struct PlaywrightTestSheet: View {
    let test: ExportedTest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(test.text)
                    .font(DS.Font.literalSmall)
                    .textSelection(.enabled)
                    .padding(DS.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("playwright-test-text")
            }
            .background(DS.Palette.base)
            .navigationTitle(test.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") { FilesPasteboard.copy(test.text) }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: test, preview: SharePreview(test.name)) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .macMinimumSize(width: 640, height: 480)
    }
}

// MARK: - Sharing

/// A session as its `.unreplay` file.
struct ReplayFile: Transferable {
    let session: UUID

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: ReplayStore.fileType) { file in
            let data = try await MainActor.run { try ReplayStore.shared.bundle(file.session) }
            let name = await MainActor.run { ReplayStore.shared.session(file.session)?.displayTitle } ?? "Session"
            let url = FileManager.default.temporaryDirectory.appending(path: Self.safe(name) + "." + ReplayStore.fileExtension)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    static func safe(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        return String(cleaned.prefix(80))
    }
}

/// A Playwright test, shared as a `.spec.ts` file.
struct ExportedTest: Identifiable, Transferable {
    var id: String { name }
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "ts", conformingTo: .sourceCode) ?? .plainText) { test in
            let url = FileManager.default.temporaryDirectory.appending(path: test.name)
            try Data(test.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
