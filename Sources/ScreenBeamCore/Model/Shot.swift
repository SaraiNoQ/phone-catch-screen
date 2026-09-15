import Foundation

/// A single captured frame, already encoded for transport.
///
/// The engine keeps these in a small ring buffer so the phone can pull recent
/// frames by id without re-capturing. `payload` is always encoded (jpeg or png)
/// rather than a raw `CGImage`, because the store is read from HTTP connection
/// threads and `CGImage` is not cheap to copy around.
public struct Shot: Sendable {
    public enum Format: String, Codable, Sendable {
        case jpeg
        case png

        public var mimeType: String {
            switch self {
            case .jpeg: return "image/jpeg"
            case .png: return "image/png"
            }
        }

        public var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            }
        }
    }

    public let id: String
    public let payload: Data
    public let format: Format
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let createdAt: Date
    /// Human readable description of what was captured, e.g. `display:0` or `window:Safari`.
    public let source: String

    public init(
        id: String,
        payload: Data,
        format: Format,
        pixelWidth: Int,
        pixelHeight: Int,
        createdAt: Date,
        source: String
    ) {
        self.id = id
        self.payload = payload
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
        self.source = source
    }

    public var byteCount: Int { payload.count }
}

/// Errors surfaced by the capture path. These are all user-actionable, so each
/// case carries enough detail to print a useful hint on the CLI.
public enum CaptureError: Error, CustomStringConvertible {
    case screenRecordingPermissionDenied
    case noDisplayAvailable
    case noFrontmostWindow
    case captureReturnedNoImage(String)
    case encodingFailed(String)

    public var description: String {
        switch self {
        case .screenRecordingPermissionDenied:
            return "缺少「屏幕录制」权限。打开 系统设置 → 隐私与安全性 → 屏幕录制，勾选 ScreenBeam。"
        case .noDisplayAvailable:
            return "没有找到可用显示器。"
        case .noFrontmostWindow:
            return "没有找到可截取的前台窗口。"
        case .captureReturnedNoImage(let detail):
            return "截屏未返回图像：\(detail)"
        case .encodingFailed(let detail):
            return "图像编码失败：\(detail)"
        }
    }
}
