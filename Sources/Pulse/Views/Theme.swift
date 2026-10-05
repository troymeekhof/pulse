import SwiftUI

enum Theme {
    // GPU: electric violet → cyan.  Memory: coral → amber.
    static let gpuA = Color(red: 0.55, green: 0.36, blue: 1.00)
    static let gpuB = Color(red: 0.25, green: 0.85, blue: 1.00)
    static let memA = Color(red: 1.00, green: 0.45, blue: 0.40)
    static let memB = Color(red: 1.00, green: 0.78, blue: 0.30)

    static let netA = Color(red: 0.30, green: 0.75, blue: 1.00)    // download
    static let netB = Color(red: 0.70, green: 0.50, blue: 1.00)    // upload
    static let diskA = Color(red: 0.35, green: 0.92, blue: 0.65)   // read
    static let diskB = Color(red: 1.00, green: 0.55, blue: 0.70)   // write

    static let powerA = Color(red: 1.00, green: 0.85, blue: 0.30)
    static let powerB = Color(red: 0.45, green: 0.95, blue: 0.70)

    static let good = Color(red: 0.35, green: 0.90, blue: 0.60)
    static let warn = Color(red: 1.00, green: 0.75, blue: 0.25)
    static let bad  = Color(red: 1.00, green: 0.40, blue: 0.40)

    static let gpuGradient = LinearGradient(colors: [gpuA, gpuB], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let memGradient = LinearGradient(colors: [memA, memB], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let windowBackground = LinearGradient(
        colors: [Color(red: 0.07, green: 0.07, blue: 0.10), Color(red: 0.03, green: 0.03, blue: 0.05)],
        startPoint: .top, endPoint: .bottom)

    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.10)
    static let textSecondary = Color.white.opacity(0.55)

    // Memory breakdown palette
    static let segApp = Color(red: 1.00, green: 0.55, blue: 0.40)
    static let segWired = Color(red: 1.00, green: 0.80, blue: 0.35)
    static let segCompressed = Color(red: 0.75, green: 0.50, blue: 1.00)
    static let segCached = Color.white.opacity(0.28)
    static let segFree = Color.white.opacity(0.10)

    static func thermalColor(_ s: ProcessInfo.ThermalState) -> Color {
        switch s {
        case .nominal: return good
        case .fair: return Color(red: 1.0, green: 0.85, blue: 0.35)
        case .serious: return Color(red: 1.0, green: 0.55, blue: 0.25)
        case .critical: return bad
        @unknown default: return textSecondary
        }
    }

    static func pressureColor(_ p: MemorySample.Pressure) -> Color {
        switch p { case .normal: return good; case .warning: return warn; case .critical: return bad }
    }
}

// MARK: - Glass card container

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
            )
    }
}

// MARK: - Ring gauge

struct Ring: View {
    var value: Double          // 0…1
    var gradient: LinearGradient
    var lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.003, min(1, value)))
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .white.opacity(0.15), radius: 6)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: value)
        }
    }
}

// MARK: - Sparkline (no dependencies, smooth area chart)

struct Sparkline: View {
    var values: [Double]       // 0…100
    var colors: [Color]
    var lineColor: Color

    var body: some View {
        GeometryReader { geo in
            let path = linePath(in: geo.size)
            ZStack {
                areaPath(in: geo.size)
                    .fill(LinearGradient(colors: colors.map { $0.opacity(0.45) } + [Color.clear],
                                         startPoint: .top, endPoint: .bottom))
                path.stroke(lineColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * stepX, y: size.height - CGFloat(min(max(v, 0), 100) / 100) * (size.height - 2) - 1)
        }
    }

    private func linePath(in size: CGSize) -> Path {
        var p = Path()
        let pts = points(in: size)
        guard let first = pts.first else { return p }
        p.move(to: first)
        for i in 1..<pts.count {
            let prev = pts[i - 1], cur = pts[i]
            let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
            p.addQuadCurve(to: mid, control: prev)
            if i == pts.count - 1 { p.addLine(to: cur) }
        }
        return p
    }

    private func areaPath(in size: CGSize) -> Path {
        var p = linePath(in: size)
        guard let last = points(in: size).last else { return p }
        p.addLine(to: CGPoint(x: last.x, y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Stacked memory bar

struct StackedBar: View {
    var segments: [(Color, Double)]   // fractions summing ≤ 1
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(seg.0)
                        .frame(width: max(0, geo.size.width * CGFloat(seg.1) - 2))
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.5), value: segments.map { $0.1 })
        }
        .frame(height: 10)
    }
}

// MARK: - Small labelled stat

struct Stat: View {
    var label: String
    var value: String
    var color: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary).textCase(.uppercase)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color ?? .white)
        }
    }
}

// MARK: - Throughput pieces

struct DualSparkline: View {
    var a: [Double]; var b: [Double]
    var colorA: Color; var colorB: Color
    var body: some View {
        let peak = max((a + b).max() ?? 0, 1)
        ZStack {
            Sparkline(values: b.map { $0 / peak * 100 }, colors: [colorB, colorB], lineColor: colorB.opacity(0.9))
            Sparkline(values: a.map { $0 / peak * 100 }, colors: [colorA, colorA], lineColor: colorA)
        }
    }
}

struct RateRow: View {
    var symbol: String
    var color: Color
    var value: String
    var sub: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color).frame(width: 12)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Spacer(minLength: 2)
            if let sub {
                Text(sub).font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary).monospacedDigit().lineLimit(1)
            }
        }
    }
}

struct DriveCard: View {
    var drive: DriveSample
    var compact: Bool

    private var usedFraction: Double {
        let total = drive.volumeTotal
        guard total > 0 else { return 0 }
        return 1 - Double(drive.free) / Double(total)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: drive.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(drive.isInternal ? Theme.diskA : Theme.diskB)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(drive.name)
                            .font(.system(size: 11.5, weight: .bold))
                            .lineLimit(1).truncationMode(.middle)
                        Text(drive.detail)
                            .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .help([drive.product, drive.volumes.map(\.name).joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " — "))

                RateRow(symbol: "arrow.down.doc", color: Theme.diskA, value: Fmt.rate(drive.readBps), sub: compact ? nil : "read")
                RateRow(symbol: "square.and.pencil", color: Theme.diskB, value: Fmt.rate(drive.writeBps), sub: compact ? nil : "write")
                DualSparkline(a: drive.readHistory, b: drive.writeHistory, colorA: Theme.diskA, colorB: Theme.diskB)
                    .frame(height: compact ? 30 : 48)

                if drive.volumeTotal > 0 {
                    VStack(alignment: .leading, spacing: 3) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(usedFraction > 0.9 ? Theme.bad : (usedFraction > 0.8 ? Theme.warn : Color.white.opacity(0.45)))
                                    .frame(width: g.size.width * CGFloat(usedFraction))
                            }
                        }
                        .frame(height: 4)
                        Text("\(Fmt.bytesDec(drive.free)) free of \(Fmt.bytesDec(drive.volumeTotal))")
                            .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary).monospacedDigit().lineLimit(1)
                    }
                } else {
                    Text("Not mounted · \(Fmt.bytesDec(drive.capacity))")
                        .font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                if !compact {
                    HStack {
                        Stat(label: "Session R", value: Fmt.bytesDec(drive.sessionRead))
                        Spacer()
                        Stat(label: "W", value: Fmt.bytesDec(drive.sessionWrite))
                    }
                }
            }
        }
    }
}

struct AppIORow: View {
    var app: ProcIO
    var maxTotal: Double

    private var netText: String? {
        var p: [String] = []
        if app.netIn >= 1024 { p.append("↓" + Fmt.rate(app.netIn)) }
        if app.netOut >= 1024 { p.append("↑" + Fmt.rate(app.netOut)) }
        return p.isEmpty ? nil : p.joined(separator: " ")
    }
    private var diskText: String? {
        var p: [String] = []
        if app.diskRead >= 1024 { p.append("R " + Fmt.rate(app.diskRead)) }
        if app.diskWrite >= 1024 { p.append("W " + Fmt.rate(app.diskWrite)) }
        return p.isEmpty ? nil : p.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(app.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let n = netText { Text(n).foregroundStyle(Theme.netA) }
                if let d = diskText { Text(d).foregroundStyle(Theme.diskA) }
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
            GeometryReader { g in
                let m = max(maxTotal, 1)
                HStack(spacing: 1) {
                    if app.net > 0 { Capsule().fill(Theme.netA).frame(width: g.size.width * CGFloat(app.net / m)) }
                    if app.disk > 0 { Capsule().fill(Theme.diskA).frame(width: g.size.width * CGFloat(app.disk / m)) }
                    Spacer(minLength: 0)
                }
                .animation(.easeOut(duration: 0.4), value: app.total)
            }
            .frame(height: 3)
        }
    }
}

struct EnergyTile: View {
    var label: String
    var wh: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.textSecondary).textCase(.uppercase)
            Text(Fmt.energy(wh))
                .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LegendDot: View {
    var color: Color
    var label: String
    var value: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 4)
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}
