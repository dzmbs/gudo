import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The composer's suggestions for the word being typed, above the field: commands after `/`,
/// files after `@`. The selected row is the one Tab or Return takes.
struct ChatAutocompleteList: View {
    let autocomplete: ChatAutocomplete
    let accept: (Int) -> Void
    private static let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if autocomplete.suggestions.isEmpty, let note = autocomplete.note {
                Text(note).font(ChatFont.subtitle).foregroundStyle(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.l)
                    .frame(maxWidth: .infinity, minHeight: DS.Size.touchTarget, alignment: .leading)
                    .accessibilityIdentifier("chat-autocomplete-note")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(autocomplete.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                                row(suggestion, isSelected: index == autocomplete.selection)
                                    .id(suggestion.id)
                                    .onTapGesture { accept(index) }
                                    .accessibilityAddTraits(index == autocomplete.selection ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityAction { accept(index) }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: CGFloat(Self.visibleRows) * DS.Size.touchTarget)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: autocomplete.selection) { _, selection in
                        guard autocomplete.suggestions.indices.contains(selection) else { return }
                        proxy.scrollTo(autocomplete.suggestions[selection].id)
                    }
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
        .surface(.tile, in: RoundedRectangle.rounded(DS.Radius.card), fill: DS.Palette.raised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(autocomplete.trigger?.kind == .file ? "Files" : "Commands")
        .accessibilityIdentifier("chat-autocomplete")
    }

    private func row(_ suggestion: ChatAutocomplete.Suggestion, isSelected: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: suggestion.symbol)
                .font(ChatFont.caption).foregroundStyle(DS.Palette.textTertiary)
                .frame(width: DS.Space.l)
            Text(Self.emphasised(suggestion.title, at: suggestion.emphasis))
                .font(ChatFont.subtitle)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if !suggestion.detail.isEmpty {
                Text(verbatim: suggestion.detail).font(ChatFont.caption).foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(minHeight: DS.Size.touchTarget)
        .background(RoundedRectangle.rounded(DS.Radius.control).fill(DS.Palette.selectedFill).opacity(isSelected ? 1 : 0))
        .padding(.horizontal, DS.Space.xs)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-suggestion-\(suggestion.id)")
    }

    static func emphasised(_ text: String, at positions: Set<Int>) -> AttributedString {
        var result = AttributedString()
        for (index, scalar) in text.unicodeScalars.enumerated() {
            var piece = AttributedString(String(scalar))
            if positions.contains(index) { piece.inlinePresentationIntent = .stronglyEmphasized }
            result.append(piece)
        }
        return result
    }
}

/// Files waiting to go with the next message, each a pill with its picture or name and a way
/// to take it off.
struct ChatAttachmentPills: View {
    let attachments: [ChatAttachment]
    let pending: String?
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DS.Space.s) {
                ForEach(attachments) { attachment in pill(attachment) }
                if let pending {
                    HStack(spacing: DS.Space.xs) {
                        ProgressView().controlSize(.mini)
                        Text(verbatim: pending).lineLimit(1)
                    }
                    .font(ChatFont.caption).foregroundStyle(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.m)
                    .frame(height: Self.height)
                    .background(DS.Palette.selectedFill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                    .accessibilityIdentifier("chat-attachment-pending")
                }
            }
            .padding(.horizontal, DS.Space.s)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityIdentifier("chat-attachments")
    }

    static let height: CGFloat = 36

    private func pill(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: DS.Space.xs) {
            if let thumbnail = attachment.thumbnail.flatMap(Self.image) {
                thumbnail.resizable().scaledToFill()
                    .frame(width: Self.height - DS.Space.s, height: Self.height - DS.Space.s)
                    .clipShape(.rect(cornerRadius: DS.Radius.chip, style: .continuous))
            } else {
                Image(systemName: "doc").font(ChatFont.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Text(verbatim: attachment.name).font(ChatFont.caption).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
            Button { remove(attachment.id) } label: {
                Label("Remove \(attachment.name)", systemImage: "xmark").labelStyle(.iconOnly)
                    .font(ChatFont.captionDetail.weight(.semibold)).foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.Size.touchTarget * 0.6, height: Self.height)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-attachment-remove")
        }
        .padding(.leading, DS.Space.xs)
        .frame(height: Self.height)
        .background(DS.Palette.selectedFill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .foregroundStyle(DS.Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.name)
    }

    private static func image(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }
}

/// Messages held while the agent works, above the composer: each can go back to the field,
/// go now, or be dropped.
struct ChatQueueStrip: View {
    let messages: [ChatQueuedMessage]
    let edit: (ChatQueuedMessage) -> Void
    let sendNow: (ChatQueuedMessage) -> Void
    let remove: (ChatQueuedMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(messages.count == 1 ? "Queued, sends when the turn ends" : "\(messages.count) queued, sent one per turn")
                .font(ChatFont.caption).foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.s)
            ForEach(messages) { message in
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "clock").font(ChatFont.caption).foregroundStyle(DS.Palette.textTertiary)
                        .frame(width: DS.Space.l)
                    Text(verbatim: Self.oneLine(message.text)).font(ChatFont.subtitle)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    action("Edit", symbol: "pencil", identifier: "chat-queued-edit") { edit(message) }
                    action("Send now", symbol: "arrow.up.circle", identifier: "chat-queued-send") { sendNow(message) }
                    action("Remove", symbol: "xmark", identifier: "chat-queued-remove") { remove(message) }
                }
                .padding(.leading, DS.Space.m)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-queued-message")
            }
        }
        .surface(.tile, in: RoundedRectangle.rounded(DS.Radius.card), fill: DS.Palette.sidebar)
        .accessibilityIdentifier("chat-queue")
    }

    private func action(_ title: LocalizedStringKey, symbol: String, identifier: String,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .font(ChatFont.subtitle)
                .frame(width: DS.Size.touchTarget, height: DS.Size.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Palette.textSecondary)
        .help(Text(title))
        .accessibilityIdentifier(identifier)
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
