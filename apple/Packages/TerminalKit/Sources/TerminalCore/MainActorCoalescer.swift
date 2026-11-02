import Synchronization

/// Hands notifications from any thread to the main actor, folding a burst into one call: a
/// signal while a call is already queued adds nothing. A program can set its title or ring
/// the bell hundreds of thousands of times a second; the main actor then runs at most once
/// per turn instead of once per event. A signal that arrives while the action runs queues
/// one more call, so the last change is never missed.
public final class MainActorCoalescer: Sendable {
    private let queued = Atomic<Bool>(false)
    private let action: @MainActor @Sendable () -> Void

    public init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    public func signal() {
        guard !queued.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Task { @MainActor [self] in
            queued.store(false, ordering: .releasing)
            action()
        }
    }
}
