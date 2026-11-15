import CoreGraphics

/// An inline image keeps one height from the first frame, so loading it never moves the rows.
nonisolated enum ChatImageBox {
    static let height: CGFloat = 220
    static let attachmentHeight: CGFloat = 120
    static let maximumPixelSize = 1_600
    static let maximumFileBytes: UInt64 = 24 << 20
}
