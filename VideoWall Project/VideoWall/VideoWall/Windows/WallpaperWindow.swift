import AppKit
import AVFoundation

// MARK: - WallpaperWindow
//
// Wraps a plain NSWindow (never subclasses — Tahoe ARC rules).
//
// Each AVQueuePlayer lives inside a container CALayer so Core Image filters
// (CIGaussianBlur) can be applied to the composed video frame for the
// cycle crossfade effect without touching the AVPlayerLayer directly.

@MainActor
final class WallpaperWindow {

    // MARK: Private Constants
    private enum Keys {
        static let blurFilterName = "vwBlur"
        static let blurRadiusPath = "filters.\(blurFilterName).inputRadius"
    }

    // MARK: Public

    let window: NSWindow

    // MARK: Private – layer stack

    /// The container CALayer wrapping the currently active AVPlayerLayer.
    private var activeContainer:   CALayer?
    private var activePlayerLayer: AVPlayerLayer?

    /// Incoming container during a crossfade — kept so we can abort it if
    /// setPlayer() is called before the animation completes.
    private var pendingContainer:  CALayer?

    /// Outgoing container during a crossfade — tracked so rapid player changes
    /// don't leave orphaned blurred layers in the window.
    private var outgoingContainer: CALayer?

    /// A plain CALayer that mirrors the current video frame at a low frame rate.
    private let snapshotLayer = CALayer()

    // MARK: Init

    init(screen: NSScreen) {
        window = NSWindow(
            contentRect: screen.frame,
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       true           // never display inside init (Tahoe ARC fix)
        )
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
        )
        window.collectionBehavior    = [.canJoinAllSpaces, .stationary]
        window.isOpaque              = false
        window.backgroundColor       = .clear   // transparent when no content — shows real wallpaper
        window.ignoresMouseEvents    = true
        window.isReleasedWhenClosed  = false

        let host = NSView(frame: screen.frame)
        host.wantsLayer = true
        if let layer = host.layer {
            layer.backgroundColor = NSColor.clear.cgColor
        }

        snapshotLayer.frame            = host.bounds
        snapshotLayer.contentsGravity  = .resizeAspectFill
        snapshotLayer.masksToBounds    = true
        snapshotLayer.backgroundColor  = NSColor.clear.cgColor
        snapshotLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        
        if let layer = host.layer {
            layer.addSublayer(snapshotLayer)
        }

        window.contentView = host

        window.setFrame(screen.frame, display: false)
    }

    // MARK: Lifecycle

    func show() { window.orderFront(nil) }
    func hide() { window.orderOut(nil)  }

    // MARK: – Direct player assignment (no transition)

    func setPlayer(_ player: AVQueuePlayer) {
        guard let hostLayer = window.contentView?.layer else { return }

        // Abort any in-flight crossfade
        pendingContainer?.removeFromSuperlayer()
        pendingContainer  = nil
        outgoingContainer?.removeFromSuperlayer()
        outgoingContainer = nil
        activeContainer?.removeFromSuperlayer()

        let bounds = hostLayer.bounds
        let (container, avLayer) = makeLayerPair(player: player, bounds: bounds)
        hostLayer.addSublayer(container)

        activeContainer   = container
        activePlayerLayer = avLayer
    }

    func clearPlayer() {
        // AVPlayerLayer.player is optional in this SDK — use if-let.
        if let player = activePlayerLayer?.player {
            player.pause()
        }
        activePlayerLayer?.player = nil
        activeContainer?.removeFromSuperlayer()
        pendingContainer?.removeFromSuperlayer()
        outgoingContainer?.removeFromSuperlayer()
        activeContainer   = nil
        activePlayerLayer = nil
        pendingContainer  = nil
        outgoingContainer = nil
        snapshotLayer.contents = nil
    }

    /// Updates the back-most mirror layer with a still of the current video
    /// frame. Called at a low frame rate by WallpaperManager. Disable actions so
    /// the swap is instant and never animates.
    func updateSnapshot(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotLayer.contents = image
        CATransaction.commit()
    }

    // MARK: – Crossfade transition

    /// Crossfade from the current video to `newPlayer` over `duration` seconds.
    func crossfade(to newPlayer: AVQueuePlayer, duration: TimeInterval, peakBlur: CGFloat = 16) {
        guard let hostLayer = window.contentView?.layer else { return }

        let reduceMotion = self.isReduceMotionEnabled
        let useBlur      = !reduceMotion && peakBlur > 0.5
        let bounds       = hostLayer.bounds
        let outContainer = activeContainer

        outgoingContainer = outContainer

        let (inContainer, inPlayerLayer) = makeLayerPair(player: newPlayer, bounds: bounds)
        pendingContainer = inContainer

        let now = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if useBlur {
            inContainer.opacity = 1.0
            attachBlur(radius: peakBlur, to: inContainer)

            if let out = outContainer {
                hostLayer.insertSublayer(inContainer, above: out)
                attachBlur(radius: 0, to: out)
                let bo = blurAnim(from: 0, to: peakBlur,
                                  duration: duration * 0.5,
                                  beginTime: now)
                out.add(bo, forKey: "blurOut")
            } else {
                hostLayer.addSublayer(inContainer)
            }

            let midTime = now + duration * 0.5
            let fi = opacityAnim(from: 0, to: 1, duration: duration * 0.5,
                                 timing: .easeInEaseOut, beginTime: midTime)
            inContainer.add(fi, forKey: "fadeIn")

            let bi = blurAnim(from: peakBlur, to: 0,
                              duration: duration * 0.75,
                              beginTime: midTime)
            inContainer.add(bi, forKey: "blurIn")

        } else {
            // Simplified transition for Reduce Motion or no-blur requests
            inContainer.opacity = 1.0

            if let out = outContainer {
                hostLayer.insertSublayer(inContainer, above: out)
                let fi = opacityAnim(from: 0, to: 1, duration: reduceMotion ? duration * 0.5 : duration,
                                     timing: .easeInEaseOut, beginTime: now)
                inContainer.add(fi, forKey: "fadeIn")
            } else {
                hostLayer.addSublayer(inContainer)
            }
        }

        CATransaction.commit()

        // ── Cleanup after animation using Swift Concurrency ───────────────────
        Task { [weak self, weak outContainer, weak inContainer] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.15) * 1_000_000_000))
            
            outContainer?.removeFromSuperlayer()
            if useBlur { inContainer?.filters = nil }
            
            guard let self else { return }
            if self.pendingContainer === inContainer {
                self.pendingContainer = nil
            }
            if let outContainer, self.outgoingContainer === outContainer {
                self.outgoingContainer = nil
            }
        }

        activeContainer   = inContainer
        activePlayerLayer = inPlayerLayer
    }

    // MARK: – Other controls

    func setAllSpaces(_ enabled: Bool) {
        if enabled {
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.collectionBehavior.remove(.moveToActiveSpace)
        } else {
            window.collectionBehavior.remove(.canJoinAllSpaces)
        }
    }

    func updateFrame(for screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        let b        = window.contentView?.bounds ?? .zero
        let expanded = b.insetBy(dx: -blurEdgePadding, dy: -blurEdgePadding)
        let expSize  = CGRect(origin: .zero, size: expanded.size)
        activeContainer?.frame    = expanded
        activePlayerLayer?.frame  = expSize
        snapshotLayer.frame       = b
        pendingContainer?.frame   = expanded
        outgoingContainer?.frame  = expanded
    }

    // MARK: – Private helpers

    private let blurEdgePadding: CGFloat = 16

    /// Checks the system-wide accessibility preference for reduced motion.
    private var isReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func makeLayerPair(player: AVQueuePlayer,
                                bounds: CGRect) -> (CALayer, AVPlayerLayer) {
        let expanded = bounds.insetBy(dx: -blurEdgePadding, dy: -blurEdgePadding)

        let container               = CALayer()
        container.frame             = expanded
        container.masksToBounds     = false

        let avLayer                 = AVPlayerLayer(player: player)
        avLayer.frame               = CGRect(origin: .zero, size: expanded.size)
        avLayer.videoGravity        = .resizeAspectFill
        avLayer.autoresizingMask    = [.layerWidthSizable, .layerHeightSizable]
        container.addSublayer(avLayer)

        return (container, avLayer)
    }

    private func attachBlur(radius: CGFloat, to layer: CALayer) {
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.name = Keys.blurFilterName
        blur.setValue(radius, forKey: "inputRadius")
        layer.filters = [blur]
    }

    // MARK: Animation builders

    private func opacityAnim(from: Float, to: Float,
                              duration: TimeInterval,
                              timing: CAMediaTimingFunctionName,
                              beginTime: CFTimeInterval) -> CABasicAnimation {
        let a                    = CABasicAnimation(keyPath: "opacity")
        a.fromValue              = from
        a.toValue                = to
        a.duration               = duration
        a.beginTime              = beginTime
        a.timingFunction         = CAMediaTimingFunction(name: timing)
        a.fillMode               = .both
        a.isRemovedOnCompletion  = false
        return a
    }

    private func blurAnim(from: CGFloat, to: CGFloat,
                           duration: TimeInterval,
                           beginTime: CFTimeInterval) -> CABasicAnimation {
        let a                    = CABasicAnimation(keyPath: Keys.blurRadiusPath)
        a.fromValue              = from
        a.toValue                = to
        a.duration               = duration
        a.beginTime              = beginTime
        a.fillMode               = .both
        a.isRemovedOnCompletion  = false
        return a
    }
}
