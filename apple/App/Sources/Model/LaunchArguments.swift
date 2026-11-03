import Foundation

/// Test and tooling hooks read from this launch's arguments (`-testTicket …`) only, never from
/// the app's saved defaults: another process can write those (`defaults write`) and would
/// otherwise turn off host key checks or swap the helper the app installs on hosts.
nonisolated struct LaunchArguments {
    private let values: [String: Any]

    init(_ values: [String: Any] = Self.launchValues) {
        self.values = values
    }

    /// Whether this build takes test hooks at all: iPhone and iPad release builds never do.
    static var acceptsTestHooks: Bool {
        #if DEBUG || os(macOS)
        true
        #else
        false
        #endif
    }

    private static var launchValues: [String: Any] {
        acceptsTestHooks ? UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain) : [:]
    }

    func string(forKey key: String) -> String? {
        switch values[key] {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    func bool(forKey key: String) -> Bool {
        switch values[key] {
        case let string as NSString: string.boolValue
        case let number as NSNumber: number.boolValue
        default: false
        }
    }

    func integer(forKey key: String) -> Int {
        switch values[key] {
        case let string as NSString: string.integerValue
        case let number as NSNumber: number.intValue
        default: 0
        }
    }

    func double(forKey key: String) -> Double {
        switch values[key] {
        case let string as NSString: string.doubleValue
        case let number as NSNumber: number.doubleValue
        default: 0
        }
    }
}
