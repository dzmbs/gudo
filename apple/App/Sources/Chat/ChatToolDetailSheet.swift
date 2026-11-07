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
                if section == .input { input } else { output }
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
            note("No input was recorded for this tool.")
        } else if admitsInput {
            NativeTextPreview(text: tool.input).accessibilityIdentifier("chat-tool-input")
        } else {
            note("This input is too large to show here. Open Terminal to read it.")
        }
    }

    private var admitsInput: Bool {
        guard tool.input.utf8.count <= ChatOutputLimits.pageBytes else { return false }
        return tool.input.utf8.lazy.filter { $0 == 10 }.prefix(ChatOutputLimits.pageLines).count
            < ChatOutputLimits.pageLines
    }

    private var output: some View {
        VStack(spacing: 0) {
            if let page = reader.page {
                let end = page.offset + UInt64(page.text.utf8.count)
                Text("Bytes \(page.offset.formatted()) to \(end.formatted()) of \(page.totalBytes.formatted())")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.l).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat-tool-output-range")
                if page.text.isEmpty {
                    note("This output is empty.")
                } else {
                    NativeTextPreview(text: page.text).id(page.offset)
                        .accessibilityIdentifier("chat-tool-output")
                }
                navigation(page)
            } else if reader.isLoading {
                note("Loading output…")
            } else if reader.error == nil {
                note("No output was recorded for this tool.")
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
        .accessibilityIdentifier("chat-tool-output-navigation")
    }

    private func pageButton(_ title: String, target: UInt64?) -> some View {
        let enabled = target != nil && !reader.isLoading
        return Button(title) { if let target { offset = target } }
            .frame(minHeight: DS.Size.touchTarget).disabled(!enabled)
            .foregroundStyle(enabled ? DS.Palette.text : DS.Palette.textQuaternary)
    }

    private func note(_ message: String) -> some View {
        Text(verbatim: message).font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(DS.Space.l)
    }
}
#endif
