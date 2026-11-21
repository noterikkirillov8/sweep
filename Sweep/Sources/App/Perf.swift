import Foundation

/// `-perf`: prints timings to stdout (open to first frame, each scan, main-thread stalls while scanning).
enum Perf {
    static let on = CommandLine.arguments.contains("-perf")
    nonisolated static func log(_ s: String) { if on { print("[perf] " + s); fflush(stdout) } }
    nonisolated static func ms(since t: CFAbsoluteTime) -> Int { Int((CFAbsoluteTimeGetCurrent() - t) * 1000) }

    nonisolated(unsafe) private static var openAt: CFAbsoluteTime = 0
    nonisolated(unsafe) private static var scanAt: CFAbsoluteTime = 0
    nonisolated(unsafe) private static var monitor: StallMonitor?

    static func openStarted() { openAt = CFAbsoluteTimeGetCurrent() }
    static func firstFrame() { log("open to first frame: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - openAt) * 1000)) ms") }

    static func scanStarted() {
        guard on else { return }
        scanAt = CFAbsoluteTimeGetCurrent(); monitor = StallMonitor(); monitor?.start()
    }
    static func scanFinished() {
        guard on else { return }
        log("scan refresh: \(ms(since: scanAt)) ms")
        if let m = monitor { m.stop(); log("main thread while scanning: \(m.report)") }
        monitor = nil
    }
}

/// Pings the main queue every 8 ms from a background timer and records how late each ping arrives.
final class StallMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var maxLag = 0.0, over16 = 0, pings = 0, big: [(Double, Double)] = []
    private let t0 = CFAbsoluteTimeGetCurrent()
    private var timer: DispatchSourceTimer?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(8))
        t.setEventHandler { [self] in
            let sent = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async { [self] in
                let lag = (CFAbsoluteTimeGetCurrent() - sent) * 1000
                lock.lock(); pings += 1; maxLag = max(maxLag, lag); if lag > 16.7 { over16 += 1; if lag > 50 { big.append((CFAbsoluteTimeGetCurrent() - t0, lag)) } }; lock.unlock()
            }
        }
        t.resume(); timer = t
    }
    func stop() { timer?.cancel(); timer = nil }
    var report: String {
        lock.lock(); defer { lock.unlock() }
        return "stalls >50 ms at (s, ms): \(big.prefix(12).map { String(format: "%.1f/%.0f", $0.0, $0.1) }.joined(separator: " ")); max stall \(String(format: "%.1f", maxLag)) ms, \(over16) of \(pings) pings over 16.7 ms"
    }
}
