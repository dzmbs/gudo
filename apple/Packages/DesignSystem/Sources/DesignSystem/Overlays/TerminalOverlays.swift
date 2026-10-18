import SwiftUI

// Overlays drawn over a terminal surface. Each is a port of the matching view in Ghostty's macOS
// app (reference/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView.swift and friends, MIT;
// see apple/THIRD_PARTY_NOTICES.md) with the same metrics, adapted to plain values instead of a
// Ghostty surface.

/// A terminal grid size.
nonisolated public struct GridSize: Equatable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// "80 ⨯ 24" while a pane is being resized (Ghostty `SurfaceResizeOverlay`): hidden for the first
/// size and for 500 ms after appearing, shown on each change, gone 750 ms after the last one.
public struct ResizeOverlay: View {
    let size: GridSize?
    var mode: TerminalPreferences.ResizeOverlay

    @State private var lastSize: GridSize?
    @State private var ready = false
    @State private var visible = false

    public init(size: GridSize?, mode: TerminalPreferences.ResizeOverlay = .afterFirst) {
        self.size = size
        self.mode = mode
    }

    public var body: some View {
        Group {
            if let size {
                Text(verbatim: "\(size.cols) ⨯ \(size.rows)")
                    .font(DS.Font.overlay)
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.chip)
                            .fill(.background)
                            .shadow(radius: 3))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            ready = true
        }
        .task(id: size) {
            defer { lastSize = size }
            guard ready, size != nil else { return }
            switch mode {
            case .never: return
            case .afterFirst where lastSize == nil: return
            default: break
            }
            visible = true
            guard (try? await Task.sleep(for: DS.Motion.resizeOverlayDuration)) != nil else { return }
            visible = false
        }
    }
}

/// The bar at the bottom of a pane whose process exited (Ghostty `ChildExitedMessageBar`): one
/// line, centered, the window background for success and red 50 % for failure; it hides while
/// the pointer is over it so it never covers the last line for good.
public struct ProcessExitedBar: View {
    let message: String
    let failed: Bool
    @State private var isHovered = false

    public init(_ message: String, failed: Bool) {
        self.message = message
        self.failed = failed
    }

    public var body: some View {
        Text((try? AttributedString(markdown: message)) ?? AttributedString(message))
            .lineLimit(1)
            .truncationMode(.tail)
            .font(DS.Font.overlay)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(failed ? AnyShapeStyle(Color.red.opacity(0.5)) : AnyShapeStyle(.background))
            .foregroundStyle(.primary)
            .opacity(isHovered ? 0 : 1)
            .onHover { isHovered = $0 }
            .transition(.move(edge: .bottom))
            .accessibilityLabel(message)
    }
}

/// Ghostty's bell border: a 3 pt #FFCC00 50 % stroke that fades in and out over 0.3 s.
public struct BellBorder: View {
    let ringing: Bool

    public init(ringing: Bool) {
        self.ringing = ringing
    }

    public var body: some View {
        Rectangle()
            .strokeBorder(DS.Palette.bell, lineWidth: 3)
            .allowsHitTesting(false)
            .opacity(ringing ? 1 : 0)
            .animation(DS.Motion.bell, value: ringing)
            .accessibilityHidden(true)
    }
}

/// Ghostty's unfocused-split dimming: a rectangle of the fill color (the terminal background by
/// default) at `1 - unfocused-split-opacity` over the pane.
public struct UnfocusedDim: View {
    let opacity: Double
    let fill: Color

    public init(unfocusedSplitOpacity: Double = TerminalPreferences.Default.unfocusedSplitOpacity, fill: Color) {
        self.opacity = 1 - min(max(unfocusedSplitOpacity, 0.15), 1)
        self.fill = fill
    }

    public var body: some View {
        Rectangle()
            .fill(fill)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The secure-input badge (Ghostty `SecureInputOverlay`): a lock shield in the top-right corner
/// while the terminal is reading a password with echo off. Tapping it explains why.
public struct SecureInputBadge: View {
    @State private var gradientAngle = Angle.degrees(0)
    @State private var gradientOpacity = 0.5
    @State private var isExplaining = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Image(systemName: "lock.shield.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 25, height: 25)
            .foregroundStyle(.primary)
            .padding(5)
            .background(
                Rectangle()
                    .fill(.background)
                    .overlay(
                        Rectangle()
                            .fill(AngularGradient(colors: [.cyan, .blue, .yellow, .blue, .cyan], center: .center, angle: gradientAngle))
                            .blur(radius: 4, opaque: true)
                            .mask(RadialGradient(colors: [.clear, .black], center: .center, startRadius: 0, endRadius: 25))
                            .opacity(gradientOpacity)))
            .mask(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray, lineWidth: 1))
            .onTapGesture { isExplaining = true }
            .popover(isPresented: $isExplaining, arrowEdge: .bottom) {
                Text("Secure input is on while the terminal reads a password. Other apps can't read what you type here.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(idealWidth: 280)
                    .padding()
                    .presentationCompactAdaptation(.popover)
            }
            .padding(.top, 10)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .accessibilityLabel("Secure input on")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { gradientAngle = .degrees(360) }
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: true)) { gradientOpacity = 1 }
            }
    }
}

/// The hovered link's URL in the bottom-left corner, moving to the right while the pointer is over
/// it (Ghostty `URLHoverBanner`: padding 5, radius 9 on the inner top corner).
public struct URLHoverBanner: View {
    let url: String
    @State private var isHoveringLeft = false

    public init(url: String) {
        self.url = url
    }

    public var body: some View {
        ZStack {
            banner(corner: .init(topLeading: 9))
                .opacity(isHoveringLeft ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            banner(corner: .init(topTrailing: 9))
                .opacity(isHoveringLeft ? 0 : 1)
                .onHover { isHoveringLeft = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func banner(corner: RectangleCornerRadii) -> some View {
        Text(verbatim: url)
            .font(DS.Font.literalSmall)
            .padding(5)
            .background(UnevenRoundedRectangle(cornerRadii: corner).fill(.background))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
