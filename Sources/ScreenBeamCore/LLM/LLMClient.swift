import Foundation

/// One exchange in the question history. Text only — the image is re-attached to
/// the current question each time rather than being replayed from history, which
/// would multiply the image cost across every turn.
public struct LLMTurn: Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct LLMAnswer: Sendable {
    public let text: String
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let stopReason: String?

    public var json: [String: Any] {
        var object: [String: Any] = ["text": text, "model": model]
        if let inputTokens { object["inputTokens"] = inputTokens }
        if let outputTokens { object["outputTokens"] = outputTokens }
        if let stopReason { object["stopReason"] = stopReason }
        return object
    }
}

public enum LLMError: Error, CustomStringConvertible {
    case notConfigured
    case missingKey
    case invalidBaseURL(String)
    case httpFailed(status: Int, body: String)
    case malformedResponse(String)
    case refused(String?)

    public var description: String {
        switch self {
        case .notConfigured:
            return "还没启用 AI，请在「问 AI」面板下方填写并勾选启用。"
        case .missingKey:
            return "缺少 API Key，请在「问 AI」面板下方填写。"
        case .invalidBaseURL(let value):
            return "Base URL 无效：\(value)"
        case .httpFailed(let status, let body):
            return "模型接口返回 HTTP \(status)：\(body)"
        case .malformedResponse(let detail):
            return "模型返回内容无法解析：\(detail)"
        case .refused(let category):
            return "模型拒绝回答这个请求" + (category.map { "（\($0)）" } ?? "") + "。"
        }
    }

    /// Distinguishes "not set up yet" from "the request failed", so the phone can
    /// show a setup hint instead of a red error.
    public var httpStatus: Int {
        switch self {
        case .notConfigured, .missingKey, .invalidBaseURL: return 400
        case .refused: return 200
        case .httpFailed(let status, _): return status == 401 ? 401 : 502
        case .malformedResponse: return 502
        }
    }
}

/// Calls a vision model with the current screenshot plus the user's question.
///
/// Two wire shapes rather than an SDK: Swift has no official Anthropic SDK, and
/// the OpenAI-compatible shape is the lingua franca of every other provider.
///
/// Building the request is split from sending it so the wire shape can be
/// checked without a network round trip — a wrong content-block format otherwise
/// only shows up as a runtime failure against a real API. The shapes were taken
/// from the API reference rather than from memory; see `AGENTS.md`.
public enum LLMClient {
    /// Caps replayed history so a long conversation cannot grow without bound and
    /// quietly inflate every request.
    private static let maxHistoryTurns = 20

    public static func ask(
        question: String,
        history: [LLMTurn],
        image: Shot,
        config: LLMConfig
    ) async throws -> LLMAnswer {
        guard config.enabled else { throw LLMError.notConfigured }

        let request = try buildRequest(
            question: question,
            history: history,
            image: image,
            config: config
        )
        let payload = try await send(request)
        return try parse(payload, config: config)
    }

    // MARK: - Request building

    static func buildRequest(
        question: String,
        history: [LLMTurn],
        image: Shot,
        config: LLMConfig
    ) throws -> URLRequest {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.missingKey }

        let trimmedHistory = Array(history.suffix(maxHistoryTurns))
        let body: [String: Any]

        switch config.provider {
        case .anthropic:
            body = anthropicBody(
                question: question, history: trimmedHistory, image: image, config: config
            )
        case .openai:
            body = openAIBody(
                question: question, history: trimmedHistory, image: image, config: config
            )
        }

        let path = config.provider == .anthropic ? "/v1/messages" : "/v1/chat/completions"
        var request = try makeRequest(base: config.baseURL, path: path, config: config)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch config.provider {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if config.useFallbacks {
                // Scalar form: the API picks the fallback by refusal category, so
                // there is no model list to keep current.
                request.setValue(
                    "server-side-fallback-2026-07-01",
                    forHTTPHeaderField: "anthropic-beta"
                )
            }
        case .openai:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func anthropicBody(
        question: String,
        history: [LLMTurn],
        image: Shot,
        config: LLMConfig
    ) -> [String: Any] {
        var messages: [[String: Any]] = history.map { turn in
            ["role": turn.role.rawValue, "content": [["type": "text", "text": turn.text]]]
        }

        // The image block goes before the text block.
        messages.append([
            "role": "user",
            "content": [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": image.format.mimeType,
                        "data": image.payload.base64EncodedString(),
                    ],
                ],
                ["type": "text", "text": question],
            ],
        ])

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": max(256, config.maxTokens),
            "messages": messages,
        ]
        if !config.systemPrompt.isEmpty {
            body["system"] = config.systemPrompt
        }
        if let effort = config.effort, !effort.isEmpty {
            // Thinking itself is left at the model default, which on current
            // models is adaptive — no need to ask for it.
            body["output_config"] = ["effort": effort]
        }
        if config.useFallbacks {
            body["fallbacks"] = "default"
        }
        return body
    }

    private static func openAIBody(
        question: String,
        history: [LLMTurn],
        image: Shot,
        config: LLMConfig
    ) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !config.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": config.systemPrompt])
        }
        for turn in history {
            messages.append(["role": turn.role.rawValue, "content": turn.text])
        }
        messages.append([
            "role": "user",
            "content": [
                ["type": "text", "text": question],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(image.format.mimeType);base64,\(image.payload.base64EncodedString())"
                    ],
                ],
            ],
        ])

        return [
            "model": config.model,
            "max_tokens": max(256, config.maxTokens),
            "messages": messages,
        ]
    }

    private static func makeRequest(base: String, path: String, config: LLMConfig) throws -> URLRequest {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard !trimmed.isEmpty, let url = URL(string: trimmed + path) else {
            throw LLMError.invalidBaseURL(base)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A vision call is slow; this has to sit well above the connection's idle
        // timeout, which the router extends to match.
        request.timeoutInterval = max(15, config.timeoutSeconds)
        request.setValue(
            "\(BeamPaths.appName)/\(ScreenBeamVersion.current)",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    // MARK: - Response parsing

    static func parse(_ payload: [String: Any], config: LLMConfig) throws -> LLMAnswer {
        switch config.provider {
        case .anthropic: return try parseAnthropic(payload, config: config)
        case .openai: return try parseOpenAI(payload, config: config)
        }
    }

    private static func parseAnthropic(_ payload: [String: Any], config: LLMConfig) throws -> LLMAnswer {
        let stopReason = payload["stop_reason"] as? String

        // Checked before reading content: a refusal can carry no text at all, and
        // with fallbacks enabled a refusal reaching us means the whole chain declined.
        if stopReason == "refusal" {
            let details = payload["stop_details"] as? [String: Any]
            throw LLMError.refused(details?["category"] as? String)
        }

        let text = textBlocks(in: payload["content"]).joined(separator: "\n")
        guard !text.isEmpty else {
            throw LLMError.malformedResponse("没有 text 内容块（stop_reason=\(stopReason ?? "nil")）")
        }

        let usage = payload["usage"] as? [String: Any]
        return LLMAnswer(
            text: text,
            model: payload["model"] as? String ?? config.model,
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            stopReason: stopReason
        )
    }

    /// `content` is an array of blocks; only `text` blocks carry prose. Thinking
    /// and fallback-marker blocks are deliberately skipped.
    private static func textBlocks(in value: Any?) -> [String] {
        guard let blocks = value as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
    }

    private static func parseOpenAI(_ payload: [String: Any], config: LLMConfig) throws -> LLMAnswer {
        guard let choices = payload["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.malformedResponse("响应里没有 choices[0].message")
        }

        // Some gateways return content as an array of parts rather than a string.
        let text: String
        if let plain = message["content"] as? String {
            text = plain
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            text = ""
        }
        guard !text.isEmpty else {
            throw LLMError.malformedResponse("choices[0].message.content 为空")
        }

        let usage = payload["usage"] as? [String: Any]
        return LLMAnswer(
            text: text,
            model: payload["model"] as? String ?? config.model,
            inputTokens: usage?["prompt_tokens"] as? Int,
            outputTokens: usage?["completion_tokens"] as? Int,
            stopReason: choices.first?["finish_reason"] as? String
        )
    }

    // MARK: - Transport

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? "<无响应体>"
            throw LLMError.httpFailed(status: status, body: String(body.prefix(500)))
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.malformedResponse("不是合法 JSON：\(body.prefix(200))")
        }
        return object
    }
}
