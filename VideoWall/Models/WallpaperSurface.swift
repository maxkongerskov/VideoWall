import CoreGraphics
import Foundation

// MARK: - WallpaperSurface
//
// Which system surface the wallpaper overlay is currently targeting.
// Lock wins over screensaver when both notifications fire.

enum WallpaperSurface: Equatable, Sendable {
    case desktop
    case screensaver
    case lockScreen
}

enum WallpaperSurfacePolicy: Sendable {

    /// Resolves the active surface from lock / screensaver flags.
    static func surface(isLocked: Bool, isScreensaver: Bool) -> WallpaperSurface {
        if isLocked { return .lockScreen }
        if isScreensaver { return .screensaver }
        return .desktop
    }

    /// Window level for the overlay. Screensaver / lock sit just above the
    /// system saver so the video is visible, but well below the shielding
    /// level so the lock clock and password field stay on top.
    static func windowLevel(for surface: WallpaperSurface) -> Int {
        switch surface {
        case .desktop:
            return Int(CGWindowLevelForKey(.desktopWindow)) + 1
        case .screensaver, .lockScreen:
            return Int(CGWindowLevelForKey(.screenSaverWindow)) + 1
        }
    }

    /// Hide our overlay so a native aerial can play *behind* the lock UI.
    /// Screensaver always keeps the overlay (covers whatever saver is running).
    static func shouldHideOverlay(
        surface: WallpaperSurface,
        nativeLockPlayback: Bool
    ) -> Bool {
        surface == .lockScreen && nativeLockPlayback
    }
}
