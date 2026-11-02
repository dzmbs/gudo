#if os(iOS)
/// Hold-to-repeat with iOS keyboard timing: the first repeat fires 400 ms after the press, then one
/// every 45 ms. UIKit sends no repeats for hardware keys handled in
/// `pressesBegan`, so the terminal view uses this as well as the key bar.
@MainActor
public final class KeyRepeater {
    public static let initialDelay = Duration.milliseconds(400)
    public static let interval = Duration.milliseconds(45)

    private var task: Task<Void, Never>?

    public init() {}

    /// Calls `fire` after the initial delay, then at the repeat interval until `stop()`. Replaces a
    /// repeat that is already running. Deadlines are absolute, so a late tick does not drift.
    public func start(_ fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            let clock = ContinuousClock()
            var deadline = clock.now + Self.initialDelay
            while !Task.isCancelled {
                guard (try? await clock.sleep(until: deadline, tolerance: .milliseconds(1))) != nil else { return }
                fire()
                deadline += Self.interval
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
#endif
