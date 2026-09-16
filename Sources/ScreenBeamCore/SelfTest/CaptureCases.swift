import CoreGraphics
import Foundation

/// Change detection decides whether the watcher wakes your phone, so both false
/// positives (notification spam) and false negatives (a missed frame) matter.
enum CaptureCases {
    static let all: [(String, () throws -> Void)] = [
        ("完全相同的画面差异为 0", {
            let a = try checkUnwrap(ChangeDetector.signature(of: solid(gray: 120)), "签名 a")
            let b = try checkUnwrap(ChangeDetector.signature(of: solid(gray: 120)), "签名 b")
            try checkClose(ChangeDetector.difference(a, b), 0, 0.0001, "差异")
        }),

        ("黑白全屏变化超过默认阈值", {
            let a = try checkUnwrap(ChangeDetector.signature(of: solid(gray: 0)), "签名 a")
            let b = try checkUnwrap(ChangeDetector.signature(of: solid(gray: 255)), "签名 b")
            try check(ChangeDetector.difference(a, b) > 0.02, "全屏反色应判定为变化")
        }),

        // The default threshold exists to ignore a blinking cursor; a 5% area
        // flip must not trip it.
        ("小面积变化不触发默认阈值", {
            let before = try checkUnwrap(ChangeDetector.signature(of: solid(gray: 0)), "签名 before")
            let after = try checkUnwrap(
                ChangeDetector.signature(of: patch(background: 0, patch: 255, fraction: 0.05)),
                "签名 after"
            )
            let difference = ChangeDetector.difference(before, after)
            try check(difference > 0, "小变化应当被检测到")
            try check(difference < 0.02, "小变化不应触发默认阈值，否则会刷屏")
        }),

        ("同一画面的签名可重复", {
            let image = patch(background: 30, patch: 200, fraction: 0.5)
            let first = try checkUnwrap(ChangeDetector.signature(of: image), "第一次")
            let second = try checkUnwrap(ChangeDetector.signature(of: image), "第二次")
            try checkEqual(first.gray, second.gray, "签名内容")
        }),

        // A dimension mismatch should be treated as "changed" rather than
        // silently comparing incompatible buffers.
        ("尺寸不一致时判定为已变化", {
            let small = try checkUnwrap(ChangeDetector.signature(of: solid(gray: 0, size: 16), size: 16), "小图")
            let large = try checkUnwrap(ChangeDetector.signature(of: solid(gray: 0, size: 32), size: 32), "大图")
            try checkClose(ChangeDetector.difference(small, large), 1.0, 0.0001, "差异")
        }),

        ("缩略图尺寸恒定，与输入分辨率无关", {
            let expected = ChangeDetector.gridSize * ChangeDetector.gridSize
            for size in [64, 512, 2048] {
                let signature = try checkUnwrap(
                    ChangeDetector.signature(of: solid(gray: 100, size: size)),
                    "\(size)px 图像"
                )
                try checkEqual(signature.gray.count, expected, "\(size)px 的签名长度")
            }
        }),

        // Whether capture is permitted must come from what actually happened, not
        // from the TCC preflight — that answer is cached for the life of the
        // process and reads stale after a rebuild.
        ("权限状态由实测结果推导，最近一次为准", {
            typealias State = BeamEngine.CapturePermissionState

            try checkEqual(State.derive(lastSuccess: nil, lastPermissionFailure: nil), .unknown, "从未尝试")

            let t0 = Date(timeIntervalSince1970: 1_000)
            let t1 = Date(timeIntervalSince1970: 2_000)

            try checkEqual(State.derive(lastSuccess: t0, lastPermissionFailure: nil), .working, "只成功过")
            try checkEqual(State.derive(lastSuccess: nil, lastPermissionFailure: t0), .denied, "只失败过")

            try checkEqual(
                State.derive(lastSuccess: t1, lastPermissionFailure: t0), .working,
                "先失败后成功 —— 应报告可用"
            )
            try checkEqual(
                State.derive(lastSuccess: t0, lastPermissionFailure: t1), .denied,
                "先成功后失败 —— 应报告不可用"
            )
        }),
    ]

    // MARK: - Helpers

    static func solid(gray: UInt8, size: Int = 128) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(CGColor(gray: CGFloat(gray) / 255.0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    static func patch(background: UInt8, patch: UInt8, fraction: CGFloat, size: Int = 128) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(CGColor(gray: CGFloat(background) / 255.0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let side = CGFloat(size) * fraction
        context.setFillColor(CGColor(gray: CGFloat(patch) / 255.0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }
}
