import Foundation

// MARK: - Payload

/// Everything a delivery backend needs about one frame.
public struct NotifyPayload: Sendable {
    public let shot: Shot
    public let caption: String
    /// Direct link to the image bytes, on whatever base URL is reachable.
    public let imageURL: String
    /// Link to the live viewer page. This is the reliable tap target: it works
    /// over the LAN even when no public URL exists.
    public let viewerURL: String
    public let hostName: String

    public init(shot: Shot, caption: String, imageURL: String, viewerURL: String, hostName: String) {
        self.shot = shot
        self.caption = caption
        self.imageURL = imageURL
        self.viewerURL = viewerURL
        self.hostName = hostName
    }
}

// MARK: - Protocol

public protocol Notifier: Sendable {
    var label: String { get }
    func send(_ payload: NotifyPayload) async throws
}

// MARK: - Service

/// Owns the configured backends and fans a payload out to all of them.
///
/// Deliveries run concurrently and independently: one misconfigured channel must
/// not stop the others, and a slow HTTP call must not block the capture loop.
public final class NotifierService: @unchecked Sendable {
    private let lock = NSLock()
    private var notifiers: [Notifier] = []

    public init(config: BeamConfig) {
        reload(config)
    }

    public func reload(_ config: BeamConfig) {
        var built: [Notifier] = []
        for channel in config.notify.channels where channel.enabled {
            if let notifier = NotifierFactory.make(channel: channel, config: config) {
                built.append(notifier)
            } else {
                Log.warn("通知渠道 [\(channel.label)] 配置不完整，已跳过。")
            }
        }

        lock.lock()
        notifiers = built
        lock.unlock()

        if built.isEmpty {
            Log.info("未启用任何推送渠道（截图仍可通过网页查看）。")
        } else {
            Log.info("已启用推送渠道：\(built.map(\.label).joined(separator: ", "))")
        }
    }

    public var activeLabels: [String] {
        lock.lock()
        defer { lock.unlock() }
        return notifiers.map(\.label)
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return notifiers.isEmpty
    }

    /// Synchronous on purpose: `NSLock` cannot be used directly from an async
    /// context, so the critical section lives in its own non-async function.
    private func snapshot() -> [Notifier] {
        lock.lock()
        defer { lock.unlock() }
        return notifiers
    }

    public func dispatch(_ payload: NotifyPayload) async {
        let snapshot = snapshot()
        guard !snapshot.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for notifier in snapshot {
                group.addTask {
                    do {
                        try await notifier.send(payload)
                        Log.info("推送成功：[\(notifier.label)]")
                    } catch {
                        Log.error("推送失败 [\(notifier.label)]：\(error)")
                    }
                }
            }
        }
    }
}

// MARK: - Factory

enum NotifierFactory {
    static func make(channel: NotifyChannel, config: BeamConfig) -> Notifier? {
        switch channel.kind {
        case .bark:
            guard let key = channel.deviceKey, !key.isEmpty else { return nil }
            return BarkNotifier(
                label: channel.label,
                server: nonEmpty(channel.server) ?? "https://api.day.app",
                deviceKey: key,
                sound: nonEmpty(channel.sound),
                sendImageLink: channel.attachImage ?? false
            )

        case .ntfy:
            guard let topic = nonEmpty(channel.topic) else { return nil }
            return NtfyNotifier(
                label: channel.label,
                server: nonEmpty(channel.server) ?? "https://ntfy.sh",
                topic: topic,
                authToken: nonEmpty(channel.authToken)
            )

        case .telegram:
            guard let botToken = nonEmpty(channel.botToken),
                  let chatId = nonEmpty(channel.chatId) else { return nil }
            return TelegramNotifier(label: channel.label, botToken: botToken, chatId: chatId)

        case .feishu:
            let webhook = nonEmpty(channel.webhook)
            let appId = nonEmpty(channel.botToken)
            let appSecret = nonEmpty(channel.authToken)
            let chatId = nonEmpty(channel.chatId)
            guard webhook != nil || (appId != nil && appSecret != nil && chatId != nil) else {
                return nil
            }
            return FeishuNotifier(
                label: channel.label,
                webhook: webhook,
                appId: appId,
                appSecret: appSecret,
                chatId: chatId,
                server: nonEmpty(channel.server) ?? "https://open.feishu.cn"
            )

        case .webhook:
            guard let url = nonEmpty(channel.url) else { return nil }
            return WebhookNotifier(
                label: channel.label,
                url: url,
                method: nonEmpty(channel.method) ?? "POST",
                headers: channel.headers ?? [:],
                bodyTemplate: nonEmpty(channel.bodyTemplate)
            )
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

// MARK: - Caption rendering

public enum CaptionTemplate {
    /// Rendered before the `NotifyPayload` exists, so it takes the individual
    /// pieces rather than the assembled payload.
    public static func render(
        _ template: String,
        shot: Shot,
        hostName: String,
        viewerURL: String
    ) -> String {
        let time = formatter("HH:mm:ss").string(from: shot.createdAt)
        let date = formatter("yyyy-MM-dd").string(from: shot.createdAt)

        return template
            .replacingOccurrences(of: "{host}", with: hostName)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{source}", with: shot.source)
            .replacingOccurrences(of: "{width}", with: String(shot.pixelWidth))
            .replacingOccurrences(of: "{height}", with: String(shot.pixelHeight))
            .replacingOccurrences(of: "{url}", with: viewerURL)
    }

    /// `DateFormatter` is not thread-safe, so each call gets a fresh instance.
    /// This runs once per capture, so the allocation is irrelevant.
    static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
