import DesignSystem
import SwiftUI
import VoiceKit

/// Settings › Voice: dictation on/off, its language, and whether that language's on-device model
/// is here (with a download button for SpeechAnalyzer's model).
struct VoiceSettingsSection: View {
    @AppStorage(VoiceSettings.enabledKey) private var enabled = true
    /// "" = the system language.
    @AppStorage(VoiceSettings.localeKey) private var localeIdentifier = ""
    @State private var locales: [Locale] = []
    @State private var availability: SystemSpeechRecognizer.Availability?
    @State private var download: Double?
    @State private var downloadError: String?

    private var locale: Locale { VoiceSettings(localeIdentifier: localeIdentifier).locale }

    var body: some View {
        Section {
            Toggle("Dictation", isOn: $enabled)
                .settingAnchor("dictation")
            if enabled {
                Picker("Language", selection: $localeIdentifier) {
                    Text("System (\(SystemSpeechRecognizer.displayName(Locale.current)))").tag("")
                    ForEach(locales, id: \.identifier) { locale in
                        Text(SystemSpeechRecognizer.displayName(locale)).tag(locale.identifier)
                    }
                }
                status
            }
        } header: {
            Text("Voice")
        } footer: {
            Text(footer)
        }
        .task { locales = await SystemSpeechRecognizer.supportedLocales() }
        .task(id: localeIdentifier) {
            downloadError = nil
            availability = await SystemSpeechRecognizer.availability(of: locale)
        }
    }

    @ViewBuilder private var status: some View {
        switch availability {
        case .installed:
            LabeledContent("Speech Model", value: "On this device")
        case .downloadable(let fallback):
            if let download {
                LabeledContent("Speech Model") {
                    ProgressView(value: download).frame(maxWidth: 140)
                }
            } else {
                LabeledContent {
                    Button("Download") { Task { await fetch() } }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speech Model")
                        Text(fallback ? "Until then, the older on-device recognizer is used." : "Needed to dictate in this language.")
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            }
            if let downloadError {
                Text(downloadError).font(DS.Font.rowSubtitle).foregroundStyle(DS.Palette.error)
            }
        case .downloading:
            LabeledContent("Speech Model", value: "Downloading…")
        case .legacyOnly:
            LabeledContent("Speech Model", value: "On this device")
        case .unavailable:
            LabeledContent("Speech Model", value: "Not available")
        case nil:
            LabeledContent("Speech Model", value: "")
        }
    }

    private var footer: String {
        #if os(macOS)
        "Hold ⌃⌥Space in a terminal to dictate; let go to insert the words. Nothing runs until you press Return. Speech is recognized on this Mac."
        #else
        "Hold the mic key, or ⌃⌥Space on a keyboard, to dictate; let go to insert the words. Nothing runs until you press Return. Speech is recognized on this device."
        #endif
    }

    private func fetch() async {
        download = 0
        defer { download = nil }
        do {
            try await SystemSpeechRecognizer.download(locale) { download = $0 }
        } catch {
            downloadError = "Download failed: \(error.localizedDescription)"
        }
        availability = await SystemSpeechRecognizer.availability(of: locale)
    }
}
