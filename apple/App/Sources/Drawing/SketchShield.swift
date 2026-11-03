import DesignSystem
import Observation
import PaneLayout
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Sketching covers the whole tab: while one pane is sketched on, the tab's other panes dim and
/// take no input (a drag there never selects text), and clicking one moves the sketch to it.
@MainActor
@Observable
final class SketchMode {
    static let shared = SketchMode()

    struct Target {
        let workspace: ObjectIdentifier
        let pane: PaneId
        let tabPanes: Set<PaneId>
    }

    private(set) var target: Target?
    @ObservationIgnored private var shields: [PaneId: SketchShieldView] = [:]

    var isSketching: Bool { target != nil }

    func began(on drawing: PaneDrawing) {
        removeShields()
        guard let workspace = drawing.workspace else { return }
        let pane = PaneId(drawing.paneId)
        let tabPanes = workspace.session.tab(containing: pane)?.root.panes ?? [pane]
        target = Target(workspace: ObjectIdentifier(workspace), pane: pane, tabPanes: Set(tabPanes))
        for other in SketchTargeting.shielded(tabPanes: tabPanes, target: pane) {
            guard let view = workspace.pane(other)?.view else { continue }
            let shield = SketchShieldView(canSketch: Self.canSketch(other), dark: drawing.isDarkTheme)
            shield.frame = view.bounds
            shield.onActivate = { [weak workspace] in
                guard let workspace else { return }
                SketchMode.shared.clicked(other, in: workspace)
            }
            view.addSubview(shield)
            shields[other] = shield
        }
    }

    func ended(on drawing: PaneDrawing) {
        guard target?.pane == PaneId(drawing.paneId) else { return }
        removeShields()
        target = nil
    }

    /// A SwiftUI leaf (editor, browser, tool) of the sketched tab other than its target.
    func shields(leaf: PaneId, in workspace: Workspace?) -> Bool {
        guard let target, let workspace, target.workspace == ObjectIdentifier(workspace) else { return false }
        return leaf != target.pane && target.tabPanes.contains(leaf)
    }

    private func clicked(_ pane: PaneId, in workspace: Workspace) {
        guard let target else { return }
        switch SketchTargeting.click(on: pane, target: target.pane, canSketch: Self.canSketch(pane)) {
        case .stay:
            break
        case .unavailable:
            #if os(macOS)
            NSSound.beep()
            #endif
        case .retarget:
            CanvasWebView.log.info("draw: sketch moves to pane \(pane.rawValue)")
            workspace.apply(.focus(pane))
            PaneDrawing.of(pane)?.beginDrawing()
        }
    }

    private func removeShields() {
        for shield in shields.values { shield.removeFromSuperview() }
        shields = [:]
    }

    static func canSketch(_ pane: PaneId) -> Bool {
        guard let drawing = PaneDrawing.of(pane) else { return false }
        return drawing.canvas == nil && !drawing.isReadOnly
    }
}

/// Over each other pane of the tab while sketching: a slight dim that takes clicks and taps
/// (moving the sketch there) and drags (so they never select text). The Pencil goes through on
/// iPad, where it starts a sketch on that pane by itself.
final class SketchShieldView: PlatformView {
    var onActivate: (() -> Void)?
    #if os(iOS)
    private var hint: UIHostingController<ThemedRoot<SketchHereHint>>?
    #else
    private var hint: NSHostingView<ThemedRoot<SketchHereHint>>?
    #endif

    init(canSketch: Bool, dark: Bool) {
        super.init(frame: .zero)
        let dim = (dark ? PlatformColor.black : PlatformColor.white).withAlphaComponent(dark ? 0.28 : 0.35)
        #if os(iOS)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = dim
        isAccessibilityElement = true
        accessibilityIdentifier = "drawing.shield"
        accessibilityLabel = canSketch ? "Sketch on this pane" : "Not available while sketching"
        accessibilityTraits = canSketch ? .button : .notEnabled
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        if canSketch {
            let host = UIHostingController(rootView: ThemedRoot { SketchHereHint() })
            host.view.backgroundColor = .clear
            host.sizingOptions = [.intrinsicContentSize]
            host.overrideUserInterfaceStyle = dark ? .dark : .light
            host.view.isUserInteractionEnabled = false
            addSubview(host.view)
            hint = host
        }
        #else
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = dim.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("drawing.shield")
        setAccessibilityLabel(canSketch ? "Sketch on this pane" : "Not available while sketching")
        if canSketch {
            let host = NSHostingView(rootView: ThemedRoot { SketchHereHint() })
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            addSubview(host)
            hint = host
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    #if os(iOS)
    @objc private func tapped() { onActivate?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let view = hint?.view else { return }
        let size = view.intrinsicContentSize
        view.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return nil }
        return super.hitTest(point, with: event)
    }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
    #else
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let hint else { return }
        let size = hint.fittingSize
        hint.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    override func resetCursorRects() {
        if hint != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }
    #endif
}

struct SketchHereHint: View {
    var body: some View {
        Label("Sketch Here", systemImage: "pencil.tip")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 6)
            .floatingCapsule()
            .fixedSize()
    }
}

/// The same dim over the tab's editor, browser and tool leaves, which cannot be sketched on.
struct SketchLeafShield: View {
    let leaf: PaneId
    let workspace: Workspace?
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        if SketchMode.shared.shields(leaf: leaf, in: workspace) {
            theme.background.opacity(0.35)
                .contentShape(.rect)
                .onTapGesture {}
                .accessibilityIdentifier("drawing.shield")
        }
    }
}

#if os(iOS)
private typealias PlatformColor = UIColor
#else
private typealias PlatformColor = NSColor
#endif
