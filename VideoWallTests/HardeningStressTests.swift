import XCTest
import AppKit
import CoreGraphics
import AVFoundation
@testable import VideoWall

// MARK: - Hardening toward ship confidence
//
// Stress races, desktop window contracts, recording-indicator pure detection,
// screen-parameter storms, directory-watcher coalescing, and sustained play.

@MainActor
final class HardeningStressTests: XCTestCase {

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
            .appendingPathComponent("VideoWallHard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        sampleURL = tempRoot.appendingPathComponent("base.mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: sampleURL, durationSeconds: 1.5)

        settings = AppSettings()
        settings.pauseOnBattery = false
        settings.pauseOnScreenRecording = false
        settings.playbackMode = .loop
        settings.resolution = .original
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

    // MARK: Desktop window contract (Mission Control / click-through)

    func testDesktopWindowsMatchScreenGeometryAndLevel() async throws {
        runSetup()
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow)) + 1
        let screens = NSScreen.screens
        XCTAssertEqual(wallpaper.debugWindowCount, screens.count)

        for (win, screen) in zip(wallpaper.debugWallpaperWindows, screens) {
            XCTAssertEqual(win.window.level.rawValue, desktopLevel,
                           "wallpaper must sit just above desktop level")
            XCTAssertTrue(win.window.ignoresMouseEvents,
                          "must not steal clicks from icons/desktop")
            XCTAssertFalse(win.window.isOpaque)
            XCTAssertEqual(win.window.appearance?.name, .darkAqua)
            XCTAssertTrue(win.window.contentView is WallpaperHostView)
            XCTAssertTrue(win.window is DesktopFillWindow)
            assertFramesNearlyEqual(win.window.frame, screen.frame)
            assertFramesNearlyEqual(
                win.window.constrainFrameRect(screen.frame, to: screen),
                screen.frame
            )
            XCTAssertTrue(win.window.collectionBehavior.contains(.stationary))
            XCTAssertTrue(win.window.collectionBehavior.contains(.ignoresCycle))
            XCTAssertTrue(win.window.canBecomeVisibleWithoutLogin,
                          "lock/login screen eligibility")
            XCTAssertFalse(win.window.canHide)
            XCTAssertFalse(win.window.hidesOnDeactivate)
        }
    }

    func testPlayKeepsDesktopLevelAndClickThrough() async throws {
        runSetup()
        let video = try await importClip("a.mp4")
        wallpaper.play(video: video)
        try await Task.sleep(for: .milliseconds(500))

        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow)) + 1
        for win in wallpaper.debugWallpaperWindows {
            XCTAssertEqual(win.window.level.rawValue, desktopLevel)
            XCTAssertTrue(win.window.ignoresMouseEvents)
            XCTAssertTrue(win.window.isOpaque,
                          "playing wallpaper must be opaque so menu-bar glass does not frost white")
            XCTAssertEqual(win.window.backgroundColor, .black)
        }
        XCTAssertTrue(wallpaper.debugHasActivePlayer)
    }

    func testStopRestoresTransparentWallpaperChrome() async throws {
        runSetup()
        let video = try await importClip("idle.mp4")
        wallpaper.play(video: video)
        try await Task.sleep(for: .milliseconds(500))
        wallpaper.stop()
        for win in wallpaper.debugWallpaperWindows {
            XCTAssertFalse(win.window.isOpaque)
            XCTAssertEqual(win.window.backgroundColor, .clear)
        }
    }

    func testScreensaverRaisesWindowAboveDesktopLevel() async throws {
        runSetup()
        settings.playOnLockAndScreensaver = true
        let desktopLevel = WallpaperSurfacePolicy.windowLevel(for: .desktop)
        let saverLevel   = WallpaperSurfacePolicy.windowLevel(for: .screensaver)

        wallpaper.debugSimulateScreensaver(true)
        XCTAssertEqual(wallpaper.debugSurface, .screensaver)
        for win in wallpaper.debugWallpaperWindows {
            XCTAssertEqual(win.window.level.rawValue, saverLevel)
        }

        wallpaper.debugSimulateScreensaver(false)
        XCTAssertEqual(wallpaper.debugSurface, .desktop)
        for win in wallpaper.debugWallpaperWindows {
            XCTAssertEqual(win.window.level.rawValue, desktopLevel)
        }
    }

    func testLockWithoutNativePlaybackRaisesOverlay() async throws {
        runSetup()
        settings.playOnLockAndScreensaver = true
        wallpaper.debugSetNativeLockReady(false)
        wallpaper.debugSimulateLock(true)
        XCTAssertEqual(wallpaper.debugSurface, .lockScreen)
        let saverLevel = WallpaperSurfacePolicy.windowLevel(for: .lockScreen)
        for win in wallpaper.debugWallpaperWindows {
            XCTAssertEqual(win.window.level.rawValue, saverLevel)
        }
        wallpaper.debugSimulateLock(false)
        XCTAssertEqual(wallpaper.debugSurface, .desktop)
    }

    func testLockWithNativePlaybackHidesOverlay() async throws {
        runSetup()
        settings.playOnLockAndScreensaver = true
        wallpaper.debugSimulateLock(true)
        wallpaper.debugSetNativeLockReady(true)
        XCTAssertTrue(
            WallpaperSurfacePolicy.shouldHideOverlay(
                surface: wallpaper.debugSurface,
                nativeLockPlayback: wallpaper.debugNativeLockReady
            )
        )
        wallpaper.debugSetNativeLockReady(false)
        wallpaper.debugSimulateLock(false)
    }

    func testLockSettingOffForcesDesktopLevel() async throws {
        runSetup()
        wallpaper.debugSimulateScreensaver(true)
        XCTAssertEqual(wallpaper.debugSurface, .screensaver)
        wallpaper.setPlayOnLockAndScreensaver(false)
        let desktopLevel = WallpaperSurfacePolicy.windowLevel(for: .desktop)
        for win in wallpaper.debugWallpaperWindows {
            XCTAssertEqual(win.window.level.rawValue, desktopLevel)
        }
        wallpaper.setPlayOnLockAndScreensaver(true)
        wallpaper.debugSimulateScreensaver(false)
    }

    // MARK: Screen-parameter storm (spurious macOS notifications)

    func testScreenParameterStormDoesNotDropPlayer() async throws {
        runSetup()
        let video = try await importClip("a.mp4")
        wallpaper.play(video: video)
        try await Task.sleep(for: .milliseconds(400))
        let id = video.id

        for _ in 0..<12 {
            NotificationCenter.default.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
        }
        // Coalesce delay is 300ms — wait past it
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(wallpaper.currentVideo?.id, id)
        XCTAssertEqual(wallpaper.debugWindowCount, NSScreen.screens.count)
        // Player may be recreated on real geometry change; identity must hold
        XCTAssertNotNil(wallpaper.currentVideo)
    }

    // MARK: Transition race stress

    func testRapidAlternatingPlayStopDoesNotLeaveStuckState() async throws {
        runSetup()
        let a = try await importClip("a.mp4")
        let b = try await importClip("b.mp4")

        for i in 0..<16 {
            wallpaper.play(video: i % 2 == 0 ? a : b)
            if i % 3 == 0 {
                wallpaper.stop()
            } else if i % 5 == 0 {
                wallpaper.debugSetAutoPause(.battery, active: true)
                wallpaper.debugSetAutoPause(.battery, active: false)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        wallpaper.stop()
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertNil(wallpaper.currentVideo)
        XCTAssertFalse(wallpaper.isPlaying)
        XCTAssertFalse(wallpaper.debugHasActivePlayer)
        XCTAssertFalse(wallpaper.debugTransitionInProgress)
    }

    func testBurstCrossfadeThenDeleteAll() async throws {
        runSetup()
        let a = try await importClip("a.mp4")
        let b = try await importClip("b.mp4")
        let c = try await importClip("c.mp4")

        wallpaper.play(video: a)
        try await Task.sleep(for: .milliseconds(200))
        wallpaper.play(video: b)
        wallpaper.play(video: c)
        wallpaper.play(video: a)
        try await Task.sleep(for: .milliseconds(80))
        library.deleteAll()
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertNil(wallpaper.currentVideo)
        XCTAssertFalse(wallpaper.isPlaying)
        XCTAssertFalse(wallpaper.debugTransitionInProgress)
        XCTAssertTrue(library.videos.isEmpty)
    }

    // MARK: Sustained play

    func testSustainedPlayTwoSecondsStaysOwned() async throws {
        runSetup()
        // Longer clip so a 2s wait is not always mid loop-crossfade.
        let longURL = tempRoot.appendingPathComponent("long.mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: longURL, durationSeconds: 5.0)
        let before = Set(library.videos.map(\.id))
        library.importVideo(from: longURL)
        var video: VideoItem!
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let item = library.videos.first(where: { !before.contains($0.id) }) {
                video = item
                break
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertNotNil(video)

        wallpaper.play(video: video)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(wallpaper.debugHasActivePlayer)

        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(wallpaper.currentVideo?.id, video.id)
        // Still owned: active player, or a legitimate in-flight loop self-crossfade.
        XCTAssertTrue(
            wallpaper.debugHasActivePlayer || wallpaper.debugTransitionInProgress,
            "playback must still own a player or an in-progress transition after 2s"
        )
        XCTAssertFalse(wallpaper.debugAutoPauseReasons.contains(.battery))
    }

    func testTogglePlayPauseWhilePlaying() async throws {
        runSetup()
        let video = try await importClip("a.mp4")
        wallpaper.play(video: video)
        try await Task.sleep(for: .milliseconds(400))

        wallpaper.togglePlayPause()
        XCTAssertFalse(wallpaper.isPlaying)

        wallpaper.togglePlayPause()
        try await Task.sleep(for: .milliseconds(200))
        // Resume may ramp; allow either playing or player present
        XCTAssertTrue(wallpaper.isPlaying || wallpaper.debugHasActivePlayer)
    }

    // MARK: Recording indicator pure policy

    func testRecordingDetectionRecognizesControlCenterIndicator() {
        let ownerKey = kCGWindowOwnerName as String
        let nameKey = kCGWindowName as String

        let positive: [[String: Any]] = [
            [ownerKey: "Safari", nameKey: "Home"],
            [ownerKey: "Control Center", nameKey: "StatusIndicator"]
        ]
        XCTAssertTrue(ScreenRecordingDetection.isRecordingIndicatorPresent(in: positive))

        let alt: [[String: Any]] = [
            [ownerKey: "Control Center", nameKey: "Screen Recording"]
        ]
        XCTAssertTrue(ScreenRecordingDetection.isRecordingIndicatorPresent(in: alt))

        let negative: [[String: Any]] = [
            [ownerKey: "Control Center", nameKey: "Wi‑Fi"],
            [ownerKey: "Finder", nameKey: "Desktop"]
        ]
        XCTAssertFalse(ScreenRecordingDetection.isRecordingIndicatorPresent(in: negative))

        XCTAssertFalse(ScreenRecordingDetection.isRecordingIndicatorPresent(in: []))
    }

    func testRecordingHoldViaMonitorCallbackPath() async throws {
        runSetup()
        let video = try await importClip("a.mp4")
        wallpaper.play(video: video)
        try await Task.sleep(for: .milliseconds(350))

        // Simulate what ScreenRecordingMonitor would report when recording starts
        wallpaper.debugSetAutoPause(.recording, active: true)
        XCTAssertFalse(wallpaper.isPlaying)
        XCTAssertTrue(wallpaper.debugAutoPauseReasons.contains(.recording))

        wallpaper.debugSetAutoPause(.recording, active: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(wallpaper.isPlaying)
    }

    // MARK: Directory watcher coalescing

    func testDirectoryWatcherPicksUpDroppedFile() async throws {
        // Library already watches tempRoot/VideoWall/Library
        let dest = library.libraryFolderURL.appendingPathComponent("dropped_from_finder.mp4")
        try FileManager.default.copyItem(at: sampleURL, to: dest)

        let deadline = Date().addingTimeInterval(6)
        var found = false
        while Date() < deadline {
            if library.videos.contains(where: { $0.filename == "dropped_from_finder.mp4" }) {
                found = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(found, "directory watcher must import files added outside the app")
    }

    func testDirectoryWatcherBurstDoesNotDuplicate() async throws {
        for i in 0..<5 {
            let dest = library.libraryFolderURL.appendingPathComponent("burst_\(i).mp4")
            try FileManager.default.copyItem(at: sampleURL, to: dest)
        }
        try await Task.sleep(for: .seconds(2.5))

        let burst = library.videos.filter { $0.filename.hasPrefix("burst_") }
        let names = burst.map(\.filename)
        XCTAssertEqual(Set(names).count, names.count, "no duplicate filenames in library")
        XCTAssertEqual(burst.count, 5)
    }

    // MARK: Cycle mode next-video policy under real library

    func testCycleModePlaySwitchDoesNotCrash() async throws {
        runSetup()
        settings.playbackMode = .cycle
        let a = try await importClip("a.mp4")
        let b = try await importClip("b.mp4")
        wallpaper.play(video: a)
        try await Task.sleep(for: .milliseconds(300))
        wallpaper.play(video: b)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(wallpaper.currentVideo?.id, b.id)
        XCTAssertEqual(settings.playbackMode, .cycle)
    }

    // MARK: Helpers

    private func importClip(_ name: String) async throws -> VideoItem {
        let source = tempRoot.appendingPathComponent("src-\(name)")
        if !FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: sampleURL, to: source)
        }
        let before = Set(library.videos.map(\.id))
        library.importVideo(from: source)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let item = library.videos.first(where: { !before.contains($0.id) }) {
                return item
            }
            if let err = library.importError {
                throw NSError(domain: "HardIT", code: 1, userInfo: [NSLocalizedDescriptionKey: err])
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw NSError(domain: "HardIT", code: 2)
    }
}

private func assertFramesNearlyEqual(_ a: CGRect, _ b: CGRect,
                                     file: StaticString = #filePath, line: UInt = #line) {
    let accuracy: CGFloat = 1.0
    XCTAssertEqual(a.origin.x, b.origin.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.origin.y, b.origin.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.size.width, b.size.width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.size.height, b.size.height, accuracy: accuracy, file: file, line: line)
}
