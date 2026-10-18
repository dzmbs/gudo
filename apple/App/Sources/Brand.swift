import Foundation

/// Product naming comes from apple/Brand.xcconfig through the bundle, never from string literals.
nonisolated enum Brand {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
}
