import Foundation

/// Delivery-path helpers: JSON escaping for webhook templates, the private-IP
/// policy that decides whether a push may reference a URL, multipart framing, and
/// shot id generation.
enum DeliveryCases {
    static let all: [(String, () throws -> Void)] = [
        // `{{text}}` lands inside the caller's own JSON document. An unescaped
        // quote there produces a body the receiving endpoint rejects, and the
        // failure surfaces as a 400 far from the cause.
        ("webhook 转义后仍是合法 JSON", {
            let messy = "he said \"hi\" and \\ left\nline2\tr\ttab"
            let escaped = NotifySupport.jsonEscape(messy)
            let document = "{\"text\":\"\(escaped)\"}"
            let parsed = try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any]
            try checkEqual(parsed?["text"] as? String, messy, "往返后的文本")
        }),

        ("webhook 转义控制字符", {
            let messy = "bell:\u{07} null:\u{00} esc:\u{1B}"
            let escaped = NotifySupport.jsonEscape(messy)
            let document = "{\"text\":\"\(escaped)\"}"
            let parsed = try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any]
            try checkEqual(parsed?["text"] as? String, messy, "控制字符往返")
        }),

        ("webhook 转义保留中文", {
            let text = "截图完成 · ScreenBeam — 3 张"
            let escaped = NotifySupport.jsonEscape(text)
            try checkEqual(escaped, text, "无需转义的文本应原样保留")
        }),

        ("webhook 转义普通文本不变", {
            try checkEqual(NotifySupport.jsonEscape("plain"), "plain", "普通文本")
        }),

        // Bark and ntfy have their *server* fetch the image, so a private address
        // would just produce a broken preview on the phone.
        ("内网地址不附加到推送", {
            let privateURLs = [
                "http://127.0.0.1:8787/x.jpg",
                "http://localhost:8787/x.jpg",
                "http://10.72.187.32:8787/x.jpg",
                "http://192.168.1.23:8787/x.jpg",
                "http://172.16.0.9:8787/x.jpg",
                "http://172.31.255.1:8787/x.jpg",
                "http://100.101.102.103:8787/x.jpg",
            ]
            for url in privateURLs {
                try check(!NtfyNotifier.isPubliclyReachable(url), "\(url) 不应被附加")
            }
        }),

        ("公网地址允许附加到推送", {
            let publicURLs = [
                "https://beam.example.com/x.jpg",
                "http://203.0.113.10:8787/x.jpg",
                // 172.32 falls outside the private /12 block.
                "http://172.32.0.1:8787/x.jpg",
            ]
            for url in publicURLs {
                try check(NtfyNotifier.isPubliclyReachable(url), "\(url) 应可附加")
            }
        }),

        ("非法地址一律视为不可附加", {
            try check(!NtfyNotifier.isPubliclyReachable("not a url"), "非 URL")
            try check(!NtfyNotifier.isPubliclyReachable(""), "空串")
        }),

        // Telegram and Feishu reject a malformed boundary, so the framing has to
        // be byte-exact.
        ("multipart 表单框定正确", {
            var form = MultipartFormData(boundary: "BOUNDARY")
            form.addField(name: "chat_id", value: "42")
            form.addFile(name: "photo", filename: "a.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))

            let text = String(decoding: form.finalized(), as: UTF8.self)
            try checkEqual(form.contentType, "multipart/form-data; boundary=BOUNDARY", "Content-Type")
            try check(text.contains("--BOUNDARY\r\n"), "起始分隔符")
            try check(
                text.contains("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n42\r\n"),
                "字段框定"
            )
            try check(
                text.contains(
                    "Content-Disposition: form-data; name=\"photo\"; filename=\"a.jpg\"\r\n"
                        + "Content-Type: image/jpeg\r\n\r\n"
                ),
                "文件框定"
            )
            try check(text.hasSuffix("--BOUNDARY--\r\n"), "结束分隔符")
        }),

        ("multipart 边界串每次不同", {
            let a = MultipartFormData()
            let b = MultipartFormData()
            try check(a.boundary != b.boundary, "共用边界串会破坏并发上传")
        }),

        // Shot ids become file names and URL path segments.
        ("截图 ID 可排序且对 URL 安全", {
            let early = ShotID.make(date: Date(timeIntervalSince1970: 1_000_000))
            let late = ShotID.make(date: Date(timeIntervalSince1970: 2_000_000))
            try check(early < late, "ID 按字符串排序即应按时间排序")

            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
            for id in [early, late] {
                try check(
                    id.unicodeScalars.allSatisfy { allowed.contains($0) },
                    "\(id) 含路径或 URL 中不安全的字符"
                )
            }
        }),

        ("同一毫秒内的截图 ID 基本不重复", {
            let date = Date(timeIntervalSince1970: 1_789_000_000)
            let ids = Set((0..<500).map { _ in ShotID.make(date: date) })
            try check(ids.count > 480, "500 次生成仅得到 \(ids.count) 个唯一 ID，随机后缀不够随机")
        }),
    ]
}
