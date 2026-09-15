import Foundation

/// The parser is fed arbitrary byte chunks by Network.framework, so the cases
/// that matter are about arrival timing, not the happy path.
enum ParserCases {
    static let all: [(String, () throws -> Void)] = [
        ("解析简单 GET 请求", {
            let request = try Self.parse("GET /api/status?token=abc123 HTTP/1.1\r\nHost: mac.local\r\n\r\n")
            try checkEqual(request?.method, "GET", "method")
            try checkEqual(request?.path, "/api/status", "path")
            try checkEqual(request?.query["token"], "abc123", "query token")
            try checkEqual(request?.header("host"), "mac.local", "host header")
        }),

        ("请求头大小写不敏感", {
            let request = try Self.parse("GET / HTTP/1.1\r\nX-Auth-Token: secret\r\n\r\n")
            try checkEqual(request?.header("x-auth-token"), "secret", "小写查找")
            try checkEqual(request?.header("X-Auth-Token"), "secret", "原样查找")
        }),

        ("请求头未收全时返回 nil", {
            var parser = HTTPRequestParser()
            parser.append(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8))
            try check(try parser.next() == nil, "头部未结束时不应产出请求")

            parser.append(Data("\r\n".utf8))
            try checkEqual(try parser.next()?.path, "/", "补齐 CRLF 后应产出请求")
        }),

        ("逐字节投递也能正确解析", {
            var parser = HTTPRequestParser()
            var request: HTTPRequest?
            let bytes = Array(Data("POST /api/shot HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8))
            for byte in bytes {
                parser.append(Data([byte]))
                if let parsed = try parser.next() { request = parsed }
            }
            try checkEqual(request?.method, "POST", "method")
            try checkEqual(String(data: request?.body ?? Data(), encoding: .utf8), "hello", "body")
        }),

        ("请求体未收全时等待", {
            var parser = HTTPRequestParser()
            parser.append(Data("POST /x HTTP/1.1\r\nContent-Length: 11\r\n\r\nhel".utf8))
            try check(try parser.next() == nil, "body 不完整时不应产出请求")

            parser.append(Data("lo world".utf8))
            let request = try parser.next()
            try checkEqual(String(data: request?.body ?? Data(), encoding: .utf8), "hello world", "body")
        }),

        ("一次缓冲里的多个请求逐个消费", {
            var parser = HTTPRequestParser()
            parser.append(Data("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n".utf8))
            try checkEqual(try parser.next()?.path, "/a", "第一个请求")
            try checkEqual(try parser.next()?.path, "/b", "第二个请求")
            try check(try parser.next() == nil, "不应有多余请求")
        }),

        ("百分号解码路径与查询串", {
            let request = try Self.parse("GET /api/frame/2026%2D01.jpg?name=a%20b&x=1 HTTP/1.1\r\n\r\n")
            try checkEqual(request?.path, "/api/frame/2026-01.jpg", "path")
            try checkEqual(request?.query["name"], "a b", "带空格的查询值")
            try checkEqual(request?.query["x"], "1", "普通查询值")
        }),

        ("无值查询参数", {
            let request = try Self.parse("GET /?recapture HTTP/1.1\r\n\r\n")
            try checkEqual(request?.query["recapture"], "", "无值参数应为空串")
        }),

        ("路径分段忽略空段", {
            let request = try Self.parse("GET //api//frame//x.jpg HTTP/1.1\r\n\r\n")
            try checkEqual(request?.segments, ["api", "frame", "x.jpg"], "segments")
        }),

        ("重复请求头按 RFC 合并", {
            let request = try Self.parse("GET / HTTP/1.1\r\nAccept: a\r\nAccept: b\r\n\r\n")
            try checkEqual(request?.header("accept"), "a, b", "合并后的值")
        }),

        ("拒绝 Transfer-Encoding", {
            try checkThrows("分块传输") {
                _ = try Self.parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
            }
        }),

        ("拒绝超大请求体", {
            try checkThrows("超大 body") {
                _ = try Self.parse("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")
            }
        }),

        ("拒绝超大请求头", {
            var parser = HTTPRequestParser()
            let filler = String(repeating: "X-Pad: aaaaaaaa\r\n", count: 4000)
            parser.append(Data("GET / HTTP/1.1\r\n\(filler)".utf8))
            try checkThrows("超大 header") { _ = try parser.next() }
        }),

        ("拒绝畸形请求行", {
            try checkThrows("畸形请求行") { _ = try Self.parse("GARBAGE\r\n\r\n") }
        }),

        ("响应带 Content-Length 且禁止缓存", {
            let response = HTTPResponse.json(["ok": true])
            let text = String(data: response.serialized(closeConnection: true), encoding: .utf8) ?? ""
            try check(text.hasPrefix("HTTP/1.1 200 OK\r\n"), "状态行")
            try check(text.contains("Content-Length: "), "应带 Content-Length")
            try check(text.contains("Connection: close"), "应关闭连接")
            try check(text.contains("Cache-Control: no-store"), "截图不允许被缓存")
            try check(text.contains("\"ok\""), "JSON body")
        }),
    ]

    static func parse(_ raw: String) throws -> HTTPRequest? {
        var parser = HTTPRequestParser()
        parser.append(Data(raw.utf8))
        return try parser.next()
    }
}
