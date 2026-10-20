import DesignSystem
import SwiftUI
import VoiceKit

/// A small capsule at the bottom of the window while dictating ("Listening · English"), and the
/// reason when dictation could not start or stopped. The words themselves show at the terminal
/// cursor as marked text (`PaneDictationTarget`).
private struct DictationIndicator: ViewModifier {
    private let voice = VoiceDictation.shared.voice

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            Group {
                switch voice.phase {
                case .starting, .listening, .finishing:
                    capsule {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(voice.phase == .listening ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(.secondary))
                            .symbolEffect(.pulse, isActive: voice.phase == .starting)
                        Text(title)
                            .font(.callout.weight(.medium))
                        Text(SystemSpeechRecognizer.displayName(voice.settings.locale))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("dictation-listening")
                case .failed(let error):
                    capsule {
                        Image(systemName: "mic.slash")
                            .foregroundStyle(DS.Palette.error)
                        Text(error.message)
                            .font(.callout.weight(.medium))
                            .lineLimit(3)
                    }
                    .onTapGesture { voice.cancel() }
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        if case .failed = voice.phase { voice.cancel() }
                    }
                    .accessibilityIdentifier("dictation-error")
                case .idle:
                    EmptyView()
                }
            }
            .padding(.bottom, DS.Space.xxl)
            .padding(.horizontal, DS.Space.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(DS.Motion.overlay, value: voice.phase)
    }

    private var title: String {
        switch voice.phase {
        case .starting: "Starting…"
        case .finishing: "Inserting…"
        default: "Listening"
        }
    }

    private func capsule(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: DS.Space.s) { content() }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s + 2)
            .floatingCapsule(interactive: false)
    }
}

extension View {
    /// Shows the dictation state over the window (see `DictationIndicator`).
    func dictationIndicator() -> some View {
        modifier(DictationIndicator())
    }
}
