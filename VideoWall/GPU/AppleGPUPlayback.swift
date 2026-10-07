import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import Metal

// MARK: - AppleGPUPlayback
//
// Wallpaper decode/display must stay on VideoToolbox + Metal.
// Attaching AVVideoComposition for a resolution cap forces AVFoundation's
// compositor (often a CPU/BGRA convert) and drops the hardware overlay.

enum AppleGPUPlayback {

    static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    static func makeSnapshotCIContext() -> CIContext {
        if let metalDevice {
            return CIContext(mtlDevice: metalDevice, options: [
                .cacheIntermediates: false
            ])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }

    /// Wallpaper never needs more than 60 fps — displays are 60 Hz, and 120/240
    /// fps 4K HEVC is decoded in full unless we cap the composition clock.
    static let maxOutputFrameRate: Int32 = 60

    /// Native decoder output (NV12) + Metal/IOSurface. Requesting 32BGRA here
    /// forces the whole player off the VideoToolbox overlay into an RGB convert.
    static var snapshotPixelBufferAttributes: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
    }

    /// Largest framebuffer among `screens` (points × backingScaleFactor).
    @MainActor
    static func maxDisplayPixels(screens: [NSScreen] = NSScreen.screens) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for screen in screens {
            let scale = screen.backingScaleFactor
            width = max(width, screen.frame.width * scale)
            height = max(height, screen.frame.height * scale)
        }
        if width < 1 || height < 1 {
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Decoder output cap: user render size, never larger than the displays.
    /// Original still caps to the displays so 8K sources don't decode extra pixels.
    @MainActor
    static func decoderCap(
        for resolution: VideoResolution,
        screens: [NSScreen] = NSScreen.screens
    ) -> CGSize {
        let display = maxDisplayPixels(screens: screens)
        guard let requested = resolution.renderSize else { return display }
        return CGSize(
            width: min(requested.width, display.width),
            height: min(requested.height, display.height)
        )
    }

    static func needsFrameRateCap(_ sourceFrameRate: Float) -> Bool {
        sourceFrameRate > Float(maxOutputFrameRate) + 0.5
    }

    /// Item-time duration of one composed frame so wall-clock output stays ~60 fps
    /// at `rate`× (`1/60` at 1×, `10/60` at 10×).
    static func pacingFrameDuration(rate: Double) -> CMTime {
        let clamped = min(max(rate, 1), 10)
        return CMTime(seconds: clamped / Double(maxOutputFrameRate), preferredTimescale: 600)
    }

    @MainActor
    static func nominalFrameRate(of asset: AVAsset) async -> Float {
        nonisolated(unsafe) let source = asset
        guard let track = try? await source.loadTracks(withMediaType: .video).first else { return 0 }
        return (try? await track.load(.nominalFrameRate)) ?? 0
    }

    @MainActor
    static func configure(item: AVPlayerItem, resolution: VideoResolution) {
        item.preferredMaximumResolution = decoderCap(for: resolution)
    }

    @MainActor
    static func configure(player: AVQueuePlayer, resolution: VideoResolution) {
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        for item in player.items() {
            configure(item: item, resolution: resolution)
        }
        if let current = player.currentItem {
            configure(item: current, resolution: resolution)
        }
    }

    /// Caps output to ~60 fps wall-clock. Uses Fig's passthrough compositor (YUV)
    /// — a custom 32BGRA blit was heavier than native decode.
    /// 24/30/60 fps *native* items stay on the VideoToolbox overlay unless
    /// `force` is set (3×…10× `scaleTimeRange` items, which must drop frames).
    @MainActor
    static func applyFrameRateCap(
        to item: AVPlayerItem,
        asset: AVAsset,
        resolution: VideoResolution,
        playbackRate: Double = 1,
        force: Bool = false
    ) async {
        configure(item: item, resolution: resolution)
        let fps = await nominalFrameRate(of: asset)
        guard force || needsFrameRateCap(fps) else {
            item.videoComposition = nil
            return
        }
        let cap = decoderCap(for: resolution)
        guard let composition = await makeFrameRateCapComposition(
            for: asset,
            renderSize: cap,
            playbackRate: playbackRate
        ) else {
            print("VideoWall: \(fps)fps cap skipped (no composition); playing native")
            return
        }
        item.videoComposition = composition
        print(String(format: "VideoWall: capping %.0ffps to %dfps", fps, maxOutputFrameRate))
    }

    /// Keeps a high-fps cap at ~60 fps wall-clock when the user clicks 1×…10×.
    /// Mutates the live composition in place — reassigning videoComposition
    /// rebuilds the render pipeline and hitches every stop.
    @MainActor
    static func syncPacingFrameDuration(on item: AVPlayerItem, rate: Double) {
        guard let composition = item.videoComposition as? AVMutableVideoComposition else { return }
        let duration = pacingFrameDuration(rate: rate)
        guard abs(composition.frameDuration.seconds - duration.seconds) > 0.0005 else { return }
        composition.frameDuration = duration
    }

    /// Passthrough over `asset`'s own timeline. Never `videoComposition(withPropertiesOf:)` —
    /// that emits URL-asset instructions and undoes 3×…10× `scaleTimeRange`.
    @MainActor
    static func makeFrameRateCapComposition(
        for asset: AVAsset,
        renderSize cap: CGSize,
        playbackRate: Double = 1
    ) async -> AVMutableVideoComposition? {
        nonisolated(unsafe) let source = asset
        guard let duration = try? await source.load(.duration),
              duration.isValid, !duration.isIndefinite, duration.seconds > 0,
              let tracks = try? await source.loadTracks(withMediaType: .video),
              !tracks.isEmpty
        else { return nil }

        let composition = AVMutableVideoComposition()
        composition.frameDuration = pacingFrameDuration(rate: playbackRate)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.enablePostProcessing = false
        instruction.layerInstructions = tracks.map {
            AVMutableVideoCompositionLayerInstruction(assetTrack: $0)
        }
        composition.instructions = [instruction]

        if let track = tracks.first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let mapped = natural.applying(transform)
            let src = CGSize(width: abs(mapped.width), height: abs(mapped.height))
            if src.width >= 2, src.height >= 2, cap.width >= 2, cap.height >= 2 {
                composition.renderSize = CGSize(
                    width: min(src.width, cap.width).rounded(),
                    height: min(src.height, cap.height).rounded()
                )
            } else if src.width >= 2, src.height >= 2 {
                composition.renderSize = src
            }
        }
        return composition
    }
}
