import Foundation
import IOKit.ps

// MARK: - BatteryMonitor
//
// Polls the power source on a timer and reports whether the Mac is currently
// running on battery. Owns only this one concern; the coordinator decides what
// to do with the answer.

@MainActor
final class BatteryMonitor {

    /// Called on `start()` and after each poll with the current state.
    var onChange: ((_ onBattery: Bool) -> Void)?

    private var timer: Timer?
    private let interval: TimeInterval

    init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    func start() {
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-checks immediately (e.g. when the user flips the related setting).
    func evaluate() {
        onChange?(isOnBatteryPower())
    }

    private func isOnBatteryPower() -> Bool {
        guard let rawInfo = IOPSCopyPowerSourcesInfo() else { return false }
        let snapshot = rawInfo.takeRetainedValue()
        guard let rawList = IOPSCopyPowerSourcesList(snapshot) else { return false }
        let sources = rawList.takeRetainedValue() as [CFTypeRef]
        return sources.contains { source in
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let state = info[kIOPSPowerSourceStateKey as String] as? String
            else { return false }
            return state == kIOPSBatteryPowerValue as String
        }
    }
}
