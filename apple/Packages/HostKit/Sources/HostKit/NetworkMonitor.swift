import Foundation
import Network
import Observation

/// The device's network path (NWPathMonitor), for the offline banner and for redialling on
/// path changes (retry budgets reset on network change).
@MainActor
@Observable
public final class NetworkMonitor {
    public private(set) var isOffline = false
    /// Interface types of the current path ("wifi", "cellular", "wired", "other").
    public private(set) var interfaces: [String] = []
    /// Low Data Mode is on for the current path.
    public private(set) var isLowDataMode = false
    /// Called after the usable path changed (debounced), not for the first report.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Called when Low Data Mode turns on or off.
    @ObservationIgnored public var onLowDataModeChange: ((Bool) -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastSignature: String?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            let interfaces = path.availableInterfaces.map { interface -> String in
                switch interface.type {
                case .wifi: "wifi"
                case .cellular: "cellular"
                case .wiredEthernet: "wired"
                default: "other"
                }
            }
            let signature = "\(offline)|\(interfaces.joined(separator: ","))|\(path.isExpensive)"
            let lowDataMode = path.isConstrained
            Task { @MainActor [weak self] in
                self?.update(offline: offline, interfaces: interfaces, lowDataMode: lowDataMode, signature: signature)
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }

    private func update(offline: Bool, interfaces: [String], lowDataMode: Bool, signature: String) {
        isOffline = offline
        self.interfaces = interfaces
        if lowDataMode != isLowDataMode {
            isLowDataMode = lowDataMode
            onLowDataModeChange?(lowDataMode)
        }
        defer { lastSignature = signature }
        guard let lastSignature, lastSignature != signature, !offline else { return }
        // Interfaces flap while Wi-Fi hands over; act once it settles.
        debounce?.cancel()
        debounce = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            self?.onChange?()
        }
    }
}
