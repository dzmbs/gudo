#if os(iOS)
import DesignSystem
import SwiftUI

struct ChatOutputPager: View {
    struct Messages {
        var loading = "Loading output…"
        var empty = "This output is empty."
        var missing = "No output was recorded for this tool."
        var identifier = "chat-tool-output"
    }

    let reader: ChatOutputReader
    @Binding var offset: UInt64
    var messages = Messages()

    var body: some View {
        VStack(spacing: 0) {
            if let page = reader.page {
                let end = page.offset + UInt64(page.text.utf8.count)
                Text("Bytes \(page.offset.formatted()) to \(end.formatted()) of \(page.totalBytes.formatted())")
                    .font(DS.Font.caption.monospacedDigit()).foregroundStyle(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.l).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(messages.identifier + "-range")
                if page.text.isEmpty {
                    ChatOutputNote(message: messages.empty)
                } else {
                    NativeTextPreview(text: page.text).id(page.offset)
                        .accessibilityIdentifier(messages.identifier)
                }
                navigation(page)
            } else if reader.isLoading {
                ChatOutputNote(message: messages.loading)
            } else if reader.error == nil {
                ChatOutputNote(message: messages.missing)
            }
            if let error = reader.error {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(verbatim: error).font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
                    Button("Try Again") { Task { await reader.load(offset: offset) } }
                        .frame(minHeight: DS.Size.touchTarget)
                }.padding(DS.Space.l).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func navigation(_ page: ChatOutputPage) -> some View {
        HStack(spacing: DS.Space.m) {
            pageButton("Beginning", target: page.offset == 0 ? nil : 0)
            Spacer(minLength: 0)
            pageButton("Previous", target: reader.previousOffset)
            pageButton("Next", target: page.nextOffset)
        }
        .font(DS.Font.caption).frame(minHeight: DS.Size.touchTarget)
        .padding(.horizontal, DS.Space.l).disabled(reader.isLoading)
        .accessibilityIdentifier(messages.identifier + "-navigation")
    }

    private func pageButton(_ title: String, target: UInt64?) -> some View {
        let enabled = target != nil && !reader.isLoading
        return Button(title) { if let target { offset = target } }
            .frame(minHeight: DS.Size.touchTarget).disabled(!enabled)
            .foregroundStyle(enabled ? DS.Palette.text : DS.Palette.textQuaternary)
    }
}

struct ChatOutputNote: View {
    let message: String

    var body: some View {
        Text(verbatim: message).font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(DS.Space.l)
    }
}
#endif
