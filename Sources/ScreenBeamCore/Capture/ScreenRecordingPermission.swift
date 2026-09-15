import AppKit
import CoreGraphics
import Foundation

/// Screen Recording is a TCC-protected capability. Two things matter in practice:
///
/// 1. The grant is keyed to the *code identity* of the process. A bare Mach-O
///    built by `swift build` has no stable identity, so the grant lands on
///    whatever launched it (Terminal, launchd) and is lost on every rebuild.
///    That is why the build script assembles a real `.app` bundle with a fixed
///    `CFBundleIdentifier` and ad-hoc signs it.
/// 2. macOS does not apply a fresh grant to an already-running process for
///    screen capture. The daemon has to be relaunched after the user flips the
///    switch — see `BeamEngine` for how that is handled.
public enum ScreenRecordingPermission {
    /// Non-prompting check. Safe to call at any time.
    public static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system consent dialog. Returns the current state immediately;
    /// the dialog is answered asynchronously and the answer only takes effect for
    /// a *new* process. Once the user has denied, this returns `false` without
    /// prompting again, and System Settings is the only way back.
    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Deep-links straight to the Screen Recording pane so the user does not have
    /// to hunt through System Settings.
    public static func openSystemSettings() {
        let raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Polls until the grant appears. Only useful as a "did the user just grant
    /// it?" signal — the caller still has to relaunch before capture will work.
    public static func waitUntilGranted(
        pollInterval: TimeInterval = 2,
        timeout: TimeInterval = 90
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isGranted { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return isGranted
    }
}
