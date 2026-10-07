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
        return ScreenRecordingDetection.isRecordingIndicatorPresent(
            in: windows,
            controlCenterPIDs: Self.controlCenterProcessIDs()
        )
    }

    /// The ControlCenter process identified by bundle ID — its owner/window
    /// names are localized, so matching the literal string "Control Center"
    /// breaks on non-English systems.
    static func controlCenterProcessIDs() -> Set<Int32> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.apple.controlcenter" }
            .map(\.processIdentifier))
    }
}

// MARK: - Pure detection (unit-tested)

enum ScreenRecordingDetection: Sendable {
    /// True when the global window list contains the system recording indicator.
    /// The indicator lives in the "Control Center" process (QuickTime, CleanShot,
    /// Loom, OBS, Zoom screen-share, etc.).
    ///
    /// A window is the indicator when it is owned by the ControlCenter process
    /// (matched by PID — locale-independent) *and* carries an indicator name.
    /// `kCGWindowOwnerName` is localized ("Control Center" only on English
    /// systems), which is why the literal-string check is only a fallback;
    /// "StatusIndicator" is the window's internal name and is not localized.
    static func isRecordingIndicatorPresent(
        in windows: [[String: Any]],
        controlCenterPIDs: Set<Int32> = []
    ) -> Bool {
        windows.contains { window in
            let pid   = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            guard controlCenterPIDs.contains(pid) || owner == "Control Center"
            else { return false }

            guard let name = window[kCGWindowName as String] as? String else { return false }
            return name == "StatusIndicator" ||
                   name.localizedCaseInsensitiveContains("screen recording")
        }
    }
}
