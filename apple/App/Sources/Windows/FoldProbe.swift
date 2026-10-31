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
        #if DEBUG
        view.debugPostureObserver = DebugPostures.observe { [weak model] posture in model?.debugPosture = posture }
        #endif
        view.onChange = { [weak model] hinge, division, active, size in
            guard let model else { return }
            #if DEBUG
            if let posture = model.debugPosture {
                model.updateFold(.simulated(posture, in: size))
                return
            }
            #endif
            model.updateFold(FoldGeometry(hinge: hinge, division: division, isDivisionActive: active, windowSize: size))
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
        #if DEBUG
        var debugPostureObserver: NSObjectProtocol?
        #endif

        private func register() {
            if let registered, registered !== window { Self.layouts[ObjectIdentifier(registered)] = nil }
            registered = window
            if let window { Self.layouts[ObjectIdentifier(window)] = layout }
        }
        var onChange: ((HingeReading?, CGRect?, Bool, CGSize) -> Void)?
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
            onChange?(hinge, division, active, bounds.size)
        }
    }
}

#if DEBUG
/// Folds the simulator from outside without a prompt: `xcrun simctl spawn <device> notifyutil -p
/// dev.unnamed.debug.posture.<name>` (`real`: the device's own hinge). A URL would ask first.
enum DebugPostures {
    private static let prefix = "dev.unnamed.debug.posture."
    private static let local = Notification.Name("DebugPosture")
    nonisolated(unsafe) private static var installed = false

    static func observe(_ apply: @escaping @MainActor (FoldPosture?) -> Void) -> NSObjectProtocol {
        install()
        return NotificationCenter.default.addObserver(forName: local, object: nil, queue: .main) { note in
            let name = note.object as? String
            MainActor.assumeIsolated { apply(name.flatMap(FoldPosture.init(rawValue:))) }
        }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in FoldPosture.allCases.map(\.rawValue) + ["real"] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                let posture = String(name.dropFirst(DebugPostures.prefix.count))
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: DebugPostures.local, object: posture)
                }
            }, (prefix + name) as CFString, nil, .deliverImmediately)
        }
    }
}
#endif

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
