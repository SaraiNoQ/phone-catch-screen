import Foundation

/// The LLM layer is the one place where a wrong shape fails only at runtime,
/// against a real API, with a confusing error. These cases check the request the
/// client builds and the responses it accepts, without any network traffic.
enum LLMCases {
    static let all: [(String, () throws -> Void)] = [

        // ---- Configuration -------------------------------------------------

        ("LLM 配置部分字段缺失时用默认值", {
            let config = try JSONDecoder().decode(
                BeamConfig.self,
                from: Data(#"{"llm":{"enabled":true}}"#.utf8)
            )
            try check(config.llm.enabled, "指定的字段应生效")
            try checkEqual(config.llm.provider, .anthropic, "provider 默认值")
            try checkEqual(config.llm.model, "claude-opus-5", "model 默认值")
            try checkEqual(config.llm.baseURL, "https://api.anthropic.com", "baseURL 默认值")
            try check(config.llm.maxTokens >= 4096, "max_tokens 不应给得过小（会截断思考+回答）")
            try check(config.llm.useFallbacks, "默认应开启 refusal 兜底")
            try check(!config.llm.systemPrompt.isEmpty, "应有默认 system prompt")
        }),

        ("默认配置里 AI 是关闭的", {
            let config = ConfigStore.defaultConfig()
            try check(!config.llm.enabled, "需要用户自己填 key，不应默认开启")
            try check(!config.llm.isUsable, "没有 key 时不应可用")
        }),

        ("isUsable 需要同时满足启用与有 key", {
            var config = LLMConfig(enabled: true, apiKey: "  ")
            try check(!config.isUsable, "只有空白 key 时不可用")

            config.apiKey = "sk-test"
            try check(config.isUsable, "启用且 key 非空时应可用")

            config.enabled = false
            try check(!config.isUsable, "未启用时不可用")
        }),

        // The phone must never be able to read the key back out, or a paired
        // device could exfiltrate it.
        ("对外配置 JSON 里绝不包含 API Key", {
            let config = LLMConfig(enabled: true, apiKey: "sk-super-secret-value")
            let json = config.publicJSON

            let serialized = String(
                data: try JSONSerialization.data(withJSONObject: json),
                encoding: .utf8
            ) ?? ""
            try check(!serialized.contains("sk-super-secret-value"), "序列化结果里出现了 key")
            try check(!json.keys.contains("apiKey"), "不应有 apiKey 字段")
            try checkEqual(json["hasKey"] as? Bool, true, "应只暴露「是否已配置」")
        }),

        // ---- Anthropic request shape ---------------------------------------

        ("Anthropic 请求的形状正确", {
            let config = LLMConfig(
                enabled: true, provider: .anthropic,
                baseURL: "https://api.anthropic.com", apiKey: "sk-test",
                model: "claude-opus-5", maxTokens: 4096, effort: "low",
                systemPrompt: "你是助手", useFallbacks: true
            )
            let request = try LLMClient.buildRequest(
                question: "图里写了什么？", history: [],
                image: sampleShot(), config: config
            )

            try checkEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages", "URL")
            try checkEqual(request.httpMethod, "POST", "方法")
            try checkEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test", "x-api-key")
            try checkEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01", "版本头")
            try checkEqual(
                request.value(forHTTPHeaderField: "anthropic-beta"),
                "server-side-fallback-2026-07-01", "refusal 兜底的 beta 头"
            )
            try check(
                request.value(forHTTPHeaderField: "Authorization") == nil,
                "Anthropic 不应带 Bearer 头"
            )

            let body = try jsonBody(request)
            try checkEqual(body["model"] as? String, "claude-opus-5", "model")
            try checkEqual(body["max_tokens"] as? Int, 4096, "max_tokens")
            try checkEqual(body["system"] as? String, "你是助手", "system")
            try checkEqual(
                (body["output_config"] as? [String: Any])?["effort"] as? String,
                "low", "effort 应放在 output_config 里"
            )
            try checkEqual(body["fallbacks"] as? String, "default", "fallbacks 标量形式")

            // The image block must come first, and carry the real media type.
            let messages = try checkUnwrap(body["messages"] as? [[String: Any]], "messages")
            try checkEqual(messages.count, 1, "只有一条消息")
            let content = try checkUnwrap(messages[0]["content"] as? [[String: Any]], "content 数组")
            try checkEqual(content.count, 2, "两个内容块")
            try checkEqual(content[0]["type"] as? String, "image", "第一个块应为图片")
            try checkEqual(content[1]["type"] as? String, "text", "第二个块应为文字")
            try checkEqual(content[1]["text"] as? String, "图里写了什么？", "问题文本")

            let source = try checkUnwrap(content[0]["source"] as? [String: Any], "source")
            try checkEqual(source["type"] as? String, "base64", "source.type")
            try checkEqual(source["media_type"] as? String, "image/jpeg", "media_type")
            try checkEqual(
                source["data"] as? String,
                sampleShot().payload.base64EncodedString(),
                "base64 应与图片字节一致"
            )
        }),

        ("关闭兜底时不发送 fallbacks 与 beta 头", {
            let config = LLMConfig(
                enabled: true, provider: .anthropic, apiKey: "sk-test", useFallbacks: false
            )
            let request = try LLMClient.buildRequest(
                question: "q", history: [], image: sampleShot(), config: config
            )

            try check(request.value(forHTTPHeaderField: "anthropic-beta") == nil, "不应有 beta 头")
            let body = try jsonBody(request)
            try check(body["fallbacks"] == nil, "不应有 fallbacks 字段")
        }),

        ("清空 effort 时不发送 output_config", {
            let config = LLMConfig(enabled: true, provider: .anthropic, apiKey: "k", effort: nil)
            let request = try LLMClient.buildRequest(
                question: "q", history: [], image: sampleShot(), config: config
            )
            let body = try jsonBody(request)
            try check(body["output_config"] == nil, "effort 为空时不应发送 output_config")
        }),

        ("历史轮次会被截断，避免请求无限膨胀", {
            let history = (0..<40).map { index in
                LLMTurn(role: index % 2 == 0 ? .user : .assistant, text: "turn\(index)")
            }
            let config = LLMConfig(enabled: true, provider: .anthropic, apiKey: "k")

            let anthropic = try jsonBody(try LLMClient.buildRequest(
                question: "q", history: history, image: sampleShot(), config: config
            ))
            let anthropicMessages = try checkUnwrap(
                anthropic["messages"] as? [[String: Any]], "messages"
            )
            // 20 retained turns plus the current question.
            try checkEqual(anthropicMessages.count, 21, "Anthropic 消息数")

            var openAIConfig = config
            openAIConfig.provider = .openai
            let openai = try jsonBody(try LLMClient.buildRequest(
                question: "q", history: history, image: sampleShot(), config: openAIConfig
            ))
            let openAIMessages = try checkUnwrap(openai["messages"] as? [[String: Any]], "messages")
            // system + 20 retained turns + current question.
            try checkEqual(openAIMessages.count, 22, "OpenAI 消息数")
        }),

        ("max_tokens 有下限，避免被配置成 0 或负数", {
            let config = LLMConfig(enabled: true, provider: .anthropic, apiKey: "k", maxTokens: -5)
            let body = try jsonBody(try LLMClient.buildRequest(
                question: "q", history: [], image: sampleShot(), config: config
            ))
            try checkEqual(body["max_tokens"] as? Int, 256, "应被抬到下限")
        }),

        // ---- OpenAI request shape ------------------------------------------

        ("OpenAI 兼容请求的形状正确", {
            let config = LLMConfig(
                enabled: true, provider: .openai, baseURL: "https://api.deepseek.com",
                apiKey: "sk-openai", model: "deepseek-vl", systemPrompt: "你是助手"
            )
            let request = try LLMClient.buildRequest(
                question: "这是什么？", history: [], image: sampleShot(), config: config
            )

            try checkEqual(
                request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions", "URL"
            )
            try checkEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-openai", "鉴权头")
            try check(request.value(forHTTPHeaderField: "x-api-key") == nil, "不应带 Anthropic 头")
            try check(request.value(forHTTPHeaderField: "anthropic-version") == nil, "不应带版本头")

            let messages = try checkUnwrap(
                try jsonBody(request)["messages"] as? [[String: Any]], "messages"
            )
            try checkEqual(messages[0]["role"] as? String, "system", "system 应在最前")
            try checkEqual(messages[1]["role"] as? String, "user", "然后是用户消息")

            let content = try checkUnwrap(messages[1]["content"] as? [[String: Any]], "content")
            try checkEqual(content[0]["type"] as? String, "text", "先文字")
            try checkEqual(content[1]["type"] as? String, "image_url", "后图片")

            let imageURL = try checkUnwrap(
                (content[1]["image_url"] as? [String: Any])?["url"] as? String, "图片 URL"
            )
            try check(imageURL.hasPrefix("data:image/jpeg;base64,"), "应为 data URI：\(imageURL.prefix(40))")
        }),

        ("Base URL 末尾多余的斜杠会被处理", {
            let config = LLMConfig(
                enabled: true, provider: .openai, baseURL: "https://api.openai.com/", apiKey: "k"
            )
            let request = try LLMClient.buildRequest(
                question: "q", history: [], image: sampleShot(), config: config
            )
            try checkEqual(
                request.url?.absoluteString, "https://api.openai.com/v1/chat/completions",
                "不应出现双斜杠"
            )
        }),

        ("缺少 API Key 时直接报错，不发请求", {
            let config = LLMConfig(enabled: true, provider: .anthropic, apiKey: "   ")
            var threw = false
            do {
                _ = try LLMClient.buildRequest(
                    question: "q", history: [], image: sampleShot(), config: config
                )
            } catch { threw = true }
            try check(threw, "空白 key 应抛错")

            let badURL = LLMConfig(enabled: true, provider: .anthropic, baseURL: "", apiKey: "k")
            threw = false
            do {
                _ = try LLMClient.buildRequest(
                    question: "q", history: [], image: sampleShot(), config: badURL
                )
            } catch { threw = true }
            try check(threw, "空 baseURL 应抛错")
        }),

        // ---- Response parsing ----------------------------------------------

        ("解析 Anthropic 响应：跳过 thinking 只取 text", {
            let payload: [String: Any] = [
                "model": "claude-opus-5",
                "stop_reason": "end_turn",
                "content": [
                    ["type": "thinking", "thinking": "……不该被当成答案……"],
                    ["type": "text", "text": "第一行是标题"],
                    ["type": "text", "text": "第二行是说明"],
                ],
                "usage": ["input_tokens": 1234, "output_tokens": 56],
            ]
            let answer = try LLMClient.parse(payload, config: LLMConfig(provider: .anthropic))

            try checkEqual(answer.text, "第一行是标题\n第二行是说明", "只应拼接 text 块")
            try check(!answer.text.contains("不该被当成答案"), "thinking 内容不应混入")
            try checkEqual(answer.inputTokens, 1234, "输入 tokens")
            try checkEqual(answer.outputTokens, 56, "输出 tokens")
            try checkEqual(answer.stopReason, "end_turn", "结束原因")
        }),

        ("解析 Anthropic 响应：拒绝回答时报错并带分类", {
            let payload: [String: Any] = [
                "stop_reason": "refusal",
                "stop_details": ["type": "refusal", "category": "cyber"],
                "content": [],
            ]
            var message = ""
            do {
                _ = try LLMClient.parse(payload, config: LLMConfig(provider: .anthropic))
            } catch let error as LLMError {
                message = error.description
            }
            try check(message.contains("拒绝"), "应提示被拒绝：\(message)")
            try check(message.contains("cyber"), "应带上分类：\(message)")
        }),

        ("解析 Anthropic 响应：没有文本块时报错", {
            let payload: [String: Any] = ["stop_reason": "max_tokens", "content": []]
            var threw = false
            do { _ = try LLMClient.parse(payload, config: LLMConfig(provider: .anthropic)) }
            catch { threw = true }
            try check(threw, "空 content 应抛错而不是返回空答案")
        }),

        ("解析 OpenAI 响应：字符串与数组两种 content", {
            let asString: [String: Any] = [
                "model": "deepseek-vl",
                "choices": [["message": ["content": "答案是 42"], "finish_reason": "stop"]],
                "usage": ["prompt_tokens": 100, "completion_tokens": 7],
            ]
            var answer = try LLMClient.parse(asString, config: LLMConfig(provider: .openai))
            try checkEqual(answer.text, "答案是 42", "字符串 content")
            try checkEqual(answer.inputTokens, 100, "prompt_tokens")
            try checkEqual(answer.outputTokens, 7, "completion_tokens")

            // Some gateways return the parts array instead.
            let asArray: [String: Any] = [
                "choices": [[
                    "message": ["content": [["type": "text", "text": "第一段"], ["type": "text", "text": "第二段"]]],
                ]],
            ]
            answer = try LLMClient.parse(asArray, config: LLMConfig(provider: .openai))
            try checkEqual(answer.text, "第一段\n第二段", "数组 content")
        }),

        ("解析 OpenAI 响应：内容为空时报错", {
            let payload: [String: Any] = ["choices": [["message": [String: Any]()]]]
            var threw = false
            do { _ = try LLMClient.parse(payload, config: LLMConfig(provider: .openai)) }
            catch { threw = true }
            try check(threw, "空 content 应抛错")

            threw = false
            do { _ = try LLMClient.parse([:], config: LLMConfig(provider: .openai)) }
            catch { threw = true }
            try check(threw, "缺少 choices 应抛错")
        }),

        // ---- Status codes must not collide with device authentication -------
        //
        // 401/403 are how this server tells a phone "your own credential is bad" —
        // the one thing that makes it discard its pairing. A model API rejecting
        // the *server's* key used to come back as 401, so every failed question
        // logged the phone out and threw it back to the pairing screen.

        ("LLM 错误绝不映射到 401/403", {
            let samples: [LLMError] = [
                .notConfigured,
                .missingKey,
                .invalidBaseURL(""),
                .httpFailed(status: 401, body: "unauthorized"),
                .httpFailed(status: 403, body: "forbidden"),
                .httpFailed(status: 400, body: "bad request"),
                .httpFailed(status: 429, body: "rate limited"),
                .httpFailed(status: 500, body: "boom"),
                .malformedResponse("x"),
                .refused(nil),
                .refused("cyber"),
            ]
            for error in samples {
                let status = error.httpStatus
                try check(
                    status != 401 && status != 403,
                    "\(error) 映射成了 \(status)，会与设备鉴权状态码冲突"
                )
            }
        }),

        ("上游拒绝 Key 时返回 400 并说清原因", {
            let rejected = LLMError.httpFailed(status: 401, body: "invalid api key")
            try checkEqual(rejected.httpStatus, 400, "上游 401 应转成 400")
            try check(rejected.description.contains("Key"), "信息里应提到 Key：\(rejected.description)")

            let forbidden = LLMError.httpFailed(status: 403, body: "no access")
            try checkEqual(forbidden.httpStatus, 400, "上游 403 也应转成 400")

            // Anything else upstream is a gateway problem, not the caller's fault.
            try checkEqual(
                LLMError.httpFailed(status: 500, body: "boom").httpStatus, 502, "上游 5xx"
            )
            try checkEqual(
                LLMError.httpFailed(status: 429, body: "slow down").httpStatus, 502, "上游 429"
            )
        }),

        ("错误响应只在需要时带 code 标记", {
            func decode(_ response: HTTPResponse) throws -> [String: Any] {
                guard let any = try? JSONSerialization.jsonObject(with: response.body) else {
                    throw TestFailure(message: "响应体不是 JSON")
                }
                return try checkUnwrap(any as? [String: Any], "响应体是对象")
            }

            let auth = try decode(.error(401, "x", code: "unauthenticated"))
            try checkEqual(auth["code"] as? String, "unauthenticated", "鉴权失败应带标记")

            let forbidden = try decode(.error(403, "x", code: "forbidden"))
            try checkEqual(forbidden["code"] as? String, "forbidden", "越权应带不同的标记")

            // An ordinary failure must not carry a marker: the phone treats the
            // marker as "throw away my pairing", so adding it casually is dangerous.
            let plain = try decode(.error(400, "x"))
            try check(plain["code"] == nil, "普通错误不应带 code")
        }),
    ]

    // MARK: - Helpers

    static func sampleShot(payload: Data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])) -> Shot {
        Shot(
            id: "20260915-120000-000-aaaa",
            payload: payload,
            format: .jpeg,
            pixelWidth: 100,
            pixelHeight: 50,
            createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            source: "display:0"
        )
    }

    static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody else {
            throw TestFailure(message: "请求没有 body")
        }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any] else {
            throw TestFailure(message: "body 不是 JSON 对象")
        }
        return object
    }
}
