import Foundation

// MARK: - PlaybackMode
// Exactly one of these is always active. There is no "off" state for playback.

enum PlaybackMode: String, CaseIterable, Codable, Sendable {
    case loop  = "Loop"
    case cycle = "Cycle"

    var label: String { rawValue }

    var subtitle: String {
        switch self {
        case .loop:  return "Repeat current video"
        case .cycle: return "Crossfade through library"
        }
    }
}

// MARK: - AppSettings

@MainActor
final class AppSettings: ObservableObject {

    // MARK: Playback

    @Published var playOnAllSpaces: Bool {
        didSet { save(playOnAllSpaces, forKey: .playOnAllSpaces) }
    }

    /// Keep the video playing on the screensaver and lock screen.
    @Published var playOnLockAndScreensaver: Bool {
        didSet { save(playOnLockAndScreensaver, forKey: .playOnLockAndScreensaver) }
    }

    @Published var isMuted: Bool {
        didSet { save(isMuted, forKey: .isMuted) }
    }

    @Published var volume: Float {
        didSet { save(volume, forKey: .volume) }
    }

    @Published var resolution: VideoResolution {
        didSet { save(resolution.rawValue, forKey: .resolution) }
    }

    /// Single source of truth for Loop vs Cycle (replaces legacy dual booleans).
    @Published var playbackMode: PlaybackMode {
        didSet { save(playbackMode.rawValue, forKey: .playbackMode) }
    }

    // Peak blur radius (0 = no blur, 16 = default, 32 = max) used during cycle crossfades.
    @Published var cycleBlurRadius: Double {
        didSet { save(cycleBlurRadius, forKey: .cycleBlurRadius) }
    }

    // Global trim points (0.0 – 1.0 fraction of total duration), applied to the active clip.
    @Published var trimStart: Double {
        didSet { save(trimStart, forKey: .trimStart) }
    }

    @Published var trimEnd: Double {
        didSet { save(trimEnd, forKey: .trimEnd) }
    }

    /// Discrete 1×–10× click stops; Pause is the Pause button.
    @Published var playbackRate: Double {
        didSet {
            let clamped = PlaybackRateSlider.clamped(playbackRate)
            if playbackRate != clamped {
                playbackRate = clamped
                return
            }
            persistRateTask?.cancel()
            persistRateTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                self.save(self.playbackRate, forKey: .playbackRate)
                self.persistRateTask = nil
            }
        }
    }

    private var persistRateTask: Task<Void, Never>?

    // MARK: System

    @Published var launchAtLogin: Bool {
        didSet { save(launchAtLogin, forKey: .launchAtLogin) }
    }

    @Published var pauseOnBattery: Bool {
        didSet { save(pauseOnBattery, forKey: .pauseOnBattery) }
    }

    @Published var pauseOnScreenRecording: Bool {
        didSet { save(pauseOnScreenRecording, forKey: .pauseOnScreenRecording) }
    }

    @Published var selectedVideoID: UUID? {
        didSet { save(selectedVideoID?.uuidString, forKey: .selectedVideoID) }
    }

    // MARK: Convenience

    var loopEnabled: Bool { playbackMode == .loop }
    var cycleEnabled: Bool { playbackMode == .cycle }

    // MARK: Init

    init() {
        let d = UserDefaults.standard
        playOnAllSpaces            = d.bool(forKey: Key.playOnAllSpaces.rawValue, default: true)
        playOnLockAndScreensaver   = d.bool(forKey: Key.playOnLockAndScreensaver.rawValue, default: true)
        isMuted                = d.bool(forKey: Key.isMuted.rawValue, default: true)
        volume                 = d.float(forKey: Key.volume.rawValue, default: 0.5)
        cycleBlurRadius        = d.double(forKey: Key.cycleBlurRadius.rawValue, default: 4.0)
        trimStart              = d.double(forKey: Key.trimStart.rawValue, default: 0.0)
        trimEnd                = d.double(forKey: Key.trimEnd.rawValue, default: 1.0)
        let storedRate         = d.double(forKey: Key.playbackRate.rawValue, default: 1.0)
        playbackRate           = PlaybackRateSlider.clamped(storedRate)
        launchAtLogin          = d.bool(forKey: Key.launchAtLogin.rawValue, default: false)
        pauseOnBattery         = d.bool(forKey: Key.pauseOnBattery.rawValue, default: true)
        pauseOnScreenRecording = d.bool(forKey: Key.pauseOnScreenRecording.rawValue, default: true)

        // Resolution — clean corrupted values so they don't persist forever
        let resRaw = d.string(forKey: Key.resolution.rawValue) ?? VideoResolution.original.rawValue
        if VideoResolution(rawValue: resRaw) == nil {
            d.removeObject(forKey: Key.resolution.rawValue)
        }
        resolution = VideoResolution(rawValue: resRaw) ?? .original

        // Selected video — clean malformed UUID strings so they don't persist forever
        if let uuidStr = d.string(forKey: Key.selectedVideoID.rawValue),
           let uuid = UUID(uuidString: uuidStr) {
            selectedVideoID = uuid
        } else {
            if d.object(forKey: Key.selectedVideoID.rawValue) != nil {
                d.removeObject(forKey: Key.selectedVideoID.rawValue)
            }
            selectedVideoID = nil
        }

        playbackMode = Self.loadPlaybackMode(from: d)
    }

    /// Migrates legacy `loopEnabled`/`cycleEnabled` UserDefaults into a single mode.
    /// Prefer the modern `playbackMode` key when present.
    nonisolated static func loadPlaybackMode(from d: UserDefaults = .standard) -> PlaybackMode {
        if let raw = d.string(forKey: Key.playbackMode.rawValue),
           let mode = PlaybackMode(rawValue: raw) {
            return mode
        }

        // Legacy dual-boolean migration
        let hasLoopKey  = d.object(forKey: Key.legacyLoopEnabled.rawValue) != nil
        let hasCycleKey = d.object(forKey: Key.legacyCycleEnabled.rawValue) != nil
        if hasLoopKey || hasCycleKey {
            let loop  = d.bool(forKey: Key.legacyLoopEnabled.rawValue)
            let cycle = d.bool(forKey: Key.legacyCycleEnabled.rawValue)
            // Match prior normalization: both off → loop; both on → cycle wins.
            if cycle && !loop { return .cycle }
            if cycle && loop  { return .cycle }
            if !loop && !cycle { return .loop }
            return .loop
        }

        return .loop
    }

    // MARK: Private helpers

    private func save(_ value: Any?, forKey key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    private enum Key: String {
        case playOnAllSpaces, playOnLockAndScreensaver, isMuted, volume, resolution
        case playbackMode
        case cycleBlurRadius, trimStart, trimEnd, playbackRate
        case launchAtLogin, pauseOnBattery, pauseOnScreenRecording
        case selectedVideoID
        // Legacy keys — read-only migration, not written anymore
        case legacyLoopEnabled  = "loopEnabled"
        case legacyCycleEnabled = "cycleEnabled"
    }
}

// MARK: - UserDefaults convenience

private extension UserDefaults {
    func bool(forKey key: String, default def: Bool) -> Bool {
        object(forKey: key) == nil ? def : bool(forKey: key)
    }
    func float(forKey key: String, default def: Float) -> Float {
        object(forKey: key) == nil ? def : float(forKey: key)
    }
    func double(forKey key: String, default def: Double) -> Double {
        object(forKey: key) == nil ? def : double(forKey: key)
    }
}
