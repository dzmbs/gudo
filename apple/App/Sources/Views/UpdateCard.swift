#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI

/// The sidebar's update control: what is on offer, its notes, the download's progress and the
/// one action that moves it on. Folds to `UpdateIndicator` in the footer.
struct UpdateCard: View {
    let prompt: UpdatePrompt
    @Environment(\.chrome) private var chrome
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.searchPanel, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.gap10) {
            header
            if prompt.showsNotes, let notes = prompt.offer?.notes {
                ScrollView {
                    Text(notes)
                        .font(DS.Font.sidebarSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 148)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
                .accessibilityLabel("Release notes")
            }
            actions
        }
        .padding(DS.Space.m)
        .background { surface }
        .glassEdge(Self.shape)
        .shadow(color: .black.opacity(chrome.scheme == .dark ? 0.28 : 0.08), radius: 6, y: 2)
        .padding(.horizontal, DS.Space.s)
        .animation(DS.Motion.snappy, value: prompt.phase)
        .animation(DS.Motion.snappy, value: prompt.showsNotes)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("sidebar-update")
    }

    /// The theme's surface as glass, lit from the top corner with a breath of its accent.
    @ViewBuilder private var surface: some View {
        let light = chrome.scheme == .light
        let paper = light ? chrome.baseColor : chrome.raisedColor
        if reduceTransparency {
            Self.shape.fill(paper)
        } else {
            Color.clear
                .glassEffect(.regular.tint(paper.opacity(light ? 0.85 : 0.6)), in: Self.shape)
                .overlay {
                    Self.shape.fill(LinearGradient(
                        colors: [chrome.accentColor.opacity(light ? 0.08 : 0.12), .clear],
                        startPoint: .topLeading, endPoint: .center))
                }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.gap10) {
            UpdateGlyph(phase: prompt.phase, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DS.Font.sidebarTitle.weight(.semibold))
                    .foregroundStyle(DS.Palette.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.sidebarSubtitle.monospacedDigit())
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
            }
            .padding(.top, 1)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                if prompt.holdsUpdate {
                    cornerButton("Minimize", systemImage: "chevron.down", help: "Show as an icon") { prompt.toggleMinimized() }
                        .accessibilityIdentifier("sidebar-update-minimize")
                }
                if let dismissHelp {
                    cornerButton(dismissHelp, systemImage: "xmark", help: dismissHelp) { prompt.dismiss() }
                        .accessibilityIdentifier("sidebar-update-dismiss")
                }
            }
            .padding(.top, -3)
            .padding(.trailing, -6)
        }
    }

    private func cornerButton(_ title: String, systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage) {
            withAnimation(DS.Motion.snappy) { action() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.sidebarDismiss)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(DS.Palette.textTertiary)
        .help(help)
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch prompt.phase {
        case .available, .ready:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s) {
                    notesButton.fixedSize()
                    Spacer(minLength: 0)
                    acceptButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    acceptButton
                    notesButton
                }
            }
        case .downloading(let fraction), .preparing(let fraction):
            UpdateProgressBar(fraction: fraction)
                .accessibilityLabel(title)
                .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
        case .installing where prompt.canRetryRestart:
            HStack {
                Spacer(minLength: 0)
                Button("Restart to Update") { prompt.accept() }
                    .buttonStyle(UpdateActionButtonStyle())
            }
        default:
            EmptyView()
        }
    }

    private var acceptButton: some View {
        Button {
            withAnimation(DS.Motion.snappy) { prompt.accept() }
        } label: {
            Text(acceptTitle).frame(maxWidth: .infinity)
        }
        .buttonStyle(UpdateActionButtonStyle())
        .accessibilityIdentifier("sidebar-update-accept")
    }

    @ViewBuilder private var notesButton: some View {
        if prompt.offer?.notes != nil {
            Button {
                prompt.toggleNotes()
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Text("What's New")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(prompt.showsNotes ? 180 : 0))
                }
            }
            .buttonStyle(.quiet)
            .padding(.leading, -DS.Space.s)
            .accessibilityLabel(prompt.showsNotes ? "Hide Release Notes" : "Show Release Notes")
            .accessibilityIdentifier("sidebar-update-notes")
        } else if let url = prompt.offer?.notesURL {
            Button {
                prompt.openURL(url)
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Text("What's New")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                }
            }
            .buttonStyle(.quiet)
            .padding(.leading, -DS.Space.s)
            .help(url.absoluteString)
            .accessibilityLabel("Release Notes")
            .accessibilityHint("Opens in your browser")
            .accessibilityIdentifier("sidebar-update-notes")
        }
    }

    // MARK: Copy

    private var version: String { prompt.offer.map { "\(Brand.name) \($0.displayVersion)" } ?? Brand.name }

    private var title: String {
        switch prompt.phase {
        case .hidden, .available: "Update available"
        case .checking: "Checking…"
        case .downloading: "Downloading"
        case .preparing: "Preparing"
        case .ready: "Ready to update"
        case .installing: "Restarting…"
        case .upToDate: "Up to date"
        case .failed: "Update failed"
        }
    }

    private var subtitle: String? {
        switch prompt.phase {
        case .hidden, .checking: nil
        case .available, .ready, .installing, .preparing: version
        case .downloading(let fraction): fraction.map { "\(version) · \(Int($0 * 100))%" } ?? version
        case .upToDate: "\(Brand.name) \(Self.currentVersion) is the latest version."
        case .failed(let message): message
        }
    }

    private var acceptTitle: String {
        if prompt.phase == .ready { return "Restart to Update" }
        return prompt.offer?.isInformationOnly == true ? "Learn More" : "Download"
    }

    /// What the close button does, as its label; nil while it can't be stopped.
    private var dismissHelp: String? {
        switch prompt.phase {
        case .available: prompt.offer?.isInformationOnly == true ? "Dismiss" : "Skip This Version"
        case .ready: "Install When You Quit"
        case .downloading: "Cancel Download"
        case .checking: "Cancel"
        case .upToDate, .failed: "Close"
        case .hidden, .preparing, .installing: nil
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// The phase's mark: an arrow on the accent's soft tint, a ring while downloading, a check when
/// up to date.
struct UpdateGlyph: View {
    let phase: UpdatePrompt.Phase
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            switch phase {
            case .checking, .installing, .preparing(nil), .downloading(nil):
                ProgressView()
                    .controlSize(.mini)
                    .tint(DS.Palette.accent)
            case .downloading(let fraction?), .preparing(let fraction?):
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
                    .animation(DS.Motion.quick, value: fraction)
                Image(systemName: "arrow.down")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(DS.Palette.accent)
            default:
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch phase {
        case .ready: "arrow.clockwise"
        case .upToDate: "checkmark"
        case .failed: "exclamationmark"
        default: "arrow.down"
        }
    }

    private var tint: ChromeStyle {
        switch phase {
        case .upToDate: DS.Palette.done
        case .failed: DS.Palette.attention
        default: DS.Palette.accent
        }
    }
}

/// The card folded: the glyph in the footer, beside Settings.
struct UpdateIndicator: View {
    let prompt: UpdatePrompt

    var body: some View {
        Button {
            withAnimation(DS.Motion.snappy) { prompt.toggleMinimized() }
        } label: {
            UpdateGlyph(phase: prompt.phase, size: 20)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 26, minHeight: 26)
        .contentShape(.rect)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityHint("Shows the update")
        .accessibilityIdentifier("sidebar-update-indicator")
    }

    private var help: String {
        let version = prompt.offer.map { "\(Brand.name) \($0.displayVersion)" } ?? Brand.name
        return switch prompt.phase {
        case .downloading(let fraction?): "Downloading \(version), \(Int(fraction * 100))%"
        case .downloading, .preparing: "Preparing \(version)"
        case .ready: "\(version) is ready to install"
        case .installing: "Restarting"
        default: "\(version) is available"
        }
    }
}

/// A thin determinate bar in the accent, or a travelling one until the size is known.
private struct UpdateProgressBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let fraction {
                GeometryReader { proxy in
                    Capsule()
                        .fill(DS.Palette.accent)
                        .frame(width: max(4, proxy.size.width * fraction))
                        .animation(DS.Motion.quick, value: fraction)
                }
            } else if reduceMotion {
                Capsule().fill(DS.Palette.accent.opacity(0.5))
            } else {
                TimelineView(.animation) { context in
                    GeometryReader { proxy in
                        let period = 1.4
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let width = proxy.size.width * 0.3
                        Capsule()
                            .fill(DS.Palette.accent)
                            .frame(width: width)
                            .offset(x: -width + (proxy.size.width + width) * phase)
                    }
                }
            }
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity)
        .background(DS.Palette.ink.opacity(0.1), in: .capsule)
        .clipShape(.capsule)
        .padding(.top, DS.Space.xxs)
    }
}

/// The card's one action: a small solid capsule in the theme's prominent accent. Solid, not
/// glass, on a glass card.
private struct UpdateActionButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.sidebarSubtitle.weight(.semibold))
            .foregroundStyle(DS.Palette.onProminent)
            .lineLimit(1)
            .padding(.horizontal, DS.Space.gap10)
            .frame(minHeight: 24)
            .background(Capsule().fill(DS.Palette.prominent))
            .overlay(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0 : isHovered ? 0.1 : 0)).blendMode(.plusLighter))
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.Motion.press, value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

/// Tells the updater which window this sidebar is in, so a check asked for there answers there.
struct UpdateSidebarAnchor: NSViewRepresentable {
    let model: WindowModel

    func makeNSView(context: Context) -> Marker { Marker(model: model) }

    func updateNSView(_ marker: Marker, context: Context) {
        marker.model = model
    }

    final class Marker: NSView {
        weak var model: WindowModel?

        init(model: WindowModel) {
            self.model = model
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, let model { AppUpdater.shared.registerSidebar(in: window, model: model) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
