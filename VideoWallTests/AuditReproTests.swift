import XCTest
import AppKit
import AVFoundation
@testable import VideoWall

// MARK: - Verification-first audit repros
//
// Each test is a runtime demonstration of a suspected product bug.
// Failures here are the evidence; passing tests are not reported.

@MainActor
final class AuditReproTests: XCTestCase {

    private var tempRoot: URL!
    private var sampleURL: URL!
    private var settings: AppSettings!
    private var library: VideoLibraryManager!
    private var wallpaper: WallpaperManager!
    private var didSetup = false
    private var defaultsSnapshot = UserDefaultsSnapshot()

    override func setUp() async throws {
        try await super.setUp()
        defaultsSnapshot.capture()

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoWallAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        sampleURL = tempRoot.appendingPathComponent("base.mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: sampleURL, durationSeconds: 1.5)

        settings = AppSettings()
        settings.pauseOnBattery = false
        settings.pauseOnScreenRecording = false
        settings.playbackMode = .loop
        settings.resolution = .original
        settings.trimStart = 0
        settings.trimEnd = 1
        settings.playbackRate = 1

        library = VideoLibraryManager(applicationSupportRoot: tempRoot)
        wallpaper = WallpaperManager(settings: settings, library: library)
        library.onVideosRemoved = { [weak wallpaper] ids in
            wallpaper?.handleVideosRemoved(ids)
        }
    }

    override func tearDown() async throws {
        if didSetup { wallpaper.teardown(); didSetup = false }
        else { wallpaper.stop() }
        library.stopWatching()
        try? FileManager.default.removeItem(at: tempRoot)
        defaultsSnapshot.restore()
        try await super.tearDown()
    }


    private func runSetup() {
        wallpaper.setup()
        didSetup = true
    }

    // MARK: Cycle with a single clip (fixed: loops instead of freezing)

    func testCycleWithOneClipLoopsInsteadOfFreezing() async throws {
        runSetup()
        settings.playbackMode = .cycle
        let video = try await importClip(named: "solo.mp4")
        wallpaper.play(video: video)

        let playDeadline = Date().addingTimeInterval(5)
        while Date() < playDeadline, !wallpaper.debugHasActivePlayer {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertTrue(wallpaper.debugHasActivePlayer)
        XCTAssertEqual(settings.playbackMode, .cycle)

        // Clip is ~1.5s. A 1-item library has no next video, so the manager
        // installs a looper instead of parking on the last frame.
        try await Task.sleep(for: .seconds(3.2))

        XCTAssertTrue(wallpaper.debugHasLooper,
                      "single-clip cycle must loop, not freeze at item end")
        XCTAssertEqual(wallpaper.currentVideo?.id, video.id)
        XCTAssertTrue(wallpaper.isPlaying, "playback must survive past the clip end")
        XCTAssertTrue(wallpaper.debugHasActivePlayer)
    }

    // MARK: 5× with a too-short trim (fixed: cap is surfaced, not silent)

    func testHighRateWithShortTrimPlaysCappedAndFlagsTheCap() async throws {
        runSetup()
        settings.playbackMode = .loop
        let video = try await importClip(named: "a.mp4")
        wallpaper.play(video: video)

        let playDeadline = Date().addingTimeInterval(5)
        while Date() < playDeadline, !wallpaper.isPlaying {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertTrue(wallpaper.isPlaying)
        XCTAssertTrue(wallpaper.debugHasBoundaryObserver,
                      "loop play must arm the boundary observer")
        XCTAssertLessThan(wallpaper.debugCompositionSpeedup, 1.01)
        XCTAssertFalse(wallpaper.debugIsPlaybackRateCapped)

        // Minimum DualRangeSlider span is 0.05. On a 1.5s clip that is 0.075s,
        // below the 0.15s composition threshold.
        settings.trimStart = 0
        settings.trimEnd = 0.05
        wallpaper.setPlaybackRate(5)

        let swapDeadline = Date().addingTimeInterval(8)
        while Date() < swapDeadline, wallpaper.debugRateSwapInFlight {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertFalse(wallpaper.debugRateSwapInFlight)
        XCTAssertEqual(settings.playbackRate, 5, accuracy: 0.01)
        XCTAssertLessThan(wallpaper.debugCompositionSpeedup, 1.01)
        XCTAssertEqual(
            wallpaper.debugPlayerRate, 2,
            accuracy: 0.15,
            "short trim cannot scale; 5× falls back to native capped at 2×"
        )
        XCTAssertTrue(
            wallpaper.debugIsPlaybackRateCapped,
            "the 2× fallback must be surfaced, not silent"
        )
        XCTAssertTrue(
            wallpaper.debugHasBoundaryObserver,
            "speed change must not drop the loop boundary observer"
        )
    }

    // MARK: M1 — superseded crossfade must not kill the live player

    func testRapidSwitchDuringCrossfadeKeepsPlaybackAlive() async throws {
        runSetup()
        let a = try await importClip(named: "m1a.mp4", durationSeconds: 8)
        let b = try await importClip(named: "m1b.mp4", durationSeconds: 8)
        let c = try await importClip(named: "m1c.mp4", durationSeconds: 8)

        wallpaper.play(video: a)
        try await waitForPlaying()

        // B's crossfade adopts its player early, then sleeps for the fade.
        wallpaper.play(video: b)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(wallpaper.debugHasActivePlayer)

        // Supersede mid-fade. The old behavior paused/emptied B's player and
        // cleared the windows — a blank wallpaper until C finished building.
        wallpaper.play(video: c)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(wallpaper.debugHasActivePlayer,
                      "superseding a crossfade must not blank the live player")
        XCTAssertTrue(wallpaper.isPlaying)

        // C's fade completes and playback continues on C.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, wallpaper.debugTransitionInProgress {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(wallpaper.debugTransitionInProgress)
        XCTAssertTrue(wallpaper.debugHasActivePlayer)
        XCTAssertTrue(wallpaper.isPlaying)
        XCTAssertEqual(wallpaper.currentVideo?.id, c.id)
    }

    func testSpeedSwapDuringCrossfadeDoesNotKillPlayback() async throws {
        runSetup()
        let a = try await importClip(named: "m1d.mp4", durationSeconds: 8)
        let b = try await importClip(named: "m1e.mp4", durationSeconds: 8)

        wallpaper.play(video: a)
        try await waitForPlaying()

        wallpaper.play(video: b)
        try await Task.sleep(for: .milliseconds(400))

        // The speed swap cancels B's in-flight crossfade. The old behavior let
        // the cancelled task destroy B (the adopted live player), then the
        // swap's restore guard saw a cleared player and gave up — dead
        // wallpaper with the UI still saying "Playing".
        wallpaper.setPlaybackRate(5)
        let swapDeadline = Date().addingTimeInterval(10)
        while Date() < swapDeadline, wallpaper.debugRateSwapInFlight {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(wallpaper.debugRateSwapInFlight)
        XCTAssertTrue(wallpaper.debugHasActivePlayer,
                      "speed swap during a crossfade must leave a live player")
        XCTAssertTrue(wallpaper.isPlaying,
                      "playback must still be running after the swap")
        XCTAssertEqual(wallpaper.debugCompositionSpeedup, 5, accuracy: 0.01)
    }

    // MARK: M2 — trim changes apply to the live clip

    func testTrimChangeWhilePlayingReappliesToLivePlayer() async throws {
        runSetup()
        let video = try await importClip(named: "m2.mp4", durationSeconds: 8)
        wallpaper.play(video: video)
        try await waitForPlaying()
        let before = wallpaper.debugTrimReapplies

        settings.trimStart = 0.25
        settings.trimEnd = 0.75

        // Debounced 450ms, then a replay of the current video.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, wallpaper.debugTrimReapplies == before {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertGreaterThan(wallpaper.debugTrimReapplies, before,
                             "trim change while playing must re-apply to the live clip")
        XCTAssertEqual(wallpaper.currentVideo?.id, video.id)
        XCTAssertTrue(wallpaper.isPlaying || wallpaper.debugHasActivePlayer)
    }

    // MARK: Finder-deleted files (fixed: watcher reconciles deletions)

    func testDeletingFileOnDiskReconcilesLibraryInSession() async throws {
        let video = try await importClip(named: "ghost.mp4")
        let fileURL = library.url(for: video)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try FileManager.default.removeItem(at: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // The directory watcher coalesces 500ms, then scans.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !library.videos.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(library.videos.isEmpty,
                      "a Finder-deleted file must leave the library in-session")

        wallpaper.play(video: video)
        XCTAssertNil(
            wallpaper.currentVideo,
            "play() silently no-ops on a missing file and never reports an error"
        )
        XCTAssertFalse(wallpaper.debugHasActivePlayer)
    }

    // MARK: Extensionless filename collision (fixed: no trailing dot)

    func testExtensionlessImportCollisionProducesCleanFilename() async throws {
        let first = tempRoot.appendingPathComponent("noext")
        let secondSource = tempRoot.appendingPathComponent("otherdir", isDirectory: true)
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        let second = secondSource.appendingPathComponent("noext")
        try FileManager.default.copyItem(at: sampleURL, to: first)
        try FileManager.default.copyItem(at: sampleURL, to: second)

        let a = try await importFrom(first)
        XCTAssertEqual(a.filename, "noext")

        let b = try await importFrom(second)
        XCTAssertEqual(
            b.filename, "noext_1",
            "uniqueDestURL must not interpolate an empty extension as a trailing dot"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: library.url(for: b).path),
            "the collision-renamed file must actually exist on disk"
        )
    }

    // MARK: Test host writes production UserDefaults

    func testAppSettingsMutationsWriteProductionSuite() {
        XCTAssertEqual(
            Bundle.main.bundleIdentifier,
            "com.maxkongerskov.videowall",
            "VideoWallTests is hosted by the production app"
        )
        settings.playbackMode = .cycle
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "playbackMode"),
            PlaybackMode.cycle.rawValue
        )
        settings.pauseOnBattery = true
        XCTAssertEqual(UserDefaults.standard.object(forKey: "pauseOnBattery") as? Bool, true)
    }

    // MARK: Helpers

    private func importClip(named: String, durationSeconds: Double = 1.5) async throws -> VideoItem {
        let source = tempRoot.appendingPathComponent("src-\(named)")
        if !FileManager.default.fileExists(atPath: source.path) {
            if abs(durationSeconds - 1.5) < 0.01 {
                try FileManager.default.copyItem(at: sampleURL, to: source)
            } else {
                try WallpaperIntegrationTests.renderTinyMP4(to: source, durationSeconds: durationSeconds)
            }
        }
        return try await importFrom(source)
    }

    @discardableResult
    private func waitForPlaying(timeout: TimeInterval = 5) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !wallpaper.isPlaying {
            try await Task.sleep(for: .milliseconds(40))
        }
        return wallpaper.isPlaying
    }

    private func importFrom(_ url: URL) async throws -> VideoItem {
        let before = Set(library.videos.map(\.id))
        library.importVideo(from: url)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let item = library.videos.first(where: { !before.contains($0.id) }) {
                return item
            }
            if let err = library.importError {
                XCTFail(err)
                throw NSError(domain: "AuditRepro", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: err
                ])
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw NSError(domain: "AuditRepro", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "import timeout \(url.lastPathComponent)"
        ])
    }
}
