import DesignSystem
import PaneLayout
import SwiftUI

/// A browsing tool in a window of its own on the Mac. Each belongs to the window that opened it
/// and shows that window's host; asking again brings it forward.
struct ToolWindowRequest: Codable, Hashable {
    var route: String
    /// The opening window's `WindowModel.serial`.
    var window: Int

    static let sceneId = "tool"
}

extension SheetRoute {
    /// The tool window's title until its content names it.
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

/// Tool windows show no Done button; ⌘W and the close button do that.
extension EnvironmentValues {
    @Entry var isToolWindow = false
}

#if os(macOS)
/// Closes when the owning window has gone.
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

struct ToolWindowContent: View {
    let route: SheetRoute
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        content
            .navigationTitle(route.toolTitle)
            .frame(minWidth: minSize.width, minHeight: minSize.height)
            .background(theme.background.ignoresSafeArea())
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    @ViewBuilder private var content: some View {
        if let tool = ToolMember.Tool(route: route) { ToolContent(tool: tool) }
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
