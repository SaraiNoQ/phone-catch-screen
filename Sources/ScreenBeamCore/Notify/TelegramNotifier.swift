import Foundation

/// Telegram Bot API.
///
/// This is the one backend that uploads the image bytes itself, so it works from
/// anywhere — no LAN reachability, no public URL, no tunnel. If you want frames
/// delivered while you are away from home, this is the channel to configure.
struct TelegramNotifier: Notifier {
    let label: String
    let botToken: String
    let chatId: String

    private var apiBase: URL? {
        URL(string: "https://api.telegram.org/bot\(botToken)")
    }

    func send(_ payload: NotifyPayload) async throws {
        guard let base = apiBase else {
            throw NotifyError.missingConfiguration("Telegram bot token 无效")
        }

        // Telegram caps photo captions at 1024 chars.
        let caption = payload.caption.count > 1000
            ? String(payload.caption.prefix(1000))
            : payload.caption

        var form = MultipartFormData()
        form.addField(name: "chat_id", value: chatId)
        form.addField(name: "caption", value: caption)
        form.addFile(
            name: "photo",
            filename: "screenbeam-\(payload.shot.id).\(payload.shot.format.fileExtension)",
            mimeType: payload.shot.format.mimeType,
            data: payload.shot.payload
        )

        var request = NotifySupport.request(url: base.appendingPathComponent("sendPhoto"))
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let data = try await NotifySupport.send(request)

        // Telegram reports application-level failures with HTTP 200 in some
        // cases, so check the envelope as well.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = object["ok"] as? Bool, !ok {
            let description = object["description"] as? String ?? "未知错误"
            throw NotifyError.invalidResponse("Telegram 返回失败：\(description)")
        }
    }
}
