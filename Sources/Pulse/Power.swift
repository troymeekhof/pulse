import Foundation
import IOKit

// MARK: - SMC reader (unprivileged; same path Stats / iStat use)

final class SMC {
    private var conn: io_connect_t = 0

    // Layout must match the kernel's SMCParamStruct exactly (80 bytes).
    private struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0; var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
    private struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
    }
    private enum Selector: UInt8 { case handleYPCEvent = 2, readKey = 5, getKeyInfo = 9 }

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS else { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, UInt32(Selector.handleYPCEvent.rawValue),
                                          &input, MemoryLayout<SMCParamStruct>.stride, &output, &outSize)
        guard kr == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    /// Reads a key and decodes common numeric SMC types to Double.
    func readDouble(_ key: String) -> Double? {
        var info = SMCParamStruct()
        info.key = SMC.fourCC(key)
        info.data8 = Selector.getKeyInfo.rawValue
        guard let infoOut = call(&info) else { return nil }

        var read = SMCParamStruct()
        read.key = info.key
        read.keyInfo = infoOut.keyInfo
        read.data8 = Selector.readKey.rawValue
        guard let out = call(&read) else { return nil }

        let size = Int(infoOut.keyInfo.dataSize)
        let bytes: [UInt8] = withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
        let type = infoOut.keyInfo.dataType
        switch type {
        case SMC.fourCC("flt "):
            guard bytes.count == 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.load(as: Float32.self) })
        case SMC.fourCC("ui8 "): return bytes.first.map(Double.init)
        case SMC.fourCC("ui16"): return bytes.count == 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case SMC.fourCC("ui32"): return bytes.count == 4 ? Double(bytes.reduce(0) { ($0 << 8) | UInt32($1) }) : nil
        case SMC.fourCC("sp78"): return bytes.count == 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256 : nil
        case SMC.fourCC("fp88"): return bytes.count == 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256 : nil
        default: return nil
        }
    }
}

// MARK: - Power sample

struct PowerSample {
    var systemWatts: Double = 0      // whole-machine draw (SMC PSTR), or battery-derived fallback
    var cpuWatts: Double? = nil      // PCPC / package
    var gpuWatts: Double? = nil      // PGPR
    var source: String = "—"
    var onBattery: Bool = false
}

enum PowerReader {
    static let smc = SMC()

    static func read() -> PowerSample {
        var s = PowerSample()
        if let smc = smc {
            // PSTR = System Total power on Apple Silicon. PDTR = DC-in (adapter) total.
            if let w = smc.readDouble("PSTR"), w > 0 { s.systemWatts = w; s.source = "SMC" }
            else if let w = smc.readDouble("PDTR"), w > 0 { s.systemWatts = w; s.source = "SMC (DC-in)" }
            s.cpuWatts = smc.readDouble("PCPC") ?? smc.readDouble("PCPT")
            s.gpuWatts = smc.readDouble("PGPR") ?? smc.readDouble("PG0R")
        }
        if s.systemWatts <= 0, let b = batteryWatts() {
            s.systemWatts = b.watts; s.onBattery = b.discharging; s.source = "Battery"
        }
        return s
    }

    /// Fallback: instantaneous battery power from IOPMPowerSource (only meaningful on battery).
    private static func batteryWatts() -> (watts: Double, discharging: Bool)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMPowerSource"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any],
              let mV = (d["Voltage"] as? NSNumber)?.doubleValue,
              let mA = (d["InstantAmperage"] as? NSNumber)?.doubleValue else { return nil }
        let w = abs(mV * mA) / 1_000_000
        return (w, mA < 0)
    }
}

// MARK: - Energy store (Wh buckets, persisted)

final class EnergyStore {
    private(set) var minutes: [Int: Double] = [:]   // epoch-minute → Wh (kept 48 h)
    private(set) var hours: [Int: Double] = [:]     // epoch-hour   → Wh (kept 400 d)
    private(set) var since: Date
    private var dirty = false
    private var lastSave = Date()
    private let url: URL

    private struct Disk: Codable { var minutes: [Int: Double]; var hours: [Int: Double]; var since: Date }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("energy.json")
        since = Date()
        if let data = try? Data(contentsOf: url), let d = try? JSONDecoder().decode(Disk.self, from: data) {
            minutes = d.minutes; hours = d.hours; since = d.since
        }
    }

    /// Adds energy for `seconds` at `watts`.
    func add(watts: Double, seconds: Double, at date: Date = Date()) {
        guard watts > 0, seconds > 0, seconds < 120 else { return }   // skip gaps (sleep) — no data, no guess
        let wh = watts * seconds / 3600
        let t = Int(date.timeIntervalSince1970)
        minutes[t / 60, default: 0] += wh
        hours[t / 3600, default: 0] += wh
        dirty = true
        if Date().timeIntervalSince(lastSave) > 60 { save() }
    }

    func total(lastSeconds: TimeInterval, now: Date = Date()) -> Double {
        let cutoff = now.timeIntervalSince1970 - lastSeconds
        if lastSeconds <= 48 * 3600 {
            return minutes.reduce(0) { Double($1.key * 60) >= cutoff ? $0 + $1.value : $0 }
        }
        return hours.reduce(0) { Double($1.key * 3600 + 3600) > cutoff ? $0 + $1.value : $0 }
    }

    /// Projects a 30-day total from the average daily energy over the tracked window (up to 30 days).
    /// Time the Mac was asleep/off (no samples) counts as ~zero, which is what a real bill sees.
    func projection30(now: Date = Date()) -> (wh: Double, daysBasis: Double) {
        let elapsed = min(now.timeIntervalSince(since), 30 * 86400)
        guard elapsed >= 600 else { return (0, 0) }             // need ≥10 min of history
        let window = total(lastSeconds: elapsed, now: now)
        let days = elapsed / 86400
        return (window / days * 30, days)
    }

    func save() {
        let now = Int(Date().timeIntervalSince1970)
        minutes = minutes.filter { $0.key * 60 > now - 48 * 3600 }
        hours = hours.filter { $0.key * 3600 > now - 400 * 86400 }
        guard dirty else { return }
        if let data = try? JSONEncoder().encode(Disk(minutes: minutes, hours: hours, since: since)) {
            try? data.write(to: url, options: .atomic)
        }
        dirty = false; lastSave = Date()
    }

    func reset() {
        minutes = [:]; hours = [:]; since = Date(); dirty = true; save()
    }
}

extension Fmt {
    static func energy(_ wh: Double) -> String {
        if wh >= 1000 { return String(format: "%.2f kWh", wh / 1000) }
        if wh >= 100 { return String(format: "%.0f Wh", wh) }
        return String(format: "%.1f Wh", wh)
    }
    static func money(_ d: Double) -> String { String(format: "$%.2f", d) }
    static func watts(_ w: Double) -> String { String(format: w >= 100 ? "%.0f W" : "%.1f W", w) }
}
