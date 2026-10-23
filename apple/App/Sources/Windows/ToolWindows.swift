import DesignSystem
import SwiftUI

/// Files, Changes, Ports and Session Replays on the Mac: windows of their own beside the
/// terminal (Finder's, Xcode's), not sheets that block the window they came from. Each belongs
/// to the window that opened it and shows that window's host; asking again brings it forward.
struct ToolWindowRequest: Codable, Hashable {
    var route: String
    /// The opening window's `WindowModel.serial`.
    var window: Int

    static let sceneId = "tool"
}

extension SheetRoute {
    /// Browsing tools kept open beside the terminal: a window on the Mac, a sheet elsewhere.
    var opensInWindow: Bool {
        switch self {
        case .files, .diff, .browser, .replays: true
        default: false
        }
    }

    /// The window's title until its content names it.
    var toolTitle: String {
        switch self {
        case .files: "Files"
        case .diff: "Changes"
        case .browser: "Ports"
        case .replays: "Session Replays"
        default: ""
        }
    }
}

/// Whether a view is in a tool window: no Done button there (⌘W and the close button do).
extension EnvironmentValues {
    @Entry var isToolWindow = false
}

#if os(macOS)
/// A tool window's content for its owning window's model; closes when that window has gone.
struct ToolWindowRoot: View {
    let request: ToolWindowRequest
    @Environment(\.dismiss) private var dismiss

    private var model: WindowModel? {
        AppModel.shared.openWindows.first { $0.serial == request.window }
    }

    var body: some View {
        if let model, let route = SheetRoute(rawValue: request.route) {
            ThemedRoot {
                ToolWindowContent(route: route)
                    .environment(model)
                    .environment(model.app)
                    .environment(\.isToolWindow, true)
            }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}

/// One tool, sized for what it shows, on the window's seamless titlebar.
struct ToolWindowContent: View {
    let route: SheetRoute
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        content
            .navigationTitle(route.toolTitle)
            .frame(minWidth: minSize.width, minHeight: minSize.height)
            .background(theme.background.ignoresSafeArea())
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .files:
            NavigationStack {
                FilesBrowserView(
                    source: model.files,
                    onOpenInEditor: model.files.unavailableReason == nil ? { path in model.openEditor(path: path) } : nil,
                    onRevealInTerminal: { model.revealInTerminal($0) },
                    onInsertPath: { model.insertInTerminal($0) })
            }
        case .diff:
            NavigationStack { DiffReviewView(source: model.diffs) }
        case .browser:
            BrowserSheet()
        case .replays:
            SessionReplaysSheet(request: model.replayRequest)
        default:
            EmptyView()
        }
    }

    private var minSize: CGSize {
        switch route {
        case .files: CGSize(width: 520, height: 400)
        case .browser: CGSize(width: 640, height: 440)
        default: CGSize(width: 720, height: 480)
        }
    }
}
#endif
