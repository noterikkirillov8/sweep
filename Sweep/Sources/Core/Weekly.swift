import CoreGraphics
import Foundation
import IOKit.ps

/// The weekly quiet check: a background scan that shows nothing unless a lot is reclaimable.
enum Weekly {
    static let interval: TimeInterval = 7 * 86400

    static func ready(power: (onAC: Bool, batteryPercent: Double?), idleSeconds: Double) -> Bool {
        idleSeconds > 300 && (power.onAC || (power.batteryPercent ?? 0) >= 50)
    }

    static func shouldNotify(_ bytes: Int64, thresholdGB: Int) -> Bool { thresholdGB > 0 && bytes >= Int64(thresholdGB) * 1_000_000_000 }

    static func powerStatus() -> (onAC: Bool, batteryPercent: Double?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let kind = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return (false, nil) }
        if kind as String == kIOPSACPowerValue { return (true, nil) }
        guard kind as String == kIOPSBatteryPowerValue, let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return (false, nil) }
        for source in sources as NSArray {
            guard let details = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = details[kIOPSCurrentCapacityKey] as? Double, let max = details[kIOPSMaxCapacityKey] as? Double,
                  max > 0, (0...max).contains(current) else { continue }
            return (false, 100 * current / max)
        }
        return (false, nil)
    }

    static func idleSeconds() -> Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }

    /// Same numbers a manual scan would show as reclaimable: sized folders not in use, plus Docker when it answers.
    static func reclaimable(_ cfg: ScanConfig, dockerPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "", dockerExtra: [String] = Docker.extraDirs) -> Int64 {
        let folders = Scanner.find(cfg).filter { $0.selectable(now: cfg.now) }.reduce(Int64(0)) { $0 + ($1.size ?? Scanner.size(of: $1.urls)) }
        let docker = Docker.items(path: dockerPath, extra: dockerExtra)?.reduce(Int64(0)) { $0 + ($1.size ?? 0) } ?? 0
        return folders + docker
    }
}
