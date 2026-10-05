import SwiftUI
import AppKit
import ServiceManagement

@main
struct PulseApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(compact: true)
                .environmentObject(monitor)
        } label: {
            MenuBarLabel()
                .environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)

        Window("Pulse", id: "dashboard") {
            DashboardView(compact: false)
                .environmentObject(monitor)
                .frame(minWidth: 560, minHeight: 520)
                .background(Theme.windowBackground)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 620, height: 560)
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    @EnvironmentObject var monitor: Monitor
    @AppStorage("labelStyle") private var labelStyle: BarStyle = .both

    enum BarStyle: String, CaseIterable, Identifiable {
        case both, all, gpu, memory, power, net, disk, icon
        var id: String { rawValue }
        var title: String {
            switch self {
            case .both: return "GPU + Memory"
            case .all: return "GPU + Memory + Watts"
            case .power: return "Watts only"
            case .net: return "Network ↓↑"
            case .disk: return "Disk read/write"
            case .gpu: return "GPU only"
            case .memory: return "Memory only"
            case .icon: return "Icon only"
            }
        }
    }

    // MenuBarExtra only renders a single Image or Text reliably, so we rasterize the
    // icon + numbers into one template NSImage — crisp, adapts to light/dark menu bars.
    var body: some View {
        Image(nsImage: renderLabel())
    }

    private var text: String {
        var parts: [String] = []
        if [.both, .all, .gpu].contains(labelStyle) { parts.append(Fmt.pct(monitor.gpu.utilization)) }
        if [.both, .all, .memory].contains(labelStyle) { parts.append(Fmt.bytes(monitor.memory.used, decimals: 1)) }
        if [.all, .power].contains(labelStyle) { parts.append(Fmt.watts(monitor.power.systemWatts)) }
        if labelStyle == .net { parts.append("↓\(Fmt.rate(monitor.net.downBps)) ↑\(Fmt.rate(monitor.net.upBps))") }
        if labelStyle == .disk { parts.append("R \(Fmt.rate(monitor.disk.readBps)) W \(Fmt.rate(monitor.disk.writeBps))") }
        return parts.joined(separator: "  ·  ")
    }

    @MainActor private func renderLabel() -> NSImage {
        let view = HStack(spacing: 5) {
            Image(systemName: monitor.thermal.isThrottling ? "thermometer.high" : "waveform.path.ecg")
                .font(.system(size: 13, weight: .semibold))
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 1)
        .frame(height: 22)

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = renderer.nsImage ?? NSImage(size: NSSize(width: 22, height: 22))
        img.isTemplate = true   // lets macOS tint it for light/dark menu bars
        return img
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LaunchAtLogin error: \(error.localizedDescription)")
        }
    }
}
