import CoreGraphics

/// The hinge as the system reports it (`UIHinge`, SwiftUI `DeviceHinge`), kept free of UIKit so
/// the layout rules below are plain values.
struct HingeReading: Equatable, Sendable {
    enum Status: String, Sendable {
        case unknown, closed, partiallyOpen, fullyOpen
    }

    var status: Status
    /// Radians: 0 closed, π flat.
    var angle: Double
}

/// What a foldable is doing. iOS has no posture value (Apple DTS): it is read from the hinge's
/// status and the fold's division region, whose shape says which way the fold runs.
enum FoldPosture: String, Sendable, CaseIterable {
    /// No hinge: iPhone, iPad, Mac.
    case none
    /// Closed: the cover screen.
    case folded
    /// The inner screen, open flat.
    case flat
    /// Partly open with the fold running top to bottom: two pages.
    case book
    /// Partly open with the fold running across: a screen above, a deck below (laptop, tabletop).
    case tabletop
}

/// The window's fold: the hinge, and the division region in window coordinates (`.division`,
/// queried with `.includeInactive` so a flat screen still says where its fold is).
struct FoldGeometry: Equatable, Sendable {
    var hinge: HingeReading?
    /// The division's frame, margins included; zero wide (or tall) while the screen is flat.
    var division: CGRect?
    /// Active only while the device is partly open: then nothing interactive belongs under it.
    var isDivisionActive = false
    var windowSize: CGSize = .zero

    /// Narrower than this, a window is a phone (the width bucket's boundary).
    static let phoneWidth = WidthBucket.boundary
    /// The band kept clear over a flat fold, which still shows as a faint crease.
    static let flatGutter: CGFloat = 12

    var posture: FoldPosture {
        guard let hinge else { return .none }
        switch hinge.status {
        case .closed:
            return .folded
        case .fullyOpen:
            return .flat
        case .partiallyOpen:
            if isDivisionActive, let fold = foldLine {
                return fold.isVertical ? .book : .tabletop
            }
            // Partly open with no fold in this window: the cover screen, or one side of a split.
            return Double(windowSize.width) < Self.phoneWidth ? .folded : .flat
        case .unknown:
            return Double(windowSize.width) < Self.phoneWidth ? .folded : .flat
        }
    }

    /// Where the fold crosses this window and which way it runs. A division wider than tall runs
    /// across; a zero-sized one (flat) is read from its own extent.
    var foldLine: (isVertical: Bool, frame: CGRect)? {
        guard let division, windowSize.width > 0, windowSize.height > 0 else { return nil }
        let window = CGRect(origin: .zero, size: windowSize)
        let isVertical = division.height >= division.width
        // Only a fold that crosses the window splits it (a Split View half has none).
        if isVertical {
            guard division.midX > window.minX, division.midX < window.maxX else { return nil }
        } else {
            guard division.midY > window.minY, division.midY < window.maxY else { return nil }
        }
        return (isVertical, division)
    }

    /// The band nothing is placed under: the active division, or a thin one over a flat fold.
    var gutter: CGRect? {
        guard let fold = foldLine else { return nil }
        if isDivisionActive, fold.frame.width > 0, fold.frame.height > 0 { return fold.frame }
        let half = Self.flatGutter / 2
        return fold.isVertical
            ? CGRect(x: fold.frame.midX - half, y: 0, width: Self.flatGutter, height: windowSize.height)
            : CGRect(x: 0, y: fold.frame.midY - half, width: windowSize.width, height: Self.flatGutter)
    }
}

extension FoldGeometry {
    /// The band a partly open fold reserves in `simulated`: a guess, as Apple publishes no width
    /// (the device reports its own through the division's frame and margins).
    static let simulatedCrease: CGFloat = 24

    /// `posture` over a window of `size`, the fold through its middle: top to bottom for a book,
    /// across for tabletop, and across the long side when flat (the inner screen folds in half).
    /// For the simulator, which folds only by hand, and for tests.
    static func simulated(_ posture: FoldPosture, in size: CGSize) -> FoldGeometry {
        var fold = FoldGeometry(windowSize: size)
        let vertical = CGRect(x: size.width / 2, y: 0, width: 0, height: size.height)
        let across = CGRect(x: 0, y: size.height / 2, width: size.width, height: 0)
        let half = simulatedCrease / 2
        switch posture {
        case .none:
            break
        case .folded:
            fold.hinge = HingeReading(status: .closed, angle: 0)
        case .flat:
            fold.hinge = HingeReading(status: .fullyOpen, angle: .pi)
            fold.division = size.width >= size.height ? vertical : across
        case .book:
            fold.hinge = HingeReading(status: .partiallyOpen, angle: .pi * 5 / 9)
            fold.division = vertical.insetBy(dx: -half, dy: 0)
            fold.isDivisionActive = true
        case .tabletop:
            fold.hinge = HingeReading(status: .partiallyOpen, angle: .pi * 5 / 9)
            fold.division = across.insetBy(dx: 0, dy: -half)
            fold.isDivisionActive = true
        }
        return fold
    }
}

/// How a window uses its fold.
enum FoldLayout: Equatable, Sendable {
    /// What the window's width gives: iPhone, iPad, Mac, the cover screen, a Split View half, and
    /// the inner screen held tall and flat (scrolling content may cross a flat fold; HIG).
    case standard
    /// A fold top to bottom (open wide, or a book): one page each side. `leading` is the left
    /// page's width and `gutter` the band between the pages, both in window points.
    case pages(leading: CGFloat, gutter: CGFloat)
    /// A fold across, partly open: the terminal above, the deck below. `top` is the upper
    /// screen's height and `gutter` the band between them.
    case deck(top: CGFloat, gutter: CGFloat)

    /// Each side of a fold must hold a phone-width page; a narrower half is no page at all.
    static let minimumPage: CGFloat = 320
    static let minimumDeck: CGFloat = 200

    static func plan(_ fold: FoldGeometry) -> FoldLayout {
        guard let gutter = fold.gutter, let line = fold.foldLine else { return .standard }
        let size = fold.windowSize
        switch fold.posture {
        case .flat where line.isVertical, .book where line.isVertical:
            let leading = gutter.minX
            let trailing = size.width - gutter.maxX
            guard leading >= minimumPage, trailing >= minimumPage else { return .standard }
            return .pages(leading: leading, gutter: gutter.width)
        case .tabletop where !line.isVertical:
            let top = gutter.minY
            let bottom = size.height - gutter.maxY
            guard top >= minimumDeck, bottom >= minimumDeck else { return .standard }
            return .deck(top: top, gutter: gutter.height)
        default:
            return .standard
        }
    }
}

extension FoldLayout {
    var name: String {
        switch self {
        case .standard: "standard"
        case .pages: "pages"
        case .deck: "deck"
        }
    }

    var isPages: Bool {
        if case .pages = self { true } else { false }
    }

    /// The band over the fold, nothing on it.
    var gutter: CGFloat {
        switch self {
        case .standard: 0
        case .pages(_, let gutter), .deck(_, let gutter): gutter
        }
    }

    /// The left page's width for a view whose leading edge is at `x` (window points).
    func leadingPage(from x: CGFloat) -> CGFloat? {
        if case .pages(let leading, _) = self { max(0, leading - x) } else { nil }
    }

    /// The upper screen's height for a view whose top is at `y` (window points).
    func deckTop(from y: CGFloat) -> CGFloat? {
        if case .deck(let top, _) = self { max(0, top - y) } else { nil }
    }
}
