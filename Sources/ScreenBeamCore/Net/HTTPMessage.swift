import Foundation

// MARK: - Request

public struct HTTPRequest: Sendable {
    public let method: String
    public let rawTarget: String
    /// Percent-decoded path, always starting with `/` and without the query.
    public let path: String
    public let query: [String: String]
    /// Header names are lower-cased so lookups are case-insensitive.
    public let headers: [String: String]
    public let body: Data

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Path split into non-empty segments, used by the router.
    public var segments: [String] {
        path.split(separator: "/").map(String.init)
    }
}

public enum HTTPParseError: Error, CustomStringConvertible {
    case malformedRequestLine
    case headersTooLarge
    case bodyTooLarge
    case unsupportedTransferEncoding

    public var description: String {
        switch self {
        case .malformedRequestLine: return "请求行格式错误"
        case .headersTooLarge: return "请求头过大"
        case .bodyTooLarge: return "请求体过大"
        case .unsupportedTransferEncoding: return "不支持 Transfer-Encoding"
        }
    }
}

/// Incremental HTTP/1.1 request parser.
///
/// `Network.framework` hands us arbitrary byte chunks, so the parser keeps a
/// buffer and only emits a request once the full head (and any declared body) has
/// arrived. One connection carries one request — we always answer with
/// `Connection: close` — so no pipelining state is needed.
public struct HTTPRequestParser {
    private static let maxHeadBytes = 32 * 1024
    private static let maxBodyBytes = 1024 * 1024

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() throws -> HTTPRequest? {
        guard let headEnd = Self.findHeadEnd(in: buffer) else {
            if buffer.count > Self.maxHeadBytes { throw HTTPParseError.headersTooLarge }
            return nil
        }

        let headData = buffer[buffer.startIndex..<headEnd]
        guard let headString = String(data: headData, encoding: .utf8) else {
            throw HTTPParseError.malformedRequestLine
        }

        var lines = headString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformedRequestLine }

        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw HTTPParseError.malformedRequestLine }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Duplicate headers are joined per RFC 7230 §3.2.2.
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        if let encoding = headers["transfer-encoding"], !encoding.isEmpty {
            // We only ever receive small, content-length-delimited requests from
            // our own clients, so refusing this keeps the parser simple and safe.
            throw HTTPParseError.unsupportedTransferEncoding
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= Self.maxBodyBytes else {
            throw HTTPParseError.bodyTooLarge
        }

        let bodyStart = headEnd + 4 // skip CRLFCRLF
        let available = buffer.count - (bodyStart - buffer.startIndex)
        guard available >= contentLength else { return nil }

        let bodyEnd = bodyStart + contentLength
        let body = Data(buffer[bodyStart..<bodyEnd])

        // Consume everything belonging to this request.
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let (path, query) = Self.splitTarget(rawTarget)
        return HTTPRequest(
            method: method,
            rawTarget: rawTarget,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }

    private static func findHeadEnd(in data: Data) -> Data.Index? {
        let pattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard data.count >= pattern.count else { return nil }

        // Search on a byte array: `Data.range(of:)` with a [UInt8] pattern is
        // available but allocating a copy each call is wasteful in a hot path.
        let bytes = [UInt8](data)
        let limit = bytes.count - pattern.count
        var index = 0
        while index <= limit {
            if bytes[index] == 0x0D,
               bytes[index + 1] == 0x0A,
               bytes[index + 2] == 0x0D,
               bytes[index + 3] == 0x0A {
                return data.startIndex + index
            }
            index += 1
        }
        return nil
    }

    private static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let mark = target.firstIndex(of: "?") else {
            return (decode(target), [:])
        }
        let path = String(target[target.startIndex..<mark])
        let queryString = String(target[target.index(after: mark)...])

        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "=") else {
                query[decode(String(pair))] = ""
                continue
            }
            let key = decode(String(pair[pair.startIndex..<equals]))
            let value = decode(String(pair[pair.index(after: equals)...]))
            query[key] = value
        }
        return (decode(path), query)
    }

    /// `removingPercentEncoding` also turns `+` into nothing special, which is
    /// what we want for tokens (base64url-ish) — form encoding is not used here.
    private static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}

// MARK: - Response

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func serialized(closeConnection: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"

        var allHeaders = headers
        allHeaders.append(("Content-Length", String(body.count)))
        allHeaders.append(("Server", BeamPaths.appName))
        // A capture can expose anything on screen, so no caching anywhere.
        if !allHeaders.contains(where: { $0.0.lowercased() == "cache-control" }) {
            allHeaders.append(("Cache-Control", "no-store, no-cache, must-revalidate"))
        }
        allHeaders.append(("Connection", closeConnection ? "close" : "keep-alive"))

        for (name, value) in allHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    public static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}

// MARK: - Convenience constructors

public extension HTTPResponse {
    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: data
        )
    }

    static func text(_ string: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [("Content-Type", contentType)],
            body: Data(string.utf8)
        )
    }

    static func html(_ string: String, status: Int = 200) -> HTTPResponse {
        text(string, status: status, contentType: "text/html; charset=utf-8")
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["ok": false, "error": message], status: status)
    }
}
