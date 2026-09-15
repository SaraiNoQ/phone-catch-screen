import Foundation

/// 飞书 / Lark.
///
/// Two modes, because the two kinds of bot have different powers:
///
/// - **Webhook mode** (自定义机器人, just a URL): cannot upload images at all —
///   the card `img` element needs an `img_key` that only the app APIs can mint.
///   So this mode sends an interactive card with a button that opens the viewer.
/// - **App mode** (app_id + app_secret + chat_id): uploads the image through
///   `im/v1/images`, then posts it as a real image message. This is the one that
///   actually puts the screenshot in the chat.
///
/// Giving it both is fine; app mode wins because it delivers more.
struct FeishuNotifier: Notifier {
    let label: String
    let webhook: String?
    let appId: String?
    let appSecret: String?
    let chatId: String?
    let server: String

    init(
        label: String,
        webhook: String?,
        appId: String?,
        appSecret: String?,
        chatId: String?,
        server: String = "https://open.feishu.cn"
    ) {
        self.label = label
        self.webhook = webhook
        self.appId = appId
        self.appSecret = appSecret
        self.chatId = chatId
        self.server = server
    }

    func send(_ payload: NotifyPayload) async throws {
        if let appId, let appSecret, let chatId {
            try await sendAsApp(payload, appId: appId, appSecret: appSecret, chatId: chatId)
            return
        }
        if let webhook {
            try await sendAsWebhook(payload, webhook: webhook)
            return
        }
        throw NotifyError.missingConfiguration("飞书需要 webhook，或 app_id/app_secret/chat_id")
    }

    // MARK: - App mode (real image message)

    private func sendAsApp(
        _ payload: NotifyPayload,
        appId: String,
        appSecret: String,
        chatId: String
    ) async throws {
        let token = try await tenantAccessToken(appId: appId, appSecret: appSecret)
        let imageKey = try await uploadImage(payload, token: token)

        let body: [String: Any] = [
            "receive_id": chatId,
            "msg_type": "image",
            // Feishu wants the message content as a JSON *string*, not an object.
            "content": "{\"image_key\":\"\(imageKey)\"}",
        ]

        var components = URLComponents(string: server + "/open-apis/im/v1/messages")
        components?.queryItems = [URLQueryItem(name: "receive_id_type", value: "chat_id")]
        guard let url = components?.url else {
            throw NotifyError.missingConfiguration("飞书 messages 接口地址无效")
        }

        var request = NotifySupport.request(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NotifySupport.jsonBody(body)

        try Self.check(await NotifySupport.send(request), context: "发送图片消息")
    }

    private func tenantAccessToken(appId: String, appSecret: String) async throws -> String {
        guard let url = URL(string: server + "/open-apis/auth/v3/tenant_access_token/internal") else {
            throw NotifyError.missingConfiguration("飞书 token 接口地址无效")
        }
        var request = NotifySupport.request(url: url)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NotifySupport.jsonBody(["app_id": appId, "app_secret": appSecret])

        let data = try await NotifySupport.send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["tenant_access_token"] as? String else {
            throw NotifyError.invalidResponse("飞书未返回 tenant_access_token")
        }
        return token
    }

    private func uploadImage(_ payload: NotifyPayload, token: String) async throws -> String {
        guard let url = URL(string: server + "/open-apis/im/v1/images") else {
            throw NotifyError.missingConfiguration("飞书图片上传接口地址无效")
        }

        var form = MultipartFormData()
        form.addField(name: "image_type", value: "message")
        form.addFile(
            name: "image",
            filename: "screenbeam.\(payload.shot.format.fileExtension)",
            mimeType: payload.shot.format.mimeType,
            data: payload.shot.payload
        )

        var request = NotifySupport.request(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let data = try await NotifySupport.send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payloadObject = object["data"] as? [String: Any],
              let key = payloadObject["image_key"] as? String else {
            throw NotifyError.invalidResponse("飞书未返回 image_key")
        }
        return key
    }

    // MARK: - Webhook mode (card with a link)

    private func sendAsWebhook(_ payload: NotifyPayload, webhook: String) async throws {
        guard let url = URL(string: webhook) else {
            throw NotifyError.missingConfiguration("飞书 webhook 地址无效")
        }

        let card: [String: Any] = [
            "config": ["wide_screen_mode": true],
            "header": [
                "template": "blue",
                "title": ["tag": "plain_text", "content": "ScreenBeam 截图"],
            ],
            "elements": [
                ["tag": "div", "text": ["tag": "lark_md", "content": payload.caption]],
                [
                    "tag": "action",
                    "actions": [[
                        "tag": "button",
                        "text": ["tag": "plain_text", "content": "打开查看"],
                        "url": payload.viewerURL,
                        "type": "primary",
                    ]],
                ],
            ],
        ]

        var request = NotifySupport.request(url: url)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NotifySupport.jsonBody([
            "msg_type": "interactive",
            "card": card,
        ])

        let data = try await NotifySupport.send(request)

        // The card schema changes occasionally. If the bot rejects it, a plain
        // text message with the link still gets the job done.
        guard Self.feishuCode(in: data) != 0 else { return }
        Log.warn("飞书卡片消息被拒绝，回退为纯文本。")

        var fallback = NotifySupport.request(url: url)
        fallback.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        fallback.httpBody = try NotifySupport.jsonBody([
            "msg_type": "text",
            "content": ["text": "\(payload.caption)\n\(payload.viewerURL)"],
        ])
        try Self.check(await NotifySupport.send(fallback), context: "发送文本消息")
    }

    // MARK: - Response checking

    private static func feishuObject(in data: Data) -> [String: Any]? {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return any as? [String: Any]
    }

    private static func feishuCode(in data: Data) -> Int? {
        feishuObject(in: data)?["code"] as? Int
    }

    private static func check(_ data: Data, context: String) throws {
        guard let code = feishuCode(in: data), code != 0 else { return }
        let message = feishuObject(in: data)?["msg"] as? String ?? "未知错误"
        throw NotifyError.invalidResponse("\(context)失败 code=\(code)：\(message)")
    }
}
