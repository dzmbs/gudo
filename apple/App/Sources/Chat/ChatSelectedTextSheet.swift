import CoreText
import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct ChatSelectedText: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct ChatSelectedTextSheet: View {
    let selection: ChatSelectedText
    let openTerminal: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatTextSelection(selection: selection)
                .background(DS.Palette.base)
                .navigationTitle(selection.title).toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Terminal", systemImage: "terminal", action: openTerminal)
                            .frame(minHeight: DS.Size.touchTarget)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.frame(minHeight: DS.Size.touchTarget)
                    }
                }
        }
    }
}

/// One native range selector per presented sheet, never a text view in every transcript cell.
#if canImport(UIKit)
struct ChatTextSelection: UIViewRepresentable {
    let selection: ChatSelectedText

    final class Coordinator { var selection: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.allowsEditingTextAttributes = false
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: DS.Space.l, left: DS.Space.l, bottom: DS.Space.l, right: DS.Space.l)
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = "chat-selected-text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // The snapshot is immutable. Theme/live-parent updates must not compare or replace its
        // entire string, resetting a reader's range selection and scroll position in the process.
        if context.coordinator.selection != selection.id {
            view.text = selection.text
            context.coordinator.selection = selection.id
        }
        let resolved = DS.Font.literal.resolve(in: context.environment.fontResolutionContext)
        let font = UIFont.monospacedSystemFont(ofSize: CTFontGetSize(resolved.ctFont), weight: .regular)
        if view.font != font { view.font = font }
        let ink = UIColor(context.environment.chrome.text)
        let accent = UIColor(context.environment.chrome.accentColor)
        if view.textColor != ink { view.textColor = ink }
        if view.tintColor != accent { view.tintColor = accent }
    }
}
#else
struct ChatTextSelection: NSViewRepresentable {
    let selection: ChatSelectedText

    final class Coordinator { var selection: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: DS.Space.l, height: DS.Space.l)
        view.textContainer?.lineFragmentPadding = 0
        view.setAccessibilityIdentifier("chat-selected-text")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        // The snapshot is immutable: replacing its string would reset the reader's selection.
        if context.coordinator.selection != selection.id {
            view.string = selection.text
            context.coordinator.selection = selection.id
        }
        let resolved = DS.Font.literal.resolve(in: context.environment.fontResolutionContext)
        let font = NSFont.monospacedSystemFont(ofSize: CTFontGetSize(resolved.ctFont), weight: .regular)
        if view.font != font { view.font = font }
        let ink = NSColor(context.environment.chrome.text)
        if view.textColor != ink { view.textColor = ink }
        view.insertionPointColor = NSColor(context.environment.chrome.accentColor)
    }
}
#endif
