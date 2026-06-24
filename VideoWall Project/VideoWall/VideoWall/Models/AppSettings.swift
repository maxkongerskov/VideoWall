import Foundation

// MARK: - PlaybackMode
// Exactly one of these is always active. There is no "off" state for playback.

enum PlaybackMode: String, CaseIterable {
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

    @Published var isMuted: Bool {
        didSet { save(isMuted, forKey: .isMuted) }
    }

    @Published var volume: Float {
        didSet { save(volume, forKey: .volume) }
    }

    @Published var resolution: VideoResolution {
        didSet { save(resolution.rawValue, forKey: .resolution) }
    }

    @Published var loopEnabled: Bool {
        didSet { save(loopEnabled, forKey: .loopEnabled) }
    }

    @Published var cycleEnabled: Bool {
        didSet { save(cycleEnabled, forKey: .cycleEnabled) }
    }

    // Peak blur radius (0 = no blur, 16 = default, 32 = max) used during cycle crossfades.
    @Published var cycleBlurRadius: Double {
        didSet { save(cycleBlurRadius, forKey: .cycleBlurRadius) }
    }

    // Trim points (0.0 – 1.0 fraction of total duration)
    @Published var trimStart: Double {
        didSet { save(trimStart, forKey: .trimStart) }
    }

    @Published var trimEnd: Double {
        didSet { save(trimEnd, forKey: .trimEnd) }
    }

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

    // MARK: Init

    init() {
        let d = UserDefaults.standard
        playOnAllSpaces      = d.bool(forKey: Key.playOnAllSpaces.rawValue, default: true)
        isMuted              = d.bool(forKey: Key.isMuted.rawValue, default: true)
        volume               = d.float(forKey: Key.volume.rawValue, default: 0.5)
        loopEnabled          = d.bool(forKey: Key.loopEnabled.rawValue, default: true)
        cycleEnabled         = d.bool(forKey: Key.cycleEnabled.rawValue, default: false)
        cycleBlurRadius      = d.double(forKey: Key.cycleBlurRadius.rawValue, default: 4.0)
        trimStart            = d.double(forKey: Key.trimStart.rawValue, default: 0.0)
        trimEnd              = d.double(forKey: Key.trimEnd.rawValue, default: 1.0)
        launchAtLogin        = d.bool(forKey: Key.launchAtLogin.rawValue, default: false)
        pauseOnBattery       = d.bool(forKey: Key.pauseOnBattery.rawValue, default: true)
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

        // Normalize: exactly one playback mode must be active. Legacy installs
        // (or anyone who managed to land in the "both off" state) get pushed
        // back to Loop. "Both on" shouldn't happen with the new UI, but if it
        // did we'd treat Cycle as the winner.
        if !loopEnabled && !cycleEnabled {
            loopEnabled = true
        } else if loopEnabled && cycleEnabled {
            loopEnabled = false
        }
    }

    // MARK: Playback mode (computed view over loop/cycle)

    var playbackMode: PlaybackMode {
        cycleEnabled ? .cycle : .loop
    }

    // MARK: Private helpers

    private func save(_ value: Any?, forKey key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    private enum Key: String {
        case playOnAllSpaces, isMuted, volume, resolution
        case loopEnabled, cycleEnabled, cycleBlurRadius, trimStart, trimEnd
        case launchAtLogin, pauseOnBattery, pauseOnScreenRecording
        case selectedVideoID
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

