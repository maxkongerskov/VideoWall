import AppKit
import AVFoundation
import Combine

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Auto-pause coordination
//
// Playback can be held paused for several independent reasons (on battery,
// screen being recorded). Each monitor owns exactly one reason and only ever
// adds/removes *its own* reason; the single source of truth for "should we be
// playing" is `userPaused == false && autoPauseReasons.isEmpty`. This stops the
// battery and recording monitors from overriding each other (e.g. a recording
// ending must not resume playback while still on battery).
private enum PauseReason: Hashable {
    case battery
    case recording
}

// MARK: - Clip bounds
//
// The effective playable window of a clip in seconds, after applying the trim
// fractions. Crossfade timing is derived from `length` (end − start), never the
// absolute end, so clips trimmed to start partway through still fade correctly.
// Internal (not private) so the unit tests can exercise `compute`.
struct ClipBounds {
    let start: Double
    let end:   Double
    var length: Double { Swift.max(0, end - start) }

    static let none = ClipBounds(start: 0, end: 0)

    /// Computes bounds from a total duration and the 0…1 trim fractions.
    static func compute(total: Double, trimStart: Double, trimEnd: Double) -> ClipBounds {
        guard total > 0 else { return .none }
        let start = (total * trimStart).clamped(to: 0...total)
        let end   = (total * trimEnd).clamped(to: start...total)
        return ClipBounds(start: start, end: end)
    }
}

// MARK: - WallpaperManager

@MainActor
final class WallpaperManager: ObservableObject {

    // MARK: Published state

    @Published var currentVideo: VideoItem?
    @Published var isPlaying:    Bool = false

    // MARK: Dependencies (injected via init)

    let settings: AppSettings
    let library:  VideoLibraryManager

    init(settings: AppSettings, library: VideoLibraryManager) {
        self.settings = settings
        self.library  = library
    }

    // MARK: Private – windows

    private var wallpaperWindows: [WallpaperWindow] = []

    // MARK: Private – active player

    private var player:       AVQueuePlayer?
    private var looper:       AVPlayerLooper?
    private var timeObserver: Any?          // trim end-enforcer (non-loop path)

    // MARK: Private – cycle/loop crossfade

    private var cycleObserver:        Any?           // periodic observer → triggers transition
    private var cycleObserverPlayer:  AVQueuePlayer? // the player the observer is attached to
    private var loopObserver:         Any?
    private var loopObserverPlayer:   AVQueuePlayer?
    private var transitionPlayer:     AVQueuePlayer?
    private var transitionInProgress: Bool = false

    // MARK: Private – async tasks

    /// Loop/trim setup + cycle-observer arming for the current play() call.
    /// Cancelled in stopPlayer() so a stale task can't restart a stopped player.
    private var setupTask:    Task<Void, Never>?
    private var slowDownTask: Task<Void, Never>?
    private var preRollTask:  Task<Void, Never>?

    // MARK: Private – auto-pause coordination

    private var autoPauseReasons: Set<PauseReason> = []
    /// True when the user explicitly paused via the UI.
    private var userPaused = false

    /// True when "Pause During Screen Recording" is on but the app lacks the
    /// Screen Recording permission needed to detect captures. Observed by the UI.
    @Published var needsScreenRecordingPermission = false

    // MARK: Private – extracted monitors

    private let batteryMonitor   = BatteryMonitor()
    private let recordingMonitor = ScreenRecordingMonitor()
    private let snapshotMirror   = SnapshotMirror()

    // MARK: Private – observers

    private var endObserver:    NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    /// Cached screen geometry so we can tell a real display change from the
    /// many spurious didChangeScreenParameters notifications macOS emits
    /// (display sleep/wake, brightness, Night Shift, etc.).
    private var lastScreenSignature: [CGRect] = []
    /// Coalesces bursts of screen-parameter notifications into one handling.
    private var screenChangeTask: Task<Void, Never>?

    // MARK: Private – settings binding

    private var settingsCancellables = Set<AnyCancellable>()

    // MARK: Setup / Teardown

    func setup() {
        restoreWallpaperFromLegacyBackupIfNeeded()
        createWallpaperWindows()
        observeScreenChanges()
        observePlaybackEnd()
        bindSettings()
        wireMonitors()
    }

    private func wireMonitors() {
        batteryMonitor.onChange = { [weak self] onBattery in
            guard let self else { return }
            self.setAutoPause(.battery, active: self.settings.pauseOnBattery && onBattery)
        }

        recordingMonitor.onRecordingChange = { [weak self] isRecording in
            guard let self else { return }
            self.setAutoPause(.recording, active: self.settings.pauseOnScreenRecording && isRecording)
        }
        recordingMonitor.onPermissionChange = { [weak self] granted in
            guard let self else { return }
            self.needsScreenRecordingPermission = self.settings.pauseOnScreenRecording && !granted
        }

        snapshotMirror.onFrame = { [weak self] cgImage in
            self?.wallpaperWindows.forEach { $0.updateSnapshot(cgImage) }
        }

        batteryMonitor.start()
        recordingMonitor.start()
        // start() above runs an immediate evaluate(), so hasPermission is current.
        needsScreenRecordingPermission = settings.pauseOnScreenRecording && !recordingMonitor.hasPermission
    }

    /// Prompts for Screen Recording permission (needed for recording detection)
    /// and refreshes the derived UI state.
    func requestScreenRecordingPermission() {
        recordingMonitor.requestPermission()
        needsScreenRecordingPermission = settings.pauseOnScreenRecording && !recordingMonitor.hasPermission
    }

    /// Opens the Screen Recording pane of System Settings.
    func openScreenRecordingSettings() {
        recordingMonitor.openSystemSettings()
    }

    /// Full teardown for app termination: stops playback, tears down the
    /// monitoring timers, and removes the long-lived notification observers.
    /// `stop()` deliberately does NOT do this so the monitors survive a
    /// "stop current video" without dying for the rest of the session.
    func teardown() {
        batteryMonitor.stop()
        recordingMonitor.stop()
        snapshotMirror.stop()
        screenChangeTask?.cancel(); screenChangeTask = nil

        if let endObserver    { NotificationCenter.default.removeObserver(endObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        endObserver    = nil
        screenObserver = nil

        settingsCancellables.removeAll()
        stopPlayer()
        tearDownWindows()
        currentVideo = nil
        isPlaying    = false
    }

    // MARK: – Playback control

    func play(video: VideoItem) {
        guard let url = resolvedURL(for: video) else { return }

        currentVideo = video
        settings.selectedVideoID = video.id

        // A fresh user-initiated play clears any prior pause intent; the
        // monitors re-evaluate their conditions on their next tick.
        userPaused = false
        autoPauseReasons.removeAll()

        if player != nil {
            playWithTransition(video: video, url: url)
        } else {
            playCold(video: video, url: url)
        }
    }

    func stop() {
        stopPlayer()
        currentVideo = nil
        isPlaying    = false
        userPaused   = false
        autoPauseReasons.removeAll()
    }

    func togglePlayPause() {
        if isPlaying {
            userPaused = true
        } else {
            // Explicit user resume overrides any active auto-pause holds; the
            // monitors will re-apply on their next tick if a condition persists.
            userPaused = false
            autoPauseReasons.removeAll()
        }
        reconcilePlayback()
    }

    // MARK: – Live transition (video already playing → crossfade with blur)

    private func playWithTransition(video: VideoItem, url: URL) {
        // Snapshot outgoing state before cancelling anything.
        let outPlayer = player
        let outLooper = looper

        // Cancel in-flight tasks and observers, but do NOT pause or nil the old
        // player — it must keep producing frames under the crossfade.
        setupTask?.cancel();    setupTask    = nil
        slowDownTask?.cancel(); slowDownTask = nil
        preRollTask?.cancel();  preRollTask  = nil
        stopCycleObserver()
        stopLoopObserver()

        if let obs = timeObserver {
            outPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
        looper = nil   // our stored ref gone; outLooper still holds it alive

        transitionPlayer?.pause()
        transitionPlayer?.replaceCurrentItem(with: nil)
        transitionPlayer     = nil
        transitionInProgress = false

        // Build and pre-roll the incoming player.
        let (newPlayer, item, asset) = makePlayer(url: url)
        player = newPlayer

        isPlaying = true
        let peakBlur          = CGFloat(settings.cycleBlurRadius)
        let crossfadeDuration = 3.0

        // Pre-roll: start the new player immediately so AVFoundation decodes the
        // first frame, then fire the crossfade after a short decode window.
        newPlayer.play()

        preRollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else {
                outPlayer?.pause()
                outPlayer?.replaceCurrentItem(with: nil)
                return
            }

            // Crossfade — outgoing video continues playing underneath the blur.
            self.wallpaperWindows.forEach {
                $0.crossfade(to: newPlayer, duration: crossfadeDuration, peakBlur: peakBlur)
            }

            // Tear down the outgoing player only after the animation finishes.
            try? await Task.sleep(for: .seconds(crossfadeDuration + 0.2))
            guard !Task.isCancelled else {
                outPlayer?.pause()
                outPlayer?.replaceCurrentItem(with: nil)
                return
            }
            outPlayer?.pause()
            outPlayer?.replaceCurrentItem(with: nil)
            _ = outLooper   // keep looper alive until old player is torn down
            self.preRollTask = nil
        }

        armPlayback(item: item, player: newPlayer, asset: asset)
    }

    // MARK: – Cold start (nothing playing yet)

    private func playCold(video: VideoItem, url: URL) {
        stopPlayer()

        let (queuePlayer, item, asset) = makePlayer(url: url)
        player = queuePlayer

        wallpaperWindows.forEach { $0.setPlayer(queuePlayer) }
        isPlaying = true

        armPlayback(item: item, player: queuePlayer, asset: asset)
    }

    /// Sets up trim/loop, starts playback, and arms the cycle/loop crossfade
    /// observer for a freshly built player. Shared by cold-start and live
    /// transitions.
    private func armPlayback(item: AVPlayerItem, player: AVQueuePlayer, asset: AVURLAsset) {
        let trimStart    = settings.trimStart
        let trimEnd      = settings.trimEnd
        let loopEnabled  = settings.loopEnabled
        let cycleEnabled = settings.cycleEnabled

        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let bounds = await self.setupLoopAndTrim(
                item:         item,
                player:       player,
                asset:        asset,
                trimStart:    trimStart,
                trimEnd:      trimEnd,
                loop:         loopEnabled,
                cycleEnabled: cycleEnabled
            )
            guard !Task.isCancelled else { return }
            if cycleEnabled {
                self.setupCycleObserver(player: player, bounds: bounds)
            } else if loopEnabled {
                self.setupLoopObserver(player: player, bounds: bounds)
            }
            self.setupTask = nil
        }
    }

    // MARK: – Rate ramps (~1.4 s, 28 steps, cosine family)

    private func reconcilePlayback() {
        guard player != nil else { return }
        let shouldPlay = currentVideo != nil && !userPaused && autoPauseReasons.isEmpty
        if shouldPlay {
            if !isPlaying { rampUp() }
        } else {
            if isPlaying { rampDown() }
        }
    }

    private func rampDown() {
        guard let player else { return }
        isPlaying = false
        slowDownTask?.cancel()
        let capturedPlayer = player
        slowDownTask = Task { @MainActor [weak self] in
            await self?.applySlowDownRamp(player: capturedPlayer)
        }
    }

    private func rampUp() {
        guard let player else { return }
        isPlaying = true
        slowDownTask?.cancel()
        let capturedPlayer = player
        slowDownTask = Task { @MainActor [weak self] in
            await self?.applySpeedUpRamp(player: capturedPlayer)
        }
    }

    private func applySlowDownRamp(player: AVQueuePlayer) async {
        let steps = 28; let stepMs = 1_400 / steps
        for i in 0...steps {
            if Task.isCancelled { return }
            player.rate = max(0, Float(cos(Double(i) / Double(steps) * .pi / 2)))
            if i < steps { try? await Task.sleep(for: .milliseconds(stepMs)) }
        }
        if !Task.isCancelled { player.pause() }
        slowDownTask = nil
    }

    private func applySpeedUpRamp(player: AVQueuePlayer) async {
        let steps = 28; let stepMs = 1_400 / steps
        for i in 0...steps {
            if Task.isCancelled { return }
            player.rate = min(1, Float(sin(Double(i) / Double(steps) * .pi / 2)))
            if i < steps { try? await Task.sleep(for: .milliseconds(stepMs)) }
        }
        if !Task.isCancelled { player.rate = 1.0 }
        slowDownTask = nil
    }

    // MARK: – Volume

    // Volume/mute changes flow through `settings`, whose Combine sinks (see
    // bindSettings) apply the value to the live player — a single code path.

    func setVolume(_ value: Float) {
        settings.volume = value
    }

    func toggleMute() {
        settings.isMuted.toggle()
    }

    // MARK: – Resolution

    func setResolution(_ resolution: VideoResolution) {
        settings.resolution = resolution
        if let video = currentVideo { play(video: video) }
    }

    // MARK: – All Spaces

    func setPlayOnAllSpaces(_ enabled: Bool) {
        settings.playOnAllSpaces = enabled
        wallpaperWindows.forEach { $0.setAllSpaces(enabled) }
    }

    // MARK: – Playback mode (Loop ↔ Cycle, exactly one active)

    /// Single coordinated entry point for switching between Loop and Cycle.
    /// Flips both `loopEnabled` and `cycleEnabled` atomically and replays
    /// the current video exactly once.
    func setPlaybackMode(_ mode: PlaybackMode) {
        let wantsLoop  = (mode == .loop)
        let wantsCycle = (mode == .cycle)

        // No-op if already in the requested state.
        guard settings.loopEnabled != wantsLoop ||
              settings.cycleEnabled != wantsCycle else { return }

        settings.loopEnabled  = wantsLoop
        settings.cycleEnabled = wantsCycle

        if let video = currentVideo {
            play(video: video)
        }
    }

    // MARK: – Private: player construction

    /// Builds a player for `url`, applies the resolution downscale, wires up the
    /// snapshot mirror, and returns the pieces needed for trim/loop setup.
    private func makePlayer(url: URL) -> (AVQueuePlayer, AVPlayerItem, AVURLAsset) {
        let asset = AVURLAsset(url: url)
        let item  = AVPlayerItem(asset: asset)
        applyResolution(settings.resolution, to: item, asset: asset)

        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.volume          = settings.isMuted ? 0 : settings.volume
        queuePlayer.actionAtItemEnd = .none
        snapshotMirror.attach(to: item, player: queuePlayer)
        return (queuePlayer, item, asset)
    }

    // MARK: – Private: player teardown

    /// Tears down the active player and all associated observers.
    ///
    /// - Parameter preserveWindowContent: When `true`, the window layer is left
    ///   intact (old frame stays visible) so the caller can crossfade to the next
    ///   player without a black flash.
    private func stopPlayer(preserveWindowContent: Bool = false) {
        // Cancel every in-flight async task so stale continuations can't
        // restart a player that has already been replaced.
        setupTask?.cancel();    setupTask    = nil
        slowDownTask?.cancel(); slowDownTask = nil
        preRollTask?.cancel();  preRollTask  = nil

        snapshotMirror.stop()
        stopCycleObserver()
        stopLoopObserver()

        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
        looper = nil
        player?.pause()
        if !preserveWindowContent {
            player?.replaceCurrentItem(with: nil)
        }
        player = nil

        transitionPlayer?.pause()
        transitionPlayer?.replaceCurrentItem(with: nil)
        transitionPlayer     = nil
        transitionInProgress = false

        if !preserveWindowContent {
            wallpaperWindows.forEach { $0.clearPlayer() }
        }
    }

    private func resolvedURL(for video: VideoItem) -> URL? {
        let url = library.url(for: video)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: – Private: resolution downscale (optional)

    private func applyResolution(_ res: VideoResolution,
                                  to item: AVPlayerItem,
                                  asset: AVURLAsset) {
        guard let targetSize = res.renderSize else { return }

        Task { @MainActor [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await track.load(.naturalSize),
                  let transform   = try? await track.load(.preferredTransform),
                  let composition = try? await AVMutableVideoComposition.videoComposition(
                      withPropertiesOf: asset
                  )
            else { return }

            let vidSize = naturalSize.applying(transform)
            let absSize = CGSize(width: abs(vidSize.width), height: abs(vidSize.height))
            let scale   = min(targetSize.width  / absSize.width,
                              targetSize.height / absSize.height,
                              1.0)
            composition.renderSize = CGSize(
                width:  (absSize.width  * scale).rounded(),
                height: (absSize.height * scale).rounded()
            )

            // Guard against a stale async result landing on an item that has
            // already been swapped out by a newer play()/transition.
            guard let self,
                  self.player?.currentItem === item
                        || self.transitionPlayer?.currentItem === item
            else { return }
            item.videoComposition = composition
        }
    }

    // MARK: – Private: trim + loop setup

    /// Configures trim/loop for a freshly built player, starts playback, and
    /// returns the effective clip bounds (used to arm the crossfade observer).
    @discardableResult
    private func setupLoopAndTrim(item:         AVPlayerItem,
                                   player:       AVQueuePlayer,
                                   asset:        AVURLAsset,
                                   trimStart:    Double,
                                   trimEnd:      Double,
                                   loop:         Bool,
                                   cycleEnabled: Bool) async -> ClipBounds {

        let hasTrim = trimStart > 0.005 || trimEnd < 0.995

        // Fast path: no trim, no cycle, no loop — duration not needed.
        if !hasTrim && !cycleEnabled && !loop {
            if Task.isCancelled { return .none }
            player.play()
            return .none
        }

        // We need duration for trimming, cycle timing, or loop crossfade scheduling.
        guard let duration = try? await asset.load(.duration),
              duration.isValid, !duration.isIndefinite,
              duration.seconds > 0 else {
            if Task.isCancelled { return .none }
            // No usable duration — play once; the end-notification safety net
            // will restart or advance as appropriate.
            player.play()
            return .none
        }

        if Task.isCancelled { return .none }

        let bounds   = ClipBounds.compute(total: duration.seconds,
                                          trimStart: trimStart, trimEnd: trimEnd)
        let startCMT = CMTime(seconds: bounds.start, preferredTimescale: 600)
        let endCMT   = CMTime(seconds: bounds.end,   preferredTimescale: 600)

        if cycleEnabled {
            // HARD RULE: cycle mode never creates a looper. The video plays
            // exactly once from trimStart to trimEnd, then the cycle observer
            // or the end-notification safety net advances to the next video.
            if bounds.start > 0.005 {
                _ = await player.seek(
                    to: startCMT,
                    toleranceBefore: .zero,
                    toleranceAfter:  CMTime(seconds: 0.1, preferredTimescale: 600)
                )
            }
            if Task.isCancelled { return .none }
            player.play()
            return bounds
        }

        // Non-cycle path with optional trim.
        if loop {
            // AVPlayerLooper gives reliable looping so the video never freezes
            // at item end and the play button always works. .advance is required
            // for the looper to queue the next copy when the item finishes.
            // The crossfade observer (armed by the caller) fires ~3 s before the
            // end for the smooth visual transition; the looper is the safety net.
            player.actionAtItemEnd = .advance
            looper = hasTrim
                ? AVPlayerLooper(player: player, templateItem: item,
                                 timeRange: CMTimeRange(start: startCMT, end: endCMT))
                : AVPlayerLooper(player: player, templateItem: item)
            if bounds.start > 0.005 {
                _ = await player.seek(to: startCMT,
                                      toleranceBefore: .zero,
                                      toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
            }
        } else {
            _ = await player.seek(to: startCMT,
                                  toleranceBefore: .zero,
                                  toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            let endSec   = bounds.end
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: interval, queue: .main
            ) { [weak self] time in
                guard time.seconds >= endSec - 0.12 else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.player?.pause()
                    self.userPaused = true
                    self.isPlaying  = false
                }
            }
        }

        if Task.isCancelled { return .none }
        player.play()
        return bounds
    }

    // MARK: – Private: cycle / loop crossfade observers

    private func setupCycleObserver(player targetPlayer: AVQueuePlayer, bounds: ClipBounds) {
        guard bounds.length > 0 else { return }

        let crossfadeDur = min(3.0, bounds.length * 0.9)
        let triggerSec   = max(bounds.start, bounds.end - crossfadeDur)
        let interval     = CMTime(seconds: 0.25, preferredTimescale: 600)

        cycleObserverPlayer = targetPlayer
        cycleObserver = targetPlayer.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self,
                      time.seconds >= triggerSec,
                      !self.transitionInProgress
                else { return }

                Task { @MainActor [weak self] in
                    await self?.beginTransition(mode: .cycle, crossfadeDuration: crossfadeDur)
                }
            }
        }
    }

    private func stopCycleObserver() {
        if let obs = cycleObserver {
            cycleObserverPlayer?.removeTimeObserver(obs)
            cycleObserver       = nil
            cycleObserverPlayer = nil
        }
    }

    private func setupLoopObserver(player targetPlayer: AVQueuePlayer, bounds: ClipBounds) {
        guard bounds.length > 0 else { return }

        let crossfadeDur = min(3.0, bounds.length * 0.9)
        let triggerSec   = max(bounds.start, bounds.end - crossfadeDur)
        let interval     = CMTime(seconds: 0.25, preferredTimescale: 600)

        loopObserverPlayer = targetPlayer
        loopObserver = targetPlayer.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self,
                      time.seconds >= triggerSec,
                      !self.transitionInProgress
                else { return }

                Task { @MainActor [weak self] in
                    await self?.beginTransition(mode: .loop, crossfadeDuration: crossfadeDur)
                }
            }
        }
    }

    private func stopLoopObserver() {
        if let obs = loopObserver {
            loopObserverPlayer?.removeTimeObserver(obs)
            loopObserver       = nil
            loopObserverPlayer = nil
        }
    }

    // MARK: – Private: unified crossfade transition (loop replay + cycle advance)

    private func nextVideoForCycle() -> VideoItem? {
        let videos = library.videos
        guard videos.count >= 2 else { return nil }
        if let cur = currentVideo, let idx = videos.firstIndex(of: cur) {
            return videos[(idx + 1) % videos.count]
        }
        return videos.first
    }

    /// Crossfades to the next clip. In `.loop` mode the "next" clip is the
    /// current video again; in `.cycle` mode it is the next video in the library.
    private func beginTransition(mode: PlaybackMode, crossfadeDuration: Double) async {
        guard !transitionInProgress else { return }

        let target: VideoItem?
        switch mode {
        case .loop:  target = currentVideo
        case .cycle: target = nextVideoForCycle()
        }
        guard let target, let url = resolvedURL(for: target) else { return }

        transitionInProgress = true

        let (nextPlayer, _, asset) = makePlayer(url: url)
        transitionPlayer = nextPlayer

        let bounds = await clipBounds(for: asset)

        if bounds.start > 0.005 {
            _ = await nextPlayer.seek(
                to: CMTime(seconds: bounds.start, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter:  CMTime(seconds: 0.1, preferredTimescale: 600)
            )
        }

        if Task.isCancelled {
            transitionInProgress = false
            return
        }

        nextPlayer.play()

        let peakBlur = CGFloat(settings.cycleBlurRadius)
        wallpaperWindows.forEach {
            $0.crossfade(to: nextPlayer, duration: crossfadeDuration, peakBlur: peakBlur)
        }

        try? await Task.sleep(for: .seconds(crossfadeDuration + 0.1))

        if Task.isCancelled {
            transitionInProgress = false
            return
        }

        finalizeTransition(to: target, nextPlayer: nextPlayer, bounds: bounds, mode: mode)
    }

    private func finalizeTransition(to video:     VideoItem,
                                     nextPlayer:  AVQueuePlayer,
                                     bounds:      ClipBounds,
                                     mode:        PlaybackMode) {
        guard transitionPlayer === nextPlayer else { return }

        stopCycleObserver()
        stopLoopObserver()

        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
        looper = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)

        player               = nextPlayer
        transitionPlayer     = nil
        transitionInProgress = false

        if mode == .cycle {
            currentVideo             = video
            settings.selectedVideoID = video.id
        }

        if !isPlaying { nextPlayer.pause() }

        switch mode {
        case .cycle:
            if settings.cycleEnabled { setupCycleObserver(player: nextPlayer, bounds: bounds) }
        case .loop:
            if settings.loopEnabled  { setupLoopObserver(player: nextPlayer, bounds: bounds) }
        }
    }

    /// Effective clip bounds for the current trim settings against an asset's
    /// duration. Returns `.none` if the duration can't be read.
    private func clipBounds(for asset: AVURLAsset) async -> ClipBounds {
        guard let dur = try? await asset.load(.duration),
              dur.isValid, !dur.isIndefinite, dur.seconds > 0 else {
            return .none
        }
        return ClipBounds.compute(total: dur.seconds,
                                  trimStart: settings.trimStart,
                                  trimEnd:   settings.trimEnd)
    }

    // MARK: – Private: end-of-item safety net

    private func observePlaybackEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object:  nil,
            queue:   .main
        ) { [weak self] notification in
            let endedID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self,
                      self.settings.cycleEnabled || self.settings.loopEnabled,
                      !self.transitionInProgress,
                      let current = self.player?.currentItem,
                      ObjectIdentifier(current) == endedID
                else { return }
                // Safety net: the periodic observer should normally trigger the
                // crossfade before the item ends, but if it misses (e.g. very
                // short clip), restart playback here.
                if self.settings.cycleEnabled {
                    if let next = self.nextVideoForCycle() { self.play(video: next) }
                } else if let video = self.currentVideo {
                    self.play(video: video)
                }
            }
        }
    }

    // MARK: – Private: settings binding

    private func bindSettings() {
        settings.$isMuted
            .sink { [weak self] muted in
                guard let self else { return }
                self.player?.volume = muted ? 0 : self.settings.volume
            }
            .store(in: &settingsCancellables)

        settings.$volume
            .sink { [weak self] vol in
                guard let self, !self.settings.isMuted else { return }
                self.player?.volume = vol
            }
            .store(in: &settingsCancellables)

        // Loop / Cycle changes are routed through `setPlaybackMode` which
        // handles the replay itself — no need for per-Boolean sinks (they
        // would double-fire when we flip both atomically).

        // Re-evaluate auto-pause states immediately when the user flips a
        // toggle, instead of waiting for the next monitor tick.
        settings.$pauseOnBattery
            .dropFirst()
            .sink { [weak self] _ in self?.batteryMonitor.evaluate() }
            .store(in: &settingsCancellables)

        settings.$pauseOnScreenRecording
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.needsScreenRecordingPermission = enabled && !self.recordingMonitor.hasPermission
                self.recordingMonitor.evaluate()
            }
            .store(in: &settingsCancellables)
    }

    // MARK: – Private: window management

    private func createWallpaperWindows() {
        tearDownWindows()
        let allSpaces = settings.playOnAllSpaces
        for screen in NSScreen.screens {
            let w = WallpaperWindow(screen: screen)
            w.setAllSpaces(allSpaces)
            wallpaperWindows.append(w)
        }
        wallpaperWindows.forEach { $0.show() }
    }

    private func tearDownWindows() {
        wallpaperWindows.forEach { $0.hide() }
        wallpaperWindows.removeAll()
    }

    private func observeScreenChanges() {
        lastScreenSignature = currentScreenSignature()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenParametersChange()
            }
        }
    }

    private func currentScreenSignature() -> [CGRect] {
        NSScreen.screens.map { $0.frame }
    }

    private func handleScreenParametersChange() {
        screenChangeTask?.cancel()
        screenChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }

            let newSignature = self.currentScreenSignature()

            if newSignature == self.lastScreenSignature { return }

            let sameScreenCount = newSignature.count == self.lastScreenSignature.count
            self.lastScreenSignature = newSignature

            if sameScreenCount {
                for (window, screen) in zip(self.wallpaperWindows, NSScreen.screens) {
                    window.updateFrame(for: screen)
                }
            } else {
                self.createWallpaperWindows()
                if let video = self.currentVideo { self.play(video: video) }
            }
        }
    }

    // MARK: – Private: legacy wallpaper restore

    private func restoreWallpaperFromLegacyBackupIfNeeded() {
        let key = "vw_originalDesktopURLs"
        guard let backup = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        else { return }
        for screen in NSScreen.screens {
            if let path = backup[screen.localizedName] {
                try? NSWorkspace.shared.setDesktopImageURL(
                    URL(fileURLWithPath: path), for: screen, options: [:]
                )
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: – Private: auto-pause reasons

    /// Adds or removes a single auto-pause reason and reconciles playback.
    /// Each monitor only ever touches its own reason, so they can't override
    /// one another (e.g. a recording ending won't resume playback on battery).
    private func setAutoPause(_ reason: PauseReason, active: Bool) {
        let changed: Bool
        if active {
            changed = autoPauseReasons.insert(reason).inserted
        } else {
            changed = autoPauseReasons.remove(reason) != nil
        }
        if changed { reconcilePlayback() }
    }
}
