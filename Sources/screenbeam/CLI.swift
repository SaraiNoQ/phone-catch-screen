import Darwin
import Foundation
import ScreenBeamCore

/// Command line entry point.
enum CLI {
    /// Kept alive for the process lifetime so the signal sources are not deallocated.
    private static var signalSources: [DispatchSourceSignal] = []

    static func main(_ argv: [String]) async {
        let args = Arguments(argv)

        do {
            switch args.command {
            case "run":
                try await runDaemon(args)

            case "shot":
                try await shotCommand(args)

            case "status":
                try await statusCommand(args)

            case "url":
                try await urlCommand(args)

            case "pair":
                try await pairCommand(args)

            case "devices":
                try await devicesCommand(args)

            case "perm":
                try await permissionCommand(args)

            case "config":
                try configCommand(args)

            case "install":
                try Installer.install(explicitBundle: args.string("bundle"))

            case "uninstall":
                try Installer.uninstall()

            case "start":
                Installer.start()

            case "stop":
                Installer.stop()

            case "restart":
                Installer.restart()

            case "logs":
                try logsCommand(args)

            case "selftest":
                try selfTestCommand(args)

            case "version", "--version", "-v":
                print(ScreenBeamVersion.current)

            case "help", "--help", "-h", nil:
                printHelp()

            case .some(let unknown):
                print(Term.error("未知命令：\(unknown)"))
                print("")
                printHelp()
                exit(2)
            }
            exit(0)
        } catch {
            print(Term.error("错误：\(error)"))
            exit(1)
        }
    }

    // MARK: - run

    private static func runDaemon(_ args: Arguments) async throws {
        let config = try loadConfig(args)

        // Level first, so nothing logs before it is applied. `SCREENBEAM_LOG`
        // wins, which lets a development run be verbose without touching config.
        Log.level = Log.resolveLevel(configLevel: config.logging.level)
        Log.mirrorToStderr = true
        BeamPaths.tightenLogPermissions()

        // Under launchd we must exit(1) after a permission grant so the agent
        // restarts us with the grant applied — macOS does not apply a fresh
        // Screen Recording grant to an already-running process.
        let underLaunchd = ProcessInfo.processInfo
            .environment["XPC_SERVICE_NAME"]?
            .contains(BeamPaths.bundleIdentifier) ?? false
        let relaunch = args.has("relaunch-on-grant") || underLaunchd

        let engine = BeamEngine(
            config: config,
            configURL: resolveConfigURL(args),
            overrides: BeamEngine.Overrides(
                host: args.string("host"),
                port: args.int("port"),
                token: args.string("token")
            ),
            relaunchOnPermissionGrant: relaunch
        )
        try engine.start()

        // On a fresh install nothing is paired, so lead with the pairing code —
        // the addresses are useless until a phone can actually get in.
        if engine.pairedDeviceCount == 0, let code = engine.currentPairingCode() {
            AccessInfo.showPairing(
                code: code.value,
                expiresInSeconds: code.remainingSeconds,
                config: config,
                port: engine.boundPort
            )
        } else {
            AccessInfo.show(
                config: config,
                port: engine.boundPort,
                pairedDevices: engine.pairedDeviceCount
            )
        }

        installSignalHandlers(engine: engine)

        // Park forever. The work happens on the HTTP queue and the watch task;
        // this just keeps the process (and its async runtime) alive.
        while true {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    private static func installSignalHandlers(engine: BeamEngine) {
        let queue = DispatchQueue(label: "com.sarainoq.screenbeam.signals")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                engine.stop()
                // Clean exit, so the LaunchAgent's KeepAlive{SuccessfulExit:false}
                // leaves us stopped instead of restarting us.
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - shot

    private static func shotCommand(_ args: Arguments) async throws {
        let config = try loadConfig(args)
        let client = try DaemonClient(config: config)
        let daemonUp = await client.isRunning()

        var info: [String: Any]
        var payload: Data

        if daemonUp {
            let result = try await client.shot()
            guard let shotInfo = result["shot"] as? [String: Any] else {
                throw CLIError.daemonRejected(status: 200, message: "服务未返回截图信息")
            }
            info = shotInfo
            guard let path = shotInfo["url"] as? String else {
                throw CLIError.daemonRejected(status: 200, message: "服务未返回图片地址")
            }
            payload = try await client.imageData(shotPath: path)
        } else {
            // No daemon: capture in-process. Useful for a hotkey binding or a
            // one-off grab without running the background service.
            let shot = try await LocalCapture.capture(config: config)
            info = ShotJSON.encode(shot)
            payload = shot.payload
        }

        if args.has("push") {
            if daemonUp {
                _ = try await client.push(recapture: false)
            } else {
                try await LocalCapture.push(shot: info, payload: payload, config: config)
                print(Term.warn("  提示：服务未运行时推送的图片链接需要服务在线才能打开。"))
            }
        }

        var savedPath: String?
        if let destination = args.string("out") {
            savedPath = try write(payload: payload, to: destination, info: info)
        }

        if args.has("json") {
            print(jsonString(info))
            return
        }

        let bytes = (info["bytes"] as? Int) ?? payload.count
        let width = info["width"] as? Int ?? 0
        let height = info["height"] as? Int ?? 0
        print("已截图 \(Term.bold(info["id"] as? String ?? ""))  \(width)×\(height)  \(bytes / 1024)KB")
        if let savedPath {
            print("  保存到 \(savedPath)")
        }
        if daemonUp {
            let port = await resolveStatus(config: config).port
            print("  查看   \(Term.accent(AccessInfo.adminURL(config: config, port: port)))")
            print(Term.dim("  手机端请用 screenbeam pair 配对后查看"))
        } else {
            print(Term.dim("  （后台服务未运行，本次为本地截图；执行 screenbeam start 可开启服务）"))
        }
    }

    /// Writes the frame to `destination`. A trailing slash or an existing
    /// directory means "put it inside with the shot's id as the name"; `-` means
    /// stdout, so `screenbeam shot --out - > x.jpg` works.
    private static func write(payload: Data, to destination: String, info: [String: Any]) throws -> String {
        if destination == "-" {
            FileHandle.standardOutput.write(payload)
            return "<stdout>"
        }

        let expanded = (destination as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if (exists && isDirectory.boolValue) || destination.hasSuffix("/") {
            let ext = info["ext"] as? String ?? "jpg"
            let id = info["id"] as? String ?? ShotID.make()
            url = url.appendingPathComponent("\(id).\(ext)")
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: url, options: .atomic)
        return url.path
    }

    // MARK: - status

    private static func statusCommand(_ args: Arguments) async throws {
        let config = try loadConfig(args)
        let client = try DaemonClient(config: config)

        guard await client.isRunning() else {
            if args.has("json") {
                print(jsonString(["ok": false, "running": false]))
            } else {
                print(Term.warn("\(BeamPaths.appDisplayName) 服务未运行。"))
                print(Term.dim("  启动：screenbeam start（后台） 或 screenbeam run（前台）"))
                if Installer.isLoaded() {
                    print(Term.dim("  LaunchAgent 已注册但进程未响应，试试 screenbeam restart"))
                } else {
                    print(Term.dim("  LaunchAgent 未注册，先执行 screenbeam install"))
                }
            }
            exit(1)
        }

        let status = try await client.status()
        if args.has("json") {
            print(jsonString(status))
            return
        }

        func row(_ label: String, _ value: String) {
            print("  " + Term.dim(label.padding(toLength: 14, withPad: " ", startingAt: 0)) + value)
        }

        // Read from what actually happened, not from the TCC preflight. The
        // preflight is cached inside the daemon process and can read stale after
        // a rebuild, so reporting it as the verdict produced "未授权" next to
        // captures that were succeeding.
        let captureState = (status["screenCapture"] as? String) ?? "unknown"
        let preflight = (status["permissionPreflight"] as? Bool) ?? false
        let watching = (status["watching"] as? Bool) ?? false
        let uptime = (status["uptimeSeconds"] as? Int) ?? 0

        print("")
        print("  " + Term.bold(BeamPaths.appDisplayName) + " " + (status["version"] as? String ?? ""))
        print("")
        row("主机", status["host"] as? String ?? "-")
        row("运行时长", formatDuration(uptime))
        switch captureState {
        case "working":
            row("屏幕录制", Term.ok("正常") + Term.dim("（已实测截图）"))
        case "denied":
            row("屏幕录制", Term.error("缺少权限") + Term.dim("（截图被拒绝）"))
        default:
            row("屏幕录制", Term.dim(preflight ? "已授权，尚未截图验证" : "尚未验证"))
        }
        row("截图次数", String((status["captureCount"] as? Int) ?? 0))
        row("推送次数", String((status["pushCount"] as? Int) ?? 0))
        row("缓存截图", "\((status["storedShots"] as? Int) ?? 0) 张")
        row("查看端", "\((status["watchers"] as? Int) ?? 0) 个连接")
        row("定时截图", watching ? "开启" : "关闭")

        if let watch = status["watch"] as? [String: Any] {
            let interval = watch["intervalSeconds"] as? Double ?? 0
            let onlyOnChange = watch["onlyOnChange"] as? Bool ?? false
            row("", Term.dim("每 \(Int(interval))s\(onlyOnChange ? "，仅画面变化时" : "")"))
        }

        let notifiers = (status["notifiers"] as? [String]) ?? []
        row("推送渠道", notifiers.isEmpty ? Term.dim("未启用") : notifiers.joined(separator: ", "))

        if let lastShot = status["lastShotAt"] as? String {
            row("最近截图", lastShot)
        }
        if let lastError = status["lastError"] as? String {
            row("最近错误", Term.error(lastError))
        }

        row("访问地址", Term.accent(status["viewerURL"] as? String ?? ""))

        let interfaces = (status["lanAddresses"] as? [[String: String]]) ?? []
        for interface in interfaces {
            row("", Term.dim("\(interface["interface"] ?? "")  \(interface["address"] ?? "")"))
        }
        print("")
    }

    // MARK: - url / pair / devices

    private static func urlCommand(_ args: Arguments) async throws {
        let config = try loadConfig(args)
        let status = await resolveStatus(config: config)
        AccessInfo.show(
            config: config,
            port: status.port,
            pairedDevices: status.pairedDevices,
            showCode: !args.has("no-qr"),
            inverted: args.has("qr-inverted")
        )
    }

    /// Issues a pairing code and shows it with a QR code, so a new phone can join.
    private static func pairCommand(_ args: Arguments) async throws {
        let config = try loadConfig(args)
        let client = try DaemonClient(config: config)

        guard await client.isRunning() else {
            print(Term.warn("  服务未运行。先执行 ") + Term.accent("screenbeam start") + Term.warn(" 启动后台服务。"))
            exit(1)
        }

        let result = try await client.pairCode()
        guard let pairing = result["pairing"] as? [String: Any],
              let code = pairing["code"] as? String else {
            throw CLIError.daemonRejected(status: 200, message: "服务未返回配对码")
        }

        let status = await resolveStatus(config: config)
        AccessInfo.showPairing(
            code: code,
            expiresInSeconds: (pairing["expiresInSeconds"] as? Int) ?? 300,
            config: config,
            port: status.port,
            inverted: args.has("qr-inverted")
        )
    }

    /// Lists paired devices, or revokes one with `--revoke <id>`.
    private static func devicesCommand(_ args: Arguments) async throws {
        let config = try loadConfig(args)
        let client = try DaemonClient(config: config)

        guard await client.isRunning() else {
            print(Term.warn("  服务未运行。先执行 ") + Term.accent("screenbeam start"))
            exit(1)
        }

        // `--revoke <id>` parses as an option; a bare `--revoke` followed by a
        // positional also works.
        if let id = args.string("revoke") ?? (args.has("revoke") ? args.positional.first : nil) {
            guard !id.isEmpty else {
                print(Term.error("  请指定设备 id，例如：screenbeam devices --revoke d-1a2b3c4d"))
                exit(2)
            }
            _ = try await client.revokeDevice(id: id)
            print(Term.ok("  已解除配对：\(id)"))
            return
        }

        let result = try await client.devices()
        let devices = (result["devices"] as? [[String: Any]]) ?? []

        print("")
        if devices.isEmpty {
            print("  还没有已配对的设备。")
            print("  " + Term.dim("执行 ") + Term.accent("screenbeam pair") + Term.dim(" 生成配对码。"))
            print("")
            return
        }

        print("  " + Term.bold("已配对设备") + Term.dim("  \(devices.count) 台"))
        print("")
        for device in devices {
            let id = device["id"] as? String ?? "?"
            let name = device["name"] as? String ?? "未命名"
            print("  " + Term.accent(id) + "  " + name)
            if let last = device["lastSeenAt"] as? String {
                print("  " + String(repeating: " ", count: id.count) + "  " + Term.dim("最近活跃 \(last)"))
            } else {
                print("  " + String(repeating: " ", count: id.count) + "  " + Term.dim("尚未使用"))
            }
        }
        print("")
        print("  " + Term.dim("解除配对  ") + Term.accent("screenbeam devices --revoke <id>"))
        print("")
    }

    private struct DaemonStatus {
        let port: UInt16
        let pairedDevices: Int
    }

    /// Falls back to the configured values when the daemon is not reachable.
    private static func resolveStatus(config: BeamConfig) async -> DaemonStatus {
        let fallback = DaemonStatus(port: UInt16(clamping: config.server.port), pairedDevices: 0)

        guard let client = try? DaemonClient(config: config),
              await client.isRunning(),
              let status = try? await client.status() else {
            return fallback
        }

        var port = fallback.port
        if let server = status["server"] as? [String: Any], let value = server["port"] as? Int {
            port = UInt16(clamping: value)
        }
        return DaemonStatus(port: port, pairedDevices: (status["pairedDevices"] as? Int) ?? 0)
    }

    // MARK: - perm

    private static func permissionCommand(_ args: Arguments) async throws {
        let granted = ScreenRecordingPermission.isGranted

        if granted {
            print(Term.ok("  「屏幕录制」权限已授权。"))
        } else {
            print(Term.warn("  「屏幕录制」权限未授权，无法截图。"))
        }

        // `--request` runs a non-prompting check first: macOS only shows the
        // dialog once per bundle, so after a denial `request()` is a no-op and
        // the user has to go to System Settings.
        if !granted, args.has("request") || args.has("open") {
            print("")
            ScreenRecordingPermission.request()
            print("  已请求权限并打开系统设置，请勾选 \(BeamPaths.appName)。")
            ScreenRecordingPermission.openSystemSettings()
            print(Term.dim("  勾选后服务会自动重启生效；若没反应，执行 screenbeam restart。"))
        }

        if !granted, args.has("wait") {
            print("")
            print("  等待授权中…（最长 5 分钟）")
            let ok = await ScreenRecordingPermission.waitUntilGranted(timeout: 300)
            print(ok ? Term.ok("  已授权。") : Term.error("  超时，仍未获得授权。"))
            exit(ok ? 0 : 1)
        }
    }

    // MARK: - config

    private static func configCommand(_ args: Arguments) throws {
        let path = args.string("config")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? BeamPaths.configFile

        if args.has("path") {
            print(path.path)
            return
        }

        if args.has("init") {
            try BeamPaths.ensureDirectories()
            let config = ConfigStore.defaultConfig()
            try ConfigStore.save(config, to: path)
            print(Term.ok("  已生成默认配置：\(path.path)"))
            return
        }

        if args.has("edit") {
            try BeamPaths.ensureDirectories()
            if !FileManager.default.fileExists(atPath: path.path) {
                try ConfigStore.save(ConfigStore.defaultConfig(), to: path)
            }
            let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "open"
            if editor == "open" {
                print(Term.dim("  未设置 $EDITOR，使用默认程序打开。"))
            }
            _ = Shell.run("/usr/bin/env", [editor, path.path])
            return
        }

        try BeamPaths.ensureDirectories()
        let config = try ConfigStore.load(from: path)
        print("")
        print("  " + Term.dim("配置文件  ") + path.path)
        print("")
        print(jsonString([
            "server": [
                "host": config.server.host,
                "port": config.server.port,
                "token": config.server.token,
                "publicBaseURL": config.server.publicBaseURL ?? "",
            ],
            "capture": [
                "mode": config.capture.mode.rawValue,
                "displayIndex": config.capture.displayIndex,
                "format": config.capture.format.rawValue,
                "quality": config.capture.quality,
                "maxLongEdge": config.capture.maxLongEdge,
            ],
            "watch": [
                "enabled": config.watch.enabled,
                "intervalSeconds": config.watch.intervalSeconds,
                "onlyOnChange": config.watch.onlyOnChange,
                "pushOnCapture": config.watch.pushOnCapture,
            ],
            "notifyChannels": config.notify.channels.map {
                ["kind": $0.kind.rawValue, "enabled": $0.enabled, "name": $0.name ?? ""]
            },
        ]))
        print("")
        print(Term.dim("  编辑：screenbeam config --edit"))
        print("")
    }

    // MARK: - logs

    private static func logsCommand(_ args: Arguments) throws {
        let file = BeamPaths.logDirectory
            .appendingPathComponent(args.has("stdout") ? "out.log" : "err.log")

        guard FileManager.default.fileExists(atPath: file.path) else {
            print(Term.warn("  还没有日志文件：\(file.path)"))
            print(Term.dim("  服务运行后才会产生日志。"))
            return
        }

        if args.has("follow") {
            // Inherit stdio so Ctrl-C behaves exactly like tail.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            process.arguments = ["-f", file.path]
            try process.run()
            process.waitUntilExit()
            return
        }

        let lines = max(1, args.int("lines") ?? 40)
        let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let tail = content.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)
        print(tail.joined(separator: "\n"))
    }

    // MARK: - selftest

    /// Runs the built-in cases from `ScreenBeamCore.SelfTest`.
    ///
    /// There is no `swift test` here on purpose: XCTest and swift-testing both
    /// need a full Xcode install, and this project targets a Command Line Tools
    /// setup. The cases live in the library instead, so they ship with the binary
    /// and can be run against any build.
    private static func selfTestCommand(_ args: Arguments) throws {
        let started = Date()
        let cases = SelfTest.run(filter: args.string("filter"))
        let elapsed = Date().timeIntervalSince(started)

        let failed = cases.filter { !$0.passed }

        for testCase in cases {
            if let failure = testCase.failure {
                print("  " + Term.error("✗") + " " + testCase.name)
                print("      " + Term.dim(failure))
            } else if args.has("verbose") {
                print("  " + Term.ok("✓") + " " + testCase.name)
            }
        }

        print("")
        if failed.isEmpty {
            print("  " + Term.ok("全部通过") + "  \(cases.count) 项，用时 "
                + String(format: "%.2fs", elapsed))
            print("")
            return
        }

        print("  " + Term.error("失败 \(failed.count) / \(cases.count) 项") + "，用时 "
            + String(format: "%.2fs", elapsed))
        print("")
        exit(1)
    }

    // MARK: - Shared helpers

    private static func resolveConfigURL(_ args: Arguments) -> URL {
        args.string("config")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? BeamPaths.configFile
    }

    private static func loadConfig(_ args: Arguments) throws -> BeamConfig {
        var config = try ConfigStore.load(from: resolveConfigURL(args))
        if let port = args.int("port") { config.server.port = port }
        if let host = args.string("host") { config.server.host = host }
        if let token = args.string("token") { config.server.token = token }
        return config
    }

    static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours < 24 { return "\(hours) 小时 \(minutes) 分" }
        return "\(hours / 24) 天 \(hours % 24) 小时"
    }

    private static func printHelp() {
        print("""

        \(Term.bold(BeamPaths.appDisplayName)) — 后台截屏，手机随时查看
        \(Term.dim("仅在 macOS 14+ 上运行，截图依赖 ScreenCaptureKit。"))

        \(Term.bold("用法"))
          screenbeam <命令> [选项]

        \(Term.bold("常用"))
          run                 前台运行后台服务（调试用，Ctrl-C 退出）
          shot                立即截一张，可配 --out 存文件、--push 推送到手机
          status              查看运行状态
          logs --follow       实时查看日志

        \(Term.bold("配对与设备"))
          pair                生成配对码 + 二维码，手机扫码即可连接
          devices             列出已配对设备
          devices --revoke <id>   解除某台设备的配对
          url                 显示管理入口地址与网络信息

        \(Term.bold("安装"))
          install             安装 PHONE·CATCH·SCREEN.app 与 LaunchAgent 并申请权限
          uninstall           卸载（配置与日志保留）
          start / stop / restart    控制后台服务

        \(Term.bold("其他"))
          perm                查看屏幕录制权限；--request 申请，--wait 等待授权
          config              查看配置；--edit 编辑，--path 打印路径，--init 重建
          selftest            运行内置自检（--verbose 显示全部，--filter 过滤）
          version             打印版本
          help                显示本帮助

        \(Term.bold("通用选项"))
          --config <路径>     使用指定的配置文件
          --port <端口>       覆盖 server.port
          --host <地址>       覆盖 server.host
          --token <令牌>      覆盖访问令牌
          --json              以 JSON 输出（shot / status）

        \(Term.bold("示例"))
          screenbeam install && screenbeam pair
          screenbeam devices
          screenbeam shot --out ~/Desktop/
          screenbeam status --json

        """)
    }
}

// MARK: - Local capture (no daemon)

/// The in-process path used when the background service is not running.
enum LocalCapture {
    static func capture(config: BeamConfig) async throws -> Shot {
        guard ScreenRecordingPermission.isGranted else {
            throw CaptureError.screenRecordingPermissionDenied
        }

        let frame = try await ScreenCapturer().capture(
            mode: config.capture.mode,
            displayIndex: config.capture.displayIndex,
            showCursor: config.capture.showCursor
        )

        let encoded = try ImageEncoder.encode(
            frame.image,
            format: config.capture.format,
            quality: config.capture.quality,
            maxLongEdge: config.capture.maxLongEdge
        )

        let now = Date()
        return Shot(
            id: ShotID.make(date: now),
            payload: encoded.data,
            format: config.capture.format,
            pixelWidth: encoded.pixelWidth,
            pixelHeight: encoded.pixelHeight,
            createdAt: now,
            source: frame.source
        )
    }

    /// One-off push without a daemon. The image link in the notification points at
    /// a server that is not running, so callers should warn the user.
    static func push(shot info: [String: Any], payload: Data, config: BeamConfig) async throws {
        let service = NotifierService(config: config)
        guard !service.isEmpty else {
            throw CLIError.invalidConfiguration("没有启用任何推送渠道，请先编辑 config.json")
        }

        let shotFormat: Shot.Format = ((info["ext"] as? String) == "png") ? .png : .jpeg

        let shot = Shot(
            id: info["id"] as? String ?? ShotID.make(),
            payload: payload,
            format: shotFormat,
            pixelWidth: info["width"] as? Int ?? 0,
            pixelHeight: info["height"] as? Int ?? 0,
            createdAt: Date(),
            source: info["source"] as? String ?? "unknown"
        )

        let host = NetInfo.hostName
        let base = "http://\(NetInfo.primaryLANAddress() ?? "127.0.0.1"):\(config.server.port)"
        let viewer = "\(base)/?token=\(config.server.token)"

        let caption = CaptionTemplate.render(
            config.notify.caption,
            shot: shot,
            hostName: host,
            viewerURL: viewer
        )

        await service.dispatch(NotifyPayload(
            shot: shot,
            caption: caption,
            imageURL: "\(base)/api/frame/\(shot.id).\(shot.format.fileExtension)?token=\(config.server.token)",
            viewerURL: viewer,
            hostName: host
        ))
    }
}
