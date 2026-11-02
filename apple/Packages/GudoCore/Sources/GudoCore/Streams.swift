// Hand-written conveniences over the generated bindings (GudoCore.swift).

/// A `ClientEventListener` that turns events into an `AsyncStream`.
///
/// Rust calls `onEvent` on its runtime threads; the stream hands events to whichever task
/// iterates it (typically one on the main actor). Pass the same stream to a `DaemonClient`
/// and to any number of `SshPane`s, or one per connection.
///
/// ```swift
/// let stream = ClientEventStream()
/// let client = try DaemonClient.connect(ticket: ticket, config: config, listener: stream)
/// for await event in stream.events { … }
/// ```
public final class ClientEventStream: ClientEventListener {
    /// The events, in order.
    public let events: AsyncStream<ClientEvent>
    private let continuation: AsyncStream<ClientEvent>.Continuation

    /// `bufferingPolicy` bounds the queue if the consumer falls behind; the default keeps
    /// everything (dropping `PaneBytes` would corrupt the terminal).
    public init(bufferingPolicy: AsyncStream<ClientEvent>.Continuation.BufferingPolicy = .unbounded) {
        (events, continuation) = AsyncStream.makeStream(of: ClientEvent.self, bufferingPolicy: bufferingPolicy)
    }

    public func onEvent(event: ClientEvent) {
        continuation.yield(event)
    }

    /// Ends the stream.
    public func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}

/// An `SshSessionListener` that turns state changes into an `AsyncStream`.
public final class SshStateStream: SshSessionListener {
    /// The states, in order.
    public let states: AsyncStream<SshConnectionState>
    private let continuation: AsyncStream<SshConnectionState>.Continuation

    public init() {
        (states, continuation) = AsyncStream.makeStream(of: SshConnectionState.self)
    }

    public func onState(state: SshConnectionState) {
        continuation.yield(state)
    }

    deinit {
        continuation.finish()
    }
}
