import Foundation

/// Identifier shared by the daemon and the one-shot CLI path.
///
/// A millisecond timestamp makes ids sortable and readable in a filename; the
/// random suffix disambiguates two captures inside the same millisecond and keeps
/// a one-shot CLI process from colliding with the daemon (there is no shared
/// counter to lean on).
public enum ShotID {
    public static func make(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let suffix = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        return "\(formatter.string(from: date))-\(suffix)"
    }
}
