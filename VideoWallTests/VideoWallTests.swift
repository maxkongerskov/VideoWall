import XCTest
import CoreGraphics
import AVFoundation
@testable import VideoWall

// MARK: - ClipBounds

final class ClipBoundsTests: XCTestCase {

    func testZeroDurationIsNone() {
        let b = ClipBounds.compute(total: 0, trimStart: 0, trimEnd: 1)
        XCTAssertEqual(b.start, 0)
        XCTAssertEqual(b.end, 0)
        XCTAssertEqual(b.length, 0)
    }

    func testFullClip() {
        let b = ClipBounds.compute(total: 100, trimStart: 0, trimEnd: 1)
        XCTAssertEqual(b.start, 0, accuracy: 0.0001)
        XCTAssertEqual(b.end, 100, accuracy: 0.0001)
        XCTAssertEqual(b.length, 100, accuracy: 0.0001)
    }

    func testTrimmedEnd() {
        let b = ClipBounds.compute(total: 100, trimStart: 0.5, trimEnd: 1.0)
        XCTAssertEqual(b.start, 50, accuracy: 0.0001)
        XCTAssertEqual(b.end, 100, accuracy: 0.0001)
        XCTAssertEqual(b.length, 50, accuracy: 0.0001)
    }

    /// The trim+crossfade fix: a clip trimmed to start late must report its
    /// real (short) length, not the absolute end timestamp.
    func testTrimmedStartReportsClipLengthNotAbsoluteEnd() {
        let b = ClipBounds.compute(total: 100, trimStart: 0.5, trimEnd: 0.6)
        XCTAssertEqual(b.start, 50, accuracy: 0.0001)
        XCTAssertEqual(b.end, 60, accuracy: 0.0001)
        XCTAssertEqual(b.length, 10, accuracy: 0.0001)
    }

    func testInvertedTrimClampsToZeroLength() {
        let b = ClipBounds.compute(total: 100, trimStart: 0.8, trimEnd: 0.2)
        XCTAssertGreaterThanOrEqual(b.length, 0, "length must never go negative")
        XCTAssertEqual(b.length, 0, accuracy: 0.0001)
    }
}

// MARK: - VideoItem

final class VideoItemTests: XCTestCase {

    private func item(duration: TimeInterval) -> VideoItem {
        VideoItem(id: UUID(), name: "clip", filename: "clip.mp4",
                  duration: duration, thumbnailData: nil)
    }

    func testDurationStringUnderAnHour() {
        XCTAssertEqual(item(duration: 65).durationString, "1:05")
        XCTAssertEqual(item(duration: 0).durationString, "0:00")
    }

    func testDurationStringOverAnHour() {
        XCTAssertEqual(item(duration: 3661).durationString, "1:01:01")
    }

    func testDurationStringHandlesNonFinite() {
        XCTAssertEqual(item(duration: .nan).durationString, "0:00")
        XCTAssertEqual(item(duration: -5).durationString, "0:00")
    }

    func testSupportedExtensions() {
        XCTAssertTrue(VideoItem.supportedExtensions.contains("mp4"))
        XCTAssertTrue(VideoItem.supportedExtensions.contains("mov"))
        XCTAssertFalse(VideoItem.supportedExtensions.contains("txt"))
    }

    func testEqualityIsByID() {
        let id = UUID()
        let a = VideoItem(id: id, name: "A", filename: "a.mp4", duration: 1, thumbnailData: nil)
        let b = VideoItem(id: id, name: "B (renamed)", filename: "a.mp4", duration: 1, thumbnailData: nil)
        XCTAssertEqual(a, b, "items with the same id are equal regardless of name")
    }
}

// MARK: - VideoResolution

final class VideoResolutionTests: XCTestCase {

    func testOriginalHasNoRenderSize() {
        XCTAssertNil(VideoResolution.original.renderSize)
    }

    func testFixedRenderSizes() {
        XCTAssertEqual(VideoResolution.hd720.renderSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(VideoResolution.fhd1080.renderSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(VideoResolution.uhd4k.renderSize, CGSize(width: 3840, height: 2160))
    }

    func testRawValueRoundTrips() {
        for res in VideoResolution.allCases {
            XCTAssertEqual(VideoResolution(rawValue: res.rawValue), res)
        }
    }
}

// MARK: - PlaybackPolicy (pause reconcile + cycle selection)

final class PlaybackPolicyTests: XCTestCase {

    func testShouldPlayRequiresCurrentVideoAndNoHolds() {
        XCTAssertFalse(PlaybackPolicy.shouldPlay(
            hasCurrentVideo: false, userPaused: false, autoPauseReasons: []))
        XCTAssertFalse(PlaybackPolicy.shouldPlay(
            hasCurrentVideo: true, userPaused: true, autoPauseReasons: []))
        XCTAssertFalse(PlaybackPolicy.shouldPlay(
            hasCurrentVideo: true, userPaused: false, autoPauseReasons: [.battery]))
        XCTAssertFalse(PlaybackPolicy.shouldPlay(
            hasCurrentVideo: true, userPaused: false, autoPauseReasons: [.recording]))
        XCTAssertTrue(PlaybackPolicy.shouldPlay(
            hasCurrentVideo: true, userPaused: false, autoPauseReasons: []))
    }

    func testShouldPlayWithMultipleHolds() {
        let both: Set<PauseReason> = [.battery, .recording]
        XCTAssertFalse(PlaybackPolicy.shouldPlay(
            hasCurrentVideo: true, userPaused: false, autoPauseReasons: both))
        // Clearing one hold is not enough if the other remains.
        let onlyBattery = PlaybackPolicy.applying(reason: .recording, active: false, to: both)
        XCTAssertEqual(onlyBattery, [.battery])
        XCTAssertFalse(PlaybackPolicy.shouldPlay(
            hasCurrentVideo: true, userPaused: false, autoPauseReasons: onlyBattery))
    }

    func testApplyingPauseReasonInsertAndRemove() {
        var reasons: Set<PauseReason> = []
        reasons = PlaybackPolicy.applying(reason: .battery, active: true, to: reasons)
        XCTAssertEqual(reasons, [.battery])
        reasons = PlaybackPolicy.applying(reason: .recording, active: true, to: reasons)
        XCTAssertEqual(reasons, [.battery, .recording])
        reasons = PlaybackPolicy.applying(reason: .battery, active: false, to: reasons)
        XCTAssertEqual(reasons, [.recording])
        // Idempotent remove
        reasons = PlaybackPolicy.applying(reason: .battery, active: false, to: reasons)
        XCTAssertEqual(reasons, [.recording])
    }

    func testNextVideoForCycleWrapsAndRequiresTwoItems() {
        let a = VideoItem(id: UUID(), name: "A", filename: "a.mp4", duration: 1, thumbnailData: nil)
        let b = VideoItem(id: UUID(), name: "B", filename: "b.mp4", duration: 1, thumbnailData: nil)
        let c = VideoItem(id: UUID(), name: "C", filename: "c.mp4", duration: 1, thumbnailData: nil)

        XCTAssertNil(PlaybackPolicy.nextVideoForCycle(current: a, in: []))
        XCTAssertNil(PlaybackPolicy.nextVideoForCycle(current: a, in: [a]))

        XCTAssertEqual(PlaybackPolicy.nextVideoForCycle(current: a, in: [a, b])?.id, b.id)
        XCTAssertEqual(PlaybackPolicy.nextVideoForCycle(current: b, in: [a, b])?.id, a.id)
        XCTAssertEqual(PlaybackPolicy.nextVideoForCycle(current: b, in: [a, b, c])?.id, c.id)
        XCTAssertEqual(PlaybackPolicy.nextVideoForCycle(current: c, in: [a, b, c])?.id, a.id)
    }

    func testNextVideoForCycleWithUnknownCurrentReturnsFirst() {
        let a = VideoItem(id: UUID(), name: "A", filename: "a.mp4", duration: 1, thumbnailData: nil)
        let b = VideoItem(id: UUID(), name: "B", filename: "b.mp4", duration: 1, thumbnailData: nil)
        let orphan = VideoItem(id: UUID(), name: "X", filename: "x.mp4", duration: 1, thumbnailData: nil)
        XCTAssertEqual(PlaybackPolicy.nextVideoForCycle(current: orphan, in: [a, b])?.id, a.id)
        XCTAssertEqual(PlaybackPolicy.nextVideoForCycle(current: nil, in: [a, b])?.id, a.id)
    }

    func testTransitionTargetLoopVsCycle() {
        let a = VideoItem(id: UUID(), name: "A", filename: "a.mp4", duration: 1, thumbnailData: nil)
        let b = VideoItem(id: UUID(), name: "B", filename: "b.mp4", duration: 1, thumbnailData: nil)
        XCTAssertEqual(
            PlaybackPolicy.transitionTarget(mode: .loop, current: a, library: [a, b])?.id,
            a.id
        )
        XCTAssertEqual(
            PlaybackPolicy.transitionTarget(mode: .cycle, current: a, library: [a, b])?.id,
            b.id
        )
    }

    func testShouldContinueTransitionRequiresLiveGenerationAndNotCancelled() {
        XCTAssertTrue(PlaybackPolicy.shouldContinueTransition(
            taskCancelled: false, generation: 3, currentGeneration: 3))
        // stop()/newer schedule bumps generation → stale owner must abort
        XCTAssertFalse(PlaybackPolicy.shouldContinueTransition(
            taskCancelled: false, generation: 3, currentGeneration: 4))
        // Task.cancel() alone must abort even if generation still matches
        XCTAssertFalse(PlaybackPolicy.shouldContinueTransition(
            taskCancelled: true, generation: 3, currentGeneration: 3))
        XCTAssertFalse(PlaybackPolicy.shouldContinueTransition(
            taskCancelled: true, generation: 3, currentGeneration: 5))
    }
}

// MARK: - WallpaperSurfacePolicy

final class WallpaperSurfacePolicyTests: XCTestCase {

    func testLockWinsOverScreensaver() {
        XCTAssertEqual(
            WallpaperSurfacePolicy.surface(isLocked: true, isScreensaver: true),
            .lockScreen
        )
        XCTAssertEqual(
            WallpaperSurfacePolicy.surface(isLocked: true, isScreensaver: false),
            .lockScreen
        )
        XCTAssertEqual(
            WallpaperSurfacePolicy.surface(isLocked: false, isScreensaver: true),
            .screensaver
        )
        XCTAssertEqual(
            WallpaperSurfacePolicy.surface(isLocked: false, isScreensaver: false),
            .desktop
        )
    }

    func testLockAndScreensaverShareSaverLevelAboveDesktop() {
        let desktop = WallpaperSurfacePolicy.windowLevel(for: .desktop)
        let saver   = WallpaperSurfacePolicy.windowLevel(for: .screensaver)
        let lock    = WallpaperSurfacePolicy.windowLevel(for: .lockScreen)
        XCTAssertEqual(saver, lock)
        XCTAssertGreaterThan(saver, desktop)
        XCTAssertEqual(desktop, Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        XCTAssertEqual(saver, Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        XCTAssertLessThan(saver, Int(CGShieldingWindowLevel()))
    }

    func testHideOverlayOnlyOnLockWithNativePlayback() {
        XCTAssertTrue(WallpaperSurfacePolicy.shouldHideOverlay(
            surface: .lockScreen, nativeLockPlayback: true))
        XCTAssertFalse(WallpaperSurfacePolicy.shouldHideOverlay(
            surface: .lockScreen, nativeLockPlayback: false))
        XCTAssertFalse(WallpaperSurfacePolicy.shouldHideOverlay(
            surface: .screensaver, nativeLockPlayback: true))
        XCTAssertFalse(WallpaperSurfacePolicy.shouldHideOverlay(
            surface: .desktop, nativeLockPlayback: true))
    }
}

// MARK: - DurationFormatting

final class DurationFormattingTests: XCTestCase {

    func testUnpaddedMatchesVideoItemStyle() {
        XCTAssertEqual(DurationFormatting.string(from: 65), "1:05")
        XCTAssertEqual(DurationFormatting.string(from: 3661), "1:01:01")
        XCTAssertEqual(DurationFormatting.string(from: .nan), "0:00")
    }

    func testZeroPaddedMatchesControlsStyle() {
        XCTAssertEqual(DurationFormatting.string(from: 65, zeroPadMinutes: true), "01:05")
        XCTAssertEqual(DurationFormatting.string(from: 3661, zeroPadMinutes: true), "01:01:01")
        XCTAssertEqual(DurationFormatting.string(from: -1, zeroPadMinutes: true), "00:00")
    }
}

// MARK: - PlaybackMode migration / consistency

final class PlaybackModeSettingsTests: XCTestCase {

    private let suiteName = "VideoWallTests.PlaybackMode.\(UUID().uuidString)"

    override func tearDown() {
        if let d = UserDefaults(suiteName: suiteName) {
            d.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func testLoadPrefersModernPlaybackModeKey() {
        let d = UserDefaults(suiteName: suiteName)!
        d.set(PlaybackMode.cycle.rawValue, forKey: "playbackMode")
        d.set(true, forKey: "loopEnabled")
        d.set(false, forKey: "cycleEnabled")
        XCTAssertEqual(AppSettings.loadPlaybackMode(from: d), .cycle)
    }

    func testLoadMigratesLegacyDualBooleans() {
        let d = UserDefaults(suiteName: suiteName)!
        // both on → cycle wins (legacy normalization)
        d.set(true, forKey: "loopEnabled")
        d.set(true, forKey: "cycleEnabled")
        XCTAssertEqual(AppSettings.loadPlaybackMode(from: d), .cycle)

        d.removePersistentDomain(forName: suiteName)
        d.set(false, forKey: "loopEnabled")
        d.set(false, forKey: "cycleEnabled")
        XCTAssertEqual(AppSettings.loadPlaybackMode(from: d), .loop)

        d.removePersistentDomain(forName: suiteName)
        d.set(false, forKey: "loopEnabled")
        d.set(true, forKey: "cycleEnabled")
        XCTAssertEqual(AppSettings.loadPlaybackMode(from: d), .cycle)
    }

    func testLoadDefaultsToLoopWhenEmpty() {
        let d = UserDefaults(suiteName: suiteName)!
        d.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(AppSettings.loadPlaybackMode(from: d), .loop)
    }

    @MainActor
    func testAppSettingsComputedFlagsMatchSingleMode() {
        let settings = AppSettings()
        settings.playbackMode = .loop
        XCTAssertTrue(settings.loopEnabled)
        XCTAssertFalse(settings.cycleEnabled)
        settings.playbackMode = .cycle
        XCTAssertFalse(settings.loopEnabled)
        XCTAssertTrue(settings.cycleEnabled)
    }
}

// MARK: - AerialsInjector (isolated temp catalog, never touches system)

@MainActor
final class AerialsInjectorTests: XCTestCase {

    func testInstallWritesCatalogAndStoreThenUninstallCleans() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoWallAerials-\(UUID().uuidString)", isDirectory: true)
        let aerials = root.appendingPathComponent("aerials", isDirectory: true)
        let store = root.appendingPathComponent("Store/Index.plist")
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let videoURL = root.appendingPathComponent("clip.mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: videoURL, durationSeconds: 0.6)

        let injector = AerialsInjector(
            touchesSystem: false,
            aerialsRoot: aerials,
            storeURL: store,
            supportDir: support
        )

        XCTAssertFalse(injector.isHealthy())
        XCTAssertTrue(injector.install(videoURL: videoURL, displayName: "Clip A"))
        XCTAssertTrue(injector.isHealthy())

        let entriesURL = aerials.appendingPathComponent("manifest/entries.json")
        let data = try Data(contentsOf: entriesURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let categories = try XCTUnwrap(json["categories"] as? [[String: Any]])
        XCTAssertTrue(categories.contains { ($0["localizedNameKey"] as? String) == "VideoWall" })
        let assets = try XCTUnwrap(json["assets"] as? [[String: Any]])
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?["localizedNameKey"] as? String, "Clip A")
        XCTAssertNotNil(assets.first?["url-4K-SDR-240FPS"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        let storeData = try Data(contentsOf: store)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: storeData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertNotNil(plist["AllSpacesAndDisplays"])
        XCTAssertNotNil(plist["SystemDefault"])

        injector.uninstall()
        XCTAssertFalse(injector.isHealthy())
    }

    func testReinstallSameFileIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoWallAerials2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let videoURL = root.appendingPathComponent("clip.mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: videoURL, durationSeconds: 0.6)

        let injector = AerialsInjector(
            touchesSystem: false,
            aerialsRoot: root.appendingPathComponent("aerials"),
            storeURL: root.appendingPathComponent("Store/Index.plist"),
            supportDir: root.appendingPathComponent("support")
        )
        XCTAssertTrue(injector.install(videoURL: videoURL, displayName: "A"))
        XCTAssertTrue(injector.install(videoURL: videoURL, displayName: "A"))
        XCTAssertTrue(injector.isHealthy())
    }
}
