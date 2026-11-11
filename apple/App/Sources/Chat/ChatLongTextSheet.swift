#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI

struct ChatLongTextSheet: View {
    let longText: TimelineLongText
    let openTerminal: () -> Void
    @State private var reader: ChatOutputReader
    @State private var offset: UInt64 = 0
    @Environment(\.dismiss) private var dismiss

    init(longText: TimelineLongText, source: @escaping ChatOutputReader.Source, openTerminal: @escaping () -> Void) {
        self.longText = longText
        self.openTerminal = openTerminal
        _reader = State(initialValue: ChatOutputReader(source: source))
    }

    var body: some View {
        NavigationStack {
            ChatOutputPager(reader: reader, offset: $offset, messages: .init(
                loading: "Loading text…", empty: "This text is empty.", missing: "This text is not available.",
                identifier: "chat-long-text"
            ))
            .padding(.top, DS.Space.l)
            .background(DS.Palette.base).foregroundStyle(DS.Palette.text)
            .navigationTitle(ChatLongText.title(longText.role)).navigationBarTitleDisplayMode(.inline)
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
        .task(id: offset) { await reader.load(offset: offset) }
        .onDisappear { reader.cancel() }
    }
}
#endif
