import AppKit
import CoreGraphics

// MARK: - ScreenRecordingMonitor
//
// Polls for active screen recording and tracks Screen Recording permission.
//
// Detection works by looking for the system recording indicator (a
// "Control Center"-owned window titled "StatusIndicator") in the global window
// list. The catch: macOS only returns window *titles* (`kCGWindowName`) for
// other processes' windows when the calling app holds Screen Recording
// permission — the very same permission used for actual capture. Without it the
// title is nil and detection is impossible, so we surface `hasPermission` to the
// UI, which prompts the user to grant it.

@MainActor
final class ScreenRecordingMonitor {

    /// Called on `start()` and after each poll with whether the screen is being
    /// recorded. Always `false` when permission is missing (we can't tell).
    var onRecordingChange:  ((_ isRecording: Bool) -> Void)?
    /// Called when Screen Recording permission status changes.
    var onPermissionChange: ((_ granted: Bool) -> Void)?

    private(set) var hasPermission = false

    private var timer: Timer?
    private let interval: TimeInterval

    init(interval: TimeInterval = 2) {
        self.interval = interval
    }

    func start() {
        evaluate()
        // Recording state is time-sensitive (we don't want the wallpaper to leak
        // into the first seconds of a capture), so poll faster than battery.
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func evaluate() {
        let granted = CGPreflightScreenCaptureAccess()
        if granted != hasPermission {
            hasPermission = granted
            onPermissionChange?(granted)
        }
        onRecordingChange?(granted ? isScreenBeingRecorded() : false)
    }

    /// Triggers the system permission prompt the first time, then re-checks.
    /// Note: newly granted Screen Recording permission may only take effect for
    /// window-title reads after the app is relaunched.
    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        evaluate()
    }

    /// Opens System Settings ▸ Privacy & Security ▸ Screen Recording.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func isScreenBeingRecorded() -> Bool {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]]
        else { return false }

        // The system recording indicator lives in the "Control Center" process.
        // This catches QuickTime, CleanShot, Loom, OBS, Zoom screen-share, etc.
        return windows.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner == "Control Center",
                  let name = window[kCGWindowName as String] as? String
            else { return false }
            return name == "StatusIndicator" ||
                   name.localizedCaseInsensitiveContains("screen recording")
        }
    }
}
