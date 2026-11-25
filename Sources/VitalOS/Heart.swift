import SwiftUI

/// Turns every vital sign into one stress level, then a heart rate and a health score.
struct HeartReading {
    struct Factor: Identifiable {
        let id: String
        let channel: String      // bedside-monitor label: HR, BP, TEMP, SpO₂, PWR
        let label: String
        let stress: Double       // 0 = relaxed, 1 = maxed out
        let reading: String
        let cause: String?
        let color: Color
    }

    let factors: [Factor]
    let stress: Double

    var bpm: Double { 54 + 126 * stress }
    var health: Int { Int(((1 - stress) * 100).rounded()) }

    var status: String {
        switch stress {
        case ..<0.2: return "Resting"
        case ..<0.45: return "Active"
        case ..<0.65: return "Working hard"
        case ..<0.85: return "Strained"
        default: return "Critical"
        }
    }

    var color: Color {
        switch stress {
        case ..<0.45: return Theme.good
        case ..<0.85: return Theme.net
        default: return Theme.warn
        }
    }

    /// The vital doing the most damage, if any of them is actually elevated.
    var driver: Factor? {
        guard let top = factors.max(by: { $0.stress < $1.stress }), top.stress > 0.3 else { return nil }
        return top
    }

    var diagnosis: String {
        guard let d = driver else { return "Normal sinus rhythm. Nothing is straining your Mac." }
        switch d.id {
        case "cpu": return "Tachycardia: \(d.cause ?? "something") is working the processor hard."
        case "mem": return "High pressure: memory is tight" + (d.cause.map { ", and \($0) is the biggest user." } ?? ".")
        case "thermal": return "Running a fever: macOS says it's \(d.reading.lowercased()). Expect it to slow itself down."
        case "disk": return "Low oxygen: the startup disk is nearly full, which slows macOS and blocks updates."
        case "battery": return "Low energy: \(d.reading). Plug in soon."
        default: return d.label
        }
    }
}

enum Cardiologist {
    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    static func read(_ s: SystemSnapshot, apps: [AppUsage]) -> HeartReading {
        let topCPU = apps.filter { !$0.isSystem }.max { $0.cpu < $1.cpu }
        let topMem = apps.filter { !$0.isSystem }.max { $0.memory < $1.memory }

        // CPU: straight load.
        let cpu = clamp(s.cpu / 100)

        // Memory: macOS's own pressure level wins; otherwise fullness past 60% plus swap.
        let pressure: Double = s.pressureLevel >= 4 ? 1 : (s.pressureLevel >= 2 ? 0.7 : 0)
        let fullness = clamp((s.memFraction - 0.6) / 0.4) * 0.6
        let swap = clamp(Double(s.swapUsed) / 8_589_934_592) * 0.5
        let mem = max(pressure, min(fullness + swap, 1))
        let pressureWord = s.pressureLevel >= 4 ? "critical" : (s.pressureLevel >= 2 ? "warning" : "normal")

        // Heat: macOS thermal state.
        let thermal: Double
        let thermalWord: String
        switch s.thermal {
        case .nominal: thermal = 0; thermalWord = "Cool"
        case .fair: thermal = 0.4; thermalWord = "Warm"
        case .serious: thermal = 0.8; thermalWord = "Hot"
        case .critical: thermal = 1; thermalWord = "Critical"
        @unknown default: thermal = 0; thermalWord = "Unknown"
        }

        // Disk: nothing until 80% full, maxed at 97%.
        let disk = clamp((s.diskUsedFraction - 0.80) / 0.17)
        let freePct = (1 - s.diskUsedFraction) * 100

        // Battery: low charge off the charger, or a worn-out cell.
        var batt = 0.0
        var battReading = "On power"
        if let b = s.battery {
            if !b.onAC && b.percent < 25 { batt = clamp((25 - b.percent) / 20) }
            if let h = b.health, h < 80 { batt = max(batt, clamp((80 - h) / 30) * 0.6) }
            battReading = "\(Int(b.percent))% \(b.charging ? "charging" : b.onAC ? "plugged in" : "on battery")"
                + (b.health.map { " · health \(Int($0))%" } ?? "")
        }

        let factors = [
            HeartReading.Factor(id: "cpu", channel: "HR", label: "Processor", stress: cpu,
                                reading: Fmt.pct(s.cpu), cause: topCPU?.name, color: Theme.good),
            HeartReading.Factor(id: "mem", channel: "BP", label: "Memory", stress: mem,
                                reading: "\(Fmt.pct(s.memFraction * 100)) used · pressure \(pressureWord)",
                                cause: topMem?.name, color: Theme.warn),
            HeartReading.Factor(id: "thermal", channel: "TEMP", label: "Heat", stress: thermal,
                                reading: thermalWord, cause: nil, color: Theme.heat),
            HeartReading.Factor(id: "disk", channel: "SpO₂", label: "Disk space", stress: disk,
                                reading: "\(Int(freePct))% free · \(Fmt.bytes(s.diskFree))", cause: nil, color: Theme.cpu),
            HeartReading.Factor(id: "battery", channel: "PWR", label: "Battery", stress: batt,
                                reading: battReading, cause: nil, color: Theme.mem),
        ]

        // The worst vital sets most of the pace; the rest nudge it.
        let peak = factors.map(\.stress).max() ?? 0
        let weighted = cpu * 0.35 + mem * 0.25 + thermal * 0.2 + disk * 0.1 + batt * 0.1
        return HeartReading(factors: factors, stress: clamp(peak * 0.65 + weighted * 0.35))
    }
}

struct HeartView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: AppModel
    @State private var detail: VitalID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "Heart",
                          subtitle: "One heartbeat for your whole Mac: processor, memory, heat, disk and battery, read every 1.5 seconds.")
                if let h = monitor.heart {
                    bedside(h)
                    diagnosis(h)
                    SuggestionsCard(reading: h)
                    Text("Click a channel to see what's behind it.").font(.ui(size: 11)).foregroundStyle(.tertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(h.factors) { f in
                            channel(f)
                                .contentShape(Rectangle())
                                .onTapGesture { detail = VitalID(id: f.id) }
                        }
                    }
                } else {
                    ProgressView("Finding a pulse…").frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(28)
            .padding(.top, 8)
        }
        .vitalDetail($detail, monitor: monitor, model: model)
    }

    private func bedside(_ h: HeartReading) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ECG  II").foregroundStyle(h.color)
                    Spacer()
                    Text("×1  25 mm/s").foregroundStyle(.secondary)
                }
                .font(.ui(size: 11, weight: .medium, design: .monospaced))
                PulseLine(bpm: monitor.bpm, color: h.color)
                    .frame(height: 130)
                HStack {
                    Text("HR, last 90 s").font(.ui(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(monitor.bpmHistory.min() ?? 0))–\(Int(monitor.bpmHistory.max() ?? 0))")
                        .font(.ui(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Sparkline(values: monitor.bpmHistory, maxValue: 180, color: h.color).frame(height: 36)
            }
            .padding(18)
            .frame(maxWidth: .infinity)

            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)

            VStack(alignment: .trailing, spacing: 2) {
                Text("HR").font(.ui(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(h.color)
                Text("\(Int(monitor.bpm.rounded()))")
                    .font(.ui(size: 76, weight: .semibold, design: .monospaced))
                    .foregroundStyle(h.color)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.4), value: Int(monitor.bpm.rounded()))
                Text("bpm").font(.ui(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Text(h.status.uppercased()).font(.ui(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(h.color)
                Text("HEALTH \(h.health)/100").font(.ui(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(width: 220)
        }
        .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(h.stress >= 0.85 ? Theme.warn : Theme.stroke, lineWidth: h.stress >= 0.85 ? 2 : 1)
        )
    }

    private func diagnosis(_ h: HeartReading) -> some View {
        HStack(spacing: 12) {
            Image(systemName: h.driver == nil ? "checkmark.seal.fill" : "stethoscope")
                .font(.ui(size: 20))
                .foregroundStyle(h.color)
            Text(h.diagnosis).font(.ui(size: 14))
            Spacer()
            if let d = h.driver {
                switch d.id {
                case "cpu", "mem":
                    Button("See apps") { model.route = .apps }
                case "disk":
                    Button("Free Up Space") { model.route = .clean }
                default:
                    EmptyView()
                }
            }
        }
        .padding(14)
        .glass()
    }

    private func channel(_ f: HeartReading.Factor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(f.channel).font(.ui(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(f.color)
                Text(f.label.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((f.stress * 100).rounded()))")
                    .font(.ui(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(f.stress > 0.65 ? Theme.warn : f.color)
            }
            Text(f.reading).font(.ui(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(values: monitor.factorHistory[f.id] ?? [], maxValue: 1, color: f.color).frame(height: 34)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(f.color).frame(width: max(4, g.size.width * f.stress))
                }
            }
            .frame(height: 5)
            HStack {
                Text(f.cause.map { "Biggest user: \($0)" } ?? " ")
                Spacer()
                Image(systemName: "chevron.right")
            }
                .font(.ui(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(14)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(f.color.opacity(0.25)))
    }
}
