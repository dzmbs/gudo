import DesignSystem
import PaneLayout
import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// VS Code in a pane: the host runs `code serve-web` for the pane's folder and the workbench
/// loads over a local forward; a VS Code Remote Tunnel through vscode.dev is the opt-in alternative.
// Microsoft's licence terms are the user's own acceptance, asked once per host.
// The web view belongs to `EditorPane`, not to this view, so a tab switch doesn't reload the
// workbench. While focused, every key goes to VS Code except `WorkspaceAction.passesEditor`.
struct EditorPaneView: View {
    let pane: EditorPane
    /// Beside other panes: a slimmer bar, dimmed while unfocused.
    var isSplit = false
    var isFocused = true
    var focus: () -> Void = {}
    var onClose: () -> Void
    /// "Stop Editor on <host>": ends the server there, then closes the pane.
    var onStop: () -> Void
    /// Mac: opens the folder in desktop VS Code (nil when it is not installed).
    var openDesktop: (() -> Void)?
    /// A shortcut that leads out of VS Code, pressed while the web view has the keyboard.
    var performShortcut: (WorkspaceAction) -> Void = { _ in }
    var showsBar = true
    /// Nil where full screen isn't available.
    var toggleFullScreen: (() -> Void)?

    @Environment(\.terminalTheme) private var theme
    @Environment(\.openURL) private var openURL
    @AppStorage(TerminalPreferences.Key.unfocusedSplitOpacity) private var unfocusedOpacity = TerminalPreferences.Default.unfocusedSplitOpacity

    private var source: any EditorSource { pane.source }
    /// The editor's own commands in the bar, which has no room for the host's name.
    private var isPhone: Bool { EditorPhoneLayout.isPhone && !isSplit }

    var body: some View {
        @Bindable var pane = pane
        VStack(spacing: 0) {
            if showsBar { bar }
            ZStack {
                if let browser = pane.browser {
                    EditorWebHost(webView: browser.webView, perform: performShortcut, onShown: { shown in
                        if pane.isWebViewShown != shown { pane.isWebViewShown = shown }
                        if shown, isFocused { pane.takeKeyboard() }
                    }, onResize: { size in
                        browser.fit(to: size)
                    })
                    .opacity(pane.isWorkbenchVisible ? 1 : 0)
                    .accessibilityIdentifier("editor-web")
                    .accessibilityValue(pane.isWebViewShown ? "showing" : "empty")
                }
                if !pane.isWorkbenchVisible {
                    if let caption = pane.lastPictureCaption {
                        lastPicture(caption)
                    } else {
                        EditorProgress(
                            phase: source.phase, mode: source.mode, folder: source.folder, hostName: source.hostName,
                            installedThisRun: pane.installedThisRun, since: pane.phaseStarted,
                            retry: { Task { await source.open() } },
                            useTunnel: source.mode == .server ? { pane.isTunnelOfferShown = true } : nil,
                            close: onClose)
                            .transition(.opacity)
                    }
                }
            }
            .animation(DS.Motion.panel, value: pane.isWorkbenchVisible)
            .sheet(item: Binding(get: { pane.browser?.popup }, set: { pane.browser?.popup = $0 })) { popup in
                EditorPopupSheet(popup: popup) { pane.browser?.popup = nil }
            }
            .sheet(isPresented: $pane.isTunnelOfferShown) {
                EditorTunnelOfferSheet(hostName: source.hostName) { account in
                    pane.isTunnelOfferShown = false
                    pane.restart()
                    Task { await source.openTunnel(account: account) }
                } cancel: {
                    pane.isTunnelOfferShown = false
                    // Opened just for the tunnel: nothing else to show.
                    if source.phase == .idle { onClose() }
                }
            }
        }
        .overlay {
            if isSplit && !isFocused {
                UnfocusedDim(unfocusedSplitOpacity: unfocusedOpacity, fill: theme.background)
            }
        }
        .background(theme.background, ignoresSafeAreaEdges: [])
        .hostLinkOverlay(groupId: pane.member.hostId, enabled: !LaunchOptions.mock)
        .sheet(isPresented: licenceShown) {
            EditorLicenceSheet(hostName: source.hostName) {
                Task { await source.acceptLicence() }
            } cancel: {
                source.declineLicence()
                onClose()
            }
        }
        .onAppear {
            pane.onTouch = focus
            pane.appeared()
            if isFocused { pane.takeKeyboard() }
        }
        .onDisappear { pane.disappeared() }
        .onChange(of: isFocused) { _, focused in
            if focused { pane.takeKeyboard() } else { pane.releaseKeyboard() }
        }
        .onChange(of: pane.isWorkbenchVisible) { _, visible in
            if visible, isFocused { pane.takeKeyboard() }
        }
        .task {
            if pane.offerTunnelFirst, source.mode == .server {
                pane.offerTunnelFirst = false
                pane.isTunnelOfferShown = true
            } else if source.phase == .needsLicence {
                // Accepted for this host in another editor meanwhile.
                await source.resumeIfAccepted()
            } else if source.phase.url == nil, source.phase != .needsLicence {
                await source.open()
            }
        }
        .onChange(of: source.phase, initial: true) { _, phase in
            pane.phaseChanged(phase)
        }
        .onChange(of: source.pendingURL, initial: true) { _, url in
            // A file asked for before this view was up still opens; each address once.
            if let url { pane.load(pending: url) }
        }
        .background {
            // The device-code sheet hangs off its own view: one sheet per view.
            Color.clear.sheet(isPresented: signingInShown) {
                if case .signingIn(let login) = source.phase {
                    EditorDeviceCodeSheet(login: login, hostName: source.hostName, cancel: onStop)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-pane-\(pane.member.folderName)")
    }

    // Only the focused pane shows it, so two editors waiting on the licence never ask at once.
    private var licenceShown: Binding<Bool> {
        Binding(get: { isFocused && source.phase == .needsLicence }, set: { _ in })
    }

    private var signingInShown: Binding<Bool> {
        Binding(get: {
            if case .signingIn = source.phase { return isFocused }
            return false
        }, set: { _ in })
    }

    /// The editor's last picture until the workbench loads.
    private func lastPicture(_ caption: String) -> some View {
        ZStack {
            theme.background
            if let data = pane.snapshot, let image = Self.image(data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .opacity(0.55)
            }
            HStack(spacing: DS.Space.s) {
                Spinner(color: DS.Palette.accent, lineWidth: 2)
                    .frame(width: 14, height: 14)
                Text(caption)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.text)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(DS.Palette.raised, in: .capsule)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor-resuming")
    }

    private static func image(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }

    private var bar: some View {
        HStack(spacing: isSplit ? DS.Space.xs + 2 : DS.Space.s) {
            Button("Close Editor", systemImage: "xmark", action: onClose)
                .help("Close the editor (⌘W; it keeps running on the host)")
                .accessibilityIdentifier("editor-close")
            if !isPhone {
                Image(systemName: source.mode == .tunnel ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .help(source.mode == .tunnel ? "Through a VS Code Remote Tunnel (vscode.dev)" : "VS Code")
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(verbatim: pane.member.folderName)
                    .font(isSplit ? .caption.weight(isFocused ? .semibold : .regular) : .callout.weight(.medium))
                    .foregroundStyle((isFocused ? DS.Palette.text : DS.Palette.textSecondary))
                if !isPhone {
                    Text(verbatim: source.hostName)
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: DS.Space.s)
            if pane.isWorkbenchVisible {
                if isPhone {
                    ForEach(EditorPhoneLayout.Command.allCases, id: \.self) { command in
                        Button(command.title, systemImage: command.systemImage) { pane.browser?.run(command) }
                            .accessibilityIdentifier("editor-\(command.rawValue)")
                    }
                } else {
                    Button("Reload", systemImage: "arrow.clockwise") { pane.browser?.reload() }
                        .help("Reload the workbench")
                }
            }
            if let toggleFullScreen {
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: toggleFullScreen)
                    .help("Full Screen Editor (⌃⌘F)")
                    .accessibilityIdentifier("editor-full-screen")
            }
            Menu("More", systemImage: "ellipsis") {
                if isPhone, pane.isWorkbenchVisible, let browser = pane.browser {
                    Button("Zoom In", systemImage: "plus.magnifyingglass") { browser.zoom(by: 1) }
                        .disabled(!browser.canZoom.in)
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") { browser.zoom(by: -1) }
                        .disabled(!browser.canZoom.out)
                    Button("Fit to Screen", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { browser.zoom(by: 0) }
                    Button("Reload", systemImage: "arrow.clockwise") { browser.reload() }
                    Divider()
                }
                Button("Copy Folder Path", systemImage: "doc.on.doc") { EditorPasteboard.copy(pane.member.folder) }
                #if os(macOS)
                if source.mode == .tunnel, let uri = source.tunnelDesktopURI {
                    Button("Open in Desktop VS Code", systemImage: "macwindow") { openURL(uri) }
                } else if let openDesktop {
                    Button("Open in Desktop VS Code", systemImage: "macwindow", action: openDesktop)
                }
                #endif
                Divider()
                if source.mode == .server {
                    Button("Open Through a Remote Tunnel…", systemImage: "point.3.connected.trianglepath.dotted") {
                        pane.isTunnelOfferShown = true
                    }
                    .accessibilityIdentifier("editor-use-tunnel")
                    Button("Stop Editor on \(source.hostName.nonEmpty ?? "Host")", systemImage: "stop.circle", action: onStop)
                } else {
                    Button("Stop Tunnel on \(source.hostName.nonEmpty ?? "Host")", systemImage: "stop.circle", action: onStop)
                }
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("editor-more")
        }
        .font(isSplit ? .caption : nil)
        .labelStyle(.iconOnly)
        .buttonStyle(.bar)
        .padding(.leading, isSplit ? DS.Space.xs : DS.Space.m)
        .padding(.trailing, isSplit ? DS.Space.xxs : DS.Space.m)
        .frame(height: isSplit ? 24 : DS.Size.tabBar)
        .background(theme.background)
        .overlay(alignment: .bottom) { theme.splitDivider.frame(height: 1) }
        .contentShape(.rect)
        .onTapGesture { if !isFocused { focus() } }
    }
}

/// The wait for the editor as steps with elapsed seconds, or the failure with Try Again.
private struct EditorProgress: View {
    let phase: EditorPhase
    let mode: EditorMode
    let folder: String
    let hostName: String
    let installedThisRun: Bool
    let since: Date
    let retry: () -> Void
    let useTunnel: (() -> Void)?
    let close: () -> Void

    @Environment(\.terminalTheme) private var theme

    private enum Step: Int, CaseIterable {
        case install, start, tunnel, open
    }

    private enum StepState {
        case pending, active, done
    }

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            VStack(spacing: DS.Space.s) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(DS.Palette.text)
                    .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Palette.text)
                    .multilineTextAlignment(.center)
                Text(verbatim: folder)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if case .failed(let reason) = phase {
                VStack(spacing: DS.Space.m) {
                    Text(reason)
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(DS.Palette.text)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .textSelection(.enabled)
                    HStack(spacing: DS.Space.s) {
                        Button("Close", action: close)
                            .buttonStyle(.glass)
                        Button("Try Again", action: retry)
                            .buttonStyle(.primaryGlass)
                            .accessibilityIdentifier("editor-retry")
                    }
                    if let useTunnel {
                        Button("Open Through a Remote Tunnel Instead…", action: useTunnel)
                            .buttonStyle(.plain)
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .accessibilityIdentifier("editor-failed-tunnel")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(steps, id: \.self) { step in
                        row(step)
                    }
                }
                .padding(DS.Space.l)
                .frame(width: 340)
                .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.panel))
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .contentTransition(.opacity)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .animation(DS.Motion.snappy, value: phase)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-progress")
    }

    private var isWorking: Bool {
        if case .failed = phase { return false }
        return phase != .idle && phase != .needsLicence
    }

    private var title: String {
        if case .failed = phase { return "VS Code Didn't Open" }
        let name = (folder as NSString).lastPathComponent
        if folder == "~" || name.isEmpty { return "Opening VS Code" }
        return "Opening \(name) in VS Code"
    }

    private var footnote: String {
        switch phase {
        case .installing: "First time on \(hostName): VS Code is being set up there. It takes about 15 seconds, once."
        case .starting: "Starting VS Code on \(hostName) in this folder."
        case .loading: mode == .tunnel ? "Almost there: vscode.dev is loading." : "Almost there: the workbench is loading."
        case .checking, .idle: "Connecting to \(hostName)."
        case .needsLicence: "Microsoft’s terms come first. Nothing is set up on \(hostName) until you accept them."
        case .connectingTunnel: "Starting a VS Code Remote Tunnel on \(hostName)."
        case .signingIn: "Waiting for you to sign in."
        default: ""
        }
    }

    private var steps: [Step] {
        if mode == .tunnel { return [.tunnel, .open] }
        return installedThisRun ? [.install, .start, .open] : [.start, .open]
    }

    private func state(_ step: Step) -> StepState {
        let current: Step
        switch phase {
        case .idle, .checking: return step == steps.first ? .active : .pending
        case .needsLicence, .failed: return .pending
        case .installing: current = .install
        case .starting: current = .start
        case .connectingTunnel, .signingIn: current = .tunnel
        case .loading, .ready: current = .open
        }
        if step.rawValue < current.rawValue { return .done }
        return step == current ? .active : .pending
    }

    private func label(_ step: Step) -> String {
        switch step {
        case .install: "Set up VS Code on \(hostName)"
        case .start: "Start the editor"
        case .tunnel: "Connect the tunnel on \(hostName)"
        case .open: mode == .tunnel ? "Open vscode.dev" : "Open the workbench"
        }
    }

    private func row(_ step: Step) -> some View {
        let state = state(step)
        return HStack(spacing: DS.Space.m) {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.Palette.done)
                        .transition(.scale.combined(with: .opacity))
                case .active:
                    Spinner(color: DS.Palette.accent, lineWidth: 2)
                        .frame(width: 14, height: 14)
                case .pending:
                    Circle()
                        .strokeBorder(DS.Palette.border, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 18, height: 18)
            Text(label(step))
                .font(DS.Font.rowTitle)
                .foregroundStyle((state == .pending ? DS.Palette.textTertiary : DS.Palette.text))
            Spacer()
            if state == .active {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(since)))) s")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .contentTransition(.numericText())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An editor leaf of a split tree, wired to the window.
struct EditorLeafView: View {
    let member: EditorMember
    let isSplit: Bool
    let isFocused: Bool
    let focus: () -> Void
    var isFullScreen = false
    @Environment(WindowModel.self) private var model

    var body: some View {
        EditorPaneView(
            pane: model.editors.pane(for: member), isSplit: isSplit, isFocused: isFocused, focus: focus,
            onClose: { model.closeEditor(member.id) },
            onStop: { model.closeEditor(member.id, stopServer: true) },
            openDesktop: desktop,
            performShortcut: { action in
                if let workspace = model.workspace {
                    action.perform(on: workspace, window: model)
                } else if action == .returnToTerminal {
                    model.returnToTerminal()
                } else if action == .fullScreenEditor {
                    model.toggleEditorFullScreen()
                }
            },
            showsBar: !isFullScreen,
            toggleFullScreen: {
                focus()
                model.toggleEditorFullScreen()
            })
            // One web view per editor: never reuse another editor's view.
            .id(member.id)
    }

    private var desktop: (() -> Void)? {
        #if os(macOS)
        guard DesktopVSCode.isInstalled else { return nil }
        return { model.openInDesktopVSCode(member) }
        #else
        return nil
        #endif
    }
}

private enum EditorPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

/// An editor pane's web view in SwiftUI.
// On iPad the container answers `WorkspaceAction.passesEditor` shortcuts from the responder chain:
// otherwise the system's ⌘W (Close Window) wins over the app's menu item while the web view has
// the keyboard. On the Mac, `WorkspaceShortcuts` does the same.
struct EditorWebHost: View {
    let webView: WKWebView
    var perform: (WorkspaceAction) -> Void
    /// Whether the web view is on screen (in this or a newer view of the same editor).
    var onShown: (Bool) -> Void = { _ in }
    /// iOS: the pane's size without the keyboard, whenever it lays out.
    var onResize: ((CGSize) -> Void)?

    var body: some View {
        #if canImport(UIKit)
        Representable(webView: webView, perform: perform, onShown: onShown, onResize: onResize)
        #else
        Representable(webView: webView, perform: perform, onShown: onShown)
        #endif
    }

    #if canImport(UIKit)
    private struct Representable: UIViewRepresentable {
        let webView: WKWebView
        let perform: (WorkspaceAction) -> Void
        let onShown: (Bool) -> Void

        let onResize: ((CGSize) -> Void)?

        func makeUIView(context: Context) -> Container {
            let container = Container()
            container.perform = perform
            container.onShown = onShown
            container.onResize = onResize
            container.claim(webView)
            return container
        }

        func updateUIView(_ container: Container, context: Context) {
            container.perform = perform
            container.onShown = onShown
            container.onResize = onResize
            container.show(webView)
            container.setNeedsLayout()
        }
    }
    #else
    private struct Representable: NSViewRepresentable {
        let webView: WKWebView
        let perform: (WorkspaceAction) -> Void
        let onShown: (Bool) -> Void

        func makeNSView(context: Context) -> Container {
            let container = Container()
            container.onShown = onShown
            container.claim(webView)
            return container
        }

        func updateNSView(_ container: Container, context: Context) {
            container.onShown = onShown
            container.show(webView)
        }
    }
    #endif

    /// Holds the editor's one web view.
    // Several containers can exist for it at once (full screen and back, a tab switch
    // mid-transition): the newest shows it, one on its way out never takes it back, and one
    // leaving the window hands it to one still there.
    final class Container: PlatformView {
        private static let owners = NSMapTable<WKWebView, Container>.weakToWeakObjects()
        private static let holders = NSMapTable<WKWebView, NSHashTable<Container>>.weakToStrongObjects()
        private weak var webView: WKWebView?

        static func owner(of webView: WKWebView) -> Container? { owners.object(forKey: webView) }

        func claim(_ webView: WKWebView) {
            if self.webView !== webView {
                self.webView = webView
                let containers = Self.holders.object(forKey: webView) ?? .weakObjects()
                containers.add(self)
                Self.holders.setObject(containers, forKey: webView)
            }
            Self.owners.setObject(self, forKey: webView)
            attach(webView)
        }

        func show(_ webView: WKWebView) {
            if self.webView !== webView || Self.owner(of: webView) == nil {
                claim(webView)
            } else if Self.owner(of: webView) === self {
                attach(webView)
            }
        }

        private func attach(_ webView: WKWebView) {
            guard webView.superview !== self else { return }
            webView.removeFromSuperview()
            webView.frame = bounds
            #if canImport(UIKit)
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            #else
            webView.autoresizingMask = [.width, .height]
            #endif
            addSubview(webView)
            report()
        }

        // A move resigns the keyboard, so the pane needs to hear when it is back on screen.
        var onShown: ((Bool) -> Void)?

        private func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let webView = self.webView else { return }
                self.onShown?((webView.superview as? Container)?.window != nil)
            }
        }

        #if canImport(UIKit)
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged()
        }
        #else
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged()
        }
        #endif

        private func windowChanged() {
            guard let webView else { return }
            defer { report() }
            if window != nil {
                if Self.owner(of: webView)?.window == nil { claim(webView) }
            } else if Self.owner(of: webView) === self,
                      let other = Self.holders.object(forKey: webView)?.allObjects.first(where: { $0 !== self && $0.window != nil }) {
                other.claim(webView)
            }
        }

        #if canImport(UIKit)
        var onResize: ((CGSize) -> Void)?
        /// The pane's height without the keyboard, so showing it never rescales the workbench.
        private var fullHeight: (width: CGFloat, height: CGFloat) = (0, 0)

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let webView, webView.superview === self, bounds.width > 0 else { return }
            if fullHeight.width != bounds.width { fullHeight = (bounds.width, 0) }
            fullHeight.height = max(fullHeight.height, bounds.height)
            onResize?(CGSize(width: bounds.width, height: fullHeight.height))
        }

        static let actions = WorkspaceAction.allShortcutActions.filter(\.passesEditor)
        var perform: ((WorkspaceAction) -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            Self.actions.map { action in
                let command = UIKeyCommand(
                    input: action.shortcut.key.uiKeyInput, modifierFlags: action.shortcut.modifiers.uiKeyModifierFlags,
                    action: #selector(passEditorKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }

        @objc private func passEditorKey(_ command: UIKeyCommand) {
            guard let action = Self.actions.first(where: {
                $0.shortcut.key.uiKeyInput == command.input && $0.shortcut.modifiers.uiKeyModifierFlags == command.modifierFlags
            }) else { return }
            EditorPane.log.info("editor key passes to the app: \(action.title, privacy: .public)")
            perform?(action)
        }
        #endif
    }
}
