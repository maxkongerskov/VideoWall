import XCTest
import AVFoundation
@testable import VideoWall

// MARK: - Live manager path tests
//
// These drive the real WallpaperManager + VideoLibraryManager entry points with
// a real tiny H.264 file on disk (not mocks of the policy under test).

@MainActor
final class WallpaperIntegrationTests: XCTestCase {

    private var tempRoot: URL!
    private var sampleVideoURL: URL!
    private var settings: AppSettings!
    private var library: VideoLibraryManager!
    private var wallpaper: WallpaperManager!
    private var defaultsSnapshot = UserDefaultsSnapshot()

    override func setUp() async throws {
        try await super.setUp()
        defaultsSnapshot.capture()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoWallIT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        sampleVideoURL = tempRoot.appendingPathComponent("clip_a.mp4")
        try Self.renderTinyMP4(to: sampleVideoURL, durationSeconds: 1.2)

        settings = AppSettings()
        // Avoid clobbering the user's real launch-at-login / mode prefs mid-run:
        // only the isolated library root is redirected; settings still use defaults.
        library = VideoLibraryManager(applicationSupportRoot: tempRoot)
        wallpaper = WallpaperManager(settings: settings, library: library)
        library.onVideosRemoved = { [weak wallpaper] ids in
            wallpaper?.handleVideosRemoved(ids)
        }
        // Deliberately skip wallpaper.setup() — windows/monitors are not required
        // for play/stop/delete coordination; empty window list is a no-op.
    }

    override func tearDown() async throws {
        wallpaper.stop()
        library.stopWatching()
        try? FileManager.default.removeItem(at: tempRoot)
        defaultsSnapshot.restore()
        try await super.tearDown()
    }

    // MARK: import → play → delete current

    func testImportPlayDeleteCurrentClearsNowPlaying() async throws {
        let video = try await importSample(named: "clip_a.mp4")

        wallpaper.play(video: video)
        XCTAssertEqual(wallpaper.currentVideo?.id, video.id,
                       "play() must set currentVideo for a resolvable library file")
        XCTAssertEqual(settings.selectedVideoID, video.id)

        // Let armPlayback / AVFoundation settle briefly
        try await Task.sleep(for: .milliseconds(400))

        library.delete(video: video)

        XCTAssertNil(wallpaper.currentVideo,
                     "delete of current item must clear now-playing via onVideosRemoved")
        XCTAssertFalse(wallpaper.isPlaying)
        XCTAssertTrue(library.videos.isEmpty)
        // File gone from isolated library
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: video).path))
    }

    func testDeleteNonCurrentDoesNotClearPlaying() async throws {
        let a = try await importSample(named: "clip_a.mp4")
        // Second distinct file so uniqueDestURL does not collide on copy
        let bURL = tempRoot.appendingPathComponent("clip_b.mp4")
        try FileManager.default.copyItem(at: sampleVideoURL, to: bURL)
        let b = try await importFrom(bURL)

        wallpaper.play(video: a)
        XCTAssertEqual(wallpaper.currentVideo?.id, a.id)

        library.delete(video: b)

        XCTAssertEqual(wallpaper.currentVideo?.id, a.id,
                       "deleting a different item must not stop the current wallpaper")
        XCTAssertEqual(library.videos.count, 1)
        XCTAssertEqual(library.videos.first?.id, a.id)
    }

    func testDeleteAllWhilePlayingClearsNowPlaying() async throws {
        let a = try await importSample(named: "clip_a.mp4")
        let bURL = tempRoot.appendingPathComponent("clip_b.mp4")
        try FileManager.default.copyItem(at: sampleVideoURL, to: bURL)
        _ = try await importFrom(bURL)

        wallpaper.play(video: a)
        XCTAssertNotNil(wallpaper.currentVideo)

        library.deleteAll()

        XCTAssertNil(wallpaper.currentVideo)
        XCTAssertFalse(wallpaper.isPlaying)
        XCTAssertTrue(library.videos.isEmpty)
    }

    func testStopClearsNowPlayingWithoutLibraryChange() async throws {
        let video = try await importSample(named: "clip_a.mp4")
        wallpaper.play(video: video)
        XCTAssertNotNil(wallpaper.currentVideo)

        wallpaper.stop()

        XCTAssertNil(wallpaper.currentVideo)
        XCTAssertFalse(wallpaper.isPlaying)
        XCTAssertEqual(library.videos.count, 1, "stop must not delete library files")
    }

    func testPlayMissingFileDoesNotSetCurrentVideo() async throws {
        let ghost = VideoItem(
            id: UUID(),
            name: "ghost",
            filename: "does-not-exist.mp4",
            duration: 1,
            thumbnailData: nil
        )
        wallpaper.play(video: ghost)
        XCTAssertNil(wallpaper.currentVideo,
                     "play must refuse unresolved paths (no stale now-playing)")
    }

    func testSetPlaybackModePersistsSingleMode() async throws {
        let video = try await importSample(named: "clip_a.mp4")
        wallpaper.play(video: video)

        wallpaper.setPlaybackMode(.cycle)
        XCTAssertEqual(settings.playbackMode, .cycle)
        XCTAssertTrue(settings.cycleEnabled)
        XCTAssertFalse(settings.loopEnabled)

        wallpaper.setPlaybackMode(.loop)
        XCTAssertEqual(settings.playbackMode, .loop)
        XCTAssertTrue(settings.loopEnabled)
        XCTAssertFalse(settings.cycleEnabled)
    }

    func testHandleVideosRemovedIgnoresUnrelatedIDs() async throws {
        let video = try await importSample(named: "clip_a.mp4")
        wallpaper.play(video: video)
        wallpaper.handleVideosRemoved([UUID()])
        XCTAssertEqual(wallpaper.currentVideo?.id, video.id)
    }

    func testPlayThenImmediateStopDoesNotLeavePlayingFlag() async throws {
        let video = try await importSample(named: "clip_a.mp4")
        wallpaper.play(video: video)
        // Immediate stop — races setupTask / transitionTask cancel path
        wallpaper.stop()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(wallpaper.currentVideo)
        XCTAssertFalse(wallpaper.isPlaying)
    }

    func testSetPlaybackRateToCompositionStopsDoesNotCrash() async throws {
        let previousBattery = settings.pauseOnBattery
        let previousRecording = settings.pauseOnScreenRecording
        let previousRate = settings.playbackRate
        settings.pauseOnBattery = false
        settings.pauseOnScreenRecording = false
        settings.playbackRate = 1
        defer {
            settings.pauseOnBattery = previousBattery
            settings.pauseOnScreenRecording = previousRecording
            settings.playbackRate = previousRate
        }

        let video = try await importSample(named: "clip_a.mp4")
        wallpaper.play(video: video)
        try await waitUntil("player after play") { wallpaper.debugHasActivePlayer }
        try await waitUntil("playback started") { wallpaper.isPlaying }

        // 1× → 3× rebuilds a scaled composition on a hidden player parked
        // under the live layer, then hard-cuts (must not crash or hang).
        wallpaper.setPlaybackRate(3)
        try await waitUntil("3× swap finished", timeout: 8) { !wallpaper.debugRateSwapInFlight }
        XCTAssertEqual(settings.playbackRate, 3)
        XCTAssertTrue(wallpaper.debugHasActivePlayer)
        XCTAssertGreaterThan(
            wallpaper.debugCompositionSpeedup, 1.01,
            "3× must rebuild a scaled composition so 4K HEVC is not decoded at 3×"
        )
        XCTAssertEqual(wallpaper.debugPlayerRate, 1, accuracy: 0.15)
        XCTAssertEqual(
            wallpaper.debugPreferredMaximumResolution,
            AppleGPUPlayback.decoderCap(for: settings.resolution)
        )
        XCTAssertTrue(
            wallpaper.debugUsesVideoComposition,
            "scaled 3× item keeps a 60 fps Fig passthrough so source frames are dropped"
        )

        wallpaper.setPlaybackRate(10)
        try await waitUntil("10× swap finished", timeout: 8) { !wallpaper.debugRateSwapInFlight }
        XCTAssertEqual(settings.playbackRate, 10)
        XCTAssertTrue(wallpaper.debugHasActivePlayer)
        XCTAssertGreaterThan(wallpaper.debugCompositionSpeedup, 1.01)
        XCTAssertEqual(wallpaper.debugPlayerRate, 1, accuracy: 0.15)

        wallpaper.setPlaybackRate(1)
        try await waitUntil("1× swap finished", timeout: 8) { !wallpaper.debugRateSwapInFlight }
        XCTAssertEqual(settings.playbackRate, 1)
        XCTAssertTrue(wallpaper.debugHasActivePlayer)
        XCTAssertLessThan(wallpaper.debugCompositionSpeedup, 1.01,
                          "native 1× item must not keep a scaled composition")
        XCTAssertEqual(wallpaper.debugPlayerRate, 1, accuracy: 0.15)
    }

    func testRapidPlaySwitchThenStop() async throws {
        let a = try await importSample(named: "clip_a.mp4")
        let bURL = tempRoot.appendingPathComponent("clip_b.mp4")
        try FileManager.default.copyItem(at: sampleVideoURL, to: bURL)
        let b = try await importFrom(bURL)

        wallpaper.play(video: a)
        try await Task.sleep(for: .milliseconds(250))
        // Second play while player exists → scheduleCrossfade path
        wallpaper.play(video: b)
        try await Task.sleep(for: .milliseconds(100))
        wallpaper.stop()
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertNil(wallpaper.currentVideo)
        XCTAssertFalse(wallpaper.isPlaying)
    }

    // MARK: Helpers

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 5,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(label)")
    }

    private func importSample(named: String) async throws -> VideoItem {
        // sampleVideoURL is always clip_a.mp4 content; rename for unique dest when needed
        let source = tempRoot.appendingPathComponent("src-\(named)")
        if !FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: sampleVideoURL, to: source)
        }
        return try await importFrom(source)
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
                XCTFail("import failed: \(err)")
                throw NSError(domain: "VideoWallIT", code: 1, userInfo: [NSLocalizedDescriptionKey: err])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for import of \(url.lastPathComponent)")
        throw NSError(domain: "VideoWallIT", code: 2)
    }

    /// Writes a short solid-color H.264 MP4 using AVFoundation (no shell dependency).
    static func renderTinyMP4(to url: URL, durationSeconds: Double) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let size = CGSize(width: 320, height: 180)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(2, Int(durationSeconds * 10))
        let frameDuration = CMTime(value: 1, timescale: 10)

        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let time = CMTimeMultiply(frameDuration, multiplier: Int32(i))
            guard let pool = adaptor.pixelBufferPool else {
                throw NSError(domain: "VideoWallIT", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "missing pixel buffer pool"
                ])
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixelBuffer = buffer else {
                throw NSError(domain: "VideoWallIT", code: 4)
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                // Simple gradient fill so the file is non-empty compressed video
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<(bytesPerRow / 4) {
                        let o = y * bytesPerRow + x * 4
                        ptr[o + 0] = UInt8((x + i) & 0xFF)     // B
                        ptr[o + 1] = UInt8((y + i * 3) & 0xFF) // G
                        ptr[o + 2] = 40                        // R
                        ptr[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: time))
        }

        input.markAsFinished()
        let end = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
        writer.endSession(atSourceTime: end)

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        let waitResult = sem.wait(timeout: .now() + 10)
        guard waitResult == .success else {
            throw NSError(domain: "VideoWallIT", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "timed out finishing MP4 writer"
            ])
        }
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "VideoWallIT", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter failed: \(writer.status.rawValue)"
            ])
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "VideoWallIT", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "MP4 was not written to \(url.path)"
            ])
        }
    }
}
