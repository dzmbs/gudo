import Foundation

@MainActor
public final class TimelineChannel {
    nonisolated public enum Packet: Equatable, Sendable {
        case reset
        case snapshot(String)
        case update(String)
        case unavailable(String)
    }

    public let pane: UInt64
    private let resolve: () throws -> any DaemonTimelineAPI
    private var observers: [UUID: (Packet) -> Void] = [:]
    private var watchTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var client: (any DaemonTimelineAPI)?
    private var attempt = UUID()
    private var pending: [String] = []
    private var pendingBytes = 0
    private var needsRefresh = false
    private var isClosed = false
    private var isPaused = false

    init(pane: UInt64, resolve: @escaping () throws -> any DaemonTimelineAPI) {
        self.pane = pane
        self.resolve = resolve
    }

    public func observe(_ handler: @escaping (Packet) -> Void) -> UUID {
        let token = UUID()
        guard !isClosed else { handler(.unavailable("This pane has closed. Open Terminal.")); return token }
        observers[token] = handler
        requestSnapshot()
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
        if observers.isEmpty { stop() }
    }

    public func requestSnapshot() {
        guard !isClosed, !isPaused, !observers.isEmpty, watchTask == nil, stopTask == nil else { return }
        let client: any DaemonTimelineAPI
        do { client = try resolve() } catch {
            publish(.unavailable("Chat is unavailable. Open Terminal."))
            return
        }
        self.client = client
        let attempt = UUID()
        self.attempt = attempt
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        needsRefresh = false
        watchTask = Task { [self] in
            do {
                let snapshot = try await client.timelineWatch(paneId: pane)
                guard self.attempt == attempt else { return }
                watchTask = nil
                guard !observers.isEmpty, !isClosed else { stop(); return }
                let updates = pending
                let shouldRefresh = needsRefresh
                pending.removeAll(keepingCapacity: true)
                pendingBytes = 0
                needsRefresh = false
                publish(.snapshot(snapshot))
                if shouldRefresh {
                    requestSnapshot()
                } else {
                    for update in updates { publish(.update(update)) }
                }
            } catch {
                guard self.attempt == attempt else { return }
                watchTask = nil
                pending.removeAll(keepingCapacity: false)
                pendingBytes = 0
                publish(.unavailable("Chat could not connect. Open Terminal."))
                if observers.isEmpty { stop() }
            }
        }
    }

    func receive(_ json: String) {
        guard !isClosed, !isPaused, !observers.isEmpty else { return }
        guard watchTask != nil else { publish(.update(json)); return }
        guard !needsRefresh else { return }
        let bytes = json.utf8.count
        guard pending.count < 64, pendingBytes + bytes <= 2 * 1_024 * 1_024 else {
            pending.removeAll(keepingCapacity: false)
            pendingBytes = 0
            needsRefresh = true
            return
        }
        pending.append(json)
        pendingBytes += bytes
    }

    func reconnect() {
        isPaused = false
        resetConnection()
        publish(.reset)
        requestSnapshot()
    }

    func disconnected() {
        isPaused = true
        resetConnection()
    }

    private func resetConnection() {
        attempt = UUID()
        watchTask?.cancel()
        watchTask = nil
        stopTask?.cancel()
        stopTask = nil
        client = nil
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        needsRefresh = false
    }

    func close() {
        isClosed = true
        publish(.unavailable("This pane has closed. Open Terminal."))
        observers.removeAll()
        stop()
    }

    private func publish(_ packet: Packet) {
        for observer in Array(observers.values) { observer(packet) }
    }

    private func stop() {
        // An in-flight watch must finish before unwatch, even if its last viewer leaves.
        guard watchTask == nil, stopTask == nil, let client else { return }
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        needsRefresh = false
        self.client = nil
        let attempt = self.attempt
        stopTask = Task { [self] in
            try? await client.timelineUnwatch(paneId: pane)
            guard self.attempt == attempt else { return }
            stopTask = nil
            if !observers.isEmpty { requestSnapshot() }
        }
    }
}

extension DaemonWorkspace {
    public func timelineChannel(pane: UInt64) -> TimelineChannel {
        if let channel = timelineChannels[pane] { return channel }
        let channel = TimelineChannel(pane: pane) { [weak self] in
            guard let self else { throw HostError.notConnected }
            return try timelineClient()
        }
        timelineChannels[pane] = channel
        return channel
    }
}
