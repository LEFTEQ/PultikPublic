#if DEBUG
import Foundation
import QuartzCore

/// Debug-only: how long the main thread stays busy between run-loop sleeps,
/// so `panel-drive.sh stalls start|stop` can put a number on "sluggish".
/// A busy stretch is AfterWaiting → BeforeWaiting; one over a 120 Hz frame
/// (8.3 ms) is a stall, one over 50 ms a hitch the operator feels.
@MainActor
final class MainStallMonitor {
    static let shared = MainStallMonitor()

    private var observer: CFRunLoopObserver?
    private var busySince: CFTimeInterval?
    private var startedAt: CFTimeInterval = 0
    private var stretches: [Double] = []

    func start() {
        stop()
        stretches = []
        startedAt = CACurrentMediaTime()
        busySince = startedAt
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, CFIndex.max
        ) { _, activity in
            MainActor.assumeIsolated { MainStallMonitor.shared.note(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func note(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            busySince = now
        } else if let since = busySince {
            stretches.append((now - since) * 1000)
            busySince = nil
        }
    }

    /// Stops and reports the window's busy stretches in milliseconds.
    @discardableResult
    func stop() -> [String: Any] {
        guard let observer else { return [:] }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
        let window = (CACurrentMediaTime() - startedAt) * 1000
        let sorted = stretches.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.down)))]
        }
        func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        let stalls = sorted.filter { $0 > 8.3 }
        return [
            "windowMs": rounded(window),
            "busyMs": rounded(sorted.reduce(0, +)),
            "stretches": sorted.count,
            "stalls": stalls.count,
            "stallMs": rounded(stalls.reduce(0, +)),
            "hitches": sorted.filter { $0 > 50 }.count,
            "p50Ms": rounded(percentile(0.5)),
            "p95Ms": rounded(percentile(0.95)),
            "maxMs": rounded(sorted.last ?? 0),
            "top": sorted.suffix(8).reversed().map(rounded),
        ]
    }
}
#endif
