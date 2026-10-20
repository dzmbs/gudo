import DesignSystem
import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// VS Code for the window's project, in the app: the host runs `code serve-web` and the
/// workbench loads over a local forward. No sign-in, no choice of editor — it opens like a
/// terminal does. The first time on a host, Microsoft's licence terms come up once (the user's
/// own acceptance, kept per host); the first run then installs VS Code's CLI there, which takes a
/// few seconds, shown as the steps it is, not as a spinner. A VS Code Remote Tunnel through
/// vscode.dev is the opt-in alternative (More menu, or when the editor cannot start): it signs
/// in with the user's own account by device code. While the editor is up, every key (⌘P, ⌘⇧P,
/// ⌘F, ⌘D …) goes to VS Code: the app's own shortcuts step aside.
struct EditorScreen: View {
    let source: any EditorSource
    var onClose: () -> Void
    /// Mac: opens the folder in desktop VS Code instead (nil when it is not installed).
    var openDesktop: (() -> Void)?
    /// Opened from "Open VS Code Through a Remote Tunnel…": ask that first.
    var offerTunnelFirst = false

    @Environment(\.terminalTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var page = EditorScreen.makePage()
    @State private var browser = TunnelBrowser()
    @State private var loadedURL: URL?
    @State private var phaseStarted = Date.now
    @State private var installedThisRun = false
    @State private var isWorkbenchVisible = false
    @State private var isTunnelOfferShown = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                if source.mode == .tunnel {
                    WebViewHost(webView: browser.webView)
                        .opacity(isWorkbenchVisible ? 1 : 0)
                        .accessibilityIdentifier("editor-web")
                } else {
                    WebView(page)
                        .opacity(isWorkbenchVisible ? 1 : 0)
                        .accessibilityIdentifier("editor-web")
                }
                if !isWorkbenchVisible {
                    EditorProgress(
                        phase: source.phase, mode: source.mode, folder: source.folder, hostName: source.hostName,
                        installedThisRun: installedThisRun, since: phaseStarted,
                        retry: { Task { await source.open() } },
                        useTunnel: source.mode == .server ? { isTunnelOfferShown = true } : nil,
                        close: onClose)
                        .transition(.opacity)
                }
            }
            .animation(DS.Motion.panel, value: isWorkbenchVisible)
            .sheet(item: $browser.popup) { popup in
                EditorPopupSheet(popup: popup) { browser.popup = nil }
            }
            .sheet(isPresented: $isTunnelOfferShown) {
                EditorTunnelOfferSheet(hostName: source.hostName) { account in
                    isTunnelOfferShown = false
                    isWorkbenchVisible = false
                    loadedURL = nil
                    Task { await source.openTunnel(account: account) }
                } cancel: {
                    isTunnelOfferShown = false
                    // Opened just for the tunnel: nothing else to show.
                    if offerTunnelFirst, source.phase == .idle { onClose() }
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .sheet(isPresented: licenceShown) {
            EditorLicenceSheet(hostName: source.hostName) {
                Task { await source.acceptLicence() }
            } cancel: {
                source.declineLicence()
                onClose()
            }
        }
        #if os(iOS)
        .onAppear {
            // The pane's key bar stays with the pane; the editor brings its own keyboard.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        #endif
        .task {
            browser.onLoad = { [source] in
                guard source.mode == .tunnel, loadedURL != nil else { return }
                source.didLoad()
                isWorkbenchVisible = true
            }
            if offerTunnelFirst, source.mode == .server {
                isTunnelOfferShown = true
            } else if case .ready = source.phase {} else if source.phase.url == nil {
                await source.open()
            }
        }
        .onChange(of: source.phase, initial: true) { _, phase in
            phaseStarted = .now
            if phase == .installing { installedThisRun = true }
            if let url = phase.url, url != loadedURL {
                loadedURL = url
                if source.mode == .tunnel {
                    browser.load(url)
                } else {
                    page.load(URLRequest(url: url))
                }
            }
            if phase.url == nil { isWorkbenchVisible = false }
        }
        .onChange(of: page.isLoading) { _, loading in
            guard source.mode == .server, !loading, loadedURL != nil, page.url != nil else { return }
            source.didLoad()
            isWorkbenchVisible = true
        }
        .onChange(of: source.pendingURL) { _, url in
            guard let url else { return }
            if source.mode == .tunnel { browser.load(url) } else { page.load(URLRequest(url: url)) }
        }
        .background {
            // The device-code sheet hangs off its own view: one sheet per view.
            Color.clear.sheet(isPresented: signingInShown) {
                if case .signingIn(let login) = source.phase {
                    EditorDeviceCodeSheet(login: login, hostName: source.hostName) {
                        Task {
                            await source.close(stopServer: true)
                            onClose()
                        }
                    }
                }
            }
        }
    }

    private var licenceShown: Binding<Bool> {
        Binding(get: { source.phase == .needsLicence }, set: { _ in })
    }

    private var signingInShown: Binding<Bool> {
        Binding(get: {
            if case .signingIn = source.phase { return true }
            return false
        }, set: { _ in })
    }

    static func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        // The workbench keeps its state (open editors, settings) like a desktop window.
        configuration.websiteDataStore = .default()
        return WebPage(configuration: configuration)
    }

    /// A 36 pt strip on the terminal background: close, where, reload, more.
    private var bar: some View {
        HStack(spacing: DS.Space.s) {
            Button("Close Editor", systemImage: "xmark", action: onClose)
                .help("Close the editor (it keeps running on the host)")
                .accessibilityIdentifier("editor-close")
            Image(systemName: source.mode == .tunnel ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.foreground.opacity(0.5))
                .help(source.mode == .tunnel ? "Through a VS Code Remote Tunnel (vscode.dev)" : "")
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(verbatim: (source.folder as NSString).lastPathComponent.nonEmpty ?? source.folder)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.foreground)
                Text(verbatim: source.hostName)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(theme.foreground.opacity(0.5))
            }
            .lineLimit(1)
            Spacer(minLength: DS.Space.s)
            if isWorkbenchVisible {
                Button("Reload", systemImage: "arrow.clockwise") {
                    if source.mode == .tunnel { browser.reload() } else { page.reload() }
                }
                .help("Reload the workbench")
            }
            Menu("More", systemImage: "ellipsis") {
                Button("Copy Folder Path", systemImage: "doc.on.doc") { EditorPasteboard.copy(source.folder) }
                #if os(macOS)
                if source.mode == .tunnel, let uri = source.tunnelDesktopURI {
                    Button("Open in VS Code", systemImage: "macwindow") { openURL(uri) }
                } else if let openDesktop {
                    Button("Open in VS Code", systemImage: "macwindow", action: openDesktop)
                }
                #endif
                Divider()
                if source.mode == .server {
                    Button("Open Through a Remote Tunnel…", systemImage: "point.3.connected.trianglepath.dotted") {
                        isTunnelOfferShown = true
                    }
                    .accessibilityIdentifier("editor-use-tunnel")
                    Button("Stop Editor on \(source.hostName.nonEmpty ?? "Host")", systemImage: "stop.circle") {
                        Task {
                            await source.close(stopServer: true)
                            onClose()
                        }
                    }
                } else {
                    Button("Stop Tunnel on \(source.hostName.nonEmpty ?? "Host")", systemImage: "stop.circle") {
                        Task {
                            await source.close(stopServer: true)
                            onClose()
                        }
                    }
                }
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("editor-more")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bar)
        .padding(.horizontal, DS.Space.m)
        .frame(height: DS.Size.tabBar)
        .background(theme.background)
        .overlay(alignment: .bottom) { theme.splitDivider.frame(height: 1) }
    }
}

/// The wait for the editor as steps: install (first run only), start, open; each with its
/// state and the seconds it has taken. Failures say why and offer Try Again (and the Remote
/// Tunnel, when the default path is the one that failed).
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
                    .foregroundStyle(theme.foreground.opacity(0.85))
                    .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(theme.foreground)
                    .multilineTextAlignment(.center)
                Text(verbatim: folder)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(theme.foreground.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if case .failed(let reason) = phase {
                VStack(spacing: DS.Space.m) {
                    Text(reason)
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(theme.foreground.opacity(0.75))
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
                            .foregroundStyle(theme.foreground.opacity(0.6))
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
                .background(theme.surface(0.10), in: .rect(cornerRadius: DS.Radius.panel))
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(theme.foreground.opacity(0.5))
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
                        .strokeBorder(theme.foreground.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 18, height: 18)
            Text(label(step))
                .font(DS.Font.rowTitle)
                .foregroundStyle(theme.foreground.opacity(state == .pending ? 0.45 : 1))
            Spacer()
            if state == .active {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(since)))) s")
                        .font(DS.Font.meta)
                        .foregroundStyle(theme.foreground.opacity(0.5))
                        .contentTransition(.numericText())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Presents the editor: full screen on iPhone and iPad (the web view gets the whole keyboard),
/// a large sheet on the Mac.
struct EditorPresentation: ViewModifier {
    @Bindable var model: WindowModel

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $model.isEditorShown) { screen }
        #else
        content.sheet(isPresented: $model.isEditorShown) {
            screen.frame(minWidth: 1000, idealWidth: 1280, minHeight: 680, idealHeight: 820)
        }
        #endif
    }

    private var screen: some View {
        ThemedRoot {
            EditorScreen(
                source: model.editor, onClose: { model.closeEditor() }, openDesktop: model.desktopEditorAction,
                offerTunnelFirst: model.editorTunnelOffer)
                .environment(model)
        }
    }
}

extension View {
    /// The editor's full-screen presentation for a window (`WindowModel.isEditorShown`).
    func editorPresentation(_ model: WindowModel) -> some View {
        modifier(EditorPresentation(model: model))
    }
}

extension WindowModel {
    /// Opens VS Code for the window's project, or a file in it at a line. On the Mac, desktop VS
    /// Code (Remote - SSH over our forward) when it is installed, else the in-app editor.
    func openEditor(path: String? = nil, line: Int? = nil, column: Int? = nil) {
        #if os(macOS)
        if !LaunchOptions.mock, DesktopVSCode.isInstalled, let context = HostContext.resolve(app: app, window: self) {
            sheet = nil
            Task { @MainActor in
                let sshUser = app.hosts.record(context.hostId)?.ssh?.user
                guard let reason = await DesktopVSCode.open(context: context, sshUser: sshUser, path: path, line: line, column: column) else { return }
                DesktopVSCode.log.info("desktop VS Code unavailable, in-app editor: \(reason, privacy: .public)")
                openEditorInApp(path: path, line: line, column: column)
            }
            return
        }
        #endif
        openEditorInApp(path: path, line: line, column: column)
    }

    /// Mac: the in-app editor's "Open in VS Code" (nil when desktop VS Code is not installed).
    var desktopEditorAction: (() -> Void)? {
        #if os(macOS)
        guard DesktopVSCode.isInstalled else { return nil }
        return { [weak self] in
            guard let self, let context = HostContext.resolve(app: app, window: self) else { return }
            Task { @MainActor in
                let sshUser = self.app.hosts.record(context.hostId)?.ssh?.user
                if let reason = await DesktopVSCode.open(context: context, sshUser: sshUser, path: nil, line: nil, column: nil) {
                    self.toasts.show(Toast(reason, systemImage: "exclamationmark.triangle"))
                } else {
                    self.closeEditor()
                }
            }
        }
        #else
        return nil
        #endif
    }

    /// Palette commands beside "Open in VS Code": the Remote Tunnel, and on the Mac the in-app editor.
    var editorPaletteExtras: [(String, String, String, [String]?, () -> Void)] {
        var extras: [(String, String, String, [String]?, () -> Void)] = [
            ("editor-tunnel", "Open VS Code Through a Remote Tunnel…", "point.3.connected.trianglepath.dotted", nil, { [weak self] in
                self?.openEditorInApp(tunnelOffer: true)
            }),
        ]
        #if os(macOS)
        if DesktopVSCode.isInstalled {
            extras.append(("editor-in-app", "Open VS Code in the App", "macwindow.on.rectangle", nil, { [weak self] in
                self?.openEditorInApp()
            }))
        }
        #endif
        return extras
    }

    /// The in-app editor (`serve-web` or vscode.dev in a web view), on every platform.
    /// `tunnelOffer` brings up the Remote Tunnel's sheet first.
    func openEditorInApp(tunnelOffer: Bool) {
        editorTunnelOffer = tunnelOffer
        openEditorInApp()
    }

    /// The in-app editor (`serve-web` or vscode.dev in a web view), on every platform.
    func openEditorInApp(path: String? = nil, line: Int? = nil, column: Int? = nil) {
        let wasShowingSheet = sheet != nil
        sheet = nil
        Task { @MainActor in
            // A full-screen cover cannot come up while a sheet is still going away.
            if wasShowingSheet { try? await Task.sleep(for: .milliseconds(450)) }
            isEditorShown = true
            if let path {
                await editor.open(path: path, line: line, column: column)
            }
        }
    }

    /// Leaves the editor; the server keeps running on the host so reopening is instant.
    func closeEditor() {
        isEditorShown = false
        editorTunnelOffer = false
        Task { await editor.close(stopServer: false) }
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
