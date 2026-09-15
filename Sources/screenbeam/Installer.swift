import Foundation
import ScreenBeamCore

/// Installs the app bundle and the LaunchAgent, and drives `launchctl`.
///
/// The bundle matters beyond tidiness: macOS keys the Screen Recording grant to
/// the code identity of the process. A bare `swift build` binary has none, so the
/// grant attaches to whatever launched it and is lost on the next rebuild. A
/// `.app` with a stable `CFBundleIdentifier` (ad-hoc signed) is what makes the
/// permission stick.
enum Installer {
    static let label = BeamPaths.bundleIdentifier

    // MARK: - Bundle discovery

    static func locateBundle(explicit: String?) -> URL? {
        if let explicit {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        // 1. Already running from inside a bundle.
        var probe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while probe.path != "/" {
            if probe.pathExtension == "app" { return probe }
            probe = probe.deletingLastPathComponent()
        }

        // 2. Conventional build output, relative to CWD and to the binary.
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/PHONE-CATCH-SCREEN.app"),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("dist/PHONE-CATCH-SCREEN.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Install

    static func install(explicitBundle: String?) throws {
        guard let source = locateBundle(explicit: explicitBundle) else {
            throw CLIError.notInstalled("""
            没有找到 PHONE-CATCH-SCREEN.app。
            请先在项目目录执行 ./scripts/build.sh 生成 dist/PHONE-CATCH-SCREEN.app，\
            或用 --bundle 指定路径。
            """)
        }

        let destination = BeamPaths.installedAppBundle
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Replace any previous copy. Removing first guarantees a clean bundle
        // rather than merging into stale contents.
        if fileManager.fileExists(atPath: destination.path) {
            bootout()
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        print(Term.ok("  已安装 ") + destination.path)

        try writeLaunchAgent(bundle: destination)
        print(Term.ok("  已写入 ") + BeamPaths.launchAgentFile.path)

        let binary = destination.appendingPathComponent("Contents/MacOS/screenbeam").path
        let bootstrap = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", BeamPaths.launchAgentFile.path])
        if bootstrap.status != 0 {
            // Already-loaded agents report an error here; re-running install
            // should still succeed, so surface the text but keep going.
            print(Term.warn("  launchctl bootstrap 返回：\(bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines))"))
        } else {
            print(Term.ok("  已注册 LaunchAgent（\(label)）"))
        }

        // Running the bundled binary once is what registers the app with TCC and
        // raises the consent dialog. Without this the permission pane would not
        // even list it.
        print("")
        print("  正在申请「屏幕录制」权限，请在弹出的对话框中允许…")
        _ = Shell.run(binary, ["perm", "--request"])

        print("")
        print(Term.bold("  安装完成。接下来："))
        print("  1. 在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 \(BeamPaths.appName)")
        print("  2. 授权后服务会自动重启并生效")
        print("  3. 执行 \(Term.accent("screenbeam url")) 获取手机访问地址与二维码")
        print("")
    }

    static func uninstall() throws {
        bootout()

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: BeamPaths.launchAgentFile.path) {
            try fileManager.removeItem(at: BeamPaths.launchAgentFile)
            print(Term.ok("  已移除 LaunchAgent"))
        }
        if fileManager.fileExists(atPath: BeamPaths.installedAppBundle.path) {
            try fileManager.removeItem(at: BeamPaths.installedAppBundle)
            print(Term.ok("  已移除 \(BeamPaths.installedAppBundle.path)"))
        }

        print("")
        print(Term.dim("  配置与日志保留在："))
        print(Term.dim("    \(BeamPaths.supportDirectory.path)"))
        print(Term.dim("    \(BeamPaths.logDirectory.path)"))
        print(Term.dim("  如需彻底清除，手动删除上面两个目录即可。"))
        print("")
        print(Term.warn("  注意：请在 系统设置 → 隐私与安全性 → 屏幕录制 中手动移除 PHONE·CATCH·SCREEN 条目。"))
        print("")
    }

    // MARK: - launchctl

    static func start() {
        let result = Shell.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"])
        report(result, success: "已启动服务", failure: "启动失败")
    }

    static func stop() {
        let result = Shell.run("/bin/launchctl", ["kill", "SIGTERM", "gui/\(getuid())/\(label)"])
        report(result, success: "已停止服务", failure: "停止失败")
    }

    static func restart() {
        // `-k` kills a running instance before starting a new one.
        let result = Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
        report(result, success: "已重启服务", failure: "重启失败")
    }

    static func isLoaded() -> Bool {
        Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    private static func bootout() {
        // Ignore the result: "not loaded" is the normal case on a first install.
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    }

    private static func report(_ result: Shell.Result, success: String, failure: String) {
        if result.status == 0 {
            print(Term.ok("  \(success)"))
        } else {
            print(Term.error("  \(failure)：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"))
            print(Term.dim("  如果尚未安装，请先执行 screenbeam install"))
        }
    }

    // MARK: - LaunchAgent plist

    private static func writeLaunchAgent(bundle: URL) throws {
        let binary = bundle.appendingPathComponent("Contents/MacOS/screenbeam").path
        let logs = BeamPaths.logDirectory
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "run", "--relaunch-on-grant"],
            "RunAtLoad": true,
            // Restart on crash and on the non-zero exit we use to pick up a fresh
            // Screen Recording grant — but not after a clean `stop`, which exits 0.
            "KeepAlive": ["SuccessfulExit": false],
            // Rate-limits restarts so a persistent failure cannot spin.
            "ThrottleInterval": 10,
            // Keeps the process out of App Nap; a background capture loop that
            // gets throttled would make the phone look broken.
            "ProcessType": "Interactive",
            // Only meaningful in a logged-in GUI session, which is where screen
            // capture has to run.
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logs.appendingPathComponent("out.log").path,
            "StandardErrorPath": logs.appendingPathComponent("err.log").path,
            "WorkingDirectory": logs.path,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: BeamPaths.launchAgentFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: BeamPaths.launchAgentFile, options: .atomic)
    }
}

// MARK: - Process helper

enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "\(error)")
        }

        // Drain before waiting: a child that fills the pipe buffer would
        // otherwise block forever on a large output.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
