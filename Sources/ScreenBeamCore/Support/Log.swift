import Foundation
import os

/// Thin wrapper over `os.Logger` that also mirrors to stderr when the process is
/// running in the foreground (i.e. `screenbeam run` in a terminal).
///
/// The LaunchAgent captures stderr into `~/Library/Logs/ScreenBeam/err.log`, so
/// mirroring keeps one code path useful in both modes.
public enum Log {
    private static let subsystem = "com.sarainoq.screenbeam"
    private static let logger = Logger(subsystem: subsystem, category: "core")

    /// Set by the CLI when running attached to a terminal.
    public nonisolated(unsafe) static var mirrorToStderr = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        mirror(level: "INFO", message)
    }

    public static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        mirror(level: "WARN", message)
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        mirror(level: "ERR ", message)
    }

    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        mirror(level: "DBG ", message)
    }

    private static func mirror(level: String, _ message: String) {
        guard mirrorToStderr else { return }
        let line = "[\(formatter.string(from: Date()))] \(level) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
