import Foundation
import IOKit.ps

/// Watches the two power conditions the engine can pause on: system Low
/// Power Mode, and a low battery while unplugged. Purely observational —
/// EngineController decides what to do with the state.
public final class PowerMonitor {
    public private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    public private(set) var isLowBattery = false
    /// Fired on the main queue whenever either flag flips.
    public var onChange: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var observer: NSObjectProtocol?

    public init() {}

    public func start() {
        isLowBattery = PowerMonitor.readLowBattery()

        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            // Delivered on an arbitrary queue — state read + callback on main.
            DispatchQueue.main.async { self?.refreshLowPowerMode() }
        }

        // IOKit fires this on any power-source change (plug/unplug and every
        // capacity tick), on the run loop the source is added to.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().refreshBattery()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    private func refreshLowPowerMode() {
        let now = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard now != isLowPowerMode else { return }
        isLowPowerMode = now
        onChange?()
    }

    private func refreshBattery() {
        let now = PowerMonitor.readLowBattery()
        guard now != isLowBattery else { return }
        isLowBattery = now
        onChange?()
    }

    /// True when the internal battery is discharging below 20%. Macs without
    /// a battery report no internal-battery source, so this stays false.
    public static func readLowBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 100
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? (current * 100) / max : 100
            if onBattery && percent < 20 { return true }
        }
        return false
    }
}
