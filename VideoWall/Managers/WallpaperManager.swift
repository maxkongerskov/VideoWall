import AppKit
import AVFoundation
import Combine

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Clip bounds
//
// The effective playable window of a clip in seconds, after applying the trim
// fractions. Crossfade timing is derived from `length` (end − start), never the
// absolute end, so clips trimmed to start partway through still fade correctly.
// Internal (not private) so the unit tests can exercise `compute`.

struct ClipBounds: Equatable, Sendable {
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

    /// - Parameter lockScreenInjection: When true, copies the current video
    ///   into macOS aerials so the lock screen can play it natively. Tests
    ///   leave this false so they never touch the system wallpaper store.
    init(settings: AppSettings,
         library: VideoLibraryManager,
         lockScreenInjection: Bool = false) {
        self.settings = settings
        self.library  = library
        self.aerials  = lockScreenInjection ? AerialsInjector() : nil
    }

    // MARK: Private – windows

    private var wallpaperWindows: [WallpaperWindow] = []

    // MARK: Private – active player

    private var player:       AVQueuePlayer?
    private var looper:       AVPlayerLooper?
    private var timeObserver: Any?          // trim end-enforcer (non-loop path)

    // MARK: Private – cycle/loop crossfade (single boundary observer)

    private var boundaryObserver:       Any?
    private var boundaryObserverPlayer: AVQueuePlayer?
    private var transitionTask:         Task<Void, Never>?
    private var transitionInProgress:   Bool = false
    /// Bumped on each new transition so a cancelled prior task cannot clear the gate.
    private var transitionGeneration:   UInt64 = 0

    // MARK: Private – async tasks

    /// Loop/trim setup + boundary-observer arming for the current play() call.
    /// Cancelled in stopPlayer() so a stale task can't restart a stopped player.
    private var setupTask:    Task<Void, Never>?
    private var slowDownTask: Task<Void, Never>?

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
    private let surfaceMonitor   = ScreenSurfaceMonitor()
    private let aerials: AerialsInjector?

    /// Resolved overlay target (desktop / screensaver / lock).
    private var surface: WallpaperSurface = .desktop
    /// True after a successful aerials install for the current clip.
    private var nativeLockReady = false
    /// Overlay player was paused because native aerials own the lock screen.
    private var overlayHeldForLock = false

    private var injectTask: Task<Void, Never>?
    private var surfaceReassertTask: Task<Void, Never>?

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

        surfaceMonitor.onChange = { [weak self] locked, screensaver in
            guard let self else { return }
            self.surface = WallpaperSurfacePolicy.surface(
                isLocked: locked,
                isScreensaver: screensaver
            )
            self.applyCurrentSurface()
        }

        batteryMonitor.start()
        recordingMonitor.start()
        surfaceMonitor.start()
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
        surfaceMonitor.stop()
        injectTask?.cancel(); injectTask = nil
        surfaceReassertTask?.cancel(); surfaceReassertTask = nil
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

        // Fresh user-initiated play clears pause intent only. Auto-pause holds
        // stay authoritative; re-evaluate physical state immediately so we do
        // not wait a full poll interval while a hold should be active.
        userPaused = false
        reevaluateAutoPauseHolds()

        if player != nil {
            startCrossfade(to: video, url: url, updateIdentity: false)
        } else {
            playCold(video: video, url: url)
        }

        scheduleLockScreenInstall()
    }

    func stop() {
        injectTask?.cancel(); injectTask = nil
        stopPlayer()
        currentVideo = nil
        isPlaying    = false
        userPaused   = false
        autoPauseReasons.removeAll()
    }

    /// Stops playback when a removed library item is the current wallpaper.
    /// Called from library delete / delete-all coordination.
    func handleVideosRemoved(_ ids: Set<UUID>) {
        guard let current = currentVideo, ids.contains(current.id) else { return }
        stop()
    }

    func togglePlayPause() {
        if isPlaying {
            userPaused = true
        } else {
            // Explicit user resume clears only user intent; holds re-apply now.
            userPaused = false
            reevaluateAutoPauseHolds()
        }
        reconcilePlayback()
    }

    /// Immediately re-samples battery + recording monitors so holds match
    /// physical state without waiting for the next timer tick.
    private func reevaluateAutoPauseHolds() {
        batteryMonitor.evaluate()
        recordingMonitor.evaluate()
    }

    // MARK: – Cold start (nothing playing yet)

    private func playCold(video: VideoItem, url: URL) {
        stopPlayer()

        let (queuePlayer, item, asset) = makePlayer(url: url)
        player = queuePlayer

        wallpaperWindows.forEach { $0.setPlayer(queuePlayer) }

        armPlayback(item: item, player: queuePlayer, asset: asset)
    }

    /// Sets up trim/loop, starts playback (respecting auto-pause), and arms the
    /// boundary crossfade observer for a freshly built player.
    private func armPlayback(item: AVPlayerItem, player: AVQueuePlayer, asset: AVURLAsset) {
        let trimStart   = settings.trimStart
        let trimEnd     = settings.trimEnd
        let mode        = settings.playbackMode

        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let bounds = await self.setupLoopAndTrim(
                item:      item,
                player:    player,
                asset:     asset,
                trimStart: trimStart,
                trimEnd:   trimEnd,
                mode:      mode
            )
            guard !Task.isCancelled else { return }
            self.armBoundaryObserver(player: player, bounds: bounds, mode: mode)
            self.setupTask = nil
        }
    }

    // MARK: – Rate ramps (~1.4 s, 28 steps, cosine family)

    private func reconcilePlayback() {
        guard player != nil else { return }
        let shouldPlay = PlaybackPolicy.shouldPlay(
            hasCurrentVideo: currentVideo != nil,
            userPaused: userPaused,
            autoPauseReasons: autoPauseReasons
        )
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

    /// Starts or holds the player based on current pause policy (no ramp).
    private func applyImmediatePlaybackState(to player: AVQueuePlayer) {
        let should = PlaybackPolicy.shouldPlay(
            hasCurrentVideo: currentVideo != nil,
            userPaused: userPaused,
            autoPauseReasons: autoPauseReasons
        )
        if should {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
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

    func setPlayOnLockAndScreensaver(_ enabled: Bool) {
        settings.playOnLockAndScreensaver = enabled
        if enabled {
            scheduleLockScreenInstall()
        } else {
            injectTask?.cancel(); injectTask = nil
            nativeLockReady = false
            aerials?.uninstall()
        }
        applyCurrentSurface()
    }

    // MARK: – Playback mode (Loop ↔ Cycle, exactly one active)

    /// Single entry point for switching between Loop and Cycle.
    func setPlaybackMode(_ mode: PlaybackMode) {
        guard settings.playbackMode != mode else { return }
        settings.playbackMode = mode
        if let video = currentVideo {
            play(video: video)
        }
    }

    // MARK: – Private: player construction

    /// Builds a player for `url`, wires the snapshot mirror, and returns the
    /// pieces needed for trim/loop setup. Resolution is applied during arm.
    private func makePlayer(url: URL) -> (AVQueuePlayer, AVPlayerItem, AVURLAsset) {
        let asset = AVURLAsset(url: url)
        let item  = AVPlayerItem(asset: asset)

        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.volume          = settings.isMuted ? 0 : settings.volume
        queuePlayer.actionAtItemEnd = .none
        // Wallpaper must not block idle sleep / screensaver.
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        snapshotMirror.attach(to: item, player: queuePlayer)
        return (queuePlayer, item, asset)
    }

    // MARK: – Private: player teardown

    /// Tears down the active player and all associated observers.
    private func stopPlayer() {
        // Cancel every in-flight async task so stale continuations can't
        // restart a player that has already been replaced. Bump generation so
        // any surviving crossfade (user or auto) treats itself as obsolete.
        setupTask?.cancel();      setupTask      = nil
        slowDownTask?.cancel();   slowDownTask   = nil
        invalidateTransition(cancelTask: true)

        snapshotMirror.stop()
        stopBoundaryObserver()

        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
        looper = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil

        wallpaperWindows.forEach { $0.clearPlayer() }
    }

    /// Cancels the shared transition Task and/or invalidates its generation so
    /// `performCrossfade` aborts before reassigning player / currentVideo.
    private func invalidateTransition(cancelTask: Bool) {
        if cancelTask {
            transitionTask?.cancel()
            transitionTask = nil
        }
        transitionGeneration &+= 1
        transitionInProgress = false
    }

    private func resolvedURL(for video: VideoItem) -> URL? {
        let url = library.url(for: video)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: – Private: resolution downscale (applied before play)

    /// Applies optional render-size composition and returns when ready (or skipped).
    private func applyResolution(_ res: VideoResolution,
                                  to item: AVPlayerItem,
                                  asset: AVURLAsset) async {
        guard let targetSize = res.renderSize else { return }

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
        guard player?.currentItem === item else { return }
        item.videoComposition = composition
    }

    // MARK: – Private: trim + loop setup

    /// Configures trim/loop for a freshly built player, starts playback (subject
    /// to auto-pause), and returns the effective clip bounds.
    @discardableResult
    private func setupLoopAndTrim(item:      AVPlayerItem,
                                   player:    AVQueuePlayer,
                                   asset:     AVURLAsset,
                                   trimStart: Double,
                                   trimEnd:   Double,
                                   mode:      PlaybackMode) async -> ClipBounds {

        // Resolution composition before first frame.
        await applyResolution(settings.resolution, to: item, asset: asset)
        if Task.isCancelled { return .none }

        let hasTrim = trimStart > 0.005 || trimEnd < 0.995
        let loop    = (mode == .loop)
        let cycle   = (mode == .cycle)

        // Fast path: no trim, no cycle, no loop — duration not needed.
        if !hasTrim && !cycle && !loop {
            if Task.isCancelled { return .none }
            applyImmediatePlaybackState(to: player)
            return .none
        }

        // We need duration for trimming, cycle timing, or loop crossfade scheduling.
        guard let duration = try? await asset.load(.duration),
              duration.isValid, !duration.isIndefinite,
              duration.seconds > 0 else {
            if Task.isCancelled { return .none }
            applyImmediatePlaybackState(to: player)
            return .none
        }

        if Task.isCancelled { return .none }

        let bounds   = ClipBounds.compute(total: duration.seconds,
                                          trimStart: trimStart, trimEnd: trimEnd)
        let startCMT = CMTime(seconds: bounds.start, preferredTimescale: 600)
        let endCMT   = CMTime(seconds: bounds.end,   preferredTimescale: 600)

        if cycle {
            // HARD RULE: cycle mode never creates a looper. The video plays
            // exactly once from trimStart to trimEnd, then the boundary observer
            // or the end-notification safety net advances to the next video.
            if bounds.start > 0.005 {
                _ = await player.seek(
                    to: startCMT,
                    toleranceBefore: .zero,
                    toleranceAfter:  CMTime(seconds: 0.1, preferredTimescale: 600)
                )
            }
            if Task.isCancelled { return .none }
            applyImmediatePlaybackState(to: player)
            return bounds
        }

        // Non-cycle path with optional trim.
        if loop {
            // AVPlayerLooper gives reliable looping so the video never freezes
            // at item end. The boundary observer fires ~3 s before the end for
            // the smooth visual transition; the looper is the safety net.
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
        applyImmediatePlaybackState(to: player)
        return bounds
    }

    // MARK: – Private: single boundary observer (loop + cycle)

    private func armBoundaryObserver(player targetPlayer: AVQueuePlayer,
                                      bounds: ClipBounds,
                                      mode: PlaybackMode) {
        stopBoundaryObserver()
        guard bounds.length > 0 else { return }
        // Only arm when the mode still wants boundary transitions.
        guard mode == settings.playbackMode else { return }
        guard mode == .loop || mode == .cycle else { return }

        let crossfadeDur = min(3.0, bounds.length * 0.9)
        let triggerSec   = max(bounds.start, bounds.end - crossfadeDur)
        let interval     = CMTime(seconds: 0.25, preferredTimescale: 600)

        boundaryObserverPlayer = targetPlayer
        boundaryObserver = targetPlayer.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self,
                      time.seconds >= triggerSec,
                      !self.transitionInProgress
                else { return }
                // Fire-and-forget: work is owned by `transitionTask` inside.
                self.beginAutoTransition(mode: mode, crossfadeDuration: crossfadeDur)
            }
        }
    }

    private func stopBoundaryObserver() {
        if let obs = boundaryObserver {
            boundaryObserverPlayer?.removeTimeObserver(obs)
            boundaryObserver       = nil
            boundaryObserverPlayer = nil
        }
    }

    // MARK: – Private: unified crossfade transition

    /// Shared owner for every crossfade (user switch and cycle/loop auto).
    /// Cancels any prior transition Task and claims a new generation.
    private func scheduleCrossfade(to video: VideoItem,
                                    url: URL,
                                    updateIdentity: Bool,
                                    crossfadeDuration: Double) {
        transitionTask?.cancel()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        transitionInProgress = true
        transitionTask = Task { @MainActor [weak self] in
            await self?.performCrossfade(
                to: video,
                url: url,
                updateIdentity: updateIdentity,
                crossfadeDuration: crossfadeDuration,
                generation: generation
            )
        }
    }

    /// User-initiated switch while something is already playing.
    private func startCrossfade(to video: VideoItem, url: URL, updateIdentity: Bool) {
        scheduleCrossfade(
            to: video,
            url: url,
            updateIdentity: updateIdentity,
            crossfadeDuration: 3.0
        )
    }

    /// Automatic loop/cycle boundary — same cancellable Task as user switches.
    private func beginAutoTransition(mode: PlaybackMode, crossfadeDuration: Double) {
        guard !transitionInProgress else { return }
        guard let target = PlaybackPolicy.transitionTarget(
            mode: mode,
            current: currentVideo,
            library: library.videos
        ), let url = resolvedURL(for: target) else { return }

        scheduleCrossfade(
            to: target,
            url: url,
            updateIdentity: (mode == .cycle),
            crossfadeDuration: crossfadeDuration
        )
    }

    /// True while this crossfade generation is still the live owner.
    private func isTransitionCurrent(_ generation: UInt64) -> Bool {
        PlaybackPolicy.shouldContinueTransition(
            taskCancelled: Task.isCancelled,
            generation: generation,
            currentGeneration: transitionGeneration
        )
    }

    /// Releases the transition gate only if this generation is still current.
    private func endTransition(generation: UInt64) {
        guard generation == transitionGeneration else { return }
        transitionInProgress = false
        transitionTask = nil
    }

    /// Aborts a half-applied crossfade without clobbering a newer owner's player.
    private func abandonOutgoing(outPlayer: AVQueuePlayer?,
                                  outLooper: AVPlayerLooper?,
                                  newPlayer: AVQueuePlayer?) {
        outPlayer?.pause()
        outPlayer?.replaceCurrentItem(with: nil)
        _ = outLooper
        newPlayer?.pause()
        newPlayer?.replaceCurrentItem(with: nil)
        // Only clear manager state if we still own the active player reference.
        if player === newPlayer {
            player = nil
            wallpaperWindows.forEach { $0.clearPlayer() }
        }
    }

    /// Sole crossfade pipeline for user switches and automatic loop/cycle.
    /// Always runs on `transitionTask`. Aborts on cancel **or** stale generation
    /// (stop / delete / newer switch) so it cannot revive player or currentVideo.
    private func performCrossfade(to video: VideoItem,
                                   url: URL,
                                   updateIdentity: Bool,
                                   crossfadeDuration: Double,
                                   generation: UInt64) async {
        defer { endTransition(generation: generation) }

        guard isTransitionCurrent(generation) else { return }

        // Snapshot outgoing player before we reassign.
        let outPlayer = player
        let outLooper = looper

        setupTask?.cancel();    setupTask    = nil
        slowDownTask?.cancel(); slowDownTask = nil
        stopBoundaryObserver()

        if let obs = timeObserver {
            outPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
        looper = nil

        let (newPlayer, item, asset) = makePlayer(url: url)
        guard isTransitionCurrent(generation) else {
            newPlayer.pause()
            newPlayer.replaceCurrentItem(with: nil)
            return
        }

        player = newPlayer
        // Identity (cycle advance) is applied only after setup still owns the gate,
        // so stop/delete cannot be undone by a stale crossfade writing currentVideo.

        // Seek / resolution / trim setup before showing frames.
        let mode = settings.playbackMode
        let bounds = await setupLoopAndTrim(
            item:      item,
            player:    newPlayer,
            asset:     asset,
            trimStart: settings.trimStart,
            trimEnd:   settings.trimEnd,
            mode:      mode
        )

        guard isTransitionCurrent(generation) else {
            abandonOutgoing(outPlayer: outPlayer, outLooper: outLooper, newPlayer: newPlayer)
            return
        }

        if updateIdentity {
            currentVideo = video
            settings.selectedVideoID = video.id
        }

        // Pre-roll a brief decode window, then crossfade windows.
        try? await Task.sleep(for: .milliseconds(180))
        guard isTransitionCurrent(generation) else {
            abandonOutgoing(outPlayer: outPlayer, outLooper: outLooper, newPlayer: newPlayer)
            return
        }

        let peakBlur = CGFloat(settings.cycleBlurRadius)
        wallpaperWindows.forEach {
            $0.crossfade(to: newPlayer, duration: crossfadeDuration, peakBlur: peakBlur)
        }

        try? await Task.sleep(for: .seconds(crossfadeDuration + 0.15))

        guard isTransitionCurrent(generation) else {
            abandonOutgoing(outPlayer: outPlayer, outLooper: outLooper, newPlayer: newPlayer)
            return
        }

        outPlayer?.pause()
        outPlayer?.replaceCurrentItem(with: nil)
        _ = outLooper

        // Re-arm boundary observer for the new player; re-apply holds.
        reevaluateAutoPauseHolds()
        if !PlaybackPolicy.shouldPlay(
            hasCurrentVideo: currentVideo != nil,
            userPaused: userPaused,
            autoPauseReasons: autoPauseReasons
        ) {
            newPlayer.pause()
            isPlaying = false
        }

        guard isTransitionCurrent(generation) else { return }
        armBoundaryObserver(player: newPlayer, bounds: bounds, mode: mode)
    }

    // MARK: – Private: end-of-item safety net

    private func observePlaybackEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object:  nil,
            queue:   .main
        ) { [weak self] notification in
            let endedID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self,
                      !self.transitionInProgress,
                      let current = self.player?.currentItem,
                      ObjectIdentifier(current) == endedID
                else { return }
                // Safety net: the boundary observer should normally trigger the
                // crossfade before the item ends; if it misses, restart/advance.
                switch self.settings.playbackMode {
                case .cycle:
                    if let next = PlaybackPolicy.nextVideoForCycle(
                        current: self.currentVideo,
                        in: self.library.videos
                    ) {
                        self.play(video: next)
                    }
                case .loop:
                    if let video = self.currentVideo {
                        self.play(video: video)
                    }
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

        // Playback mode changes go through `setPlaybackMode` (replay once).

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
        applyCurrentSurface()
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
            Task { @MainActor [weak self] in
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

    // MARK: – Lock screen / screensaver overlay

    private func scheduleLockScreenInstall() {
        guard settings.playOnLockAndScreensaver,
              let aerials,
              let video = currentVideo,
              let url = resolvedURL(for: video)
        else { return }

        injectTask?.cancel()
        let name = video.name
        injectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let ok = await Task.detached {
                aerials.install(videoURL: url, displayName: name)
            }.value
            guard !Task.isCancelled else { return }
            self.nativeLockReady = ok
            if self.surface == .lockScreen {
                self.applyCurrentSurface()
            }
        }
    }

    private func applyCurrentSurface() {
        guard settings.playOnLockAndScreensaver else {
            wallpaperWindows.forEach { $0.applySurface(.desktop, hideOverlay: false) }
            resumeOverlayIfHeld()
            surfaceReassertTask?.cancel()
            surfaceReassertTask = nil
            return
        }

        let hide = WallpaperSurfacePolicy.shouldHideOverlay(
            surface: surface,
            nativeLockPlayback: nativeLockReady
        )
        wallpaperWindows.forEach { $0.applySurface(surface, hideOverlay: hide) }

        if hide {
            holdOverlayPlayerForNativeLock()
            surfaceReassertTask?.cancel()
            surfaceReassertTask = nil
        } else {
            resumeOverlayIfHeld()
            startSurfaceReassertIfNeeded()
        }
    }

    private func holdOverlayPlayerForNativeLock() {
        guard !overlayHeldForLock else { return }
        overlayHeldForLock = true
        player?.pause()
    }

    private func resumeOverlayIfHeld() {
        guard overlayHeldForLock else { return }
        overlayHeldForLock = false
        guard let player else { return }
        if PlaybackPolicy.shouldPlay(
            hasCurrentVideo: currentVideo != nil,
            userPaused: userPaused,
            autoPauseReasons: autoPauseReasons
        ) {
            player.play()
            isPlaying = true
        }
    }

    private func startSurfaceReassertIfNeeded() {
        guard surface != .desktop, surfaceReassertTask == nil else { return }
        surfaceReassertTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard self.surface != .desktop,
                      self.settings.playOnLockAndScreensaver
                else {
                    self.surfaceReassertTask = nil
                    return
                }
                let hide = WallpaperSurfacePolicy.shouldHideOverlay(
                    surface: self.surface,
                    nativeLockPlayback: self.nativeLockReady
                )
                self.wallpaperWindows.forEach {
                    $0.applySurface(self.surface, hideOverlay: hide)
                }
            }
        }
    }

    // MARK: – Private: auto-pause reasons

    /// Adds or removes a single auto-pause reason and reconciles playback.
    /// Each monitor only ever touches its own reason, so they can't override
    /// one another (e.g. a recording ending won't resume playback on battery).
    private func setAutoPause(_ reason: PauseReason, active: Bool) {
        let next = PlaybackPolicy.applying(reason: reason, active: active, to: autoPauseReasons)
        guard next != autoPauseReasons else { return }
        autoPauseReasons = next
        reconcilePlayback()
    }

    // MARK: - Test / diagnostics introspection (@testable)

    /// Number of live desktop wallpaper windows (one per screen after `setup()`).
    var debugWindowCount: Int { wallpaperWindows.count }

    /// Live wallpaper windows (for desktop-level / frame assertions in tests).
    var debugWallpaperWindows: [WallpaperWindow] { wallpaperWindows }

    /// Whether an AVQueuePlayer is currently owned by the manager.
    var debugHasActivePlayer: Bool { player != nil }

    /// Whether a user or auto crossfade currently owns the transition gate.
    var debugTransitionInProgress: Bool { transitionInProgress }

    /// Active auto-pause holds (battery / recording).
    var debugAutoPauseReasons: Set<PauseReason> { autoPauseReasons }

    /// Applies a hold the same way monitors do (for integration tests).
    func debugSetAutoPause(_ reason: PauseReason, active: Bool) {
        setAutoPause(reason, active: active)
    }

    /// Current overlay surface (desktop / screensaver / lock).
    var debugSurface: WallpaperSurface { surface }

    var debugNativeLockReady: Bool { nativeLockReady }

    func debugSimulateLock(_ locked: Bool) {
        surfaceMonitor.debugApply(locked: locked)
    }

    func debugSimulateScreensaver(_ active: Bool) {
        surfaceMonitor.debugApply(screensaver: active)
    }

    func debugSetNativeLockReady(_ ready: Bool) {
        nativeLockReady = ready
        applyCurrentSurface()
    }
}
