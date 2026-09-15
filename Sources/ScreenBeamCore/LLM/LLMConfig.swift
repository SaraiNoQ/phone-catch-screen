import Foundation

/// Configuration for the optional "ask about this screenshot" feature.
///
/// Lives on the Mac, not the phone: the browser never sees the API key, and the
/// request is made from the daemon. A paired device can *edit* these settings
/// (the UI exposes it) but can never read the key back out.
public struct LLMConfig: Codable, Sendable {
    /// Two wire shapes cover essentially everything.
    public enum Provider: String, Codable, Sendable, CaseIterable {
        /// Anthropic Messages API.
        case anthropic
        /// OpenAI chat-completions shape. Used by OpenAI, and by every
        /// OpenAI-compatible endpoint — DeepSeek, Moonshot, 通义, 智谱,
        /// SiliconFlow, Ollama, vLLM, and most self-hosted gateways.
        case openai

        public var displayName: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI 兼容"
            }
        }

        /// Canonical endpoint for each shape. `openai` is only a starting point —
        /// every compatible provider has its own host, so the UI keeps this
        /// editable.
        public static func defaultBaseURL(for provider: Provider) -> String {
            switch provider {
            case .anthropic: return "https://api.anthropic.com"
            case .openai: return "https://api.openai.com"
            }
        }
    }

    public var enabled: Bool
    public var provider: Provider
    public var baseURL: String
    /// Write-only from the API's point of view: never returned by
    /// `GET /api/llm/config`.
    public var apiKey: String
    public var model: String
    public var maxTokens: Int
    /// Anthropic only. `low` | `medium` | `high` | `xhigh` | `max`.
    ///
    /// Defaults to `low` deliberately: this is latency-sensitive interactive
    /// chat about a picture, which is the case where higher effort costs time
    /// without buying much. Clear it for any model that rejects the field.
    public var effort: String?
    public var systemPrompt: String
    public var timeoutSeconds: Double
    /// Anthropic only: opt into server-side refusal fallbacks. Sent as the
    /// `server-side-fallback-2026-07-01` beta header, which some proxies reject —
    /// turn this off if requests start failing with a beta-header error.
    public var useFallbacks: Bool

    public init(
        enabled: Bool = false,
        provider: Provider = .anthropic,
        baseURL: String = "https://api.anthropic.com",
        apiKey: String = "",
        model: String = "claude-opus-5",
        maxTokens: Int = 16000,
        effort: String? = "low",
        systemPrompt: String = LLMConfig.defaultSystemPrompt,
        timeoutSeconds: Double = 120,
        useFallbacks: Bool = true
    ) {
        self.enabled = enabled
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
        self.systemPrompt = systemPrompt
        self.timeoutSeconds = timeoutSeconds
        self.useFallbacks = useFallbacks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, false)
        provider = c.value(.provider, .anthropic)
        baseURL = c.value(.baseURL, "https://api.anthropic.com")
        apiKey = c.value(.apiKey, "")
        model = c.value(.model, "claude-opus-5")
        maxTokens = c.value(.maxTokens, 16000)
        effort = try? c.decodeIfPresent(String.self, forKey: .effort)
        systemPrompt = c.value(.systemPrompt, LLMConfig.defaultSystemPrompt)
        timeoutSeconds = c.value(.timeoutSeconds, 120)
        useFallbacks = c.value(.useFallbacks, true)
    }

    /// Written for a phone screen: terse, positional, and told not to invent
    /// details it cannot actually read.
    public static let defaultSystemPrompt = """
    你在帮用户看一张 Mac 屏幕截图。用户会发来截图和一个问题。

    回答要求：
    - 直接回答，不要复述画面、不要寒暄、不要重复问题。
    - 提到界面元素时给出具体位置（左上/中间/右下）和上面的文字。
    - 看不清或图里没有就说没有，不要猜。
    - 默认用中文回答，除非用户用其他语言提问。
    - 简短。手机屏幕小，几句话能说清就不要写一段。
    """

    /// Settings safe to hand to a paired device — no key.
    public var publicJSON: [String: Any] {
        var object: [String: Any] = [
            "enabled": enabled,
            "provider": provider.rawValue,
            "providerName": provider.displayName,
            "baseURL": baseURL,
            "model": model,
            "maxTokens": maxTokens,
            "timeoutSeconds": timeoutSeconds,
            // The UI shows "已配置 / 未配置" from this and never needs the value.
            "hasKey": !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        ]
        if let effort { object["effort"] = effort }
        return object
    }

    public var isUsable: Bool {
        enabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
