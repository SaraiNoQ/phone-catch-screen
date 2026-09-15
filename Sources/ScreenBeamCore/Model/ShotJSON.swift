import Foundation

/// Wire representation of a `Shot`. Metadata only — the image bytes are served
/// separately from `/api/frame/<id>.<ext>` so the JSON stays small and the
/// browser can cache-per-id.
public enum ShotJSON {
    public static func encode(_ shot: Shot) -> [String: Any] {
        [
            "id": shot.id,
            "ext": shot.format.fileExtension,
            "mime": shot.format.mimeType,
            "width": shot.pixelWidth,
            "height": shot.pixelHeight,
            "bytes": shot.byteCount,
            "source": shot.source,
            "createdAt": ISO8601DateFormatter().string(from: shot.createdAt),
            "url": "/api/frame/\(shot.id).\(shot.format.fileExtension)",
        ]
    }
}
