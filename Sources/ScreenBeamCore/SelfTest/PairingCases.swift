import Foundation

/// Pairing is the part of this tool that hands out access, so the cases here are
/// mostly about the ways it should *refuse*: replaying a used code, grinding a
/// short numeric code, reading a token back out of the credential file.
enum PairingCases {
    static let all: [(String, () throws -> Void)] = [
        ("配对码为指定位数的纯数字", {
            for _ in 0..<200 {
                let code = SecureToken.digits(6)
                try checkEqual(code.count, 6, "长度")
                try check(code.allSatisfy(\.isNumber), "应为纯数字，实际 \(code)")
            }
        }),

        // A generator stuck on one value would still satisfy the format checks.
        ("配对码分布不退化", {
            var codes = Set<String>()
            var seenDigits = Set<Character>()
            for _ in 0..<500 {
                let code = SecureToken.digits(6)
                codes.insert(code)
                seenDigits.formUnion(code)
            }
            try check(codes.count > 490, "500 次生成仅得到 \(codes.count) 个不同配对码")
            try checkEqual(seenDigits.count, 10, "10 个数字都应出现过")
        }),

        ("十六进制令牌长度与字符集正确", {
            let token = SecureToken.hex(bytes: 32)
            try checkEqual(token.count, 64, "32 字节应为 64 个十六进制字符")
            try check(token.allSatisfy(\.isHexDigit), "应为十六进制")
            try check(SecureToken.hex(bytes: 32) != token, "两次生成不应相同")
        }),

        ("sha256 稳定且区分不同输入", {
            let digest = SecureToken.sha256Hex("hello")
            try checkEqual(digest.count, 64, "摘要长度")
            try checkEqual(SecureToken.sha256Hex("hello"), digest, "同输入应得同摘要")
            try check(SecureToken.sha256Hex("hello!") != digest, "不同输入应得不同摘要")
        }),

        ("令牌归一化去空白并折叠大小写", {
            try checkEqual(SecureToken.normalize("  ABC123\n"), "abc123", "归一化结果")
        }),

        ("常量时间比较的基本行为", {
            try check(SecureToken.constantTimeEquals("abc", "abc"), "相同应相等")
            try check(!SecureToken.constantTimeEquals("abc", "abd"), "不同应不等")
            try check(!SecureToken.constantTimeEquals("abc", "abcd"), "长度不同应不等")
            try check(SecureToken.constantTimeEquals("", ""), "两个空串应相等")
        }),

        // ---- DeviceStore -------------------------------------------------

        ("配对后可用令牌找回设备", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            let (device, token) = try store.add(name: "我的 iPhone", userAgent: "Safari")
            try checkEqual(device.name, "我的 iPhone", "设备名")
            try checkEqual(store.count, 1, "设备数量")
            try checkEqual(store.device(forToken: token)?.id, device.id, "按令牌应找回同一设备")
        }),

        ("未知令牌无法通过校验", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            _ = try store.add(name: "A", userAgent: nil)
            try checkNil(store.device(forToken: "deadbeef"), "随机令牌")
            try checkNil(store.device(forToken: ""), "空令牌")
        }),

        // The whole point of storing a hash: reading the file must not hand over
        // working credentials.
        ("凭据文件中不出现令牌明文", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            let (_, token) = try store.add(name: "A", userAgent: nil)
            let raw = try String(contentsOf: store.fileURL, encoding: .utf8)

            try check(!raw.contains(token), "devices.json 中出现了令牌明文")
            try check(raw.contains(SecureToken.sha256Hex(SecureToken.normalize(token))), "应存的是哈希")
        }),

        ("设备列表可持久化并重新载入", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            let (device, token) = try store.add(name: "iPad", userAgent: "iPadOS")
            let reloaded = DeviceStore(fileURL: store.fileURL)

            try checkEqual(reloaded.count, 1, "重载后设备数量")
            try checkEqual(reloaded.device(forToken: token)?.id, device.id, "重载后仍能按令牌找回")
        }),

        ("撤销设备后其令牌立即失效", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            let (device, token) = try store.add(name: "A", userAgent: nil)
            try check(store.revoke(id: device.id), "撤销应返回成功")
            try checkNil(store.device(forToken: token), "撤销后令牌不应再有效")
            try check(!store.revoke(id: device.id), "重复撤销应返回失败")
        }),

        ("设备数量有上限", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            for index in 0..<DeviceStore.maxDevices {
                _ = try store.add(name: "设备\(index)", userAgent: nil)
            }
            try checkEqual(store.count, DeviceStore.maxDevices, "应达到上限")

            var threw = false
            do { _ = try store.add(name: "多出来的", userAgent: nil) } catch { threw = true }
            try check(threw, "超过上限时应抛错而不是静默接受")
        }),

        // ---- Credential resolution --------------------------------------

        ("主令牌解析为主凭证", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            let credential = Router.resolveCredential(provided: "MASTER123", master: "master123", devices: store)
            try checkEqual(credential?.isMaster, true, "应为主凭证")
        }),

        ("设备令牌解析为设备凭证", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            let (device, token) = try store.add(name: "A", userAgent: nil)
            let credential = Router.resolveCredential(provided: token, master: "master123", devices: store)

            try checkEqual(credential?.isMaster, false, "不应为主凭证")
            try checkEqual(credential?.deviceID, device.id, "设备 id")
        }),

        ("无效凭证返回 nil", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            try checkNil(Router.resolveCredential(provided: "", master: "m", devices: store), "空凭证")
            try checkNil(Router.resolveCredential(provided: "nope", master: "m", devices: store), "错误凭证")
        }),

        ("主令牌为空时不会误判通过", {
            let (store, cleanup) = try makeStore()
            defer { cleanup() }

            // A daemon with no configured master token must not accept an empty
            // string as a match.
            try checkNil(Router.resolveCredential(provided: "", master: "", devices: store), "空对空")
            try checkNil(Router.resolveCredential(provided: "anything", master: "", devices: store), "空主令牌")
        }),

        // ---- PairingSession lifecycle -----------------------------------

        ("配对码单次有效：成功兑换后立即作废", {
            let session = PairingSession()
            let code = session.issue()

            try checkEqual(session.redeem(code.value, peer: "10.0.0.1"), .ok, "首次应成功")
            try checkEqual(
                session.redeem(code.value, peer: "10.0.0.1"), .noCode,
                "同一个码不应能再次兑换"
            )
            try checkNil(session.current(), "兑换后不应还有待用配对码")
        }),

        ("错误配对码递减剩余次数", {
            let session = PairingSession(maxFailuresPerPeer: 3)
            let code = session.issue()
            let guess = wrongGuess(code.value)

            try checkEqual(session.redeem(guess, peer: "10.0.0.1"), .mismatch(remaining: 2), "第 1 次")
            try checkEqual(session.redeem(guess, peer: "10.0.0.1"), .mismatch(remaining: 1), "第 2 次")
            try checkEqual(session.redeem(guess, peer: "10.0.0.1"), .mismatch(remaining: 0), "第 3 次")
            try checkEqual(session.redeem(guess, peer: "10.0.0.1"), .tooManyAttempts, "超出后应拒绝")
        }),

        // Brute forcing a 6-digit code is only viable if you can guess freely, so
        // the per-peer budget is the thing that makes it hopeless.
        ("单一来源猜错多次后被拒绝", {
            let session = PairingSession(maxFailuresPerPeer: 2, maxTotalFailures: 1000)
            let code = session.issue()

            _ = session.redeem(wrongGuess(code.value, salt: 1), peer: "10.0.0.9")
            _ = session.redeem(wrongGuess(code.value, salt: 2), peer: "10.0.0.9")

            try checkEqual(session.redeem(wrongGuess(code.value), peer: "10.0.0.9"), .tooManyAttempts, "该来源应被拒绝")
            // The genuine phone on a different address still gets its own budget.
            try checkEqual(session.redeem(code.value, peer: "10.0.0.2"), .ok, "另一来源仍可正常配对")
        }),

        ("全局错误次数过多会作废配对码", {
            let session = PairingSession(maxFailuresPerPeer: 100, maxTotalFailures: 3)
            let code = session.issue()

            _ = session.redeem(wrongGuess(code.value, salt: 1), peer: "10.0.0.1")
            _ = session.redeem(wrongGuess(code.value, salt: 2), peer: "10.0.0.2")
            try checkEqual(
                session.redeem(wrongGuess(code.value, salt: 3), peer: "10.0.0.3"),
                .tooManyAttempts,
                "达到全局上限应作废"
            )

            // Written off for everyone, including the real phone.
            try checkEqual(session.redeem(code.value, peer: "10.0.0.4"), .tooManyAttempts, "作废后正码也不可用")
            try check(!session.hasPendingCode, "不应还有待用配对码")
        }),

        ("配对码过期后不可兑换", {
            // A negative TTL puts the expiry in the past without waiting.
            let session = PairingSession(ttl: -1)
            let code = session.issue()

            try checkEqual(session.redeem(code.value, peer: "10.0.0.1"), .expired, "过期应被识别")
            try checkNil(session.current(), "过期后不应还有待用配对码")
        }),

        ("没有配对码时兑换被拒绝", {
            let session = PairingSession()
            try checkEqual(session.redeem("123456", peer: "10.0.0.1"), .noCode, "无码状态")
        }),

        ("重新生成配对码会重置失败计数", {
            let session = PairingSession(maxFailuresPerPeer: 2)
            let first = session.issue()
            _ = session.redeem(wrongGuess(first.value), peer: "10.0.0.1")
            _ = session.redeem(wrongGuess(first.value), peer: "10.0.0.1")
            try checkEqual(
                session.redeem(wrongGuess(first.value), peer: "10.0.0.1"),
                .tooManyAttempts,
                "应已被拒绝"
            )

            let fresh = session.issue()
            try checkEqual(
                session.redeem(fresh.value, peer: "10.0.0.1"), .ok,
                "重新发码后该来源应恢复可用"
            )
        }),
    ]

    // MARK: - Helpers

    /// A 6-digit string guaranteed not to equal `code`.
    ///
    /// Hardcoding a guess like "000000" would make these cases flaky in the one
    /// run out of a million where the generator happens to produce it.
    static func wrongGuess(_ code: String, salt: Int = 0) -> String {
        let value = (Int(code) ?? 0) + 1 + salt
        return String(format: "%06d", value % 1_000_000)
    }

    /// Each case gets its own credential file in a temp directory so the real
    /// `devices.json` is never touched by a test run.
    static func makeStore() throws -> (DeviceStore, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenbeam-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("devices.json")
        let store = DeviceStore(fileURL: url)
        return (store, { try? FileManager.default.removeItem(at: directory) })
    }
}

func checkNil<T>(_ value: T?, _ label: String) throws {
    if value != nil { throw TestFailure(message: "\(label)：应为 nil，实际 \(String(describing: value))") }
}
