import Foundation
import os

/// How much the daemon writes down.
///
/// Two separate concerns are folded into one setting, because they always move
/// together: how *much* is recorded, and how much of it is legible to other
/// processes. A screen-capture tool's log is a record of when you were looking
/// at what, so the production default deliberately keeps the routine out.
public enum LogLevel: String, Codable, Sendable, CaseIterable {
    /// Warnings and errors only.
    case quiet
    /// Startup, permission, pairing and error events — but no per-capture lines.
    case normal
    /// Everything, including per-request activity. For development.
    case debug

    public var displayName: String {
        switch self {
        case .quiet: return "quiet（仅警告与错误）"
        case .normal: return "normal（启动/权限/配对，不含每次截图）"
        case .debug: return "debug（全部，开发用）"
        }
    }
}

/// Thin wrapper over `os.Logger` that also mirrors to stderr when attached to a
/// terminal.
///
/// Two properties matter here and are easy to get wrong:
///
/// 1. **Messages go to the unified log as `.private`.** The unified log is
///    readable by any process on the machine (`log show`), so a `.public`
///    message is effectively broadcast. The plaintext copy still lands in the
///    daemon's own log file, which is what `screenbeam logs` reads — the detail
///    is kept for the operator without being published to every process.
/// 2. **`debug` messages are not persisted by `os_log` at all** unless a debugger
///    or `log stream` is attached. Demoting an event to `debug` is therefore what
///    actually removes it from the record, not the level check below — the check
///    only avoids the formatting cost and the stderr mirror.
public enum Log {
    private static let subsystem = BeamPaths.bundleIdentifier
    private static let logger = Logger(subsystem: subsystem, category: "core")

    /// Set from the config at startup; `SCREENBEAM_LOG` overrides it so a
    /// development run can be verbose without editing anything.
    public nonisolated(unsafe) static var level: LogLevel = .normal

    /// Set by the CLI when running attached to a terminal.
    public nonisolated(unsafe) static var mirrorToStderr = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public static func info(_ message: @autoclosure () -> String) {
        guard level != .quiet else { return }
        emit(level: "INFO", message())
    }

    public static func warn(_ message: @autoclosure () -> String) {
        emit(level: "WARN", message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        emit(level: "ERR ", message())
    }

    /// Routine activity. See the type comment: `os_log` does not persist these,
    /// which is the point.
    public static func debug(_ message: @autoclosure () -> String) {
        guard level == .debug else { return }
        emit(level: "DBG ", message(), isDebug: true)
    }

    /// Applies an environment override, for development runs.
    public static func resolveLevel(configLevel: LogLevel) -> LogLevel {
        guard let raw = ProcessInfo.processInfo.environment["SCREENBEAM_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty else {
            return configLevel
        }
        return LogLevel(rawValue: raw) ?? configLevel
    }

    private static func emit(level tag: String, _ message: String, isDebug: Bool = false) {
        // `.private` on purpose: this text is about when the screen was captured,
        // and the unified log is world-readable to processes on this machine.
        switch tag {
        case "WARN": logger.warning("\(message, privacy: .private)")
        case "ERR ": logger.error("\(message, privacy: .private)")
        case "DBG ": logger.debug("\(message, privacy: .private)")
        default: logger.info("\(message, privacy: .private)")
        }

        guard mirrorToStderr else { return }
        let line = "[\(formatter.string(from: Date()))] \(tag) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
