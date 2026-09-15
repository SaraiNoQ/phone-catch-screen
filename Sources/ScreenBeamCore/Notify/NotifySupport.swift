import Foundation

/// Small helpers shared by the delivery backends.
enum NotifySupport {
    static let timeout: TimeInterval = 20

    static func request(url: URL, method: String = "POST") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("\(BeamPaths.appName)/\(ScreenBeamVersion.current)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Performs the request and turns any non-2xx into a thrown error carrying the
    /// response body, which is where these APIs put the actual reason.
    @discardableResult
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return data
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<无响应体>"
            throw NotifyError.httpFailed(status: http.statusCode, body: String(body.prefix(400)))
        }
        return data
    }

    static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    /// Escapes a value that is being substituted *inside* a JSON document.
    ///
    /// The webhook template lets users drop `{{text}}` into their own JSON, so a
    /// caption containing a quote or a newline would otherwise produce a body the
    /// receiving endpoint rejects. Lives here rather than in the notifier so it
    /// can be tested directly.
    static func jsonEscape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

public enum NotifyError: Error, CustomStringConvertible {
    case missingConfiguration(String)
    case httpFailed(status: Int, body: String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .missingConfiguration(let detail):
            return "配置缺失：\(detail)"
        case .httpFailed(let status, let body):
            return "HTTP \(status) — \(body)"
        case .invalidResponse(let detail):
            return "响应异常：\(detail)"
        }
    }
}

// MARK: - Multipart

/// Minimal `multipart/form-data` builder. Used where an API only accepts the
/// image as a file upload (Telegram `sendPhoto`, Feishu `im/v1/images`).
struct MultipartFormData {
    let boundary: String
    private var body = Data()

    init(boundary: String = "----\(BeamPaths.appName)Boundary\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(name: String, value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }
}
