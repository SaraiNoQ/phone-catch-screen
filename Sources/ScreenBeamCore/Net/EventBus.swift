import Foundation

/// Fan-out of live events to every connected viewer page.
///
/// Used so the phone learns about a new frame the moment it is captured, instead
/// of polling. Each subscriber is an open SSE response; removal happens either
/// explicitly or when the responder reports its socket closed.
public final class EventBus {
    private let queue = DispatchQueue(label: "com.sarainoq.screenbeam.eventbus")
    private var subscribers: [UUID: HTTPResponder] = [:]
    private var heartbeat: DispatchSourceTimer?

    public init() {}

    public var subscriberCount: Int {
        queue.sync { subscribers.count }
    }

    /// Takes ownership of `responder` until it closes.
    @discardableResult
    public func add(_ responder: HTTPResponder) -> UUID {
        let id = UUID()
        queue.sync {
            subscribers[id] = responder
            responder.addCloseHandler { [weak self] in
                self?.remove(id)
            }
            startHeartbeatIfNeeded()
        }
        Log.info("查看端已连接，当前在线 \(subscriberCount) 个。")
        return id
    }

    public func remove(_ id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.subscribers.removeValue(forKey: id) != nil else { return }
            Log.info("查看端已断开，当前在线 \(self.subscribers.count) 个。")
            if self.subscribers.isEmpty {
                self.stopHeartbeat()
            }
        }
    }

    public func broadcast(event: String, payload: [String: Any]) {
        queue.async { [weak self] in
            guard let self, !self.subscribers.isEmpty else { return }
            for responder in self.subscribers.values {
                responder.sendEvent(event, json: payload)
            }
        }
    }

    // MARK: - Heartbeat

    /// Keeps the SSE connection warm. `EventSource` ignores comment lines, so
    /// they are free to send.
    private func startHeartbeatIfNeeded() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for responder in self.subscribers.values {
                responder.sendComment("ping")
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }
}
