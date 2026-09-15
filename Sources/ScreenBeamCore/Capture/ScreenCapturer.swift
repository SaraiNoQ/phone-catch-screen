import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A captured frame plus a description of where it came from.
public struct RawFrame: @unchecked Sendable {
    public let image: CGImage
    public let source: String

    public init(image: CGImage, source: String) {
        self.image = image
        self.source = source
    }
}

/// One-shot screen capture via ScreenCaptureKit.
///
/// `SCScreenshotManager.captureImage` is the supported single-frame API on
/// macOS 14+. It is preferred over the older `CGDisplayCreateImage`, which is
/// deprecated and returns a stale frame for windows that use hardware overlays
/// (video players, some Electron apps) because it composites at the WindowServer
/// level rather than going through the capture pipeline.
public struct ScreenCapturer: Sendable {
    public init() {}

    public func capture(
        mode: CaptureConfig.Mode,
        displayIndex: Int,
        showCursor: Bool
    ) async throws -> RawFrame {
        // No `CGPreflightScreenCaptureAccess` gate here, deliberately.
        //
        // That call's answer is cached inside the process: once a process has
        // been told "no", it keeps saying "no" for the rest of its life, even
        // after the user flips the switch in System Settings. A daemon is long
        // lived, so gating on it would leave a granted machine permanently
        // unable to capture, with no way to recover short of a restart.
        //
        // ScreenCaptureKit is the authority instead, and its refusal is mapped
        // onto the same actionable error below.
        do {
            switch mode {
            case .display:
                return try await captureDisplay(index: displayIndex, showCursor: showCursor)
            case .window:
                return try await captureFrontmostWindow(showCursor: showCursor)
            }
        } catch {
            throw Self.mapCaptureFailure(error)
        }
    }

    /// Turns ScreenCaptureKit's "user declined" into the permission error, so
    /// callers surface the hint about System Settings rather than a raw
    /// framework code.
    private static func mapCaptureFailure(_ error: Error) -> Error {
        let nsError = error as NSError
        // SCStreamErrorDomain / SCStreamError.userDeclined (-3801).
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
           nsError.code == -3801 {
            return CaptureError.screenRecordingPermissionDenied
        }
        return error
    }

    // MARK: - Whole display

    private func captureDisplay(index: Int, showCursor: Bool) async throws -> RawFrame {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let displays = content.displays
        guard !displays.isEmpty else { throw CaptureError.noDisplayAvailable }

        // Clamp rather than fail: a stale `displayIndex` in config (e.g. an
        // external monitor was unplugged) should not take the daemon down.
        let resolved = min(max(index, 0), displays.count - 1)
        let display = displays[resolved]

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let pixels = Self.nativePixelSize(for: display)
        config.width = pixels.width
        config.height = pixels.height
        config.showsCursor = showCursor
        config.captureResolution = .best
        config.scalesToFit = false
        config.colorSpaceName = CGColorSpace.sRGB
        // `queueDepth` and `minimumFrameInterval` only apply to streams; leaving
        // them at defaults is correct for a one-shot capture.

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return RawFrame(image: image, source: "display:\(resolved)")
    }

    /// ScreenCaptureKit reports display geometry in points. To capture at native
    /// pixel density we need the backing scale factor, which only `NSScreen`
    /// exposes, matched up by `CGDirectDisplayID`.
    private static func nativePixelSize(for display: SCDisplay) -> (width: Int, height: Int) {
        let screen = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            return (number as? CGDirectDisplayID) == display.displayID
        }
        let scale = screen?.backingScaleFactor ?? 2
        return (
            width: Int((CGFloat(display.width) * scale).rounded()),
            height: Int((CGFloat(display.height) * scale).rounded())
        )
    }

    // MARK: - Frontmost window

    private func captureFrontmostWindow(showCursor: Bool) async throws -> RawFrame {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard let target = Self.frontmostWindow(in: content) else {
            throw CaptureError.noFrontmostWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        // A single window is captured at its own geometry; scale to native pixels.
        let scale = Self.backingScale(for: target)
        config.width = Int((target.frame.width * scale).rounded())
        config.height = Int((target.frame.height * scale).rounded())
        config.showsCursor = showCursor
        config.captureResolution = .best
        config.scalesToFit = false
        config.colorSpaceName = CGColorSpace.sRGB
        // Drops the drop-shadow margin, so the PNG/JPEG edges line up with the window.
        config.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        let owner = target.owningApplication?.applicationName ?? "window"
        return RawFrame(image: image, source: "window:\(owner)")
    }

    private static func backingScale(for window: SCWindow) -> CGFloat {
        NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 2
    }

    /// Picks the window a user would call "the frontmost one".
    ///
    /// `CGWindowListCopyWindowInfo` returns windows in front-to-back order, which
    /// `SCShareableContent.windows` does not guarantee. We walk that list and take
    /// the first entry that belongs to the active application, is a normal window
    /// (layer 0), and is big enough to be a real window rather than a shadow or a
    /// tooltip. Falling back to the frontmost window of any app keeps this useful
    /// when the active app has no eligible window (e.g. focus is on the desktop).
    private static func frontmostWindow(in content: SCShareableContent) -> SCWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let byID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })

        var fallback: SCWindow?
        for info in raw {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 120, bounds.height >= 120,
                  let window = byID[number]
            else { continue }

            if fallback == nil { fallback = window }

            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
            if let activePID, ownerPID == activePID {
                return window
            }
        }
        return fallback
    }
}
