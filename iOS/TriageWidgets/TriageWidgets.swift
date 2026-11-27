import WidgetKit
import SwiftUI
import AppIntents

// MARK: - What you can choose

enum Metric: String, AppEnum, CaseIterable {
    case heart, cpu, memory, storage, battery, network, health, uptime

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Reading"
    static var caseDisplayRepresentations: [Metric: DisplayRepresentation] = [
        .heart: "Heart rate", .cpu: "CPU", .memory: "Memory", .storage: "Storage",
        .battery: "Battery", .network: "Network", .health: "Health score", .uptime: "Uptime",
    ]
}

enum RefreshEvery: Int, AppEnum, CaseIterable {
    case five = 5, fifteen = 15, thirty = 30, hour = 60

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Refresh"
    static var caseDisplayRepresentations: [RefreshEvery: DisplayRepresentation] = [
        .five: "Every 5 minutes (as often as iOS allows)", .fifteen: "Every 15 minutes",
        .thirty: "Every 30 minutes", .hour: "Every hour",
    ]
}

struct VitalsConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Mac vitals"
    static var description = IntentDescription("Pick what this widget shows. Bigger widgets show more.")

    @Parameter(title: "Main reading", default: .heart)
    var main: Metric

    @Parameter(title: "More readings (medium & large)", default: [.cpu, .memory, .storage, .network])
    var more: [Metric]

    @Parameter(title: "Show the heartbeat line", default: true)
    var trace: Bool

    @Parameter(title: "Show busiest apps (large)", default: true)
    var apps: Bool

    @Parameter(title: "Refresh when Triage is closed", default: .fifteen)
    var refresh: RefreshEvery
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnap
    let config: VitalsConfig
    let placeholder: Bool
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .sample, config: VitalsConfig(), placeholder: true) }

    func snapshot(for config: VitalsConfig, in context: Context) async -> Entry {
        Entry(date: Date(), snap: SnapStore.load() ?? .sample, config: config, placeholder: SnapStore.load() == nil)
    }

    func timeline(for config: VitalsConfig, in context: Context) async -> Timeline<Entry> {
        // the app schedules its background readings around the most eager widget
        let want = config.refresh.rawValue
        if want < SnapStore.refreshMinutes || SnapStore.refreshMinutes == 15 { SnapStore.refreshMinutes = want }
        let snap = SnapStore.load()
        let e = Entry(date: Date(), snap: snap ?? .sample, config: config, placeholder: snap == nil)
        return Timeline(entries: [e], policy: .after(Date().addingTimeInterval(Double(want) * 60)))
    }
}

// MARK: - The widget

struct TriageVitalsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SnapStore.kind, intent: VitalsConfig.self, provider: Provider()) { e in
            VitalsView(entry: e)
                .containerBackground(for: .widget) { Palette.of(e.snap.themeID).bg }
                .widgetURL(URL(string: "triage://home"))
        }
        .configurationDisplayName("Mac vitals")
        .description("Your Mac's pulse, memory, storage and more. Live while Triage is open.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
    }
}

@main
struct TriageWidgets: WidgetBundle {
    var body: some Widget { TriageVitalsWidget() }
}

extension Palette {
    static func of(_ id: String) -> Palette { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Views

struct VitalsView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family
    private var p: Palette { .of(entry.snap.themeID) }
    private var s: WidgetSnap { entry.snap }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            case .systemLarge: large
            case .accessoryCircular: circular
            default: rectangular
            }
        }
        .foregroundStyle(p.scheme == .dark ? Color.white : Color.primary)
        .environment(\.colorScheme, p.scheme ?? .dark)
        .redacted(reason: entry.placeholder ? .placeholder : [])
    }

    // Small: one reading, big, with its line.
    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header(compact: true)
            Spacer(minLength: 0)
            big(entry.config.main)
            if entry.config.trace { line(entry.config.main).frame(height: 30) }
        }
    }

    // Medium: the main reading and its line on the left, up to four more on the right.
    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                header(compact: true)
                Spacer(minLength: 0)
                big(entry.config.main)
                if entry.config.trace { line(entry.config.main).frame(height: 34) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(extras.prefix(4)), id: \.self) { m in row(m) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Large: everything, plus the busiest apps.
    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(compact: false)
            HStack(alignment: .bottom) {
                big(entry.config.main)
                Spacer()
                if let st = s.status { Text(st).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2) }
            }
            if entry.config.trace { line(entry.config.main).frame(height: 54) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(Array(extras.prefix(6)), id: \.self) { m in row(m) }
            }
            if entry.config.apps && !s.top.isEmpty {
                Divider().overlay(p.stroke)
                VStack(alignment: .leading, spacing: 5) {
                    Text("BUSIEST").font(.caption2.weight(.bold)).foregroundStyle(p.accent)
                    ForEach(s.top.prefix(4), id: \.self) { a in
                        HStack {
                            Text(a.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", a.cpu)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: a.cpu))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var circular: some View {
        Gauge(value: min(s.bpm, 180), in: 40...180) {
            Image(systemName: "heart.fill")
        } currentValueLabel: { Text("\(Int(s.bpm))").contentTransition(.numericText(value: s.bpm)) }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.mac).font(.caption.weight(.semibold)).lineLimit(1)
            Text("\(Int(s.bpm)) bpm · CPU \(Int(s.cpu))%").font(.caption)
            Text("Mem \(Int(s.memFraction * 100))% · \(bytes(s.diskFree)) free").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var extras: [Metric] {
        var m = entry.config.more.filter { $0 != entry.config.main }
        if s.battery == nil { m.removeAll { $0 == .battery } }
        return m
    }

    // MARK: Pieces

    private func header(compact: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(s.connected && fresh ? p.good : p.heat).frame(width: 6, height: 6)
            Text(s.mac).font(.caption2.weight(.bold)).lineLimit(1)
            Spacer(minLength: 2)
            // the age ticks by itself, so you always know how fresh this is
            Text(s.t, style: .relative).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: compact ? 52 : 90, alignment: .trailing)
        }
    }

    private var fresh: Bool { Date().timeIntervalSince(s.t) < 600 }

    private func big(_ m: Metric) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title(m), systemImage: symbol(m)).font(.caption2.weight(.bold)).foregroundStyle(tint(m))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value(m)).font(.system(size: 34, weight: .bold, design: p.mono ? .monospaced : .rounded))
                    .contentTransition(.numericText(value: number(m)))
                    .minimumScaleFactor(0.5).lineLimit(1)
                Text(unit(m)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ m: Metric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol(m)).font(.caption2).foregroundStyle(tint(m))
                Text(title(m)).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(value(m) + unit(m)).font(.caption.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: number(m)))
            }
            if let f = fraction(m) {
                GeometryReader { g in
                    Capsule().fill(tint(m).opacity(0.2))
                        .overlay(alignment: .leading) { Capsule().fill(tint(m)).frame(width: max(2, g.size.width * f)) }
                }
                .frame(height: 4)
            }
        }
    }

    /// The heartbeat (or CPU) trace: the last minute, drawn like the app's monitor.
    private func line(_ m: Metric) -> some View {
        let vals = m == .cpu ? s.cpuHistory : s.bpmHistory
        let color = tint(m == .cpu ? .cpu : .heart)
        return GeometryReader { g in
            if vals.count > 1 {
                let lo = (vals.min() ?? 0) - 2, hi = (vals.max() ?? 1) + 2
                Path { path in
                    for (i, v) in vals.enumerated() {
                        let x = g.size.width * CGFloat(i) / CGFloat(vals.count - 1)
                        let y = g.size.height * (1 - CGFloat((v - lo) / max(hi - lo, 1)))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: p.glow ? color.opacity(0.7) : .clear, radius: 3)
            }
        }
    }

    private func title(_ m: Metric) -> String {
        switch m {
        case .heart: return "HEART"; case .cpu: return "CPU"; case .memory: return "MEMORY"; case .storage: return "STORAGE"
        case .battery: return "BATTERY"; case .network: return "NETWORK"; case .health: return "HEALTH"; case .uptime: return "UP"
        }
    }

    private func symbol(_ m: Metric) -> String {
        switch m {
        case .heart: return "waveform.path.ecg"; case .cpu: return "cpu"; case .memory: return "memorychip"
        case .storage: return "internaldrive"; case .battery: return s.charging == true ? "battery.100.bolt" : "battery.75"
        case .network: return "arrow.up.arrow.down"; case .health: return "heart.text.square"; case .uptime: return "clock"
        }
    }

    private func tint(_ m: Metric) -> Color {
        switch m {
        case .heart: return s.bpm > 120 ? p.warn : s.bpm > 95 ? p.heat : p.accent
        case .memory: return (s.pressure ?? 0) >= 2 ? p.warn : p.accent
        case .storage: return s.diskUsedFraction > 0.9 ? p.warn : p.accent
        case .battery: return (s.battery ?? 100) < 20 ? p.warn : p.good
        default: return p.accent
        }
    }

    private func number(_ m: Metric) -> Double {
        switch m {
        case .heart: return s.bpm; case .cpu: return s.cpu; case .memory: return s.memFraction * 100
        case .storage: return s.diskFree / 1e9; case .battery: return s.battery ?? 0
        case .network: return (s.netIn + s.netOut) / 1e3; case .health: return Double(s.health ?? 0)
        case .uptime: return (s.uptime ?? 0) / 3600
        }
    }

    private func value(_ m: Metric) -> String {
        switch m {
        case .heart: return "\(Int(s.bpm))"
        case .cpu: return "\(Int(s.cpu))"
        case .memory: return "\(Int(s.memFraction * 100))"
        case .storage: return bytes(s.diskFree)
        case .battery: return "\(Int(s.battery ?? 0))"
        case .network: return bytes(s.netIn + s.netOut)
        case .health: return "\(s.health ?? 0)"
        case .uptime:
            let u = s.uptime ?? 0
            return u > 86_400 ? "\(Int(u / 86_400))d" : "\(Int(u / 3600))h"
        }
    }

    private func unit(_ m: Metric) -> String {
        switch m {
        case .heart: return " bpm"; case .cpu, .memory, .battery: return "%"; case .storage: return " free"
        case .network: return "/s"; case .health: return "/100"; case .uptime: return ""
        }
    }

    private func fraction(_ m: Metric) -> Double? {
        switch m {
        case .cpu: return s.cpu / 100; case .memory: return s.memFraction; case .storage: return s.diskUsedFraction
        case .battery: return (s.battery ?? 0) / 100; case .health: return Double(s.health ?? 0) / 100
        default: return nil
        }
    }

    private func bytes(_ v: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) }
}
