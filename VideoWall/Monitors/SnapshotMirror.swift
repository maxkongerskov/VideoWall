import AVFoundation
import CoreImage
import CoreGraphics

// MARK: - SnapshotMirror
//
// AVPlayerLayer is invisible to Mission Control. We mirror a downscaled frame
// into a CALayer. The pixel-buffer tap MUST NOT stay on the item while
// player.rate changes — that floods FigFilePlayer -12860 and hitches 4K HEVC.

@MainActor
final class SnapshotMirror {

    var onFrame: ((CGImage) -> Void)?

    private var videoOutput: AVPlayerItemVideoOutput?
    private var player:      AVQueuePlayer?
    private var item:        AVPlayerItem?
    private var timer:       Timer?
    private var copyEnabled = true

    private var _ciContext: CIContext?
    /// Metal CIContext for downsampling frames — created lazily on the first
    /// attach, not at launch, so an app that never resumes snapshots never
    /// pays for one.
    private var ciContext: CIContext {
        if let _ciContext { return _ciContext }
        let context = AppleGPUPlayback.makeSnapshotCIContext()
        _ciContext = context
        return context
    }
    private let maxDimension: CGFloat
    private let interval: TimeInterval

    init(maxDimension: CGFloat = 640, interval: TimeInterval = 0.25) {
        self.maxDimension = maxDimension
        self.interval     = interval
    }

    func attach(to item: AVPlayerItem, player: AVQueuePlayer) {
        if self.item === item, self.player === player {
            if copyEnabled, videoOutput == nil {
                addOutput(to: item)
                startTimer()
            }
            return
        }
        // Retarget first, then drop the previous tap. Yanking a pixel-buffer
        // tap off a still-playing item hitches 4K HEVC; callers should pause
        // the old player before attaching a different item.
        let previousItem = self.item
        let previousOutput = videoOutput
        videoOutput = nil
        self.item = item
        self.player = player
        if copyEnabled {
            addOutput(to: item)
            startTimer()
        }
        if let previousOutput {
            previousItem?.remove(previousOutput)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        detachOutput()
        player = nil
        item = nil
    }

    func pauseCapture() {
        copyEnabled = false
        timer?.invalidate()
        timer = nil
        detachOutput()
    }

    func resumeCapture() {
        copyEnabled = true
        guard timer == nil, let item else { return }
        if videoOutput == nil { addOutput(to: item) }
        startTimer()
    }

    private func addOutput(to item: AVPlayerItem) {
        let output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: AppleGPUPlayback.snapshotPixelBufferAttributes
        )
        item.add(output)
        videoOutput = output
    }

    private func detachOutput() {
        if let output = videoOutput {
            item?.remove(output)
        }
        videoOutput = nil
    }

    private func startTimer() {
        guard timer == nil, copyEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.capture() }
        }
    }

    private func capture() {
        guard copyEnabled, let output = videoOutput, let player else { return }
        let t = player.currentTime()
        guard t.isValid,
              output.hasNewPixelBuffer(forItemTime: t),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
        else { return }

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
