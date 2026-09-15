import Foundation
import ScreenBeamCore

/// Talks to a running daemon over its own HTTP API.
///
/// Reusing the HTTP surface (rather than a bespoke IPC channel) means the CLI,
/// the phone page, and anything else you wire up all go through one code path
/// that is already exercised every time a page loads.
struct DaemonClient {
    let baseURL: URL
    let token: String

    init(config: BeamConfig) throws {
        // `0.0.0.0` is a bind address, not a destination — connect over loopback.
        let host = config.server.isLoopbackOnly ? "127.0.0.1" : "127.0.0.1"
        guard let url = URL(string: "http://\(host):\(config.server.port)") else {
            throw CLIError.invalidConfiguration("无法构造服务地址")
        }
        self.baseURL = url
        self.token = config.server.token
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        // Split any query off before appending. `appendingPathComponent` percent-
        // encodes the whole argument, so a path like "api/devices/revoke?id=1"
        // would become ".../revoke%3Fid=1" and the route would never match — the
        // server would see one segment, "revoke?id=1", instead of two.
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathOnly = String(parts[0])

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(pathOnly),
            resolvingAgainstBaseURL: false
        ) else {
            throw CLIError.invalidConfiguration("接口地址无效：\(path)")
        }

        var items = [URLQueryItem(name: "token", value: token)]
        if parts.count > 1 {
            let extra = URLComponents(string: "?\(parts[1])")?.queryItems ?? []
            items.append(contentsOf: extra)
        }
        components.queryItems = items

        guard let url = components.url else {
            throw CLIError.invalidConfiguration("接口地址无效：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60 // a capture on a busy machine can take a moment
        return request
    }

    /// Returns nil when nothing is listening, so callers can fall back to local
    /// capture instead of treating "daemon not running" as an error.
    func isRunning() async -> Bool {
        var probe = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        probe.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: probe)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func call(_ path: String, method: String = "GET") async throws -> [String: Any] {
        let request = try request(path, method: method)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(status) else {
            let message = object?["error"] as? String
                ?? String(data: data, encoding: .utf8)
                ?? "未知错误"
            throw CLIError.daemonRejected(status: status, message: message)
        }
        return object ?? [:]
    }

    func status() async throws -> [String: Any] { try await call("api/status") }
    func shot() async throws -> [String: Any] { try await call("api/shot", method: "POST") }
    func reload() async throws -> [String: Any] { try await call("api/reload", method: "POST") }

    func pairCode() async throws -> [String: Any] {
        try await call("api/pair/code", method: "POST")
    }

    func devices() async throws -> [String: Any] {
        try await call("api/devices")
    }

    func revokeDevice(id: String) async throws -> [String: Any] {
        try await call("api/devices/revoke?id=\(id)", method: "POST")
    }

    func captureMode() async throws -> [String: Any] {
        try await call("api/capture/mode?mode=display", method: "POST")
    }

    func push(recapture: Bool) async throws -> [String: Any] {
        try await call("api/push?recapture=\(recapture ? 1 : 0)", method: "POST")
    }

    func watch(_ action: String) async throws -> [String: Any] {
        try await call("api/watch/\(action)", method: "POST")
    }

    /// Fetches the raw image bytes for a shot so the CLI can write a file.
    func imageData(shotPath: String) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(shotPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        ) else {
            throw CLIError.invalidConfiguration("图片地址无效")
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            throw CLIError.invalidConfiguration("图片地址无效")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CLIError.daemonRejected(status: status, message: "下载截图失败")
        }
        return data
    }
}

enum CLIError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case daemonRejected(status: Int, message: String)
    case notInstalled(String)

    var description: String {
        switch self {
        case .invalidConfiguration(let detail):
            return detail
        case .daemonRejected(let status, let message):
            return "服务返回 HTTP \(status)：\(message)"
        case .notInstalled(let detail):
            return detail
        }
    }
}
