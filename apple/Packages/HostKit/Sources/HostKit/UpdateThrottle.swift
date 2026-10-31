/// Paces a stream of model updates for the views: the first after a quiet spell applies at once;
/// while updates keep coming, `flush` applies what has gathered at most once per `interval`.
/// A fleet of agents can report hundreds of times a second, and each applied update re-renders
/// whatever shows it.
@MainActor
final class UpdateThrottle {
    private let interval: Duration
    private let flush: @MainActor () -> Void
    private var window: Task<Void, Never>?
    private var held = false

    init(interval: Duration, flush: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.flush = flush
    }

    /// An update was gathered: flush now, or with the others at the end of the window.
    func note() {
        guard window == nil else {
            held = true
            return
        }
        flush()
        open()
    }

    func cancel() {
        window?.cancel()
        window = nil
        held = false
    }

    private func open() {
        window = Task { @MainActor [weak self] in
            guard let interval = self?.interval else { return }
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            if held {
                // Still busy: flush what gathered and keep pacing.
                held = false
                flush()
                open()
            } else {
                window = nil
            }
        }
    }
}
