import Foundation
import Network

/// A minimal HTTP/1.1 server built directly on `NWListener`.
///
/// Deliberately not a general-purpose server: it speaks just enough HTTP for the
/// viewer page plus a handful of JSON endpoints, always closes after one request,
/// and has no TLS. That keeps the dependency list empty (no SwiftNIO) and the
/// behaviour auditable — which matters because this process can see your screen.
///
/// Access control is enforced at the application layer (`allowRemote`) rather than
/// purely by the bind address, so `host: 127.0.0.1` in the config is a real
/// guarantee and not just a hint. The bind address is narrowed as well, as
/// defence in depth.
public final class HTTPServer {
    public typealias Handler = (HTTPRequest, HTTPResponder) -> Void

    /// Caps concurrent sockets so a misbehaving client cannot exhaust descriptors.
    private static let maxConnections = 64

    private let queue = DispatchQueue(label: "com.sarainoq.screenbeam.http")
    private let listener: NWListener
    private let handler: Handler
    private let allowRemote: Bool

    private var connections: [ObjectIdentifier: Connection] = [:]
    private let readySemaphore = DispatchSemaphore(value: 0)
    private var startError: Error?

    public private(set) var boundPort: UInt16

    private final class Connection {
        let socket: NWConnection
        let responder: HTTPResponder
        // `var`: the parser accumulates bytes across receive callbacks.
        var parser = HTTPRequestParser()

        init(socket: NWConnection, responder: HTTPResponder) {
            self.socket = socket
            self.responder = responder
        }
    }

    public init(
        port: UInt16,
        loopbackOnly: Bool,
        handler: @escaping Handler
    ) throws {
        self.handler = handler
        self.allowRemote = !loopbackOnly

        let parameters = NWParameters.tcp
        // Without this a restart can fail with "address already in use" while the
        // previous socket sits in TIME_WAIT — very visible for a daemon.
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPServerError.invalidPort(port)
        }

        // Binding to a specific host goes through `requiredLocalEndpoint`, and the
        // port must come from that endpoint — passing it to the initializer as
        // well makes the listener fail with EINVAL.
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: nwPort
            )
            do {
                self.listener = try NWListener(using: parameters)
            } catch {
                throw HTTPServerError.bindFailed("127.0.0.1:\(port) — \(error)")
            }
        } else {
            do {
                self.listener = try NWListener(using: parameters, on: nwPort)
            } catch {
                throw HTTPServerError.bindFailed("0.0.0.0:\(port) — \(error)")
            }
        }
        self.boundPort = port
    }

    public func start() throws {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port?.rawValue {
                    self.boundPort = port
                }
                self.readySemaphore.signal()
            case .failed(let error):
                self.startError = error
                self.readySemaphore.signal()
            case .cancelled:
                self.readySemaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)

        // Give the listener a moment to bind so a port conflict surfaces as a
        // real error at startup instead of a silently dead daemon.
        if readySemaphore.wait(timeout: .now() + 5) == .timedOut {
            throw HTTPServerError.startTimedOut
        }
        if let error = startError {
            throw HTTPServerError.bindFailed(String(describing: error))
        }
    }

    public func stop() {
        listener.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values {
                connection.responder.close()
                connection.socket.cancel()
            }
            self.connections.removeAll()
        }
    }

    // MARK: - Connection handling

    private func accept(_ socket: NWConnection) {
        guard admit(socket) else {
            socket.cancel()
            return
        }

        let responder = HTTPResponder(connection: socket, queue: queue)
        let connection = Connection(socket: socket, responder: responder)
        let key = ObjectIdentifier(connection)

        queue.async { [weak self] in
            guard let self else { return }
            if self.connections.count >= Self.maxConnections {
                Log.warn("并发连接已达上限，拒绝新连接。")
                socket.cancel()
                return
            }
            self.connections[key] = connection
            responder.addCloseHandler { [weak self] in
                self?.queue.async { self?.connections.removeValue(forKey: key) }
            }
            responder.armIdleTimeout()
            self.pump(connection)
        }

        socket.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections.removeValue(forKey: key) }
                responder.notifyClosed()
            default:
                break
            }
        }
        socket.start(queue: queue)
    }

    /// Rejects non-loopback peers when the config asks for local-only access.
    /// `allowRemote == false` is enforced here and not only by the bind address.
    private func admit(_ socket: NWConnection) -> Bool {
        if allowRemote { return true }
        guard case let .hostPort(host, _) = socket.endpoint else { return false }
        let value = "\(host)"
        let allowed = value == "127.0.0.1" || value == "::1" || value == "localhost"
        if !allowed {
            Log.warn("已拒绝来自 \(value) 的连接（当前配置仅允许本机访问）。")
        }
        return allowed
    }

    /// Reads exactly one request, dispatches it, and stops reading.
    ///
    /// Every response is `Connection: close` (or a stream the server drives), so
    /// there is no keep-alive to implement and no pipelining state to track. Not
    /// re-arming the receive afterwards also removes a race where a handler that
    /// replied synchronously could be re-entered by buffered bytes.
    private func pump(_ connection: Connection) {
        connection.socket.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                connection.parser.append(data)
                do {
                    if let request = try connection.parser.next() {
                        self.handler(request, connection.responder)
                        return
                    }
                } catch {
                    connection.responder.respond(.error(400, String(describing: error)))
                    return
                }
            }

            if error != nil || isComplete {
                connection.responder.close()
                return
            }

            // Partial request; keep reading.
            self.queue.async { self.pump(connection) }
        }
    }
}

public enum HTTPServerError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    case startTimedOut
    case bindFailed(String)

    public var description: String {
        switch self {
        case .invalidPort(let port):
            return "端口无效：\(port)"
        case .startTimedOut:
            return "HTTP 服务启动超时。"
        case .bindFailed(let detail):
            return "HTTP 服务绑定失败：\(detail)"
        }
    }
}
