import Foundation

// MARK: - Decoding helper

private extension KeyedDecodingContainer {
    /// Reads `key`, falling back to `fallback` when the key is absent *or* holds
    /// the wrong type. The config file is meant to be hand-edited, so a missing
    /// or malformed key should degrade to the default rather than blow up the
    /// whole daemon at startup.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
    }
}

// MARK: - Config

public struct BeamConfig: Codable, Sendable {
    public var server: ServerConfig
    public var capture: CaptureConfig
    public var watch: WatchConfig
    public var history: HistoryConfig
    public var notify: NotifyConfig

    public init(
        server: ServerConfig = ServerConfig(),
        capture: CaptureConfig = CaptureConfig(),
        watch: WatchConfig = WatchConfig(),
        history: HistoryConfig = HistoryConfig(),
        notify: NotifyConfig = NotifyConfig()
    ) {
        self.server = server
        self.capture = capture
        self.watch = watch
        self.history = history
        self.notify = notify
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = c.value(.server, ServerConfig())
        capture = c.value(.capture, CaptureConfig())
        watch = c.value(.watch, WatchConfig())
        history = c.value(.history, HistoryConfig())
        notify = c.value(.notify, NotifyConfig())
    }
}

public struct ServerConfig: Codable, Sendable {
    /// `127.0.0.1` keeps the viewer Mac-only. `0.0.0.0` exposes it to the LAN so
    /// your phone can reach it — that is the whole point, but it also means
    /// anyone on the same Wi-Fi can reach it if they learn the token.
    public var host: String
    public var port: Int
    /// Shared secret. Sent as `?token=` or an `X-Auth-Token` header.
    public var token: String
    /// Optional externally reachable base URL (Tailscale, Cloudflare Tunnel).
    /// Used when building image links for push notifications.
    public var publicBaseURL: String?

    public init(
        host: String = "0.0.0.0",
        port: Int = 8787,
        token: String = "",
        publicBaseURL: String? = nil
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.publicBaseURL = publicBaseURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = c.value(.host, "0.0.0.0")
        port = c.value(.port, 8787)
        token = c.value(.token, "")
        publicBaseURL = try? c.decodeIfPresent(String.self, forKey: .publicBaseURL)
    }

    public var isLoopbackOnly: Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

public struct CaptureConfig: Codable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Whole display, chosen by `displayIndex`.
        case display
        /// Only the frontmost normal window. Genuinely useful as a privacy
        /// control: you can share one window without leaking the rest of the desktop.
        case window
    }

    public var mode: Mode
    public var displayIndex: Int
    public var format: Shot.Format
    /// JPEG quality, 0...1.
    public var quality: Double
    /// Downscale the long edge to this many pixels before encoding. 0 disables.
    /// Keeps phone payloads small over a slow Wi-Fi link.
    public var maxLongEdge: Int
    public var showCursor: Bool

    public init(
        mode: Mode = .display,
        displayIndex: Int = 0,
        format: Shot.Format = .jpeg,
        quality: Double = 0.75,
        maxLongEdge: Int = 1600,
        showCursor: Bool = true
    ) {
        self.mode = mode
        self.displayIndex = displayIndex
        self.format = format
        self.quality = quality
        self.maxLongEdge = maxLongEdge
        self.showCursor = showCursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.value(.mode, .display)
        displayIndex = c.value(.displayIndex, 0)
        format = c.value(.format, .jpeg)
        quality = c.value(.quality, 0.75)
        maxLongEdge = c.value(.maxLongEdge, 1600)
        showCursor = c.value(.showCursor, true)
    }
}

public struct WatchConfig: Codable, Sendable {
    /// Start the periodic capture loop as soon as the daemon comes up.
    public var enabled: Bool
    public var intervalSeconds: Double
    /// Skip frames that look identical to the previous one, so a static desktop
    /// does not spam the phone.
    public var onlyOnChange: Bool
    /// Mean absolute pixel difference (0...1) above which a frame counts as changed.
    public var changeThreshold: Double
    /// Also push a notification for every auto-captured frame.
    public var pushOnCapture: Bool

    public init(
        enabled: Bool = false,
        intervalSeconds: Double = 10,
        onlyOnChange: Bool = true,
        changeThreshold: Double = 0.02,
        pushOnCapture: Bool = false
    ) {
        self.enabled = enabled
        self.intervalSeconds = intervalSeconds
        self.onlyOnChange = onlyOnChange
        self.changeThreshold = changeThreshold
        self.pushOnCapture = pushOnCapture
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, false)
        intervalSeconds = c.value(.intervalSeconds, 10)
        onlyOnChange = c.value(.onlyOnChange, true)
        changeThreshold = c.value(.changeThreshold, 0.02)
        pushOnCapture = c.value(.pushOnCapture, false)
    }
}

public struct HistoryConfig: Codable, Sendable {
    /// How many recent frames to keep in memory. Bounds RAM; each JPEG is
    /// typically 100–400 KB at the default capture settings.
    public var keepInMemory: Int
    /// Optional directory to also write frames to. `nil` disables disk history.
    public var saveDirectory: String?
    /// Frames older than this are pruned from `saveDirectory`.
    public var retentionMinutes: Int

    public init(keepInMemory: Int = 24, saveDirectory: String? = nil, retentionMinutes: Int = 120) {
        self.keepInMemory = keepInMemory
        self.saveDirectory = saveDirectory
        self.retentionMinutes = retentionMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepInMemory = c.value(.keepInMemory, 24)
        saveDirectory = try? c.decodeIfPresent(String.self, forKey: .saveDirectory)
        retentionMinutes = c.value(.retentionMinutes, 120)
    }
}

public struct NotifyConfig: Codable, Sendable {
    /// Push every manually triggered capture too, not just watcher frames.
    public var onManualCapture: Bool
    /// Caption template. Placeholders: `{host}`, `{time}`, `{date}`, `{source}`,
    /// `{width}`, `{height}`, `{url}`.
    public var caption: String
    public var channels: [NotifyChannel]

    public init(
        onManualCapture: Bool = false,
        caption: String = "ScreenBeam · {host} · {time}",
        channels: [NotifyChannel] = []
    ) {
        self.onManualCapture = onManualCapture
        self.caption = caption
        self.channels = channels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onManualCapture = c.value(.onManualCapture, false)
        caption = c.value(.caption, "ScreenBeam · {host} · {time}")
        channels = c.value(.channels, [])
    }
}

/// One delivery target. Deliberately flat with optional per-backend fields so the
/// JSON stays readable when hand-edited.
public struct NotifyChannel: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bark
        case ntfy
        case telegram
        case feishu
        case webhook
    }

    public var kind: Kind
    public var enabled: Bool
    /// Free-form label, shown in logs.
    public var name: String?

    // bark
    /// Bark device key. Set to `true` in the JSON to reuse the token as a shared secret.
    public var deviceKey: String?
    /// ntfy topic.
    public var topic: String?

    /// Bark / ntfy / webhook base host override.
    public var server: String?
    /// ntfy bearer token.
    public var authToken: String?

    // telegram
    public var botToken: String?
    public var chatId: String?

    // feishu
    public var webhook: String?

    // generic webhook
    public var url: String?
    public var method: String?
    public var headers: [String: String]?
    /// Placeholders: `{{text}}`, `{{image_url}}`, `{{image_base64}}`, `{{source}}`, `{{time}}`.
    public var bodyTemplate: String?

    /// Upload the image bytes directly instead of sending a link. Telegram and
    /// Feishu require it; Bark/ntfy prefer it when the phone is off-LAN.
    public var attachImage: Bool?

    /// Notification sound name (Bark / ntfy).
    public var sound: String?

    public init(kind: Kind, enabled: Bool = false, name: String? = nil) {
        self.kind = kind
        self.enabled = enabled
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, .webhook)
        enabled = c.value(.enabled, false)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        deviceKey = try? c.decodeIfPresent(String.self, forKey: .deviceKey)
        topic = try? c.decodeIfPresent(String.self, forKey: .topic)
        server = try? c.decodeIfPresent(String.self, forKey: .server)
        authToken = try? c.decodeIfPresent(String.self, forKey: .authToken)
        botToken = try? c.decodeIfPresent(String.self, forKey: .botToken)
        chatId = try? c.decodeIfPresent(String.self, forKey: .chatId)
        webhook = try? c.decodeIfPresent(String.self, forKey: .webhook)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        method = try? c.decodeIfPresent(String.self, forKey: .method)
        headers = try? c.decodeIfPresent([String: String].self, forKey: .headers)
        bodyTemplate = try? c.decodeIfPresent(String.self, forKey: .bodyTemplate)
        attachImage = try? c.decodeIfPresent(Bool.self, forKey: .attachImage)
        sound = try? c.decodeIfPresent(String.self, forKey: .sound)
    }

    public var label: String {
        name ?? kind.rawValue
    }
}

// MARK: - Load / save

public enum ConfigStore {
    public static func defaultConfig() -> BeamConfig {
        BeamConfig(
            server: ServerConfig(token: randomToken()),
            notify: NotifyConfig(channels: [
                NotifyChannel(kind: .bark, enabled: false, name: "iPhone (Bark)")
                    .with { $0.deviceKey = ""; $0.attachImage = true },
                NotifyChannel(kind: .ntfy, enabled: false, name: "ntfy")
                    .with { $0.server = "https://ntfy.sh"; $0.topic = "" },
                NotifyChannel(kind: .telegram, enabled: false, name: "Telegram")
                    .with { $0.botToken = ""; $0.chatId = ""; $0.attachImage = true },
                NotifyChannel(kind: .feishu, enabled: false, name: "飞书")
                    .with { $0.webhook = "" },
            ])
        )
    }

    /// Loads config from disk, creating a default file on first run.
    public static func load(from url: URL = BeamPaths.configFile) throws -> BeamConfig {
        try BeamPaths.ensureDirectories()

        guard FileManager.default.fileExists(atPath: url.path) else {
            let config = defaultConfig()
            try save(config, to: url)
            Log.info("已生成默认配置：\(url.path)")
            return config
        }

        let data = try Data(contentsOf: url)
        var config: BeamConfig
        do {
            config = try JSONDecoder().decode(BeamConfig.self, from: data)
        } catch {
            throw ConfigError.parseFailed(url.path, String(describing: error))
        }

        // An empty token means "generate one and persist it" so the very first
        // run does not silently run unauthenticated.
        if config.server.token.isEmpty {
            config.server.token = randomToken()
            try save(config, to: url)
            Log.info("已生成访问令牌并写回配置。")
        }
        return config
    }

    public static func save(_ config: BeamConfig, to url: URL = BeamPaths.configFile) throws {
        try BeamPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    public static func randomToken(length: Int = 32) -> String {
        let alphabet = Array("abcdef0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case parseFailed(String, String)

    public var description: String {
        switch self {
        case .parseFailed(let path, let detail):
            return "配置文件解析失败：\(path)\n\(detail)"
        }
    }
}

private extension NotifyChannel {
    func with(_ mutate: (inout NotifyChannel) -> Void) -> NotifyChannel {
        var copy = self
        mutate(&copy)
        return copy
    }
}
