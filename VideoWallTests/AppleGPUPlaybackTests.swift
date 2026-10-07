import XCTest
import AVFoundation
import CoreVideo
import Metal
@testable import VideoWall

@MainActor
final class AppleGPUPlaybackTests: XCTestCase {

    func testMetalDeviceIsAvailable() {
        XCTAssertNotNil(AppleGPUPlayback.metalDevice, "macOS 15 wallpaper needs a Metal device")
    }

    func testSnapshotAttributesStayOnNativeYUV() {
        let attrs = AppleGPUPlayback.snapshotPixelBufferAttributes
        XCTAssertEqual(
            attrs[kCVPixelBufferPixelFormatTypeKey as String] as? Int,
            Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        )
        XCTAssertEqual(
            attrs[kCVPixelBufferMetalCompatibilityKey as String] as? Bool,
            true
        )
        XCTAssertNotNil(attrs[kCVPixelBufferIOSurfacePropertiesKey as String])
    }

    func testFrameRateCapThreshold() {
        XCTAssertFalse(AppleGPUPlayback.needsFrameRateCap(24))
        XCTAssertFalse(AppleGPUPlayback.needsFrameRateCap(30))
        XCTAssertFalse(AppleGPUPlayback.needsFrameRateCap(60))
        XCTAssertTrue(AppleGPUPlayback.needsFrameRateCap(120))
        XCTAssertTrue(AppleGPUPlayback.needsFrameRateCap(240))
    }

    func testPacingFrameDurationScalesWithRate() {
        XCTAssertEqual(AppleGPUPlayback.pacingFrameDuration(rate: 1).seconds, 1.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(AppleGPUPlayback.pacingFrameDuration(rate: 2).seconds, 2.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(AppleGPUPlayback.pacingFrameDuration(rate: 10).seconds, 10.0 / 60.0, accuracy: 0.0001)
    }

    func testDecoderCapNeverExceedsDisplayOrSetting() {
        let display = AppleGPUPlayback.maxDisplayPixels()
        XCTAssertGreaterThan(display.width, 0)
        XCTAssertGreaterThan(display.height, 0)

        let original = AppleGPUPlayback.decoderCap(for: .original)
        XCTAssertEqual(original, display)

        let hd = AppleGPUPlayback.decoderCap(for: .hd720)
        XCTAssertLessThanOrEqual(hd.width, 1280)
        XCTAssertLessThanOrEqual(hd.height, 720)
        XCTAssertLessThanOrEqual(hd.width, display.width)
        XCTAssertLessThanOrEqual(hd.height, display.height)

        let uhd = AppleGPUPlayback.decoderCap(for: .uhd4k)
        XCTAssertLessThanOrEqual(uhd.width, 3840)
        XCTAssertLessThanOrEqual(uhd.height, 2160)
        XCTAssertLessThanOrEqual(uhd.width, display.width)
        XCTAssertLessThanOrEqual(uhd.height, display.height)
    }

    func testConfigureDropsVideoCompositionAndSetsDecoderCap() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpu-cap-\(UUID().uuidString).mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: url, durationSeconds: 0.4)
        defer { try? FileManager.default.removeItem(at: url) }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: 64, height: 64)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        item.videoComposition = composition
        XCTAssertNotNil(item.videoComposition)

        AppleGPUPlayback.configure(item: item, resolution: .hd720)

        XCTAssertEqual(item.preferredMaximumResolution, AppleGPUPlayback.decoderCap(for: .hd720))
        // configure(item:) no longer clears a composition; applyFrameRateCap does
        // that for normal 24/30/60 fps items.
        await AppleGPUPlayback.applyFrameRateCap(
            to: item,
            asset: item.asset,
            resolution: .hd720
        )
        XCTAssertNil(item.videoComposition, "10 fps test clip must stay on VideoToolbox overlay")
    }

    func testConfigurePlayerAppliesCapToCurrentItem() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpu-player-\(UUID().uuidString).mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: url, durationSeconds: 0.4)
        defer { try? FileManager.default.removeItem(at: url) }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVQueuePlayer(playerItem: item)
        AppleGPUPlayback.configure(player: player, resolution: .fhd1080)

        XCTAssertFalse(player.allowsExternalPlayback)
        XCTAssertFalse(player.automaticallyWaitsToMinimizeStalling)
        XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
        XCTAssertEqual(
            player.currentItem?.preferredMaximumResolution,
            AppleGPUPlayback.decoderCap(for: .fhd1080)
        )
        XCTAssertNil(player.currentItem?.videoComposition)
    }

    func testSnapshotCIContextUsesGPU() {
        XCTAssertNotNil(AppleGPUPlayback.makeSnapshotCIContext())
        XCTAssertNotNil(AppleGPUPlayback.metalDevice)
    }

    func testFrameRateCapCompositionUsesAssetDurationNotWithPropertiesOf() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpu-passthrough-\(UUID().uuidString).mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: url, durationSeconds: 1.2)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let composition = await AppleGPUPlayback.makeFrameRateCapComposition(
            for: asset,
            renderSize: CGSize(width: 320, height: 180)
        )
        XCTAssertNotNil(composition)
        XCTAssertNil(composition?.customVideoCompositorClass,
                     "custom 32BGRA compositor is slower than Fig passthrough")
        XCTAssertEqual(
            composition?.frameDuration.seconds ?? 0,
            AppleGPUPlayback.pacingFrameDuration(rate: 1).seconds,
            accuracy: 0.0001
        )

        let duration = try await asset.load(.duration)
        let range = (composition?.instructions.first as? AVVideoCompositionInstructionProtocol)?.timeRange
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, .zero)
        XCTAssertEqual(range?.duration.seconds ?? 0, duration.seconds, accuracy: 0.15)
    }

    func testFrameRateCapOnScaledCompositionKeepsShortenedDuration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpu-scaled-\(UUID().uuidString).mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: url, durationSeconds: 1.2)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = AVURLAsset(url: url)
        guard let srcDuration = try? await source.load(.duration),
              let track = try? await source.loadTracks(withMediaType: .video).first
        else {
            XCTFail("tiny mp4 has no video track")
            return
        }

        let scaled = AVMutableComposition()
        guard let compTrack = scaled.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            XCTFail("could not add composition track")
            return
        }
        try compTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: srcDuration),
            of: track,
            at: .zero
        )
        let inserted = scaled.duration
        scaled.scaleTimeRange(
            CMTimeRange(start: .zero, duration: inserted),
            toDuration: CMTimeMultiplyByFloat64(inserted, multiplier: 1.0 / 3.0)
        )
        XCTAssertLessThan(scaled.duration.seconds, srcDuration.seconds * 0.5)

        let cap = await AppleGPUPlayback.makeFrameRateCapComposition(
            for: scaled,
            renderSize: CGSize(width: 320, height: 180)
        )
        let range = (cap?.instructions.first as? AVVideoCompositionInstructionProtocol)?.timeRange
        XCTAssertEqual(range?.duration.seconds ?? 0, scaled.duration.seconds, accuracy: 0.15)
        XCTAssertNotEqual(range?.duration.seconds ?? 0, srcDuration.seconds, accuracy: 0.15)
    }

    func testForceCapAttachesPassthroughOnLowFpsItem() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpu-force-\(UUID().uuidString).mp4")
        try WallpaperIntegrationTests.renderTinyMP4(to: url, durationSeconds: 0.4)
        defer { try? FileManager.default.removeItem(at: url) }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        await AppleGPUPlayback.applyFrameRateCap(
            to: item,
            asset: item.asset,
            resolution: .hd720,
            playbackRate: 1,
            force: true
        )
        XCTAssertNotNil(item.videoComposition, "3×…10× scaled items must drop frames even at 24/30 fps")
        XCTAssertEqual(
            item.videoComposition?.frameDuration.seconds ?? 0,
            AppleGPUPlayback.pacingFrameDuration(rate: 1).seconds,
            accuracy: 0.0001
        )
        XCTAssertNil(
            (item.videoComposition as? AVMutableVideoComposition)?.customVideoCompositorClass,
            "forced cap must stay on Fig YUV passthrough"
        )
    }
}
