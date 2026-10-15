import Foundation
import IOKit

/// Brightness of third-party monitors over DDC/CI, the way m1ddc and
/// MonitorControl do it on Apple Silicon: every external display hangs off a
/// `DCPAVServiceProxy` in the IORegistry, and IOKit's private `IOAVService`
/// I2C calls carry the VCP packets (docs/specs/2026-09-04-dim-displays-
/// decisions.md).
///
/// Apple's own external displays sit on the same bus but do not speak DDC —
/// their "reply" is bus noise — so a display only counts when its answer to
/// a brightness read is a well-formed VCP reply for the code we asked about.
/// Those displays are `DisplayServices`' business.
///
/// Every I2C call sleeps a few tens of milliseconds and may need a retry;
/// callers keep this off the main actor.
enum DDCDisplays {
    struct Display {
        /// IORegistry entry id — stable while the monitor stays plugged in,
        /// which is exactly as long as a dim/restore round trip needs.
        let id: UInt64
        let service: AnyObject
        let maxValue: Int
        let current: Int

        var key: String { "ddc:\(id)" }
        var brightness: Double { maxValue > 0 ? Double(current) / Double(maxValue) : 0 }
    }

    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias Transfer = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private struct Bridge {
        let create: Create
        let write: Transfer
        let read: Transfer
    }

    private static let bridge: Bridge? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let write = dlsym(handle, "IOAVServiceWriteI2C"),
              let read = dlsym(handle, "IOAVServiceReadI2C")
        else {
            NSLog("pultik: IOAVService unavailable — DDC dimming disabled")
            return nil
        }
        return Bridge(
            create: unsafeBitCast(create, to: Create.self),
            write: unsafeBitCast(write, to: Transfer.self),
            read: unsafeBitCast(read, to: Transfer.self))
    }()

    private static let i2cAddress: UInt32 = 0x37
    private static let hostAddress: UInt8 = 0x51
    private static let brightnessVCP: UInt8 = 0x10

    /// What a VCP brightness probe concluded about one external service, and
    /// when. `maxValue` is the display's own range, which does not drift.
    private struct Verdict {
        let speaksDDC: Bool
        let maxValue: Int
        let current: Int
        let probedAt: Date
    }

    /// Probing costs ~59 ms per external service (a VCP request, a 50 ms
    /// settle, a read) and the answer almost never changes: a Studio Display
    /// or Pro Display XDR is on the same bus but will never speak DDC, and a
    /// monitor's `maxValue` is fixed. Re-probing all of them on every apply
    /// pass was 176 of the 191 ms an apply cost, 118 ms of it spent proving
    /// again that two Apple panels are not DDC targets
    /// (docs/specs/2026-09-10-display-preset-drag-decisions.md).
    ///
    /// Keyed by IORegistry entry id, which is fresh after any replug, so
    /// hotplug re-probes on its own. `nonisolated(unsafe)` + a lock rather
    /// than an actor: the only caller is `BrightnessStore.push`, which is
    /// synchronous and already off the main actor.
    private nonisolated(unsafe) static var verdicts: [UInt64: Verdict] = [:]
    private static let verdictLock = NSLock()

    /// How long a "does not speak DDC" verdict stands. Positive verdicts never
    /// expire; a negative one can be wrong for a monitor that was asleep or
    /// switched to another input when it was asked, and replugging is not the
    /// only way that clears.
    private static let negativeVerdictTTL: TimeInterval = 300

    private static func verdict(for id: UInt64) -> Verdict? {
        verdictLock.lock()
        defer { verdictLock.unlock() }
        guard let known = verdicts[id] else { return nil }
        guard !known.speaksDDC, Date().timeIntervalSince(known.probedAt) > negativeVerdictTTL
        else { return known }
        verdicts[id] = nil
        return nil
    }

    private static func record(_ verdict: Verdict, for id: UInt64) {
        verdictLock.lock()
        verdicts[id] = verdict
        verdictLock.unlock()
    }

    /// Every external monitor that answered a brightness read, with its level.
    /// The IORegistry walk runs every time (it is sub-millisecond); only the
    /// I2C probe behind it is remembered.
    static func displays() -> [Display] {
        guard let bridge else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [Display] = []
        var live: Set<UInt64> = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { service = IOIteratorNext(iterator) }
            let location = IORegistryEntryCreateCFProperty(
                service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard location == "External",
                  let av = bridge.create(kCFAllocatorDefault, service)?.takeRetainedValue()
            else { IOObjectRelease(service); continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            IOObjectRelease(service)
            live.insert(entryID)

            if let known = verdict(for: entryID) {
                guard known.speaksDDC else { continue }
                // `current` is the level at probe time and is deliberately not
                // refreshed — `setBrightness` writes absolutely and reads only
                // `maxValue`, so a read here would buy nothing for 59 ms.
                found.append(Display(id: entryID, service: av,
                                     maxValue: known.maxValue, current: known.current))
                continue
            }

            let reading = readBrightness(av, bridge)
            record(Verdict(speaksDDC: reading != nil,
                           maxValue: reading?.max ?? 0,
                           current: reading?.current ?? 0,
                           probedAt: Date()),
                   for: entryID)
            if let (current, max) = reading {
                found.append(Display(id: entryID, service: av, maxValue: max, current: current))
            }
        }
        // Unplugged displays must not pin their verdict forever; entry ids are
        // not reused, so this is the only thing keeping the map bounded.
        verdictLock.lock()
        verdicts = verdicts.filter { live.contains($0.key) }
        verdictLock.unlock()
        return found
    }

    /// A LIVE VCP read of one monitor's level, 0…1 — nil when it refuses.
    ///
    /// `displays()` remembers its probe, so `Display.current` is the level at
    /// discovery time and does NOT track the monitor. That is fine for writes
    /// (they are absolute and use only `maxValue`), but anything that must
    /// remember where a monitor actually is right now — the screens-off
    /// snapshot, whose whole job is putting that level back — has to ask
    /// again and pay the ~59 ms.
    static func currentBrightness(of display: Display) -> Double? {
        guard let bridge, let reading = readBrightness(display.service, bridge), reading.max > 0
        else { return nil }
        return Double(reading.current) / Double(reading.max)
    }

    /// 0…1 of the display's own range. False when the monitor refuses.
    @discardableResult
    static func setBrightness(_ value: Double, of display: Display) -> Bool {
        guard let bridge else { return false }
        let level = Int((min(max(value, 0), 1) * Double(display.maxValue)).rounded())
        var packet: [UInt8] = [0x84, 0x03, brightnessVCP, UInt8(level >> 8), UInt8(level & 0xFF), 0]
        packet[5] = checksum(packet.dropLast())
        return send(packet, to: display.service, bridge)
    }

    private static func readBrightness(_ av: AnyObject, _ bridge: Bridge) -> (current: Int, max: Int)? {
        var request: [UInt8] = [0x82, 0x01, brightnessVCP, 0]
        request[3] = checksum(request.dropLast())
        guard send(request, to: av, bridge) else { return nil }
        usleep(50_000)
        var reply = [UInt8](repeating: 0, count: 12)
        let status = reply.withUnsafeMutableBytes {
            bridge.read(av, i2cAddress, UInt32(hostAddress), $0.baseAddress!, 12)
        }
        // A real VCP reply: source 0x6E, opcode 0x02, our VCP code echoed back.
        // Anything else is an Apple display's bus noise, and is not a monitor
        // this path may write to.
        guard status == KERN_SUCCESS, reply[0] == 0x6E, reply[2] == 0x02, reply[4] == brightnessVCP
        else { return nil }
        let max = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        guard max > 0 else { return nil }
        return (current, max)
    }

    private static func send(_ packet: [UInt8], to av: AnyObject, _ bridge: Bridge) -> Bool {
        var bytes = packet
        let count = UInt32(bytes.count)
        for attempt in 0..<3 {
            let status = bytes.withUnsafeMutableBytes {
                bridge.write(av, i2cAddress, UInt32(hostAddress), $0.baseAddress!, count)
            }
            if status == KERN_SUCCESS { return true }
            if attempt < 2 { usleep(20_000) }
        }
        return false
    }

    /// DDC checksum: XOR of the destination (0x6E), the host address and the
    /// payload.
    private static func checksum<S: Sequence>(_ payload: S) -> UInt8 where S.Element == UInt8 {
        payload.reduce(0x6E ^ hostAddress) { $0 ^ $1 }
    }
}
