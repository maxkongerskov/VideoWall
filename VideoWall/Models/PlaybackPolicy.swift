import Foundation

// MARK: - Auto-pause reasons
//
// Playback can be held paused for several independent reasons (on battery,
// screen being recorded). Each monitor owns exactly one reason; the source of
// truth for "should we be playing" is `userPaused == false && reasons.isEmpty`.

enum PauseReason: Hashable, Sendable {
    case battery
    case recording
}

// MARK: - Playback policy (pure, unit-tested)

enum PlaybackPolicy: Sendable {

    /// Whether the wallpaper should actively play, given user intent and holds.
    static func shouldPlay(
        hasCurrentVideo: Bool,
        userPaused: Bool,
        autoPauseReasons: Set<PauseReason>
    ) -> Bool {
        hasCurrentVideo && !userPaused && autoPauseReasons.isEmpty
    }

    /// Applies one monitor's hold: returns the updated reason set.
    static func applying(
        reason: PauseReason,
        active: Bool,
        to reasons: Set<PauseReason>
    ) -> Set<PauseReason> {
        var next = reasons
        if active {
            next.insert(reason)
        } else {
            next.remove(reason)
        }
        return next
    }

    /// Next library item for cycle mode (wraps). Returns nil when cycling is impossible.
    static func nextVideoForCycle(current: VideoItem?, in videos: [VideoItem]) -> VideoItem? {
        guard videos.count >= 2 else { return nil }
        if let cur = current, let idx = videos.firstIndex(of: cur) {
            return videos[(idx + 1) % videos.count]
        }
        return videos.first
    }

    /// Target clip for a boundary transition: same video (loop) or next (cycle).
    static func transitionTarget(
        mode: PlaybackMode,
        current: VideoItem?,
        library: [VideoItem]
    ) -> VideoItem? {
        switch mode {
        case .loop:  return current
        case .cycle: return nextVideoForCycle(current: current, in: library)
        }
    }

    /// Whether an in-flight crossfade may keep mutating playback state.
    /// False when the Task was cancelled or a newer transition/stop invalidated `generation`.
    static func shouldContinueTransition(
        taskCancelled: Bool,
        generation: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        !taskCancelled && generation == currentGeneration
    }
}

// MARK: - Duration formatting (shared by models + UI)

enum DurationFormatting: Sendable {

    /// Formats a duration in seconds as `M:SS` / `H:MM:SS`, or `MM:SS` / `HH:MM:SS` when `zeroPadHoursMinutes` is true.
    static func string(from seconds: TimeInterval, zeroPadMinutes: Bool = false) -> String {
        guard seconds.isFinite && seconds >= 0 else {
            return zeroPadMinutes ? "00:00" : "0:00"
        }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            if zeroPadMinutes {
                return String(format: "%02d:%02d:%02d", h, m, s)
            }
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        if zeroPadMinutes {
            return String(format: "%02d:%02d", m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
