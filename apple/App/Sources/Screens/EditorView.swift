import DesignSystem
import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// VS Code for the window's project, in the app: the host runs `code serve-web` and the
/// workbench loads over a local forward. No licence prompt, no sign-in, no choice of editor —
/// it opens like a terminal does. The first run on a host installs VS Code's CLI there, which
/// takes a few seconds; that wait is shown as the steps it is, not as a spinner. While the editor
/// is up, every key (⌘P, ⌘⇧P, ⌘F, ⌘D …) goes to VS Code: the app's own shortcuts step aside.
struct EditorScreen: View {
    let source: any EditorSource
    var onClose: () -> Void

    @Environment(\.terminalTheme) private var theme
    @State private var page = EditorScreen.makePage()
    @State private var loadedURL: URL?
    @State private var phaseStarted = Date.now
    @State private var installedThisRun = false
    @State private var isWorkbenchVisible = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                WebView(page)
                    .opacity(isWorkbenchVisible ? 1 : 0)
                    .accessibilityIdentifier("editor-web")
                if !isWorkbenchVisible {
                    EditorProgress(
                        phase: source.phase, folder: source.folder, hostName: source.hostName,
                        installedThisRun: installedThisRun, since: phaseStarted,
                        retry: { Task { await source.open() } }, close: onClose)
                        .transition(.opacity)
                }
            }
            .animation(DS.Motion.panel, value: isWorkbenchVisible)
        }
        .background(theme.background.ignoresSafeArea())
        #if os(iOS)
        .onAppear {
            // The pane's key bar stays with the pane; the editor brings its own keyboard.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        #endif
        .task {
            if case .ready = source.phase {} else if source.phase.url == nil { await source.open() }
        }
        .onChange(of: source.phase, initial: true) { _, phase in
            phaseStarted = .now
            if phase == .installing { installedThisRun = true }
            if let url = phase.url, url != loadedURL {
                loadedURL = url
                page.load(URLRequest(url: url))
            }
            if case .failed = phase { isWorkbenchVisible = false }
        }
        .onChange(of: page.isLoading) { _, loading in
            guard !loading, loadedURL != nil, page.url != nil else { return }
            source.didLoad()
            isWorkbenchVisible = true
        }
        .onChange(of: source.pendingURL) { _, url in
            if let url { page.load(URLRequest(url: url)) }
        }
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
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.foreground.opacity(0.5))
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
                Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
                    .help("Reload the workbench")
            }
            Menu("More", systemImage: "ellipsis") {
                Button("Copy Folder Path", systemImage: "doc.on.doc") { EditorPasteboard.copy(source.folder) }
                Divider()
                Button("Stop Editor on \(source.hostName.nonEmpty ?? "Host")", systemImage: "stop.circle") {
                    Task {
                        await source.close(stopServer: true)
                        onClose()
                    }
                }
            }
            .menuIndicator(.hidden)
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
/// state and the seconds it has taken. Failures say why and offer Try Again.
private struct EditorProgress: View {
    let phase: EditorPhase
    let folder: String
    let hostName: String
    let installedThisRun: Bool
    let since: Date
    let retry: () -> Void
    let close: () -> Void

    @Environment(\.terminalTheme) private var theme

    private enum Step: Int, CaseIterable {
        case install, start, open
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
        return phase != .idle
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
        case .loading: "Almost there: the workbench is loading."
        case .checking, .idle: "Connecting to \(hostName)."
        default: ""
        }
    }

    private var steps: [Step] { installedThisRun ? Step.allCases : [.start, .open] }

    private func state(_ step: Step) -> StepState {
        let current: Step
        switch phase {
        case .idle, .checking: return step == .install || step == .start ? (step == steps.first ? .active : .pending) : .pending
        case .installing: current = .install
        case .starting: current = .start
        case .loading, .ready: current = .open
        case .failed: return .pending
        }
        if step.rawValue < current.rawValue { return .done }
        return step == current ? .active : .pending
    }

    private func label(_ step: Step) -> String {
        switch step {
        case .install: "Set up VS Code on \(hostName)"
        case .start: "Start the editor"
        case .open: "Open the workbench"
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
            EditorScreen(source: model.editor) { model.closeEditor() }
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
    /// Opens VS Code for the window's project, or a file in it at a line.
    func openEditor(path: String? = nil, line: Int? = nil, column: Int? = nil) {
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
