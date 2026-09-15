import Foundation

/// HTTP surface. Small on purpose: the viewer page, a handful of JSON
/// endpoints, one image endpoint and one event stream.
///
/// Two kinds of credential open the door:
///
/// - the **master token** from `config.json`, which the CLI uses and which can
///   also manage paired devices;
/// - a **device token** minted by pairing, which the phone holds.
///
/// Only the master token can touch access management. Everything a paired phone
/// legitimately needs — capturing, viewing, toggling continuous capture — works
/// with a device token.
///
/// `/healthz` and `POST /api/pair` are the only unauthenticated routes: the first
/// reveals nothing, and the second is authenticated by the pairing code itself.
enum Router {

    /// What a request is allowed to do.
    enum Credential {
        case master
        case device(PairedDevice)

        var isMaster: Bool {
            if case .master = self { return true }
            return false
        }

        var deviceID: String? {
            if case .device(let device) = self { return device.id }
            return nil
        }
    }

    // MARK: - Entry

    static func route(request: HTTPRequest, responder: HTTPResponder, engine: BeamEngine) {
        // Open so a tunnel or uptime check can probe liveness without the secret.
        if request.path == "/healthz" {
            responder.respond(.json(["ok": true]))
            return
        }

        // The viewer shell is open on purpose. It holds no secret — the master
        // token is deliberately not injected into it — and it has to be reachable
        // *before* the phone has a credential, because the pairing screen lives
        // inside it. Every data endpoint behind it still requires a credential.
        if request.method == "GET", request.segments.isEmpty {
            handleViewer(responder, engine: engine)
            return
        }

        // Pairing is authenticated by the code, not by a credential.
        if request.method == "POST", request.segments == ["api", "pair"] {
            handlePair(request, responder, engine: engine)
            return
        }

        guard let credential = authorize(request, responder: responder, engine: engine) else {
            Log.warn("拒绝未授权请求：\(request.method) \(request.path)（来自 \(responder.remoteAddress)）")
            responder.respond(.error(401, "缺少或错误的凭证", code: "unauthenticated"))
            return
        }

        dispatch(request, responder: responder, engine: engine, credential: credential)
    }

    // MARK: - Credentials

    static func authorize(
        _ request: HTTPRequest,
        responder: HTTPResponder,
        engine: BeamEngine
    ) -> Credential? {
        // `EventSource` cannot set headers, so the token has to be accepted as a
        // query parameter as well.
        let provided = request.query["token"] ?? request.header("x-auth-token") ?? ""

        let credential = resolveCredential(
            provided: provided,
            master: engine.currentConfig().server.token,
            devices: engine.devices
        )

        // Only a real device should have its activity timestamp refreshed.
        if case .device(let device)? = credential {
            engine.devices.touch(id: device.id)
        }
        return credential
    }

    /// The precedence rule, split out so it can be tested without standing up an
    /// engine (which would touch the real config and device files).
    ///
    /// Master is checked first: a device token that happened to collide with the
    /// master token would otherwise be treated as a lesser credential.
    static func resolveCredential(
        provided: String,
        master: String,
        devices: DeviceStore
    ) -> Credential? {
        guard !provided.isEmpty else { return nil }

        if !master.isEmpty,
           SecureToken.constantTimeEquals(
               SecureToken.normalize(provided),
               SecureToken.normalize(master)
           ) {
            return .master
        }

        if let device = devices.device(forToken: provided) {
            return .device(device)
        }

        return nil
    }

    private static func requireMaster(_ credential: Credential, _ responder: HTTPResponder) -> Bool {
        guard credential.isMaster else {
            // Deliberately *not* `unauthenticated`: the device's credential is
            // perfectly good, it just is not allowed here. Marking it as an auth
            // failure would sign the phone out for touching the wrong route.
            responder.respond(.error(
                403,
                "该操作需要主令牌（请用 Mac 上的 screenbeam 命令执行）",
                code: "forbidden"
            ))
            return false
        }
        return true
    }

    // MARK: - Dispatch

    private static func dispatch(
        _ request: HTTPRequest,
        responder: HTTPResponder,
        engine: BeamEngine,
        credential: Credential
    ) {
        let segments = request.segments
        let isGet = request.method == "GET"
        let isPost = request.method == "POST"

        // Routes carrying a path parameter are matched explicitly: an array
        // literal pattern is evaluated as an expression, so it cannot bind
        // (`case ["api", "frame", let id]` is a compile error).
        if segments.count == 3, segments[0] == "api" {
            switch segments[1] {
            case "frame" where isGet:
                handleFrame(segments[2], responder, engine: engine)
                return
            case "watch" where isPost:
                handleWatch(segments[2], responder, engine: engine)
                return
            default:
                break
            }
        }

        switch segments {
        case ["api", "status"] where isGet:
            responder.respond(.json(engine.statusSnapshot(includeAdminFields: credential.isMaster)))

        case ["api", "latest"] where isGet:
            handleLatest(responder, engine: engine)

        case ["api", "frames"] where isGet:
            handleFrames(request, responder, engine: engine)

        case ["api", "events"] where isGet:
            handleEvents(responder, engine: engine)

        case ["api", "shot"] where isGet || isPost:
            handleShot(responder, engine: engine)

        case ["api", "capture", "mode"] where isPost:
            handleCaptureMode(request, responder, engine: engine)

        case ["api", "push"] where isPost:
            handlePush(request, responder, engine: engine)

        case ["api", "unpair"] where isPost:
            handleUnpair(responder, engine: engine, credential: credential)

        case ["api", "llm", "config"] where isGet:
            responder.respond(.json(["ok": true, "llm": engine.llmConfig().publicJSON]))

        case ["api", "llm", "config"] where isPost:
            handleLLMConfig(request, responder, engine: engine)

        case ["api", "llm", "ask"] where isPost:
            handleLLMAsk(request, responder, engine: engine)

        // Access management is master-only.
        case ["api", "pair", "code"] where isPost:
            guard requireMaster(credential, responder) else { return }
            let code = engine.issuePairingCode()
            Log.info("已生成配对码，\(code.remainingSeconds) 秒内有效。")
            responder.respond(.json(["ok": true, "pairing": code.json]))

        case ["api", "devices"] where isGet:
            guard requireMaster(credential, responder) else { return }
            responder.respond(.json([
                "ok": true,
                "count": engine.devices.count,
                "devices": engine.devices.all().map(\.json),
            ]))

        case ["api", "devices", "revoke"] where isPost:
            guard requireMaster(credential, responder) else { return }
            handleDeviceRevoke(request, responder, engine: engine)

        case ["api", "reload"] where isPost:
            guard requireMaster(credential, responder) else { return }
            handleReload(responder, engine: engine)

        default:
            responder.respond(.error(404, "未知接口：\(request.method) \(request.path)"))
        }
    }

    // MARK: - Pairing

    private static func handlePair(
        _ request: HTTPRequest,
        _ responder: HTTPResponder,
        engine: BeamEngine
    ) {
        let body = jsonBody(request)
        let code = (body?["code"] as? String) ?? request.query["code"] ?? ""
        let name = (body?["name"] as? String) ?? request.query["name"] ?? ""

        guard !code.isEmpty else {
            responder.respond(.error(400, "缺少配对码"))
            return
        }

        do {
            let outcome = try engine.pair(
                code: code,
                peer: responder.remoteAddress,
                deviceName: name,
                userAgent: request.header("user-agent")
            )
            responder.respond(.json([
                "ok": true,
                "device": outcome.device.json,
                // Sent once. The phone is expected to store this and present it
                // on every later request.
                "deviceToken": outcome.token,
                "server": [
                    "name": NetInfo.hostName,
                    "version": ScreenBeamVersion.current,
                ],
            ]))
        } catch let error as PairingError {
            Log.warn("配对失败（来自 \(responder.remoteAddress)）：\(error.description)")
            responder.respond(.error(error.httpStatus, error.description))
        } catch {
            responder.respond(.error(500, String(describing: error)))
        }
    }

    private static func handleDeviceRevoke(
        _ request: HTTPRequest,
        _ responder: HTTPResponder,
        engine: BeamEngine
    ) {
        let id = request.query["id"] ?? jsonBody(request)?["id"] as? String ?? ""
        guard !id.isEmpty else {
            responder.respond(.error(400, "缺少设备 id"))
            return
        }
        if engine.revokeDevice(id: id) {
            responder.respond(.json(["ok": true, "revoked": id]))
        } else {
            responder.respond(.error(404, "找不到设备：\(id)"))
        }
    }

    private static func handleUnpair(
        _ responder: HTTPResponder,
        engine: BeamEngine,
        credential: Credential
    ) {
        // A device can only remove itself; the master token has no device id to
        // remove and must name one explicitly via /api/devices/revoke.
        guard let id = credential.deviceID else {
            responder.respond(.error(400, "请改用 /api/devices/revoke?id=<设备 id>"))
            return
        }
        _ = engine.revokeDevice(id: id)
        responder.respond(.json(["ok": true, "unpaired": id]))
    }

    // MARK: - Viewer

    private static func handleViewer(_ responder: HTTPResponder, engine: BeamEngine) {
        responder.respond(.html(WebViewer.html(
            hostName: NetInfo.hostName,
            version: ScreenBeamVersion.current
        )))
    }

    private static func handleLatest(_ responder: HTTPResponder, engine: BeamEngine) {
        if let shot = engine.latestShot() {
            responder.respond(.json(["ok": true, "shot": ShotJSON.encode(shot)]))
        } else {
            responder.respond(.json(["ok": true, "shot": NSNull()]))
        }
    }

    private static func handleFrames(
        _ request: HTTPRequest,
        _ responder: HTTPResponder,
        engine: BeamEngine
    ) {
        let requested = Int(request.query["limit"] ?? "") ?? 30
        let limit = min(max(requested, 1), 200)
        let shots = engine.recentShots(limit: limit).map(ShotJSON.encode)
        responder.respond(.json(["ok": true, "count": shots.count, "shots": shots]))
    }

    private static func handleFrame(
        _ filename: String,
        _ responder: HTTPResponder,
        engine: BeamEngine
    ) {
        // Accepts `<id>.<ext>` and the alias `latest.<ext>`, which is convenient
        // for iOS Shortcuts and home-screen widgets that take a fixed URL.
        let base = (filename as NSString).deletingPathExtension
        guard !base.isEmpty else {
            responder.respond(.error(400, "文件名无效"))
            return
        }

        let shot = (base == "latest") ? engine.latestShot() : engine.shot(id: base)
        guard let shot else {
            responder.respond(.error(404, "找不到截图：\(base)"))
            return
        }

        responder.respond(HTTPResponse(
            status: 200,
            headers: [
                ("Content-Type", shot.format.mimeType),
                ("Content-Disposition", "inline; filename=\"screenbeam-\(shot.id).\(shot.format.fileExtension)\""),
            ],
            body: shot.payload
        ))
    }

    private static func handleEvents(_ responder: HTTPResponder, engine: BeamEngine) {
        responder.beginStream(headers: [
            ("Content-Type", "text/event-stream; charset=utf-8"),
            // `no-transform` matters: a proxy that buffers or gzips would break
            // the incremental delivery that makes this useful.
            ("Cache-Control", "no-cache, no-transform"),
            ("X-Accel-Buffering", "no"),
        ])
        responder.write(chunk: Data("retry: 2000\n\n".utf8))

        engine.bus.add(responder)

        let current = engine.currentConfig()
        var hello: [String: Any] = [
            "granted": ScreenRecordingPermission.isGranted,
            "watching": engine.isWatching,
            "captureMode": current.capture.mode.rawValue,
            "pairedDevices": engine.devices.count,
        ]
        if let latest = engine.latestShot() {
            hello["latest"] = ShotJSON.encode(latest)
        }
        responder.sendEvent("hello", json: hello)
    }

    // MARK: - Actions

    private static func handleShot(_ responder: HTTPResponder, engine: BeamEngine) {
        // Capture takes tens to hundreds of milliseconds and must not block the
        // HTTP queue, so it runs detached and answers when done.
        Task {
            do {
                let shot = try await engine.captureNow(trigger: .api)
                responder.respond(.json(["ok": true, "shot": ShotJSON.encode(shot)]))
            } catch {
                responder.respond(.error(status(for: error), String(describing: error)))
            }
        }
    }

    private static func handleWatch(
        _ action: String,
        _ responder: HTTPResponder,
        engine: BeamEngine
    ) {
        switch action {
        case "start":
            engine.setWatchEnabled(true)
        case "stop":
            engine.setWatchEnabled(false)
        case "toggle":
            engine.setWatchEnabled(!engine.isWatching)
        default:
            responder.respond(.error(404, "未知操作：\(action)"))
            return
        }
        responder.respond(.json(["ok": true, "watching": engine.isWatching]))
    }

    private static func handleCaptureMode(
        _ request: HTTPRequest,
        _ responder: HTTPResponder,
        engine: BeamEngine
    ) {
        let raw = request.query["mode"] ?? jsonBody(request)?["mode"] as? String ?? ""
        guard let mode = CaptureConfig.Mode(rawValue: raw) else {
            responder.respond(.error(400, "mode 必须是 display（整屏）或 window（当前窗口）"))
            return
        }
        do {
            try engine.setCaptureMode(mode)
            responder.respond(.json(["ok": true, "captureMode": mode.rawValue]))
        } catch {
            responder.respond(.error(500, String(describing: error)))
        }
    }

    private static func handlePush(
        _ request: HTTPRequest,
        _ responder: HTTPResponder,
        engine: BeamEngine
    ) {
        let recaptureFlag = request.query["recapture"] ?? ""
        let recapture = recaptureFlag == "1" || recaptureFlag.lowercased() == "true"

        guard engine.hasNotifiers else {
            responder.respond(.error(400, "没有启用任何推送渠道，请先编辑 config.json"))
            return
        }

        Task {
            do {
                let shot = try await engine.pushLatest(recapture: recapture)
                responder.respond(.json([
                    "ok": true,
                    "pushed": engine.notifierLabels,
                    "shot": ShotJSON.encode(shot),
                ]))
            } catch {
                responder.respond(.error(status(for: error), String(describing: error)))
            }
        }
    }

    private static func handleReload(_ responder: HTTPResponder, engine: BeamEngine) {
        do {
            let result = try engine.reloadConfig()
            responder.respond(.json([
                "ok": true,
                "notifiers": engine.notifierLabels,
                "watching": engine.isWatching,
                "tokenChanged": result.tokenChanged,
                "requiresRestart": result.requiresRestart,
            ]))
        } catch {
            responder.respond(.error(500, String(describing: error)))
        }
    }

    // MARK: - Vision model

    private static func handleLLMConfig(
        _ request: HTTPRequest,
        _ responder: HTTPResponder,
        engine: BeamEngine
    ) {
        guard let body = jsonBody(request) else {
            responder.respond(.error(400, "需要 JSON 请求体"))
            return
        }

        do {
            let updated = try engine.updateLLMConfig { config in
                if let value = body["enabled"] as? Bool { config.enabled = value }
                if let value = body["baseURL"] as? String, !value.isEmpty { config.baseURL = value }
                if let value = body["model"] as? String, !value.isEmpty { config.model = value }
                if let value = body["systemPrompt"] as? String { config.systemPrompt = value }
                if let value = body["maxTokens"] as? Int, value > 0 { config.maxTokens = value }
                if let value = body["timeoutSeconds"] as? Double, value > 0 {
                    config.timeoutSeconds = value
                }
                if let value = body["useFallbacks"] as? Bool { config.useFallbacks = value }
                if let value = body["effort"] as? String {
                    config.effort = value.isEmpty ? nil : value
                }

                // Write-only, and only when a value actually arrives: the phone
                // never receives the current key, so an empty field must not
                // wipe it.
                if let key = body["apiKey"] as? String {
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { config.apiKey = trimmed }
                }

                if let raw = body["provider"] as? String,
                   let provider = LLMConfig.Provider(rawValue: raw),
                   provider != config.provider {
                    config.provider = provider
                    // Switching provider but keeping the old endpoint is the
                    // obvious way to land on a confusing 404, so move it to that
                    // provider's default. The model is left alone — only the user
                    // knows which one they want.
                    config.baseURL = LLMConfig.Provider.defaultBaseURL(for: provider)
                }
            }
            responder.respond(.json(["ok": true, "llm": updated.publicJSON]))
        } catch {
            responder.respond(.error(500, String(describing: error)))
        }
    }

    private static func handleLLMAsk(
        _ request: HTTPRequest,
        _ responder: HTTPResponder,
        engine: BeamEngine
    ) {
        let body = jsonBody(request) ?? [:]
        let question = (body["question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !question.isEmpty else {
            responder.respond(.error(400, "问题不能为空"))
            return
        }

        let history = (body["history"] as? [[String: Any]] ?? []).compactMap { entry -> LLMTurn? in
            guard let raw = entry["role"] as? String,
                  let role = LLMTurn.Role(rawValue: raw),
                  let text = entry["text"] as? String,
                  !text.isEmpty else { return nil }
            return LLMTurn(role: role, text: text)
        }

        // A vision call can take a minute. The default idle reap would drop the
        // connection long before the model answers, and the phone would just see
        // a dead request with no explanation.
        responder.extendIdle(by: engine.llmConfig().timeoutSeconds)

        let shotID = body["shotId"] as? String
        Task {
            do {
                let answer = try await engine.askAboutScreen(
                    question: question,
                    history: history,
                    shotID: shotID
                )
                responder.respond(.json(["ok": true, "answer": answer.json]))
            } catch let error as LLMError {
                // Logged because a failed ask is otherwise invisible: the phone
                // shows the message, but nothing lands in the daemon log to
                // diagnose it from.
                Log.warn("AI 提问失败：\(error.description)")
                responder.respond(.error(error.httpStatus, error.description))
            } catch {
                Log.warn("AI 提问失败（未预期）：\(error)")
                responder.respond(.error(502, String(describing: error)))
            }
        }
    }

    // MARK: - Helpers

    private static func jsonBody(_ request: HTTPRequest) -> [String: Any]? {
        guard !request.body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
    }

    private static func status(for error: Error) -> Int {
        if case CaptureError.screenRecordingPermissionDenied = error { return 503 }
        if case CaptureError.noDisplayAvailable = error { return 503 }
        if case CaptureError.noFrontmostWindow = error { return 503 }
        return 500
    }
}
