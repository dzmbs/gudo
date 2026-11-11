#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI

struct ChatToolDetailSheet: View {
    private enum Section: String, CaseIterable { case input = "Input", output = "Output" }
    let tool: TimelineTool
    let openTerminal: () -> Void
    @State private var reader: ChatOutputReader
    @State private var section = Section.output
    @State private var offset: UInt64 = 0
    @Environment(\.dismiss) private var dismiss

    init(tool: TimelineTool, source: @escaping ChatOutputReader.Source, openTerminal: @escaping () -> Void) {
        self.tool = tool
        self.openTerminal = openTerminal
        _reader = State(initialValue: ChatOutputReader(source: source))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Content", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(DS.Space.l)
                .frame(minHeight: DS.Size.touchTarget)
                if section == .input { input } else { ChatOutputPager(reader: reader, offset: $offset) }
            }
            .background(DS.Palette.base).foregroundStyle(DS.Palette.text)
            .navigationTitle(String(tool.title.prefix(160))).navigationBarTitleDisplayMode(.inline)
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
        .task(id: offset) { if tool.output != nil { await reader.load(offset: offset) } }
        .onDisappear { reader.cancel() }
    }

    @ViewBuilder private var input: some View {
        if tool.input.isEmpty {
            ChatOutputNote(message: "No input was recorded for this tool.")
        } else if admitsInput {
            NativeTextPreview(text: tool.input).accessibilityIdentifier("chat-tool-input")
        } else {
            ChatOutputNote(message: "This input is too large to show here. Open Terminal to read it.")
        }
    }

    private var admitsInput: Bool {
        guard tool.input.utf8.count <= ChatOutputLimits.pageBytes else { return false }
        return tool.input.utf8.lazy.filter { $0 == 10 }.prefix(ChatOutputLimits.pageLines).count
            < ChatOutputLimits.pageLines
    }
}
#endif
