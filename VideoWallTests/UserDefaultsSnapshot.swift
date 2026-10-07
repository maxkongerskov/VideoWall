import XCTest

// MARK: - UserDefaults snapshot/restore for test isolation
//
// VideoWallTests is hosted by the production app, so every `AppSettings()`
// mutation writes the user's real defaults. Every suite that constructs an
// AppSettings snapshots these keys in setUp and restores them in tearDown.

struct UserDefaultsSnapshot {
    private static let persistedKeys = [
        "playOnAllSpaces", "playOnLockAndScreensaver", "isMuted", "volume",
        "resolution", "playbackMode", "cycleBlurRadius", "trimStart", "trimEnd",
        "playbackRate", "launchAtLogin", "pauseOnBattery", "pauseOnScreenRecording",
        "selectedVideoID"
    ]

    private var snapshot: [String: Any] = [:]

    mutating func capture() {
        let d = UserDefaults.standard
        var snap: [String: Any] = [:]
        for key in Self.persistedKeys {
            snap[key] = d.object(forKey: key) ?? NSNull()
        }
        snapshot = snap
    }

    func restore() {
        let d = UserDefaults.standard
        for (key, value) in snapshot {
            if value is NSNull {
                d.removeObject(forKey: key)
            } else {
                d.set(value, forKey: key)
            }
        }
    }
}
