#if os(iOS)
import SwiftUI
import UIKit

/// Reports the window's fold to its model: the hinge from `UIHingeInteraction` (called with the
/// first state and on every change) and the division region, read in `updateConstraints()` so
/// UIKit runs it again whenever the region moves. Fills the window, so its coordinates are the
/// window's. Off a foldable (and before iOS 27.1) there is no hinge and the fold stays empty.
struct FoldProbe: UIViewRepresentable {
    let model: WindowModel

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = { [weak model] hinge, division, active in
            guard let model else { return }
            #if DEBUG
            if model.debugPosture != nil { return }
            #endif
            var next = model.fold
            next.hinge = hinge
            next.division = division
            next.isDivisionActive = active
            model.updateFold(next)
        }
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.layout = model.foldLayout
    }

    /// The page holding `view` in screen coordinates while its window lies open across a fold
    /// (`FoldLayout.pages`); nil otherwise. The key bar, in the keyboard's own window, keeps to it.
    static func page(containing view: UIView) -> CGRect? {
        guard let window = view.window,
              case .pages(let leading, let gutter) = ProbeView.layouts[ObjectIdentifier(window)]
        else { return nil }
        let frame = view.convert(view.bounds, to: window)
        let bounds = window.bounds
        let page = frame.midX < leading
            ? CGRect(x: bounds.minX, y: bounds.minY, width: leading, height: bounds.height)
            : CGRect(x: leading + gutter, y: bounds.minY, width: bounds.width - leading - gutter, height: bounds.height)
        return window.convert(page, to: window.screen.coordinateSpace)
    }

    final class ProbeView: UIView {
        /// Each window's layout, for `page(containing:)`.
        fileprivate static var layouts: [ObjectIdentifier: FoldLayout] = [:]
        var layout = FoldLayout.standard {
            didSet { register() }
        }
        private weak var registered: UIWindow?

        private func register() {
            if let registered, registered !== window { Self.layouts[ObjectIdentifier(registered)] = nil }
            registered = window
            if let window { Self.layouts[ObjectIdentifier(window)] = layout }
        }
        var onChange: ((HingeReading?, CGRect?, Bool) -> Void)?
        private var hinge: HingeReading?
        private var installed = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            register()
            guard window != nil, !installed else { return }
            installed = true
            if #available(iOS 27.1, *) {
                addInteraction(UIHingeInteraction { [weak self] _, update in
                    guard let self else { return }
                    hinge = update.hinge.map { HingeReading(status: .init($0.status), angle: Double($0.angle)) }
                    setNeedsUpdateConstraints()
                    report()
                })
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            setNeedsUpdateConstraints()
        }

        override func updateConstraints() {
            super.updateConstraints()
            report()
        }

        private func report() {
            guard window != nil else { return }
            var division: CGRect?
            var active = false
            if #available(iOS 27.1, *) {
                // Inactive ones too: a flat screen still says where its fold is.
                if let region = reservedRegions(kind: .division, options: .includeInactive).first {
                    division = region.frame
                    active = region.isActive
                }
            }
            onChange?(hinge, division, active)
        }
    }
}

@available(iOS 27.1, *)
private extension HingeReading.Status {
    init(_ status: UIHinge.Status) {
        switch status {
        case .closed: self = .closed
        case .partiallyOpen: self = .partiallyOpen
        case .fullyOpen: self = .fullyOpen
        default: self = .unknown
        }
    }
}
#endif
