import DesignSystem
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The sheets of the developer-workflow screens (New Agent, Links, Diff, Files, Browser, and the
/// editor when a fixture asks for it as a sheet), with what each one opens wired to the window.
struct ToolSheet: View {
    let route: SheetRoute
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        content
            #if os(iOS)
            // The terminal's key bar and line editor belong to the pane: put them away while a
            // sheet is up, and give the pane the keyboard back after.
            .onAppear {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .onDisappear {
                guard !model.editorHasKeys, model.sheet == nil, let workspace = model.workspace,
                      let id = workspace.focusedPane else { return }
                _ = workspace.panes[id]?.view.becomeFirstResponder()
            }
            #endif
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .launchAgent:
            NewTaskSheet(feed: model.agents)
        case .links:
            LinksSheet(
                source: model.links,
                onOpen: { link in model.open(link) },
                onShowInFiles: nil,
                onInsert: { link in model.insertInTerminal(link.resolved) })
        case .diff:
            stack { DiffReviewView(source: model.diffs) }
        case .files:
            stack {
                FilesBrowserView(
                    source: model.files,
                    onOpenInEditor: model.files.unavailableReason == nil ? { path in model.openEditor(path: path) } : nil,
                    onRevealInTerminal: { model.revealInTerminal($0) },
                    onInsertPath: { path in
                        model.insertInTerminal(path)
                        dismiss()
                    })
            }
        case .browser:
            BrowserSheet()
        default:
            EmptyView()
        }
    }

    private func stack(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("sheet-done")
                    }
                }
        }
        .macMinimumSize(width: 720, height: 560)
        // Code and file lists need the room: a page sheet on iPad, not a form sheet.
        .presentationSizing(.page)
    }
}
