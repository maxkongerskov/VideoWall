import AppKit
import Foundation

// MARK: - ScreenSurfaceMonitor
//
// Observes lock / unlock and screensaver start / stop. Lock is reported from
// both DistributedNotificationCenter (`com.apple.screenIsLocked`) and the
// Darwin notify center (`com.apple.sessionagent.screenIsLocked`) — Tahoe
// delivers the latter more reliably.

@MainActor
final class ScreenSurfaceMonitor {

    /// Called whenever the resolved lock / screensaver pair changes.
    var onChange: ((_ isLocked: Bool, _ isScreensaver: Bool) -> Void)?

    private(set) var isLocked = false
    private(set) var isScreensaver = false

    private var distributedTokens: [NSObjectProtocol] = []
    private var darwinBridge: DarwinLockBridge?

    func start() {
        stop()

        let dnc = DistributedNotificationCenter.default()

        func observe(_ name: String, _ body: @escaping @MainActor (ScreenSurfaceMonitor) -> Void) {
            let token = dnc.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { body(self) }
            }
            distributedTokens.append(token)
        }

        observe("com.apple.screenIsLocked")     { $0.apply(locked: true) }
        observe("com.apple.screenIsUnlocked")   { $0.apply(locked: false) }
        observe("com.apple.screensaver.didStart") { $0.apply(screensaver: true) }
        observe("com.apple.screensaver.didStop")  { $0.apply(screensaver: false) }
        observe("com.apple.screensaver.willstop") { $0.apply(screensaver: false) }

        let bridge = DarwinLockBridge()
        darwinBridge = bridge
        bridge.onLocked = { [weak self] locked in
            Task { @MainActor [weak self] in
                self?.apply(locked: locked)
            }
        }
        bridge.install()
    }

    func stop() {
        let dnc = DistributedNotificationCenter.default()
        for token in distributedTokens {
            dnc.removeObserver(token)
        }
        distributedTokens.removeAll()
        darwinBridge?.uninstall()
        darwinBridge = nil
    }

    /// Test / diagnostics: drive the same state path the notifications use.
    func debugApply(locked: Bool? = nil, screensaver: Bool? = nil) {
        if let locked { apply(locked: locked) }
        if let screensaver { apply(screensaver: screensaver) }
    }

    // MARK: Private

    private func apply(locked: Bool) {
        var screensaver = isScreensaver
        if !locked { screensaver = false }
        publish(locked: locked, screensaver: screensaver)
    }

    private func apply(screensaver: Bool) {
        publish(locked: isLocked, screensaver: screensaver)
    }

    private func publish(locked: Bool, screensaver: Bool) {
        guard locked != isLocked || screensaver != isScreensaver else { return }
        isLocked = locked
        isScreensaver = screensaver
        onChange?(isLocked, isScreensaver)
    }
}

// MARK: - Darwin notify bridge
//
// CFNotificationCenter callbacks are C function pointers, so they cannot
// capture self. The bridge is an @unchecked Sendable box retained by the
// monitor for the lifetime of the observers.

private final class DarwinLockBridge: @unchecked Sendable {
    var onLocked: (@Sendable (Bool) -> Void)?
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let ptr = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center, ptr,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinLockBridge>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .onLocked?(true)
            },
            "com.apple.sessionagent.screenIsLocked" as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, ptr,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinLockBridge>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .onLocked?(false)
            },
            "com.apple.sessionagent.screenIsUnlocked" as CFString,
            nil,
            .deliverImmediately
        )
    }

    func uninstall() {
        guard installed else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque()
        )
        installed = false
        onLocked = nil
    }
}
