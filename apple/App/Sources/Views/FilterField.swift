import DesignSystem
import SwiftUI

/// A sheet's filter on the Mac, where a sheet has no toolbar for `.searchable`: the drawn field
/// of Hosts' quick connect (28 pt, raised, hairline, accent edge while focused) with a magnifier
/// and a clear button.
struct FilterField: View {
    @Binding var text: String
    var prompt = "Filter"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Palette.textTertiary)
            TextField("Filter", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($isFocused)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: 28)
        .fieldSurface(isFocused: isFocused, cornerRadius: DS.Radius.field)
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
    }
}

/// A sheet's list of sections: the Mac's grouped form (cards on the page, as System Settings
/// draws lists) and the inset grouped list on iOS.
struct GroupedList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
            .chromeGrouped()
        #else
        List { content }
            .listStyle(.insetGrouped)
            .chromeGrouped()
        #endif
    }
}
