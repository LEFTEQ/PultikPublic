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

    /// Every external monitor that answered a brightness read, with its level.
    static func displays() -> [Display] {
        guard let bridge else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [Display] = []
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
            if let (current, max) = readBrightness(av, bridge) {
                found.append(Display(id: entryID, service: av, maxValue: max, current: current))
            }
        }
        return found
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
