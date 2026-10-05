import Foundation
import IOKit

// MARK: - Samples

struct NetSample {
    var downBps: Double = 0          // bytes / second
    var upBps: Double = 0
    var sessionDown: UInt64 = 0      // bytes since launch
    var sessionUp: UInt64 = 0
    var interface: String = ""       // busiest interface this tick (e.g. en0)
}

struct DiskSample {
    var readBps: Double = 0          // all physical drives combined (menu bar)
    var writeBps: Double = 0
    var sessionRead: UInt64 = 0
    var sessionWrite: UInt64 = 0
    var drives: [DriveSample] = []   // one per attached physical drive, boot drive first
}

struct VolumeInfo: Hashable {
    let name: String
    let total: UInt64
    let free: UInt64
}

struct DriveSample: Identifiable {
    enum Medium { case ssd, hdd, unknown }
    let id: UInt64                   // IORegistry entry ID — stable while attached
    var name: String
    var interconnect: String         // "Internal", "USB", "Thunderbolt", "SD Card"…
    var product: String
    var medium: Medium = .unknown
    var isInternal = false
    var isBoot = false
    var capacity: UInt64 = 0
    var volumes: [VolumeInfo] = []
    var readBps: Double = 0
    var writeBps: Double = 0
    var sessionRead: UInt64 = 0
    var sessionWrite: UInt64 = 0
    var readHistory: [Double] = []
    var writeHistory: [Double] = []

    // APFS volumes in one container report the same total/free — count each container once.
    private var containers: [VolumeInfo] {
        var seen = Set<String>(); var out: [VolumeInfo] = []
        for v in volumes where seen.insert("\(v.total)-\(v.free)").inserted { out.append(v) }
        return out
    }
    var free: UInt64 { containers.reduce(0) { $0 + $1.free } }
    var volumeTotal: UInt64 { containers.reduce(0) { $0 + $1.total } }
    var detail: String {
        var p = [interconnect]
        switch medium { case .ssd: p.append("SSD"); case .hdd: p.append("HDD"); case .unknown: break }
        return p.joined(separator: " · ")
    }
    var icon: String {
        if interconnect == "SD Card" { return "sdcard" }
        return isInternal ? "internaldrive" : "externaldrive"
    }
}

// MARK: - Network counters via getifaddrs (AF_LINK if_data) — unprivileged

final class NetReader {
    private var prev: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var prevTime: Date?
    private(set) var sessionDown: UInt64 = 0
    private(set) var sessionUp: UInt64 = 0

    private static let skipPrefixes = ["lo", "awdl", "llw", "gif", "stf", "bridge", "anpi", "ap"]

    func sample() -> NetSample {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return NetSample() }
        defer { freeifaddrs(addrs) }

        var now: [String: (rx: UInt64, tx: UInt64)] = [:]
        var p = addrs
        while let a = p {
            let ifa = a.pointee
            p = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let raw = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            if NetReader.skipPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            let d = raw.assumingMemoryBound(to: if_data.self).pointee
            now[name] = (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
        }

        var s = NetSample()
        let t = Date()
        if let pt = prevTime {
            let dt = t.timeIntervalSince(pt)
            if dt > 0 {
                var dRx: UInt64 = 0, dTx: UInt64 = 0, busiest = ("", UInt64(0))
                for (name, cur) in now {
                    guard let old = prev[name] else { continue }
                    // if_data counters are 32-bit and wrap.
                    let rx = cur.rx >= old.rx ? cur.rx - old.rx : cur.rx + (1 << 32) - old.rx
                    let tx = cur.tx >= old.tx ? cur.tx - old.tx : cur.tx + (1 << 32) - old.tx
                    dRx += rx; dTx += tx
                    if rx + tx > busiest.1 { busiest = (name, rx + tx) }
                }
                s.downBps = Double(dRx) / dt
                s.upBps = Double(dTx) / dt
                s.interface = busiest.0
                sessionDown += dRx; sessionUp += dTx
            }
        }
        prev = now; prevTime = t
        s.sessionDown = sessionDown; s.sessionUp = sessionUp
        return s
    }
}

// MARK: - Per-drive disk counters via IOBlockStorageDriver — unprivileged
//
// Each physical drive (internal SSD, USB HDD, Thunderbolt SSD, SD card) has one IOBlockStorageDriver
// with cumulative byte counters. Volumes are mapped back to their drive by walking up the IORegistry
// from each mounted /dev/diskNsM — this also works for APFS (volume → container → partition → disk).

final class DiskReader {
    private struct State {
        var prevR: UInt64, prevW: UInt64, baseR: UInt64, baseW: UInt64
        var histR = History(capacity: 60), histW = History(capacity: 60)
        var firstSeen: Date
    }
    private var states: [UInt64: State] = [:]
    private var prevTime: Date?
    private var volumeMap: [UInt64: [VolumeInfo]] = [:]
    private var bootDrive: UInt64?
    private var lastVolumeScan = Date.distantPast
    private var lastDriveSet: Set<UInt64> = []

    func sample() -> DiskSample {
        let t = Date()
        let dt = prevTime.map { t.timeIntervalSince($0) } ?? 0
        prevTime = t

        var drives = DiskReader.enumerateDrives()
        let ids = Set(drives.map { $0.sample.id })
        // Remap volumes every 3 s, or immediately when a drive is plugged in / ejected.
        if ids != lastDriveSet || t.timeIntervalSince(lastVolumeScan) > 3 {
            (volumeMap, bootDrive) = DiskReader.scanVolumes()
            lastVolumeScan = t
            lastDriveSet = ids
        }
        states = states.filter { ids.contains($0.key) }

        var out = DiskSample()
        for i in drives.indices {
            let id = drives[i].sample.id
            let (r, w) = (drives[i].rawRead, drives[i].rawWrite)
            var st = states[id] ?? State(prevR: r, prevW: w, baseR: r, baseW: w, firstSeen: t)
            var rb = 0.0, wb = 0.0
            if dt > 0 {
                rb = Double(r >= st.prevR ? r - st.prevR : 0) / dt
                wb = Double(w >= st.prevW ? w - st.prevW : 0) / dt
            }
            st.prevR = r; st.prevW = w
            st.histR.push(rb); st.histW.push(wb)
            states[id] = st

            var d = drives[i].sample
            d.readBps = rb; d.writeBps = wb
            d.sessionRead = r >= st.baseR ? r - st.baseR : 0
            d.sessionWrite = w >= st.baseW ? w - st.baseW : 0
            d.readHistory = st.histR.values
            d.writeHistory = st.histW.values
            d.volumes = volumeMap[id] ?? []
            d.isBoot = (id == bootDrive)
            d.name = DiskReader.displayName(d)
            drives[i].sample = d

            out.readBps += rb; out.writeBps += wb
            out.sessionRead += d.sessionRead; out.sessionWrite += d.sessionWrite
        }
        // Boot drive first, other internals next, then externals in the order they were plugged in.
        out.drives = drives.map(\.sample).sorted { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            if a.isInternal != b.isInternal { return a.isInternal }
            return (states[a.id]?.firstSeen ?? t) < (states[b.id]?.firstSeen ?? t)
        }
        return out
    }

    private static func displayName(_ d: DriveSample) -> String {
        if d.isBoot { return d.medium == .hdd ? "Internal Drive" : "Internal SSD" }
        if let v = d.volumes.first?.name, !v.isEmpty {
            return d.volumes.count > 1 ? "\(v) +\(d.volumes.count - 1)" : v
        }
        if !d.product.isEmpty { return d.product }
        return d.isInternal ? "Internal Drive" : "External Drive"
    }

    // MARK: enumerate physical drives

    private struct RawDrive { var sample: DriveSample; var rawRead: UInt64; var rawWrite: UInt64 }

    private static func props(_ e: io_registry_entry_t, _ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
    }
    private static func value(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func enumerateDrives() -> [RawDrive] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }

        var out: [RawDrive] = []
        var drv = IOIteratorNext(it)
        while drv != 0 {
            defer { IOObjectRelease(drv); drv = IOIteratorNext(it) }

            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(drv, &id)
            let stats = props(drv, "Statistics") ?? [:]
            let rawR = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let rawW = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0

            // Provider = the block storage device (NVMe, USB mass storage, SD reader…)
            var dev: io_registry_entry_t = 0
            var devChars: [String: Any] = [:], proto: [String: Any] = [:]
            var devClass = ""
            if IORegistryEntryGetParentEntry(drv, kIOServicePlane, &dev) == KERN_SUCCESS {
                devChars = props(dev, "Device Characteristics") ?? [:]
                proto = props(dev, "Protocol Characteristics") ?? [:]
                var name = [CChar](repeating: 0, count: 128)
                IOObjectGetClass(dev, &name)
                devClass = String(cString: name)
                IOObjectRelease(dev)
            }
            let link = (proto["Physical Interconnect"] as? String) ?? ""
            let location = (proto["Physical Interconnect Location"] as? String) ?? ""
            // Skip disk images, RAM disks and other virtual devices.
            if link.localizedCaseInsensitiveContains("virtual") || devClass.contains("HDIX") || devClass.contains("RAMDisk") { continue }

            // Child = whole-disk IOMedia (size, ejectable)
            var media: io_registry_entry_t = 0
            var size: UInt64 = 0, ejectable = false
            if IORegistryEntryGetChildEntry(drv, kIOServicePlane, &media) == KERN_SUCCESS {
                size = (value(media, "Size") as? NSNumber)?.uint64Value ?? 0
                ejectable = (value(media, "Ejectable") as? Bool) ?? false
                IOObjectRelease(media)
            }
            if size == 0 { continue }   // empty card reader / no media inserted

            var d = DriveSample(id: id, name: "", interconnect: "", product: "")
            d.product = ((devChars["Product Name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            switch (devChars["Medium Type"] as? String) ?? "" {
            case "Solid State": d.medium = .ssd
            case "Rotational": d.medium = .hdd
            default: d.medium = .unknown
            }
            d.isInternal = location == "Internal" || (location.isEmpty && !ejectable)
            d.capacity = size
            let l = link.lowercased()
            if l.contains("secure digital") || l == "sd" { d.interconnect = "SD Card" }
            else if l.contains("usb") { d.interconnect = "USB" }
            else if (l.contains("pci") || l.contains("thunderbolt")) && !d.isInternal { d.interconnect = "Thunderbolt" }
            else if l.contains("sata") && !d.isInternal { d.interconnect = "SATA" }
            else if d.isInternal { d.interconnect = "Internal" }
            else { d.interconnect = link.isEmpty ? "External" : link }
            if d.isInternal && d.medium == .unknown && d.interconnect == "Internal" { d.medium = .ssd }

            out.append(RawDrive(sample: d, rawRead: rawR, rawWrite: rawW))
        }
        return out
    }

    // MARK: map mounted volumes → drive

    private static func driverID(forBSD bsd: String) -> UInt64? {
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, match)
        var depth = 0
        while entry != 0 && depth < 24 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(entry, &id)
                IOObjectRelease(entry)
                return id
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS else { return nil }
            entry = parent
            depth += 1
        }
        if entry != 0 { IOObjectRelease(entry) }
        return nil
    }

    private static func cString<T>(_ t: T) -> String {
        withUnsafeBytes(of: t) { raw in
            let b = raw.bindMemory(to: CChar.self)
            let end = b.firstIndex(of: 0) ?? b.count
            return String(decoding: raw.prefix(end), as: UTF8.self)
        }
    }

    private static func scanVolumes() -> ([UInt64: [VolumeInfo]], UInt64?) {
        var mnts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&mnts, MNT_NOWAIT)
        guard n > 0, let m = mnts else { return ([:], nil) }
        var map: [UInt64: [VolumeInfo]] = [:]
        var boot: UInt64?
        for i in 0..<Int(n) {
            let s = m[i]
            let from = cString(s.f_mntfromname)
            let on = cString(s.f_mntonname)
            guard from.hasPrefix("/dev/disk") else { continue }
            if on == "/System/Volumes/Data" {   // fallback way to find the boot drive
                if boot == nil { boot = driverID(forBSD: String(from.dropFirst(5))) }
                continue
            }
            guard on == "/" || on.hasPrefix("/Volumes/") else { continue }   // skip /System/Volumes/*, VM, Preboot…
            guard let id = driverID(forBSD: String(from.dropFirst(5))) else { continue }
            let bsize = UInt64(s.f_bsize)
            let name = on == "/"
                ? ((try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD")
                : URL(fileURLWithPath: on).lastPathComponent
            let v = VolumeInfo(name: name, total: UInt64(s.f_blocks) * bsize, free: UInt64(s.f_bavail) * bsize)
            if on == "/" { boot = id; map[id, default: []].insert(v, at: 0) }
            else if s.f_flags & UInt32(MNT_DONTBROWSE) != 0 { continue }
            else { map[id, default: []].append(v) }
        }
        return (map, boot)
    }
}

extension Fmt {
    /// Bytes per second → "12.4 MB/s"
    static func rate(_ bps: Double) -> String {
        switch bps {
        case ..<1_000: return String(format: "%.0f B/s", bps)
        case ..<1_000_000: return String(format: "%.0f KB/s", bps / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f MB/s", bps / 1_000_000)
        default: return String(format: "%.2f GB/s", bps / 1_000_000_000)
        }
    }
    /// Bytes per second → "99 Mbps"
    static func mbps(_ bps: Double) -> String {
        let m = bps * 8 / 1_000_000
        return m >= 1000 ? String(format: "%.2f Gbps", m / 1000) : String(format: m >= 10 ? "%.0f Mbps" : "%.1f Mbps", m)
    }
    /// Bytes total (decimal, like Finder) → "1.2 GB"
    static func bytesDec(_ b: UInt64) -> String {
        let d = Double(b)
        switch d {
        case ..<1_000_000: return String(format: "%.0f KB", d / 1_000)
        case ..<1_000_000_000: return String(format: "%.0f MB", d / 1_000_000)
        default: return String(format: "%.2f GB", d / 1_000_000_000)
        }
    }
}
