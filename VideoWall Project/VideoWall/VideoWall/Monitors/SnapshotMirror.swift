import AVFoundation
import CoreImage
import CoreGraphics

// MARK: - SnapshotMirror
//
// AVPlayerLayer content is invisible to Mission Control / Exposé snapshots, so
// during Mission Control the translucent menu bar would show the real desktop
// wallpaper instead of the video. This mirrors the active player's frames at a
// low rate into a plain CGImage callback (which the caller pushes into a
// captured CALayer). Frames are downscaled before rasterizing — the snapshot is
// only ever shown small and blurred, so full resolution would be wasted GPU.

@MainActor
final class SnapshotMirror {

    /// Called at the polling rate with a fresh, downscaled frame.
    var onFrame: ((CGImage) -> Void)?

    private var videoOutput: AVPlayerItemVideoOutput?
    private var player:      AVQueuePlayer?
    private var timer:       Timer?

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let maxDimension: CGFloat
    private let interval: TimeInterval

    init(maxDimension: CGFloat = 640, interval: TimeInterval = 0.25) {
        self.maxDimension = maxDimension
        self.interval     = interval
    }

    /// Begins mirroring `player`. Safe to call repeatedly — each call retargets
    /// the mirror at the newly supplied player/item.
    func attach(to item: AVPlayerItem, player: AVQueuePlayer) {
        let attrs: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        videoOutput = output
        self.player = player
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer       = nil
        videoOutput = nil
        player      = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.capture() }
        }
    }

    private func capture() {
        guard let output = videoOutput, let player else { return }
        let t = player.currentTime()
        guard t.isValid,
              output.hasNewPixelBuffer(forItemTime: t),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
        else { return }

        // Downscale before rasterizing — the snapshot is only shown small/blurred.
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        let extent  = ciImage.extent
        let maxSide = max(extent.width, extent.height)
        let scale   = maxSide > maxDimension ? maxDimension / maxSide : 1
        let scaled  = scale < 1
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        onFrame?(cgImage)
    }
}
