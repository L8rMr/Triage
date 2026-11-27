import WidgetKit
import SwiftUI
import AppIntents

// MARK: - What you can choose

enum Metric: String, AppEnum, CaseIterable {
    case cpu, memory, storage, battery, network, health, uptime, apps, temperature, heart, nothing

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Reading"
    static var caseDisplayRepresentations: [Metric: DisplayRepresentation] = [
        .cpu: "CPU", .memory: "Memory", .storage: "Storage", .battery: "Battery", .network: "Network",
        .health: "Health score", .uptime: "Uptime", .apps: "Busiest app", .temperature: "Temperature",
        .heart: "Heart rate", .nothing: "Nothing",
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
    static var description = IntentDescription("Pick what each spot shows. Small uses spots 1–2, medium 1–4, large 1–6.")

    @Parameter(title: "Spot 1", default: .cpu) var s1: Metric
    @Parameter(title: "Spot 2", default: .memory) var s2: Metric
    @Parameter(title: "Spot 3 (medium & large)", default: .storage) var s3: Metric
    @Parameter(title: "Spot 4 (medium & large)", default: .network) var s4: Metric
    @Parameter(title: "Spot 5 (large)", default: .battery) var s5: Metric
    @Parameter(title: "Spot 6 (large)", default: .health) var s6: Metric

    @Parameter(title: "Show the status line (large)", default: true)
    var status: Bool

    @Parameter(title: "Show busiest apps (large)", default: true)
    var apps: Bool

    @Parameter(title: "Refresh when Triage is closed", default: .fifteen)
    var refresh: RefreshEvery

    var spots: [Metric] { [s1, s2, s3, s4, s5, s6] }

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$s1), \(\.$s2)") {
            \.$s3; \.$s4; \.$s5; \.$s6; \.$status; \.$apps; \.$refresh
        }
    }
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
        .description("Your Mac at a glance. Long-press › Edit Widget to choose what each spot shows.")
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

    private func spots(_ n: Int) -> [Metric] {
        Array(entry.config.spots.prefix(n).filter { $0 != .nothing && !($0 == .battery && s.battery == nil) })
    }

    // Small: two readings as tiles.
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(compact: true)
            ForEach(spots(2), id: \.self) { m in tile(m) }
            Spacer(minLength: 0)
        }
    }

    // Medium: four tiles, two by two.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(compact: false)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(spots(4), id: \.self) { m in tile(m) }
            }
            Spacer(minLength: 0)
        }
    }

    // Large: status, six tiles, the busiest apps.
    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(compact: false)
            if entry.config.status, let st = s.status {
                Label(st, systemImage: "stethoscope").font(.caption.weight(.semibold)).foregroundStyle(p.accent).lineLimit(1)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(spots(6), id: \.self) { m in tile(m) }
            }
            if entry.config.apps && !s.top.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("BUSIEST APPS", systemImage: "flame").font(.caption2.weight(.bold)).foregroundStyle(p.accent)
                    ForEach(s.top.prefix(3), id: \.self) { a in
                        HStack {
                            Image(systemName: "app.dashed").font(.caption2).foregroundStyle(.secondary)
                            Text(a.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", a.cpu)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(p.card, in: RoundedRectangle(cornerRadius: min(p.radius, 12)))
            }
            Spacer(minLength: 0)
        }
    }

    private var circular: some View {
        Gauge(value: min(s.cpu, 100), in: 0...100) {
            Image(systemName: "cpu")
        } currentValueLabel: { Text("\(Int(s.cpu))") }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(s.mac, systemImage: "laptopcomputer").font(.caption.weight(.semibold)).lineLimit(1)
            Text("CPU \(Int(s.cpu))% · Mem \(Int(s.memFraction * 100))%").font(.caption)
            Text("\(bytes(s.diskFree)) free").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func header(compact: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "laptopcomputer").font(.caption2.weight(.bold)).foregroundStyle(p.accent)
            Text(s.mac).font(.caption2.weight(.bold)).lineLimit(1)
            Circle().fill(s.connected && fresh ? p.good : p.heat).frame(width: 5, height: 5)
            Spacer(minLength: 2)
            Text(s.t, style: .relative).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: compact ? 48 : 90, alignment: .trailing)
        }
    }

    private var fresh: Bool { Date().timeIntervalSince(s.t) < 600 }

    /// One reading, drawn like the app's cards: icon and label, value, a thin bar when it's a share of something.
    private func tile(_ m: Metric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol(m)).font(.caption2.weight(.semibold)).foregroundStyle(tint(m))
                Text(title(m)).font(.caption2.weight(.bold)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value(m)).font(.system(size: 18, weight: .bold, design: p.mono ? .monospaced : .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(unit(m)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let f = fraction(m) {
                GeometryReader { g in
                    Capsule().fill(tint(m).opacity(0.2))
                        .overlay(alignment: .leading) { Capsule().fill(tint(m)).frame(width: max(2, g.size.width * min(max(f, 0), 1))) }
                }
                .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(p.card, in: RoundedRectangle(cornerRadius: min(p.radius, 12)))
        .overlay(RoundedRectangle(cornerRadius: min(p.radius, 12)).stroke(p.stroke, lineWidth: 0.5))
    }

    private func title(_ m: Metric) -> String {
        switch m {
        case .heart: return "HEART"; case .cpu: return "CPU"; case .memory: return "MEMORY"; case .storage: return "STORAGE"
        case .battery: return "BATTERY"; case .network: return "NETWORK"; case .health: return "HEALTH"; case .uptime: return "UPTIME"
        case .apps: return "BUSIEST"; case .temperature: return "TEMP"; case .nothing: return ""
        }
    }

    private func symbol(_ m: Metric) -> String {
        switch m {
        case .heart: return "waveform.path.ecg"; case .cpu: return "cpu"; case .memory: return "memorychip"
        case .storage: return "internaldrive"; case .battery: return s.charging == true ? "battery.100.bolt" : "battery.75"
        case .network: return "arrow.up.arrow.down"; case .health: return "stethoscope"; case .uptime: return "clock"
        case .apps: return "flame"; case .temperature: return "thermometer.medium"; case .nothing: return "circle"
        }
    }

    private func tint(_ m: Metric) -> Color {
        switch m {
        case .heart: return s.bpm > 120 ? p.warn : s.bpm > 95 ? p.heat : p.accent
        case .memory: return (s.pressure ?? 0) >= 2 ? p.warn : p.accent
        case .storage: return s.diskUsedFraction > 0.9 ? p.warn : p.accent
        case .battery: return (s.battery ?? 100) < 20 ? p.warn : p.good
        case .temperature: return (s.thermal ?? 0) >= 2 ? p.warn : (s.thermal ?? 0) == 1 ? p.heat : p.good
        default: return p.accent
        }
    }

    private func number(_ m: Metric) -> Double {
        switch m {
        case .heart: return s.bpm; case .cpu: return s.cpu; case .memory: return s.memFraction * 100
        case .storage: return s.diskFree / 1e9; case .battery: return s.battery ?? 0
        case .network: return (s.netIn + s.netOut) / 1e3; case .health: return Double(s.health ?? 0)
        case .uptime: return (s.uptime ?? 0) / 3600
        case .apps: return s.top.first?.cpu ?? 0; case .temperature: return Double(s.thermal ?? 0); case .nothing: return 0
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
        case .apps: return s.top.first?.name ?? "—"
        case .temperature: return ["Cool", "Warm", "Hot", "Very hot"][min(max(s.thermal ?? 0, 0), 3)]
        case .nothing: return ""
        }
    }

    private func unit(_ m: Metric) -> String {
        switch m {
        case .heart: return " bpm"; case .cpu, .memory, .battery: return "%"; case .storage: return " free"
        case .network: return "/s"; case .health: return "/100"; case .uptime, .temperature, .nothing: return ""
        case .apps: return s.top.first.map { String(format: " %.0f%%", $0.cpu) } ?? ""
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
