import Foundation

/// Filesystem locations used by the daemon and CLI.
///
/// Everything lives under the user's own Library rather than `/usr/local`, so the
/// app never needs elevated privileges and the LaunchAgent can own it.
public enum BeamPaths {
    /// Reverse-DNS identity. Deliberately *not* renamed along with the display
    /// name: it is what the TCC grant and the LaunchAgent label are keyed to, and
    /// churning it would silently drop the Screen Recording permission.
    public static let bundleIdentifier = "com.sarainoq.screenbeam"

    /// Display name, and the name of the directories under Application Support
    /// and Logs. Matches the project name; the CLI binary stays `screenbeam`,
    /// which is the normal split between a product name and its command.
    public static let appName = "PHONE-CATCH-SCREEN"

    /// Same name with the separator the UI uses. Kept separate from `appName`
    /// because HTTP header values must stay ASCII.
    public static let appDisplayName = "PHONE·CATCH·SCREEN"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public static var logDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/\(appName)", isDirectory: true)
    }

    public static var configFile: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    /// Paired-device credentials. Owner-only permissions; holds token hashes,
    /// never the tokens themselves.
    public static var devicesFile: URL {
        supportDirectory.appendingPathComponent("devices.json")
    }

    public static var pidFile: URL {
        supportDirectory.appendingPathComponent("screenbeam.pid")
    }

    /// Where `screenbeam install --login` drops the app bundle.
    public static var installedAppBundle: URL {
        let base = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(appName).app", isDirectory: true)
    }

    public static var launchAgentFile: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LaunchAgents/\(bundleIdentifier).plist")
    }

    public static func ensureDirectories() throws {
        for dir in [supportDirectory, logDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Owner-only. The support directory holds credentials and the log
        // directory holds a record of when the screen was captured; neither has
        // any reason to be readable by other accounts.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: supportDirectory.path
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: logDirectory.path
        )
    }

    /// The daemon's stdout and stderr are redirected into files by launchd, which
    /// creates them with the process umask — typically world-readable. A capture
    /// log is a record of when the screen was being watched, so tighten it.
    ///
    /// Not a defence against another process running as this user — nothing on
    /// macOS is — but it does keep the log out of reach of other accounts and of
    /// anything that merely reads broadly.
    public static func tightenLogPermissions() {
        let manager = FileManager.default
        for name in ["out.log", "err.log"] {
            let path = logDirectory.appendingPathComponent(name).path
            guard manager.fileExists(atPath: path) else { continue }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}
