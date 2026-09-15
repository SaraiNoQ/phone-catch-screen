import Darwin
import Foundation

/// Owns the capture path, the store, the HTTP server and the watch loop.
///
/// It outlives any single request, which is what lets the phone pull frames on
/// demand instead of the Mac pushing on a fixed schedule.
public final class BeamEngine: @unchecked Sendable {
    public enum Trigger: String, Sendable {
        case manual
        case api
        case watch
    }

    public struct Stats: Sendable {
        public var captureCount = 0
        public var pushCount = 0
        public var lastShotAt: Date?
        public var lastError: String?
    }

    /// Per-process overrides from the command line (`--port`, `--host`, `--token`).
    ///
    /// These are sticky: they are re-applied after every config reload. Without
    /// that, editing the file and hitting `/api/reload` would silently swap the
    /// access token and evict every connected phone mid-session.
    public struct Overrides: Sendable {
        public var host: String?
        public var port: Int?
        public var token: String?

        public init(host: String? = nil, port: Int? = nil, token: String? = nil) {
            self.host = host
            self.port = port
            self.token = token
        }

        public var isEmpty: Bool { host == nil && port == nil && token == nil }
    }

    /// Outcome of a reload, so the caller can tell the operator what changed.
    public struct ReloadResult: Sendable {
        public let tokenChanged: Bool
        /// True when host/port changed, which cannot be applied without a restart.
        public let requiresRestart: Bool
    }

    // MARK: - Collaborators

    private let capturer = ScreenCapturer()
    private let store: ShotStore
    private let notifierService: NotifierService

    /// Live viewer connections.
    public let bus = EventBus()

    /// Phones that have completed pairing.
    public let devices: DeviceStore

    /// Pending pairing code, if one is on offer.
    private let pairing = PairingSession()

    private var server: HTTPServer?

    // MARK: - State

    private var config: BeamConfig
    private let configLock = NSLock()
    private let stateLock = NSLock()
    private let overrides: Overrides

    /// The file this instance was loaded from, and the one settings are written
    /// back to.
    ///
    /// Tracked explicitly because it is *not* always `BeamPaths.configFile`: a
    /// daemon started with `--config /tmp/other.json` must not write its settings
    /// into the user's real config. Getting this wrong silently rewrites a file
    /// the operator never asked to touch.
    private let configURL: URL

    private var stats = Stats()
    private var watchTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var previousSignature: ChangeDetector.Signature?

    /// Serialises captures so a phone-triggered grab and a watcher tick never run
    /// through ScreenCaptureKit at the same time.
    private let captureGate = AsyncMutex()

    /// When true, the process exits after the user grants Screen Recording so
    /// launchd can restart it — macOS does not apply a fresh grant to a running
    /// process. Only enabled when running under the LaunchAgent; a foreground
    /// `screenbeam run` should not spontaneously quit.
    public let relaunchOnPermissionGrant: Bool

    public let startedAt = Date()

    // MARK: - Init

    public init(
        config: BeamConfig,
        configURL: URL = BeamPaths.configFile,
        overrides: Overrides = Overrides(),
        relaunchOnPermissionGrant: Bool
    ) {
        self.configURL = configURL
        self.overrides = overrides
        self.config = BeamEngine.apply(overrides, to: config)
        self.relaunchOnPermissionGrant = relaunchOnPermissionGrant
        self.store = ShotStore(
            capacity: config.history.keepInMemory,
            saveDirectory: config.history.saveDirectory,
            retentionMinutes: config.history.retentionMinutes
        )
        self.devices = DeviceStore()
        self.notifierService = NotifierService(config: self.config)
    }

    private static func apply(_ overrides: Overrides, to config: BeamConfig) -> BeamConfig {
        var result = config
        if let host = overrides.host { result.server.host = host }
        if let port = overrides.port { result.server.port = port }
        if let token = overrides.token { result.server.token = token }
        return result
    }

    // MARK: - Lifecycle

    public func start() throws {
        let current = currentConfig()

        let server = try HTTPServer(
            port: UInt16(clamping: current.server.port),
            loopbackOnly: current.server.isLoopbackOnly
        ) { [weak self] request, responder in
            guard let self else {
                responder.respond(.error(503, "服务正在关闭"))
                return
            }
            Router.route(request: request, responder: responder, engine: self)
        }

        try server.start()
        self.server = server

        Log.info("HTTP 服务已启动：http://\(current.server.host):\(server.boundPort)")

        // First run has nothing paired, so put a code on the table immediately —
        // otherwise the phone would connect and have no way in.
        if devices.isEmpty {
            let code = pairing.issue()
            Log.info("尚未配对任何设备，已生成配对码：\(code.value)（\(Int(code.expiresAt.timeIntervalSinceNow / 60) + 1) 分钟内有效）")
        }

        supervisePermission()

        if current.watch.enabled {
            startWatch()
        }
    }

    public func stop() {
        watchTask?.cancel()
        watchTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        server?.stop()
        server = nil
        Log.info("\(BeamPaths.appDisplayName) 已停止。")
    }

    /// Port the server actually bound to. Differs from the configured value when
    /// the config asked for port 0 (let the kernel choose).
    public var boundPort: UInt16 {
        server?.boundPort ?? UInt16(clamping: currentConfig().server.port)
    }

    // MARK: - Config

    public func currentConfig() -> BeamConfig {
        configLock.lock()
        defer { configLock.unlock() }
        return config
    }

    /// Re-reads the config file and rebuilds everything derived from it, keeping
    /// any command-line overrides in force.
    ///
    /// Changes to the bind address or port are *not* applied — rebinding a live
    /// listener would drop the phone's connection — so those need a restart and
    /// are reported back to the caller.
    @discardableResult
    public func reloadConfig() throws -> ReloadResult {
        let fresh = BeamEngine.apply(overrides, to: try ConfigStore.load(from: configURL))

        configLock.lock()
        let previous = config
        config = fresh
        configLock.unlock()

        notifierService.reload(fresh)

        let requiresRestart = previous.server.port != fresh.server.port
            || previous.server.host != fresh.server.host
        if requiresRestart {
            Log.warn("server.host / server.port 已变更，需要重启 \(BeamPaths.appDisplayName) 才能生效。")
        }

        let tokenChanged = previous.server.token != fresh.server.token
        if tokenChanged {
            Log.warn("访问令牌已变更，已连接的页面需要用新令牌重新打开。")
        }

        if fresh.watch.enabled, watchTask == nil {
            startWatch()
        } else if !fresh.watch.enabled, watchTask != nil {
            stopWatch()
        }

        return ReloadResult(tokenChanged: tokenChanged, requiresRestart: requiresRestart)
    }

    // MARK: - Capture

    /// Captures, stores, broadcasts and (optionally) pushes.
    public func captureNow(trigger: Trigger, push: Bool? = nil) async throws -> Shot {
        try await captureGate.withLock {
            let (frame, signature) = try await grab()
            previousSignature = signature
            let shouldPush = push ?? defaultPushDecision(for: trigger)
            return try await publish(frame, trigger: trigger, push: shouldPush)
        }
    }

    private func grab() async throws -> (frame: RawFrame, signature: ChangeDetector.Signature?) {
        let current = currentConfig()
        let frame = try await capturer.capture(
            mode: current.capture.mode,
            displayIndex: current.capture.displayIndex,
            showCursor: current.capture.showCursor
        )
        return (frame, ChangeDetector.signature(of: frame.image))
    }

    private func publish(_ frame: RawFrame, trigger: Trigger, push: Bool) async throws -> Shot {
        let current = currentConfig()

        let encoded = try ImageEncoder.encode(
            frame.image,
            format: current.capture.format,
            quality: current.capture.quality,
            maxLongEdge: current.capture.maxLongEdge
        )

        let now = Date()
        let shot = Shot(
            id: store.nextID(for: now),
            payload: encoded.data,
            format: current.capture.format,
            pixelWidth: encoded.pixelWidth,
            pixelHeight: encoded.pixelHeight,
            createdAt: now,
            source: frame.source
        )

        store.add(shot)
        recordSuccess(shot)
        Log.info("已截图 \(shot.id) [\(trigger.rawValue)] \(shot.pixelWidth)×\(shot.pixelHeight) \(shot.byteCount / 1024)KB")

        bus.broadcast(event: "shot", payload: ShotJSON.encode(shot))

        if push {
            await dispatchNotifications(for: shot)
        }
        return shot
    }

    private func defaultPushDecision(for trigger: Trigger) -> Bool {
        let current = currentConfig()
        switch trigger {
        case .manual, .api: return current.notify.onManualCapture
        case .watch: return current.watch.pushOnCapture
        }
    }

    // MARK: - Watch loop

    public var isWatching: Bool {
        watchTask != nil
    }

    public func startWatch() {
        guard watchTask == nil else { return }

        Log.info("已开启定时截图。")
        watchTask = Task { [weak self] in
            await self?.runWatchLoop()
        }
        broadcastWatchState()
    }

    public func stopWatch() {
        guard watchTask != nil else { return }
        watchTask?.cancel()
        watchTask = nil
        Log.info("已停止定时截图。")
        broadcastWatchState()
    }

    private func broadcastWatchState() {
        bus.broadcast(event: "watch", payload: ["running": isWatching])
    }

    private func runWatchLoop() async {
        var consecutiveFailures = 0

        while !Task.isCancelled {
            let current = currentConfig()
            let interval = max(1.0, current.watch.intervalSeconds)

            do {
                try await captureGate.withLock { () -> Void in
                    let (frame, signature) = try await grab()

                    var changed = true
                    if current.watch.onlyOnChange,
                       let signature,
                       let previous = previousSignature {
                        let delta = ChangeDetector.difference(previous, signature)
                        changed = delta >= current.watch.changeThreshold
                        if !changed {
                            Log.debug(String(format: "画面未变化（差异 %.4f），跳过。", delta))
                        }
                    }
                    previousSignature = signature

                    guard changed else { return }
                    _ = try await publish(
                        frame,
                        trigger: .watch,
                        push: current.watch.pushOnCapture
                    )
                }
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                recordFailure(error)

                if case CaptureError.screenRecordingPermissionDenied = error {
                    // No point spinning on a permission error; tell the viewer and
                    // wait for the supervisor to restart us after a grant.
                    bus.broadcast(event: "permission", payload: ["granted": false])
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    continue
                }
            }

            // Back off on repeated failures so a persistent error does not hammer
            // the capture pipeline.
            let backoff = consecutiveFailures > 0
                ? min(interval * Double(consecutiveFailures), 60)
                : interval
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }
    }

    // MARK: - Permission supervision

    private var permissionGranted: Bool {
        ScreenRecordingPermission.isGranted
    }

    private func supervisePermission() {
        guard !permissionGranted else {
            Log.info("屏幕录制权限正常。")
            return
        }

        Log.warn("尚未获得「屏幕录制」权限。")
        // Requested from here rather than from the installer on purpose: the
        // process asking must be the app itself. Run by launchd, this call is
        // attributed to the app, so the app gets registered in the pane and the
        // consent dialog names it. A request made from a shell would be
        // attributed to the terminal instead.
        ScreenRecordingPermission.request()
        Log.warn("请打开 系统设置 → 隐私与安全性 → 屏幕录制，勾选 \(BeamPaths.appDisplayName)。")
        Log.warn("勾选后若仍未生效，执行 screenbeam restart（预检结果在进程内是缓存的）。")

        permissionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.permissionGranted {
                    self.bus.broadcast(event: "permission", payload: ["granted": true])
                    if self.relaunchOnPermissionGrant {
                        Log.info("权限已授予，重启进程以使其生效。")
                        self.stop()
                        // Non-zero exit so the LaunchAgent's
                        // KeepAlive{SuccessfulExit:false} brings us straight back.
                        exit(1)
                    } else {
                        // macOS does not apply a fresh Screen Recording grant to an
                        // already-running process, so this instance still cannot
                        // capture. Say so rather than implying it now works.
                        Log.warn("权限已授予，但需要重启服务才能生效：screenbeam restart")
                    }
                    return
                }
            }
        }
    }

    public func requestPermissionInteractively() {
        if permissionGranted {
            Log.info("屏幕录制权限已具备。")
            return
        }
        ScreenRecordingPermission.request()
        ScreenRecordingPermission.openSystemSettings()
    }

    // MARK: - Pairing

    public struct PairingOutcome: Sendable {
        public let device: PairedDevice
        /// Returned exactly once, to be handed straight to the phone.
        public let token: String
    }

    public var pairedDeviceCount: Int { devices.count }
    public var hasPendingPairingCode: Bool { pairing.hasPendingCode }

    @discardableResult
    public func issuePairingCode() -> PairingCode {
        pairing.issue()
    }

    public func currentPairingCode() -> PairingCode? {
        pairing.current()
    }

    /// Redeems a pairing code and mints a device credential.
    ///
    /// The code is single-use: a successful redeem destroys it, so a code that
    /// leaks after the fact is worthless.
    public func pair(
        code: String,
        peer: String,
        deviceName: String,
        userAgent: String?
    ) throws -> PairingOutcome {
        switch pairing.redeem(code, peer: peer) {
        case .ok:
            break
        case .noCode:
            throw PairingError.noCode
        case .expired:
            throw PairingError.expired
        case .tooManyAttempts:
            throw PairingError.tooManyAttempts
        case .mismatch(let remaining):
            throw PairingError.mismatch(remaining: remaining)
        }

        let (device, token) = try devices.add(name: deviceName, userAgent: userAgent)

        // A fresh device has nothing to do with the old code, so clear it and let
        // the operator issue a new one deliberately if they want another device.
        pairing.clear()

        Log.info("设备已配对：\(device.name) [\(device.id)] 来自 \(peer)")
        bus.broadcast(event: "devices", payload: ["count": devices.count])
        return PairingOutcome(device: device, token: token)
    }

    @discardableResult
    public func revokeDevice(id: String) -> Bool {
        let removed = devices.revoke(id: id)
        if removed {
            Log.info("已解除设备配对：\(id)")
            bus.broadcast(event: "devices", payload: ["count": devices.count])
        }
        return removed
    }

    // MARK: - Capture settings (changeable from the phone)

    /// Switches between whole-screen and frontmost-window capture.
    ///
    /// Persisted so the choice survives a restart — a paired device already has
    /// full capture access, so letting it pick the framing is not an escalation.
    public func setCaptureMode(_ mode: CaptureConfig.Mode) throws {
        configLock.lock()
        config.capture.mode = mode
        let snapshot = config
        configLock.unlock()

        try ConfigStore.save(snapshot, to: configURL)
        Log.info("截图模式已切换为 \(mode.rawValue)")
        bus.broadcast(event: "settings", payload: ["captureMode": mode.rawValue])
    }

    /// Enables or disables the periodic capture loop, persisting the choice.
    public func setWatchEnabled(_ enabled: Bool) {
        configLock.lock()
        config.watch.enabled = enabled
        let snapshot = config
        configLock.unlock()

        try? ConfigStore.save(snapshot, to: configURL)

        if enabled {
            startWatch()
        } else {
            stopWatch()
        }
    }

    // MARK: - Vision model

    public func llmConfig() -> LLMConfig {
        currentConfig().llm
    }

    /// Applies a partial settings update and persists it.
    ///
    /// `apiKey` is only replaced when a non-empty value arrives, so the phone can
    /// save other fields without ever having to hold or resend the key.
    @discardableResult
    public func updateLLMConfig(_ apply: (inout LLMConfig) -> Void) throws -> LLMConfig {
        configLock.lock()
        apply(&config.llm)
        let snapshot = config
        configLock.unlock()

        try ConfigStore.save(snapshot, to: configURL)
        Log.info("LLM 配置已更新：provider=\(snapshot.llm.provider.rawValue) model=\(snapshot.llm.model) enabled=\(snapshot.llm.enabled)")
        bus.broadcast(event: "settings", payload: ["llm": snapshot.llm.publicJSON])
        return snapshot.llm
    }

    /// Asks the configured vision model about a frame.
    ///
    /// The image is whatever the phone is looking at: an explicit `shotID` when it
    /// names one (so you can ask about a frame from history), otherwise the newest
    /// frame. With nothing captured yet it takes one, so a first question still works.
    public func askAboutScreen(
        question: String,
        history: [LLMTurn],
        shotID: String?
    ) async throws -> LLMAnswer {
        let config = currentConfig().llm
        guard config.enabled else { throw LLMError.notConfigured }

        let shot: Shot
        if let shotID, let named = store.shot(id: shotID) {
            shot = named
        } else if let latest = store.latest() {
            shot = latest
        } else {
            shot = try await captureNow(trigger: .api, push: false)
        }

        let answer = try await LLMClient.ask(
            question: question,
            history: history,
            image: shot,
            config: config
        )
        Log.info("LLM 已作答：\(answer.model)，输入 \(answer.inputTokens ?? 0) tokens，输出 \(answer.outputTokens ?? 0) tokens")
        return answer
    }

    // MARK: - Notifications

    public func dispatchNotifications(for shot: Shot) async {
        guard !notifierService.isEmpty else { return }

        let viewer = viewerURL()
        let host = NetInfo.hostName
        let caption = CaptionTemplate.render(
            currentConfig().notify.caption,
            shot: shot,
            hostName: host,
            viewerURL: viewer
        )

        let payload = NotifyPayload(
            shot: shot,
            caption: caption,
            imageURL: imageURL(for: shot),
            viewerURL: viewer,
            hostName: host
        )

        await notifierService.dispatch(payload)
        recordPush()
    }

    /// Re-sends the most recent frame (or captures a fresh one first).
    @discardableResult
    public func pushLatest(recapture: Bool) async throws -> Shot {
        let shot: Shot
        if recapture {
            shot = try await captureNow(trigger: .api, push: false)
        } else if let latest = store.latest() {
            shot = latest
        } else {
            shot = try await captureNow(trigger: .api, push: false)
        }
        await dispatchNotifications(for: shot)
        return shot
    }

    public var hasNotifiers: Bool { !notifierService.isEmpty }
    public var notifierLabels: [String] { notifierService.activeLabels }

    // MARK: - URLs

    /// Base URL to build links from. An explicit `publicBaseURL` wins because it
    /// is the only thing that works from outside the local network.
    public func externalBaseURL() -> String {
        let current = currentConfig()
        if let publicBase = current.server.publicBaseURL, !publicBase.isEmpty {
            return publicBase.hasSuffix("/") ? String(publicBase.dropLast()) : publicBase
        }
        let host = NetInfo.primaryLANAddress() ?? "127.0.0.1"
        return "http://\(host):\(boundPort)"
    }

    public func viewerURL(base: String? = nil) -> String {
        "\(base ?? externalBaseURL())/?token=\(currentConfig().server.token)"
    }

    public func imageURL(for shot: Shot, base: String? = nil) -> String {
        let root = base ?? externalBaseURL()
        return "\(root)/api/frame/\(shot.id).\(shot.format.fileExtension)?token=\(currentConfig().server.token)"
    }

    // MARK: - Read access for the router

    public func latestShot() -> Shot? { store.latest() }
    public func shot(id: String) -> Shot? { store.shot(id: id) }
    public func recentShots(limit: Int) -> [Shot] { store.recent(limit: limit) }
    public var storedShotCount: Int { store.count }

    // MARK: - Status

    /// - Parameter includeAdminFields: pass true only for the master credential.
    ///   `viewerURL` embeds the master token, so a paired phone reading it would
    ///   be handed full privileges — everything else in this payload is fine to
    ///   show a device.
    public func statusSnapshot(includeAdminFields: Bool) -> [String: Any] {
        let current = currentConfig()

        stateLock.lock()
        let snapshot = stats
        stateLock.unlock()

        var json: [String: Any] = [
            "ok": true,
            "version": ScreenBeamVersion.current,
            "host": NetInfo.hostName,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "uptimeSeconds": Int(Date().timeIntervalSince(startedAt)),
            "captureCount": snapshot.captureCount,
            "pushCount": snapshot.pushCount,
            "storedShots": store.count,
            "watchers": bus.subscriberCount,
            "watching": isWatching,
            "permissionGranted": permissionGranted,
            "notifiers": notifierService.activeLabels,
            "pairedDevices": devices.count,
            "awaitingPairing": pairing.hasPendingCode,
            "capture": [
                "mode": current.capture.mode.rawValue,
                "displayIndex": current.capture.displayIndex,
                "format": current.capture.format.rawValue,
                "maxLongEdge": current.capture.maxLongEdge,
            ],
            "watch": [
                "enabled": current.watch.enabled,
                "intervalSeconds": current.watch.intervalSeconds,
                "onlyOnChange": current.watch.onlyOnChange,
            ],
            "server": [
                "port": Int(boundPort),
                "loopbackOnly": current.server.isLoopbackOnly,
            ],
            "lanAddresses": NetInfo.ipv4Interfaces()
                .filter { !$0.isLoopback }
                .map { ["interface": $0.name, "address": $0.address] },
        ]

        if includeAdminFields {
            json["viewerURL"] = viewerURL()
        }
        if let lastShotAt = snapshot.lastShotAt {
            json["lastShotAt"] = ISO8601DateFormatter().string(from: lastShotAt)
        }
        if let lastError = snapshot.lastError {
            json["lastError"] = lastError
        }
        return json
    }

    // MARK: - Stats

    private func recordSuccess(_ shot: Shot) {
        stateLock.lock()
        stats.captureCount += 1
        stats.lastShotAt = shot.createdAt
        stats.lastError = nil
        stateLock.unlock()
    }

    private func recordFailure(_ error: Error) {
        stateLock.lock()
        stats.lastError = String(describing: error)
        stateLock.unlock()
    }

    private func recordPush() {
        stateLock.lock()
        stats.pushCount += 1
        stateLock.unlock()
    }
}
