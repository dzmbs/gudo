#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI

struct ChatCommandOffer: Identifiable {
    let id = UUID()
    let context: PaneChatState.ActionContext
    let draft: String
    let commands: [TimelineCommand]

    init(state: PaneChatState) {
        context = state.actionContext
        draft = state.draft
        commands = ChatCommands.matches(draft, commands: state.model?.frame.session?.commands ?? [])
    }
}

enum ChatCommands {
    static func query(_ draft: String) -> String? {
        if draft.isEmpty { return "" }
        guard draft.first == "/", draft.utf8.count <= 129 else { return nil }
        let query = String(draft.dropFirst())
        return query.unicodeScalars.allSatisfy(validNameCharacter) ? query : nil
    }

    static func matches(_ draft: String, commands: [TimelineCommand]) -> [TimelineCommand] {
        guard let query = query(draft) else { return [] }
        let prefix = query.lowercased()
        var names: Set<String> = []
        return commands.prefix(256).filter { command in
            !command.name.isEmpty && command.name.utf8.count <= 128
                && command.name.unicodeScalars.allSatisfy(validNameCharacter)
                && command.name.lowercased().hasPrefix(prefix) && names.insert(command.name).inserted
        }.sorted { $0.name < $1.name }
    }

    static func apply(_ command: TimelineCommand, offer: ChatCommandOffer, to state: PaneChatState) -> Bool {
        guard state.actionContext == offer.context, state.presentation == .chat, state.draft == offer.draft,
              !state.composer.isBusy, !state.interrupt.isBusy, !state.dictation.isActive, !state.photos.isBusy,
              offer.commands.contains(command),
              matches(state.draft, commands: state.model?.frame.session?.commands ?? []).contains(command) else { return false }
        state.invalidateActions()
        state.draft = "/" + command.name + " "
        return true
    }

    private static func validNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || "-_:".unicodeScalars.contains(scalar)
    }
}

struct ChatCommandSheet: View {
    let offer: ChatCommandOffer
    let select: (TimelineCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(offer.commands) { command in
                Button { select(command) } label: {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(verbatim: "/" + command.name).font(DS.Font.prose)
                        if !command.description.isEmpty {
                            Text(verbatim: String(command.description.prefix(256)))
                                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, minHeight: DS.Size.touchTarget, alignment: .leading)
                }.listRowBackground(Rectangle().fill(DS.Palette.base))
            }
            .scrollContentBackground(.hidden).background(DS.Palette.base).foregroundStyle(DS.Palette.text)
            .overlay {
                if offer.commands.isEmpty {
                    Text("No matching commands").font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .navigationTitle("Commands").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
