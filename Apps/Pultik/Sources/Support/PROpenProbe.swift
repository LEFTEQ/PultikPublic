import Foundation
import QuartzCore

/// Debug-only: how long a PR takes to open, from the key or click that asked
/// for its detail to each part of it on screen (`panel-drive.sh state` →
/// `prOpen`). Each mark also records when the main thread next went idle
/// after it (`<mark>Idle`): that is when the frame showing it was committed
/// and the panel could take the next key. Release builds compile it away.
@MainActor
enum PROpenProbe {
    #if DEBUG
    private static var id: String?
    private static var startedAt: CFTimeInterval = 0
    private static var marks: [String: Double] = [:]
    private static var history: [[String: Any]] = []
    /// Body evaluations by view since launch, and as they stood at `begin`.
    private static var passes: [String: Int] = [:]
    private static var passesAtBegin: [String: Int] = [:]
    #endif

    /// `view`'s body ran: each mark's idle point reports how many times each
    /// view re-evaluated since the open began.
    static func pass(_ view: String) {
        #if DEBUG
        passes[view, default: 0] += 1
        #endif
    }

    /// A PR detail was asked for (↵, a click, or the cursor moving with the detail open).
    static func begin(_ id: String) {
        #if DEBUG
        if let previous = self.id, !marks.isEmpty { archive(previous) }
        self.id = id
        startedAt = CACurrentMediaTime()
        marks = [:]
        passesAtBegin = passes
        #endif
    }

    /// `name` became visible for `id`'s detail; only the first time counts.
    static func mark(_ name: String, id: String) {
        #if DEBUG
        guard id == self.id, marks[name] == nil else { return }
        let started = startedAt
        marks[name] = elapsed(since: started)
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated {
                guard PROpenProbe.id == id, PROpenProbe.startedAt == started else { return }
                PROpenProbe.marks[name + "Idle"] = PROpenProbe.elapsed(since: started)
                for (view, count) in PROpenProbe.passes {
                    PROpenProbe.marks["\(name)Passes.\(view)"] = Double(count - PROpenProbe.passesAtBegin[view, default: 0])
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        #endif
    }

    #if DEBUG
    private static func elapsed(since started: CFTimeInterval) -> Double {
        ((CACurrentMediaTime() - started) * 10_000).rounded() / 10
    }

    private static func archive(_ id: String) {
        history.append(["id": id, "marks": marks])
        if history.count > 40 { history.removeFirst(history.count - 40) }
    }

    /// The open in progress (or last finished) and the ones before it.
    static var report: [String: Any] {
        ["current": ["id": id ?? NSNull(), "marks": marks] as [String: Any], "history": history]
    }

    static func reset() {
        id = nil
        marks = [:]
        history = []
    }
    #endif
}
