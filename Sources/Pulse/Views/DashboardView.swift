import SwiftUI
import AppKit

struct DashboardView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) private var openWindow
    @AppStorage("labelStyle") private var labelStyle: MenuBarLabel.BarStyle = .both
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage("kwhRate") private var rate: Double = 0.18   // $/kWh
    var compact: Bool

    private func basisText(_ days: Double) -> String {
        if days < 1 { return "from \(Int((days * 24).rounded())) h of data" }
        return String(format: "from %.1f d of data", days)
    }

    @AppStorage("popoverTab") private var tab: Int = 0

    var body: some View {
        Group {
            if compact { content } else { ScrollView { content } }
        }
        .frame(width: compact ? 372 : nil)
        .background(compact ? AnyView(Theme.windowBackground) : AnyView(Color.clear))
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if compact {
                Picker("", selection: $tab) {
                    Text("System").tag(0)
                    Text("Network & Disk").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if !compact || tab == 0 {
                HStack(spacing: 12) {
                    gpuCard
                    memoryCard
                }
                memoryBreakdown
                powerCard
                thermalCard
            }
            if !compact || tab == 1 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 160 : 200), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    netCard
                    ForEach(monitor.disk.drives) { d in
                        DriveCard(drive: d, compact: compact)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: monitor.disk.drives.map(\.id))
                nasCard
                appsCard
            }
            if !compact { gpuDetail }
            footer
        }
        .padding(compact ? 14 : 22)
    }

    // MARK: Network & disk

    private var netCard: some View {
        let n = monitor.net
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("NETWORK").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: "network").font(.system(size: 11)).foregroundStyle(Theme.netA)
                }
                RateRow(symbol: "arrow.down", color: Theme.netA, value: Fmt.rate(n.downBps), sub: compact ? nil : Fmt.mbps(n.downBps))
                RateRow(symbol: "arrow.up", color: Theme.netB, value: Fmt.rate(n.upBps), sub: compact ? nil : Fmt.mbps(n.upBps))
                DualSparkline(a: monitor.netDownHistory.values, b: monitor.netUpHistory.values, colorA: Theme.netA, colorB: Theme.netB)
                    .frame(height: compact ? 34 : 56)
                HStack {
                    Stat(label: "Session ↓", value: Fmt.bytesDec(n.sessionDown))
                    Spacer()
                    Stat(label: "↑", value: Fmt.bytesDec(n.sessionUp))
                }
            }
        }
    }

    private func nasLabel(_ f: NASFlow) -> String {
        let hosts = Set(monitor.io.shares.map(\.host))
        if hosts.count == 1, let h = hosts.first, h != f.host { return "\(h) (\(f.host)) · \(f.proto)" }
        return "\(f.host) · \(f.proto)"
    }

    private var nasCard: some View {
        let io = monitor.io
        let active = io.nasIn + io.nasOut > 0
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.netA)
                    Text("NAS").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("↓ " + Fmt.rate(io.nasIn)).foregroundStyle(active ? Theme.netA : Theme.textSecondary)
                    Text("↑ " + Fmt.rate(io.nasOut)).foregroundStyle(active ? Theme.netB : Theme.textSecondary)
                }
                .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()

                if io.nas.isEmpty {
                    Text(io.shares.isEmpty ? "No NAS shares mounted, no NAS traffic." : "Idle — no traffic to your NAS right now.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(io.nas) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(nasLabel(f)).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text("↓\(Fmt.rate(f.inBps))  ↑\(Fmt.rate(f.outBps))")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(f.processes.prefix(compact ? 3 : 6)) { p in
                            HStack {
                                Text(p.name).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                Spacer()
                                Text(Fmt.rate(p.bps)).font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                            }
                            .padding(.leading, 12)
                        }
                    }
                }
                if !io.shares.isEmpty {
                    Text("Mounted: " + io.shares.map { "\($0.name) (\($0.type))" }.joined(separator: ", "))
                        .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary.opacity(0.8)).lineLimit(2)
                }
                if !compact {
                    Text("Shows this Mac's traffic to the NAS. Finder/Resolve reads from mounted shares are carried by macOS and appear as \"macOS file sharing (kernel)\". For other devices hitting the NAS, use DSM → Resource Monitor → Connections.")
                        .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var appsCard: some View {
        let apps = monitor.io.apps
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("TOP APPS").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    HStack(spacing: 4) { Circle().fill(Theme.netA).frame(width: 6, height: 6); Text("network") }
                    HStack(spacing: 4) { Circle().fill(Theme.diskA).frame(width: 6, height: 6); Text("disk") }
                }
                .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary)
                if apps.isEmpty {
                    Text("Nothing moving right now.").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(apps.prefix(compact ? 6 : 12)) { a in
                    AppIORow(app: a, maxTotal: apps.first?.total ?? 1)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pulse")
                    .font(.system(size: compact ? 15 : 22, weight: .bold, design: .rounded))
                Text(monitor.chipName + (monitor.gpu.coreCount > 0 ? "  ·  \(monitor.gpu.coreCount)-core GPU" : ""))
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Pill(text: monitor.thermal.isThrottling ? "Throttling" : "Thermal \(monitor.thermal.label)",
                     color: Theme.thermalColor(monitor.thermal.state))
                Pill(text: "Pressure \(monitor.memory.pressure.label)", color: Theme.pressureColor(monitor.memory.pressure))
            }
        }
    }

    // MARK: Power & energy

    private var powerCard: some View {
        let p = monitor.power
        let e = monitor.energy
        let peak = max(monitor.powerHistory.peak, 1)
        let norm = monitor.powerHistory.values.map { $0 / peak * 100 }
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "bolt.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.powerA)
                    Text("POWER").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(Fmt.watts(p.systemWatts))
                        .font(.system(size: compact ? 20 : 28, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("now").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }

                Sparkline(values: norm, colors: [Theme.powerA, Theme.powerB], lineColor: Theme.powerB)
                    .frame(height: compact ? 28 : 50)

                HStack(spacing: 0) {
                    EnergyTile(label: "Last hour", wh: e.hour)
                    EnergyTile(label: "24 hours", wh: e.day)
                    EnergyTile(label: "30 days", wh: e.month)
                    EnergyTile(label: "1 year", wh: e.year)
                }

                // 30-day projection
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.powerB)
                    Text("Projected 30 days")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if e.projectionDays > 0 {
                        Text(Fmt.energy(e.projected30))
                            .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Theme.powerB)
                        Text("≈ " + Fmt.money(e.projected30 / 1000 * rate))
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                        if !compact {
                            Text(basisText(e.projectionDays))
                                .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary.opacity(0.7))
                        }
                    } else {
                        Text("needs ~10 min of data").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, 2)
                .help("Average daily energy since tracking began (up to 30 days) × 30. Sleep/off time counts as zero, like a real bill. " + basisText(e.projectionDays))

                HStack(spacing: 12) {
                    if !compact, let c = p.cpuWatts { Stat(label: "CPU", value: Fmt.watts(c)) }
                    if !compact, let g = p.gpuWatts { Stat(label: "GPU", value: Fmt.watts(g)) }
                    if !compact { Stat(label: "Peak", value: Fmt.watts(monitor.powerHistory.peak)) }
                    if !compact { Stat(label: "Avg", value: Fmt.watts(monitor.powerHistory.average)) }
                    Spacer()
                    Text("via \(p.source) · tracking since \(e.since.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: Thermal

    private var thermalCard: some View {
        let t = monitor.thermal
        let color = Theme.thermalColor(t.state)
        let speed = t.cpuSpeedLimit ?? 100
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: t.isThrottling ? "thermometer.high" : "thermometer.medium")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                    Text("THERMAL").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(t.label)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                }
                // CPU speed limit — 100% means no throttling
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("CPU speed limit").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(speed)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(speed < 100 ? color : .white)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(colors: [Theme.good, speed < 100 ? color : Theme.good],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * CGFloat(min(max(speed, 0), 100)) / 100)
                                .animation(.easeOut(duration: 0.5), value: speed)
                        }
                    }
                    .frame(height: 6)
                }
                if !compact || t.isThrottling {
                    Text(t.detail).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                }
                if !compact, let sched = t.schedulerLimit {
                    Text("Scheduler limit \(sched)%").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: GPU card

    private var gpuCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("GPU").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: "cpu").font(.system(size: 11)).foregroundStyle(Theme.gpuB)
                }
                ZStack {
                    Ring(value: monitor.gpu.utilization / 100, gradient: Theme.gpuGradient)
                    VStack(spacing: 0) {
                        Text(Fmt.pct(monitor.gpu.utilization))
                            .font(.system(size: compact ? 24 : 34, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("busy").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(height: compact ? 110 : 150)
                .padding(.horizontal, 6)

                Sparkline(values: monitor.gpuHistory.values, colors: [Theme.gpuA, Theme.gpuB], lineColor: Theme.gpuB)
                    .frame(height: compact ? 34 : 56)

                HStack {
                    Stat(label: "Peak", value: Fmt.pct(monitor.gpuHistory.peak))
                    Spacer()
                    Stat(label: "Avg", value: Fmt.pct(monitor.gpuHistory.average))
                    Spacer()
                    Stat(label: "GPU mem", value: Fmt.bytes(monitor.gpu.inUseBytes))
                }
            }
        }
    }

    // MARK: Memory card

    private var memoryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("MEMORY").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: "memorychip").font(.system(size: 11)).foregroundStyle(Theme.memB)
                }
                ZStack {
                    Ring(value: monitor.memory.usedFraction, gradient: Theme.memGradient)
                    VStack(spacing: 0) {
                        Text(Fmt.bytes(monitor.memory.used))
                            .font(.system(size: compact ? 20 : 30, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("of \(Fmt.bytes(monitor.memory.total, decimals: 0))")
                            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(height: compact ? 110 : 150)
                .padding(.horizontal, 6)

                Sparkline(values: monitor.memHistory.values, colors: [Theme.memA, Theme.memB], lineColor: Theme.memB)
                    .frame(height: compact ? 34 : 56)

                HStack {
                    Stat(label: "Peak", value: Fmt.pct(monitor.memHistory.peak))
                    Spacer()
                    Stat(label: "Swap", value: Fmt.bytes(monitor.memory.swapUsed),
                         color: monitor.memory.swapUsed > 1_073_741_824 ? Theme.warn : nil)
                    Spacer()
                    Stat(label: "Free", value: Fmt.bytes(monitor.memory.free))
                }
            }
        }
    }

    // MARK: Memory breakdown

    private var memoryBreakdown: some View {
        let m = monitor.memory
        let t = Double(max(m.total, 1))
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                StackedBar(segments: [
                    (Theme.segApp, Double(m.app) / t),
                    (Theme.segWired, Double(m.wired) / t),
                    (Theme.segCompressed, Double(m.compressed) / t),
                    (Theme.segCached, Double(m.cached) / t)
                ])
                if compact {
                    HStack(spacing: 14) {
                        LegendDot(color: Theme.segApp, label: "App", value: Fmt.bytes(m.app))
                        LegendDot(color: Theme.segWired, label: "Wired", value: Fmt.bytes(m.wired))
                    }
                    HStack(spacing: 14) {
                        LegendDot(color: Theme.segCompressed, label: "Compressed", value: Fmt.bytes(m.compressed))
                        LegendDot(color: Theme.segCached, label: "Cached", value: Fmt.bytes(m.cached))
                    }
                } else {
                    HStack(spacing: 22) {
                        LegendDot(color: Theme.segApp, label: "App", value: Fmt.bytes(m.app))
                        LegendDot(color: Theme.segWired, label: "Wired", value: Fmt.bytes(m.wired))
                        LegendDot(color: Theme.segCompressed, label: "Compressed", value: Fmt.bytes(m.compressed))
                        LegendDot(color: Theme.segCached, label: "Cached", value: Fmt.bytes(m.cached))
                    }
                }
            }
        }
    }

    // MARK: GPU detail (full window only)

    private var gpuDetail: some View {
        Card(padding: 12) {
            HStack(spacing: 22) {
                Stat(label: "Renderer", value: Fmt.pct(monitor.gpu.renderer), color: Theme.gpuB)
                Stat(label: "Tiler", value: Fmt.pct(monitor.gpu.tiler), color: Theme.gpuA)
                Stat(label: "GPU in use", value: Fmt.bytes(monitor.gpu.inUseBytes))
                Stat(label: "GPU allocated", value: Fmt.bytes(monitor.gpu.allocatedBytes))
                Spacer()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Refresh", selection: $monitor.interval) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                }
                Picker("Menu bar shows", selection: $labelStyle) {
                    ForEach(MenuBarLabel.BarStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LaunchAtLogin.set($0) }))
                Divider()
                Picker("Electricity rate", selection: $rate) {
                    ForEach([0.10, 0.12, 0.14, 0.16, 0.18, 0.20, 0.22, 0.25, 0.30, 0.35, 0.40], id: \.self) { r in
                        Text(String(format: "$%.2f / kWh", r)).tag(r)
                    }
                }
                Button("Reset energy meter") { monitor.resetEnergy() }
                Divider()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)

            if compact {
                Button {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Dashboard", systemImage: "rectangle.expand.vertical")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Text("\(Int(monitor.interval * 1000)) ms")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary.opacity(0.7))

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Quit Pulse")
        }
        .padding(.top, 2)
    }
}
