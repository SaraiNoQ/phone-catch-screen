import Foundation
import Network

/// The server side of a single HTTP connection.
///
/// A handler receives this and decides how to answer. Two shapes are supported:
/// a one-shot `respond(_:)`, or a chunked `beginStream` / `write` / `endStream`
/// sequence used by the SSE endpoint. All state is confined to `queue`, so the
/// object can be handed to any thread (the notification path writes to it from a
/// capture task) without additional locking.
public final class HTTPResponder {
    private enum State {
        case idle
        case streaming
        case closed
    }

    private let queue: DispatchQueue
    private let connection: NWConnection
    private var state: State = .idle
    private var idleDeadline: DispatchWorkItem?

    /// Peer address. Used to attribute pairing attempts to a source, and to log
    /// who connected.
    public let remoteAddress: String

    /// Fired exactly once when the socket goes away. Several owners need this
    /// (the server reaps its connection table, the event bus drops the
    /// subscriber), so it is a list rather than a single slot.
    private var closeHandlers: [() -> Void] = []
    private var didNotifyClose = false

    /// Seconds a connection may sit unanswered before it is reaped. Guards
    /// against a handler that forgets to reply and leaks a file descriptor.
    private static let idleTimeout: TimeInterval = 30

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue

        if case let .hostPort(host, _) = connection.endpoint {
            self.remoteAddress = "\(host)"
        } else {
            self.remoteAddress = "unknown"
        }
    }

    /// Registers a teardown callback. If the connection is already closed the
    /// handler runs immediately, so a late subscriber cannot leak.
    public func addCloseHandler(_ handler: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.didNotifyClose {
                handler()
            } else {
                self.closeHandlers.append(handler)
            }
        }
    }

    func armIdleTimeout() {
        queue.async { [weak self] in
            guard let self, self.state == .idle else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.state == .idle else { return }
                Log.warn("HTTP 连接超时未响应，主动关闭。")
                self.close()
            }
            self.idleDeadline = item
            self.queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: item)
        }
    }

    /// Pushes the idle deadline out, for handlers that legitimately take a long
    /// time. A vision-model call can run for a minute; without this the
    /// connection would be reaped mid-flight and the phone would just see a
    /// dropped request with no explanation.
    public func extendIdle(by seconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self, self.state == .idle else { return }
            self.idleDeadline?.cancel()

            let total = Self.idleTimeout + max(0, seconds)
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.state == .idle else { return }
                Log.warn("HTTP 连接超时未响应，主动关闭。")
                self.close()
            }
            self.idleDeadline = item
            self.queue.asyncAfter(deadline: .now() + total, execute: item)
        }
    }

    // MARK: - One-shot response

    public func respond(_ response: HTTPResponse) {
        queue.async { [weak self] in
            guard let self, self.state == .idle else { return }
            self.idleDeadline?.cancel()
            self.state = .closed

            let data = response.serialized(closeConnection: true)
            self.connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    self?.connection.cancel()
                }
            )
        }
    }

    // MARK: - Chunked stream (SSE)

    public func beginStream(status: Int = 200, headers: [(String, String)] = []) {
        queue.async { [weak self] in
            guard let self, self.state == .idle else { return }
            self.idleDeadline?.cancel()
            self.state = .streaming

            var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(for: status))\r\n"
            head += "Server: \(BeamPaths.appName)\r\n"
            for (name, value) in headers {
                head += "\(name): \(value)\r\n"
            }
            // No Content-Length: the stream is delimited by chunked framing and
            // terminated with a zero-length chunk by `endStream`.
            head += "Transfer-Encoding: chunked\r\n"
            head += "Connection: keep-alive\r\n"
            head += "\r\n"

            self.send(Data(head.utf8))
        }
    }

    public func write(chunk: Data) {
        queue.async { [weak self] in
            guard let self, self.state == .streaming else { return }
            var framed = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
            framed.append(chunk)
            framed.append(Data("\r\n".utf8))
            self.send(framed)
        }
    }

    public func endStream() {
        queue.async { [weak self] in
            guard let self, self.state == .streaming else { return }
            self.send(Data("0\r\n\r\n".utf8))
            self.state = .closed
            self.connection.send(
                content: nil,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    self?.connection.cancel()
                }
            )
        }
    }

    public func close() {
        queue.async { [weak self] in
            guard let self, self.state != .closed else { return }
            self.idleDeadline?.cancel()
            self.state = .closed
            self.connection.cancel()
        }
    }

    // MARK: - Server-Sent Events helpers

    /// Writes one SSE event. A comment line (`: ping`) is used as a heartbeat
    /// because it is ignored by `EventSource` but keeps NAT and power management
    /// from silently dropping an idle connection.
    public func sendEvent(_ name: String, json: [String: Any]) {
        let payload = (try? JSONSerialization.data(
            withJSONObject: json,
            options: [.withoutEscapingSlashes]
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var text = "event: \(name)\n"
        // A JSON body never contains a raw newline (we just serialized it), so a
        // single `data:` line is safe.
        text += "data: \(payload)\n\n"
        write(chunk: Data(text.utf8))
    }

    public func sendComment(_ text: String) {
        write(chunk: Data(": \(text)\n\n".utf8))
    }

    // MARK: - Internals

    private func send(_ data: Data) {
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    // Peer went away (phone slept, Wi-Fi roamed). Tear the
                    // connection down so the subscriber list stays accurate.
                    self.queue.async {
                        guard self.state != .closed else { return }
                        self.state = .closed
                        self.connection.cancel()
                    }
                }
            }
        )
    }

    /// Invoked by the owning connection when the socket reaches a terminal state.
    /// Runs the teardown handlers exactly once, whatever path got us here.
    func notifyClosed() {
        queue.async { [weak self] in
            guard let self, !self.didNotifyClose else { return }
            self.didNotifyClose = true
            self.idleDeadline?.cancel()
            self.state = .closed

            let handlers = self.closeHandlers
            self.closeHandlers.removeAll()
            for handler in handlers { handler() }
        }
    }
}
