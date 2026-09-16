import Foundation

/// The config file is meant to be hand-edited, so it has to tolerate missing
/// keys, extra keys and the occasional wrong type without stopping the daemon.
enum ConfigCases {
    static let all: [(String, () throws -> Void)] = [
        ("空对象解码出完整默认值", {
            let config = try decode("{}")
            try checkEqual(config.server.host, "127.0.0.1", "host（默认应为回环）")
            try checkEqual(config.server.port, 8787, "port")
            try checkEqual(config.capture.mode, .display, "capture.mode")
            try checkEqual(config.capture.format, .jpeg, "capture.format")
            try checkEqual(config.capture.maxLongEdge, 1600, "capture.maxLongEdge")
            try checkEqual(config.watch.intervalSeconds, 10, "watch.intervalSeconds")
            try check(config.watch.onlyOnChange, "watch.onlyOnChange")
            try checkEqual(config.history.keepInMemory, 24, "history.keepInMemory")
            try check(config.notify.channels.isEmpty, "默认不应启用推送渠道")
        }),

        ("部分字段缺失时保留同级默认值", {
            let config = try decode(#"{"server":{"port":9000}}"#)
            try checkEqual(config.server.port, 9000, "指定值")
            try checkEqual(config.server.host, "127.0.0.1", "未指定的同级字段回退到回环默认值")
        }),

        // A typo should degrade to the default rather than stop the service from
        // starting at all.
        ("类型写错时回退到默认值", {
            let config = try decode(#"{"server":{"port":"not-a-number"},"capture":{"quality":"high"}}"#)
            try checkEqual(config.server.port, 8787, "port 回退")
            try checkEqual(config.capture.quality, 0.75, "quality 回退")
        }),

        ("枚举取值非法时回退到默认值", {
            let config = try decode(#"{"capture":{"mode":"webcam","format":"webp"}}"#)
            try checkEqual(config.capture.mode, .display, "mode 回退")
            try checkEqual(config.capture.format, .jpeg, "format 回退")
        }),

        ("未知字段被忽略", {
            let config = try decode(#"{"server":{"port":9000},"futureFeature":{"x":1}}"#)
            try checkEqual(config.server.port, 9000, "已知字段仍生效")
        }),

        ("各推送渠道字段正确解码", {
            let config = try decode("""
            {"notify":{"onManualCapture":true,"channels":[
              {"kind":"bark","enabled":true,"deviceKey":"k1","attachImage":true},
              {"kind":"ntfy","enabled":true,"server":"https://ntfy.example","topic":"t1"},
              {"kind":"telegram","enabled":true,"botToken":"b","chatId":"c"},
              {"kind":"feishu","enabled":false,"webhook":"https://open.feishu.cn/x"},
              {"kind":"webhook","enabled":true,"url":"https://x","headers":{"A":"B"}}
            ]}}
            """)

            try check(config.notify.onManualCapture, "onManualCapture")
            try checkEqual(config.notify.channels.count, 5, "渠道数量")
            try checkEqual(config.notify.channels[0].kind, .bark, "第 1 个渠道类型")
            try checkEqual(config.notify.channels[0].deviceKey, "k1", "bark deviceKey")
            try checkEqual(config.notify.channels[1].server, "https://ntfy.example", "ntfy server")
            try checkEqual(config.notify.channels[4].headers?["A"], "B", "webhook headers")
            try check(!config.notify.channels[3].enabled, "飞书渠道应保持未启用")
        }),

        ("配置编解码往返不丢字段", {
            var original = ConfigStore.defaultConfig()
            original.capture.mode = .window
            original.capture.quality = 0.42
            original.capture.displayIndex = 2
            original.watch.enabled = true
            original.watch.changeThreshold = 0.09
            original.history.saveDirectory = "/tmp/shots"
            original.server.publicBaseURL = "https://beam.example"
            original.notify.caption = "hi {host}"
            original.notify.channels[0].deviceKey = "device-key"

            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(BeamConfig.self, from: data)

            try checkEqual(decoded.capture.mode, .window, "capture.mode")
            try checkClose(decoded.capture.quality, 0.42, 0.0001, "capture.quality")
            try checkEqual(decoded.capture.displayIndex, 2, "capture.displayIndex")
            try check(decoded.watch.enabled, "watch.enabled")
            try checkClose(decoded.watch.changeThreshold, 0.09, 0.0001, "watch.changeThreshold")
            try checkEqual(decoded.history.saveDirectory, "/tmp/shots", "history.saveDirectory")
            try checkEqual(decoded.server.publicBaseURL, "https://beam.example", "server.publicBaseURL")
            try checkEqual(decoded.notify.caption, "hi {host}", "notify.caption")
            try checkEqual(decoded.notify.channels[0].deviceKey, "device-key", "bark deviceKey")
            try checkEqual(decoded.server.token, original.server.token, "token")
        }),

        ("默认配置预置令牌与全部渠道类型", {
            let config = ConfigStore.defaultConfig()
            try checkEqual(config.server.token.count, 32, "令牌长度")
            try check(config.server.token.allSatisfy { $0.isHexDigit }, "令牌应为十六进制")

            let kinds = Set(config.notify.channels.map(\.kind))
            try checkEqual(kinds, Set([.bark, .ntfy, .telegram, .feishu]), "预置渠道类型")
            try check(!config.notify.onManualCapture, "默认不应在每次手动截图时推送")
        }),

        ("随机令牌互不重复", {
            let tokens = Set((0..<200).map { _ in ConfigStore.randomToken() })
            try checkEqual(tokens.count, 200, "200 次生成的唯一令牌数")
        }),

        ("仅本机模式的判定", {
            var server = ServerConfig()
            server.host = "127.0.0.1"
            try check(server.isLoopbackOnly, "127.0.0.1")
            server.host = "localhost"
            try check(server.isLoopbackOnly, "localhost")
            server.host = "0.0.0.0"
            try check(!server.isLoopbackOnly, "0.0.0.0")
        }),

        ("文案模板全部占位符被替换", {
            let shot = sampleShot()
            let rendered = CaptionTemplate.render(
                "{host}|{date}|{time}|{source}|{width}x{height}|{url}",
                shot: shot, hostName: "mac", viewerURL: "http://x/?token=1"
            )
            try check(rendered.hasPrefix("mac|2026-"), "host 与 date 前缀：\(rendered)")
            try check(rendered.contains("window:Safari"), "source")
            try check(rendered.contains("1600x1000"), "尺寸")
            try check(rendered.hasSuffix("http://x/?token=1"), "url")
            try check(!rendered.contains("{"), "不应残留未替换的占位符：\(rendered)")
        }),

        ("未知占位符保持原样", {
            let rendered = CaptionTemplate.render("{nope}", shot: sampleShot(), hostName: "mac", viewerURL: "u")
            try checkEqual(rendered, "{nope}", "未知占位符")
        }),

        // ---- Exposure defaults -------------------------------------------
        //
        // These are the settings that decide whether the service is reachable
        // from anywhere but this machine. They are asserted because a default is
        // exactly the kind of thing that gets changed casually and then ships.

        ("默认只绑本机，不对局域网暴露", {
            let config = ConfigStore.defaultConfig()
            try check(config.server.isLoopbackOnly, "默认 host 应为 \(config.server.host)，现在不是回环地址")
            try checkEqual(config.server.host, "127.0.0.1", "默认 host")

            // And the same for a config file that omits the key entirely.
            let minimal = try JSONDecoder().decode(BeamConfig.self, from: Data("{}".utf8))
            try check(minimal.server.isLoopbackOnly, "缺省 host 应为回环地址")
        }),

        ("显式配置的局域网绑定仍然生效", {
            // Opening it up has to stay possible — it is how the phone connects.
            let config = try decode(#"{"server":{"host":"0.0.0.0"}}"#)
            try check(!config.server.isLoopbackOnly, "显式写 0.0.0.0 应生效")
        }),

        ("日志级别默认不过度记录", {
            let config = ConfigStore.defaultConfig()
            try checkEqual(config.logging.level, .normal, "默认级别")
            try check(
                config.logging.level != .debug,
                "默认不应是 debug —— 那会把每次截图都写进日志"
            )

            let minimal = try JSONDecoder().decode(BeamConfig.self, from: Data("{}".utf8))
            try checkEqual(minimal.logging.level, .normal, "缺省级别")
        }),

        ("日志级别可配置，非法值回退", {
            try checkEqual(
                try decode(#"{"logging":{"level":"debug"}}"#).logging.level, .debug, "debug"
            )
            try checkEqual(
                try decode(#"{"logging":{"level":"quiet"}}"#).logging.level, .quiet, "quiet"
            )
            try checkEqual(
                try decode(#"{"logging":{"level":"verbose"}}"#).logging.level, .normal,
                "非法值应回退到 normal"
            )
        }),

        ("三个日志级别都在（quiet 不会被悄悄删掉）", {
            try checkEqual(
                Set(LogLevel.allCases), Set([.quiet, .normal, .debug]),
                "级别集合"
            )
        }),

        ("配置往返不丢 logging 段", {
            var original = ConfigStore.defaultConfig()
            original.logging.level = .debug
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(BeamConfig.self, from: data)
            try checkEqual(decoded.logging.level, .debug, "logging.level")
        }),

        // The config file holds the LLM API key in the clear, so it must not be
        // left at the umask default the way `Data.write` creates it.
        ("写出的配置文件权限为 600", {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("screenbeam-perm-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let url = directory.appendingPathComponent("config.json")
            try ConfigStore.save(ConfigStore.defaultConfig(), to: url)

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            try checkEqual(
                permissions & 0o077, 0,
                "配置文件的组/其他权限应为空，实际 \(String(permissions, radix: 8))"
            )
        }),
    ]

    // MARK: - Helpers

    static func decode(_ json: String) throws -> BeamConfig {
        try JSONDecoder().decode(BeamConfig.self, from: Data(json.utf8))
    }

    static func sampleShot() -> Shot {
        Shot(
            id: "20260915-173012-482-abcd",
            payload: Data(),
            format: .jpeg,
            pixelWidth: 1600,
            pixelHeight: 1000,
            createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            source: "window:Safari"
        )
    }
}
