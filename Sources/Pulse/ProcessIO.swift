import Foundation
import Darwin

// Per-app network + disk throughput, and NAS (SMB/AFP/NFS/DSM) traffic breakdown.
// Network: `nettop` (ships with macOS, no root). Disk: proc_pid_rusage (your own processes, no root).

struct NamedRate: Identifiable { var id: String { name }; let name: String; var bps: Double }

struct ProcIO: Identifiable {
    var id: String { name }
    let name: String
    var netIn: Double = 0, netOut: Double = 0, diskRead: Double = 0, diskWrite: Double = 0
    var net: Double { netIn + netOut }
    var disk: Double { diskRead + diskWrite }
    var total: Double { net + disk }
}

struct NASFlow: Identifiable {
    var id: String { host + proto }
    let host: String
    let proto: String
    var inBps: Double = 0, outBps: Double = 0
    var processes: [NamedRate] = []
}

struct NASShare: Identifiable, Hashable {
    var id: String { mountPoint }
    let name: String, host: String, type: String, mountPoint: String
}

struct IOSnapshot {
    var apps: [ProcIO] = []
    var nas: [NASFlow] = []
    var shares: [NASShare] = []
    var nasIn: Double { nas.reduce(0) { $0 + $1.inBps } }
    var nasOut: Double { nas.reduce(0) { $0 + $1.outBps } }
}

final class ProcessIOSampler {
    private var prevNet: [String: (UInt64, UInt64)] = [:]
    private var prevDisk: [pid_t: (UInt64, UInt64)] = [:]
    private var prevTime: Date?

    static let nasPorts: [Int: String] = [445: "SMB", 139: "SMB", 548: "AFP", 2049: "NFS",
                                          873: "rsync", 5000: "DSM", 5001: "DSM", 6690: "Synology Drive"]

    func sample() -> IOSnapshot {
        let t = Date()
        let dt = prevTime.map { t.timeIntervalSince($0) } ?? 0
        prevTime = t

        var apps: [String: ProcIO] = [:]
        var flows: [String: NASFlow] = [:]
        var flowProcs: [String: [String: Double]] = [:]

        // ---- Network (nettop: process rows followed by their connection rows) ----
        var curNet: [String: (UInt64, UInt64)] = [:]
        var currentProc = ""
        for r in Self.runNettop() {
            if r.name.contains("<->") {
                guard !currentProc.isEmpty else { continue }
                let key = currentProc + "|" + r.name
                curNet[key] = (r.inB, r.outB)
                guard dt > 0, let ep = Self.nasEndpoint(r.name), let old = prevNet[key] else { continue }
                let din = Double(r.inB >= old.0 ? r.inB - old.0 : 0) / dt
                let dout = Double(r.outB >= old.1 ? r.outB - old.1 : 0) / dt
                guard din + dout > 0 else { continue }
                let fk = ep.host + ep.proto
                var f = flows[fk] ?? NASFlow(host: ep.host, proto: ep.proto)
                f.inBps += din; f.outBps += dout
                flows[fk] = f
                flowProcs[fk, default: [:]][Self.prettyName(currentProc), default: 0] += din + dout
            } else {
                currentProc = r.name
                curNet[r.name] = (r.inB, r.outB)
                guard dt > 0, let old = prevNet[r.name] else { continue }
                let din = Double(r.inB >= old.0 ? r.inB - old.0 : 0) / dt
                let dout = Double(r.outB >= old.1 ? r.outB - old.1 : 0) / dt
                guard din + dout > 0 else { continue }
                let name = Self.prettyName(r.name)
                var a = apps[name] ?? ProcIO(name: name)
                a.netIn += din; a.netOut += dout
                apps[name] = a
            }
        }

        // ---- Disk (per-process block I/O) ----
        var curDisk: [pid_t: (UInt64, UInt64)] = [:]
        for pid in Self.allPids() {
            guard let io = Self.diskIO(pid) else { continue }
            curDisk[pid] = io
            guard dt > 0, let old = prevDisk[pid] else { continue }
            let rd = Double(io.0 >= old.0 ? io.0 - old.0 : 0) / dt
            let wr = Double(io.1 >= old.1 ? io.1 - old.1 : 0) / dt
            guard rd + wr > 0 else { continue }
            let name = Self.procName(pid)
            var a = apps[name] ?? ProcIO(name: name)
            a.diskRead += rd; a.diskWrite += wr
            apps[name] = a
        }

        prevNet = curNet
        prevDisk = curDisk

        var snap = IOSnapshot()
        snap.apps = apps.values.filter { $0.total >= 2048 }.sorted { $0.total > $1.total }.prefix(12).map { $0 }
        snap.nas = flows.map { key, f in
            var f = f
            f.processes = (flowProcs[key] ?? [:]).map { NamedRate(name: $0.key, bps: $0.value) }.sorted { $0.bps > $1.bps }
            return f
        }.sorted { ($0.inBps + $0.outBps) > ($1.inBps + $1.outBps) }
        snap.shares = Self.nasShares()
        return snap
    }

    // MARK: nettop

    private static func runNettop() -> [(name: String, inB: UInt64, outB: UInt64)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        var out: [(String, UInt64, UInt64)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 3 else { continue }
            // Usual layout: time,name,bytes_in,bytes_out,  — fall back if there's no time column.
            if f.count >= 4, !f[1].isEmpty, let i = UInt64(f[2]), let o = UInt64(f[3]) {
                out.append((f[1], i, o))
            } else if !f[0].isEmpty, let i = UInt64(f[1]), let o = UInt64(f[2]) {
                out.append((f[0], i, o))
            }
        }
        return out
    }

    /// "tcp4 192.168.1.10:51234<->192.168.1.50:445" → ("SMB", "192.168.1.50")
    private static func nasEndpoint(_ c: String) -> (proto: String, host: String)? {
        guard let r = c.range(of: "<->") else { return nil }
        let remote = String(c[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        let isV6 = remote.filter { $0 == ":" }.count > 1
        guard let sep = isV6 ? remote.lastIndex(of: ".") : remote.lastIndex(of: ":"),
              let port = Int(remote[remote.index(after: sep)...]),
              let proto = nasPorts[port] else { return nil }
        return (proto, String(remote[..<sep]))
    }

    private static func prettyName(_ n: String) -> String {
        var base = n
        if let dot = n.lastIndex(of: "."), Int(n[n.index(after: dot)...]) != nil { base = String(n[..<dot]) }
        if base == "kernel_task" { return "macOS file sharing (kernel)" }
        return base
    }

    // MARK: per-process disk

    private static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(got, 0)))).filter { $0 > 0 }
    }

    private static func diskIO(_ pid: pid_t) -> (UInt64, UInt64)? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return r == 0 ? (info.ri_diskio_bytesread, info.ri_diskio_byteswritten) : nil
    }

    private static func procName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let s = String(cString: buf)
        return s.isEmpty ? "pid \(pid)" : s
    }

    // MARK: mounted NAS shares

    private static func cString<T>(_ t: T) -> String {
        withUnsafeBytes(of: t) { raw in
            let b = raw.bindMemory(to: CChar.self)
            let end = b.firstIndex(of: 0) ?? b.count
            return String(decoding: raw.prefix(end), as: UTF8.self)
        }
    }

    private static func nasShares() -> [NASShare] {
        var mnts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&mnts, MNT_NOWAIT)
        guard n > 0, let m = mnts else { return [] }
        var out: [NASShare] = []
        for i in 0..<Int(n) {
            let s = m[i]
            let type = cString(s.f_fstypename)
            guard ["smbfs", "afpfs", "nfs", "webdav"].contains(type) else { continue }
            let from = cString(s.f_mntfromname)
            let on = cString(s.f_mntonname)
            var host = from
            if host.hasPrefix("//") { host.removeFirst(2) }
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let cut = host.firstIndex(where: { $0 == "/" || (type == "nfs" && $0 == ":") }) { host = String(host[..<cut]) }
            host = host.replacingOccurrences(of: "._smb._tcp.local", with: "")
                       .replacingOccurrences(of: "._afpovertcp._tcp.local", with: "")
            host = host.removingPercentEncoding ?? host
            out.append(NASShare(name: URL(fileURLWithPath: on).lastPathComponent, host: host,
                                type: type.replacingOccurrences(of: "fs", with: "").uppercased(), mountPoint: on))
        }
        return out
    }
}
