import Foundation
import AppKit
import IOKit
import Combine

// MARK: - Sample models

struct GPUSample {
    var utilization: Double = 0        // 0–100, device utilization
    var renderer: Double = 0           // 0–100
    var tiler: Double = 0              // 0–100
    var inUseBytes: UInt64 = 0         // GPU-resident system memory in use
    var allocatedBytes: UInt64 = 0     // GPU-allocated system memory
    var name: String = "Apple GPU"
    var coreCount: Int = 0
}

struct MemorySample {
    var total: UInt64 = 0
    var app: UInt64 = 0        // internal (anonymous) minus purgeable — Activity Monitor "App Memory"
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0     // file-backed / purgeable
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Pressure = .normal

    enum Pressure: Int { case normal = 1, warning = 2, critical = 4
        var label: String { switch self { case .normal: return "Normal"; case .warning: return "Elevated"; case .critical: return "Critical" } }
    }

    /// Memory Activity Monitor calls "used": app + wired + compressed.
    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct ThermalSample {
    var state: ProcessInfo.ThermalState = .nominal
    var cpuSpeedLimit: Int? = nil       // % of max clock the system currently allows (from pmset)
    var schedulerLimit: Int? = nil      // % of CPU time available to apps
    var isThrottling: Bool {
        if state == .serious || state == .critical { return true }
        if let s = cpuSpeedLimit, s < 100 { return true }
        return false
    }
    var label: String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Throttling"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    var detail: String {
        switch state {
        case .nominal: return "Running at full speed."
        case .fair: return "Warming up — fans may ramp, no slowdown yet."
        case .serious: return "Hot — macOS is reducing CPU/GPU clocks."
        case .critical: return "Very hot — heavy throttling to protect hardware."
        @unknown default: return ""
        }
    }
}

// MARK: - Ring buffer

struct History {
    private(set) var values: [Double]
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity; values = Array(repeating: 0, count: capacity) }
    mutating func push(_ v: Double) { values.removeFirst(); values.append(v) }
    var last: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }
    var average: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
}

// MARK: - Monitor

@MainActor
final class Monitor: ObservableObject {
    @Published var gpu = GPUSample()
    @Published var memory = MemorySample()
    @Published var thermal = ThermalSample()
    @Published var power = PowerSample()
    @Published var powerHistory = History(capacity: 90)
    @Published var energy = EnergyTotals()
    let store = EnergyStore()
    private var lastTick: Date?

    struct EnergyTotals {
        var hour: Double = 0, day: Double = 0, month: Double = 0, year: Double = 0
        var projected30: Double = 0, projectionDays: Double = 0
        var since = Date()
    }
    @Published var gpuHistory = History(capacity: 90)
    @Published var memHistory = History(capacity: 90)

    // Network + disk throughput
    @Published var net = NetSample()
    @Published var disk = DiskSample()
    @Published var io = IOSnapshot()
    @Published var netDownHistory = History(capacity: 90)
    @Published var netUpHistory = History(capacity: 90)
    @Published var diskReadHistory = History(capacity: 90)
    @Published var diskWriteHistory = History(capacity: 90)
    // NAS totals arrive every ~2 s with the nettop sample → 45 points ≈ the same 90 s window
    @Published var nasInHistory = History(capacity: 45)
    @Published var nasOutHistory = History(capacity: 45)
    private let netReader = NetReader()
    private let diskReader = DiskReader()
    private let ioSampler = ProcessIOSampler()
    private var ioBusy = false
    private var lastIO = Date.distantPast

    @Published var interval: Double {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); restart() }
    }

    let chipName: String
    private var timer: Timer?

    init() {
        let saved = UserDefaults.standard.double(forKey: "interval")
        interval = saved > 0 ? saved : 1.0
        chipName = Monitor.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        gpu.coreCount = Monitor.gpuCoreCount()
        tick()
        restart()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.store.save()
        }
    }

    func resetEnergy() { store.reset(); refreshTotals() }

    private func refreshTotals() {
        energy.hour = store.total(lastSeconds: 3600)
        energy.day = store.total(lastSeconds: 86400)
        energy.month = store.total(lastSeconds: 30 * 86400)
        energy.year = store.total(lastSeconds: 365 * 86400)
        energy.since = store.since
        let p = store.projection30()
        energy.projected30 = p.wh
        energy.projectionDays = p.daysBasis
    }

    private func restart() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        if let g = Monitor.readGPU() {
            gpu.utilization = g.utilization
            gpu.renderer = g.renderer
            gpu.tiler = g.tiler
            gpu.inUseBytes = g.inUseBytes
            gpu.allocatedBytes = g.allocatedBytes
        }
        memory = Monitor.readMemory()
        gpuHistory.push(gpu.utilization)
        memHistory.push(memory.usedFraction * 100)

        // Power → energy integration
        let now = Date()
        power = PowerReader.read()
        if let last = lastTick {
            store.add(watts: power.systemWatts, seconds: now.timeIntervalSince(last), at: now)
        }
        lastTick = now
        powerHistory.push(power.systemWatts)
        refreshTotals()

        // Network + disk totals (cheap counters, every tick)
        net = netReader.sample()
        disk = diskReader.sample()
        netDownHistory.push(net.downBps)
        netUpHistory.push(net.upBps)
        diskReadHistory.push(disk.readBps)
        diskWriteHistory.push(disk.writeBps)

        // Per-app + NAS breakdown (spawns nettop) every ~2 s, off the main thread
        if now.timeIntervalSince(lastIO) >= 2, !ioBusy {
            lastIO = now
            ioBusy = true
            let sampler = ioSampler
            Task.detached(priority: .utility) { [weak self] in
                let snap = sampler.sample()
                await MainActor.run {
                    self?.io = snap
                    self?.nasInHistory.push(snap.nasIn)
                    self?.nasOutHistory.push(snap.nasOut)
                    self?.ioBusy = false
                }
            }
        }

        thermal.state = ProcessInfo.processInfo.thermalState
        // pmset spawns a process; refresh it every ~3 s rather than every tick.
        if now.timeIntervalSince(lastPmset) >= 3 {
            lastPmset = now
            Task.detached(priority: .utility) { [weak self] in
                let limits = Monitor.readPmsetTherm()
                await MainActor.run {
                    self?.thermal.cpuSpeedLimit = limits.speed
                    self?.thermal.schedulerLimit = limits.scheduler
                }
            }
        }
    }

    private var lastPmset = Date.distantPast

    // MARK: Thermal limits via `pmset -g therm` (no root needed)

    nonisolated static func readPmsetTherm() -> (speed: Int?, scheduler: Int?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "therm"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        func grab(_ key: String) -> Int? {
            guard let r = out.range(of: key) else { return nil }
            let tail = out[r.upperBound...]
            let digits = tail.drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits)
        }
        return (grab("CPU_Speed_Limit"), grab("CPU_Scheduler_Limit"))
    }

    // MARK: GPU via IOKit (IOAccelerator PerformanceStatistics — works unprivileged on Apple Silicon)

    nonisolated static func readGPU() -> GPUSample? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var result: GPUSample? = nil
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let cf = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let stats = cf.takeRetainedValue() as? [String: Any] else { continue }

            var s = GPUSample()
            s.utilization = num(stats, ["Device Utilization %", "GPU Activity(%)"])
            s.renderer   = num(stats, ["Renderer Utilization %"])
            s.tiler      = num(stats, ["Tiler Utilization %"])
            s.inUseBytes = UInt64(num(stats, ["In use system memory"]))
            s.allocatedBytes = UInt64(num(stats, ["Alloc system memory"]))
            result = s
            break
        }
        return result
    }

    nonisolated private static func num(_ d: [String: Any], _ keys: [String]) -> Double {
        for k in keys {
            if let v = d[k] as? NSNumber { return v.doubleValue }
        }
        return 0
    }

    nonisolated static func gpuCoreCount() -> Int {
        // AGXAccelerator exposes "gpu-core-count" in the registry on Apple Silicon.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        if let cf = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0),
           let n = cf.takeRetainedValue() as? NSNumber { return n.intValue }
        return 0
    }

    // MARK: Memory via Mach + sysctl

    nonisolated static func readMemory() -> MemorySample {
        var m = MemorySample()
        m.total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wired = UInt64(stats.wire_count) * page
            m.compressed = UInt64(stats.compressor_page_count) * page
            m.cached = (UInt64(stats.external_page_count) + purgeable) * page
            m.free = UInt64(stats.free_count) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }

        var level: Int32 = 1
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsize, nil, 0) == 0 {
            m.pressure = MemorySample.Pressure(rawValue: Int(level)) ?? .normal
        }
        return m
    }

    nonisolated static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ b: UInt64, decimals: Int = 1) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.\(decimals)f GB", gb) }
        let mb = Double(b) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }
}
