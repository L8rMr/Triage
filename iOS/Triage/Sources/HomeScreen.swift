import SwiftUI
import Charts

/// The Mac's Home "At a Glance" dashboard, on the phone.
struct HomeScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var glance: Glance?
    @State private var width: CGFloat = 0
    var go: (Pane) -> Void = { _ in }

    private var columns: [GridItem] {
        let n = width > 1000 ? 3 : width > 640 ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: n)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    NavigationLink { HeartScreen() } label: { heartTile }.buttonStyle(.plain)
                    storageTile
                    memoryTile
                    if let g = glance {
                        screenTimeTile(g)
                        heartDayTile(g)
                        uptimeTile(g)
                        macTile(g)
                        if !g.hungry.isEmpty { hungryTile(g) }
                    }
                    batteryTile
                }
            }
            .padding(16)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color.glass900)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                if let d = try? await link.call("glance"), let g: Glance = decode(d) { glance = g }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .refreshable { if let d = try? await link.call("glance"), let g: Glance = decode(d) { glance = g } }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let name = (link.info?.user ?? "").split(separator: " ").first.map(String.init) ?? ""
        let part = h < 5 ? "Still up" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        return name.isEmpty ? part : "\(part), \(name)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.caption).foregroundStyle(.secondary)
            Text(greeting).font(.largeTitle.weight(.bold))
            Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
    }

    private var statusLine: String {
        guard let v = link.vitals else { return "Listening for \(link.macName)…" }
        if (v.factors?.map(\.stress).max() ?? 0) < 0.3 { return "\(link.macName) is running easy. Nothing needs you right now." }
        if let f = v.factors?.max(by: { $0.stress < $1.stress }), let c = f.cause, !c.isEmpty { return "\(f.label) is busy. \(c) is doing the most." }
        return "\(link.macName) is working, but nothing's urgent."
    }

    // MARK: Tiles

    private func tile<C: View>(_ title: String, _ symbol: String, tint: Color, action: (() -> Void)? = nil, @ViewBuilder _ content: () -> C) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(title.uppercased(), systemImage: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
                    Spacer()
                    if let action {
                        Button(action: action) { Image(systemName: "arrow.up.right").font(.caption.weight(.bold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                content()
            }
        }
    }

    private var heartTile: some View {
        let v = link.vitals
        let c = Color.pulse(v?.bpm ?? 60)
        return tile("Heart", "heart.fill", tint: c, action: nil) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int((v?.bpm ?? 0).rounded()))").font(.system(size: 38, weight: .bold, design: .monospaced)).foregroundStyle(c)
                Text("bpm").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(v?.status ?? "").font(.subheadline.weight(.semibold)).foregroundStyle(c)
            }
            ECGView(bpm: v?.bpm ?? 60, color: c, flat: v == nil).frame(height: 54)
        }
    }

    private var storageTile: some View {
        let v = link.vitals
        let used = 1 - (v?.diskFreeFraction ?? 0)
        return tile("Storage", "internaldrive.fill", tint: .vital(max(0, used - 0.3) / 0.65), action: { go(.tools) }) {
            Text(Fmt.bytes(v?.diskFree ?? 0)).font(.system(size: 30, weight: .bold, design: .monospaced))
            Text("free of \(Fmt.bytes(v?.diskTotal ?? 0))").font(.caption).foregroundStyle(.secondary)
            bar(used, .vital(max(0, used - 0.3) / 0.65))
        }
    }

    private var memoryTile: some View {
        let v = link.vitals
        return tile("Memory", "memorychip.fill", tint: .vital(max(0, (v?.memFraction ?? 0) - 0.4) / 0.55)) {
            Text(Fmt.bytes(v?.memUsed ?? 0)).font(.system(size: 30, weight: .bold, design: .monospaced))
            Text("of \(Fmt.bytes(v?.memTotal ?? 0)) · swap \(Fmt.bytes(v?.swap ?? 0))").font(.caption).foregroundStyle(.secondary)
            bar(v?.memFraction ?? 0, .vital(max(0, (v?.memFraction ?? 0) - 0.4) / 0.55))
        }
    }

    private func bar(_ f: Double, _ c: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(c).frame(width: max(6, g.size.width * min(max(f, 0), 1)))
            }
        }
        .frame(height: 7)
    }

    private func screenTimeTile(_ g: Glance) -> some View {
        tile("Screen time today", "hourglass", tint: .phosphor) {
            Text(Fmt.span(g.todayTotal)).font(.system(size: 30, weight: .bold, design: .monospaced))
            let top = g.today.first?.secs ?? 1
            ForEach(g.today.prefix(5)) { a in
                HStack(spacing: 8) {
                    Text(a.name).font(.caption).lineLimit(1).frame(width: 92, alignment: .leading)
                    bar(a.secs / max(top, 1), .phosphor)
                    Text(Fmt.span(a.secs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
            Chart(g.week) { d in
                BarMark(x: .value("Day", d.label), y: .value("Hours", d.secs / 3600))
                    .foregroundStyle(d.label == "Today" ? Color.phosphor : Color.phosphor.opacity(0.35))
                    .cornerRadius(3)
            }
            .chartYAxis(.hidden)
            .frame(height: 70)
        }
    }

    private func heartDayTile(_ g: Glance) -> some View {
        tile("Heart, last 24 hours", "waveform.path.ecg", tint: .phosphor) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(g.heartAvg))").font(.system(size: 30, weight: .bold, design: .monospaced))
                Text("bpm average").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("peak \(Int(g.heartPeak))").font(.caption.monospacedDigit()).foregroundStyle(Color.pulse(g.heartPeak))
            }
            Chart(g.heart) { p in
                AreaMark(x: .value("Time", Date(timeIntervalSince1970: p.t)), y: .value("bpm", p.bpm))
                    .foregroundStyle(LinearGradient(colors: [Color.phosphor.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", Date(timeIntervalSince1970: p.t)), y: .value("bpm", p.bpm))
                    .foregroundStyle(Color.phosphor).interpolationMethod(.monotone)
            }
            .chartYScale(domain: 50...max(120, g.heartPeak + 10))
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 90)
        }
    }

    private func uptimeTile(_ g: Glance) -> some View {
        let up = Date().timeIntervalSince1970 - (g.boot ?? Date().timeIntervalSince1970)
        return tile("Up and running", "power", tint: .phosphor) {
            Text(Fmt.span(up)).font(.system(size: 30, weight: .bold, design: .monospaced))
            if let b = g.boot { Text("since \(Date(timeIntervalSince1970: b).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            if let beats = g.beats { Text("≈ \(Int(beats).formatted()) heartbeats since then").font(.caption).foregroundStyle(Color.phosphor) }
            Text(up > 14 * 86_400 ? "A restart would freshen things up." : "Fresh enough. No restart needed.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func macTile(_ g: Glance) -> some View {
        tile("Your Mac", "laptopcomputer", tint: .phosphor) {
            if let s = g.setup {
                let c = Calendar.current.dateComponents([.year, .month], from: Date(timeIntervalSince1970: s), to: Date())
                Text("\(c.year ?? 0)y \(c.month ?? 0)m old").font(.system(size: 30, weight: .bold, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 3) {
                if let c = g.chip { Label(c, systemImage: "cpu").font(.caption) }
                if let m = g.memTotal { Label("\(Fmt.bytes(m)) memory", systemImage: "memorychip").font(.caption) }
                if let o = g.os { Label(o, systemImage: "apple.logo").font(.caption) }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func hungryTile(_ g: Glance) -> some View {
        tile("Hungriest this week", "flame.fill", tint: .amber) {
            let apps = g.hungry.filter { $0.system != true }
            if let first = apps.first {
                Text(first.name).font(.title3.weight(.bold))
                Text("busiest app \(Int(first.share * 100))% of the time").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(apps.dropFirst().prefix(3)) { a in
                HStack { Text(a.name).font(.caption); Spacer(); Text("\(Int(a.share * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let sys = g.hungry.first(where: { $0.system == true }) {
                Text("macOS itself (indexing, updates, backups) led \(Int(sys.share * 100))% of the time").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var batteryTile: some View {
        if let b = link.vitals?.battery {
            tile("Battery", "battery.100percent", tint: b.percent < 20 && !b.onAC ? .coral : .phosphor) {
                Text("\(Int(b.percent))%").font(.system(size: 30, weight: .bold, design: .monospaced))
                Text([b.charging ? "Charging" : b.onAC ? "Plugged in" : "On battery",
                      b.health.flatMap { $0 > 0 ? "health \(Int($0))%" : nil },
                      b.cycles.flatMap { $0 > 0 ? "\($0) cycles" : nil }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                bar(b.percent / 100, b.percent < 20 && !b.onAC ? .coral : .phosphor)
            }
        }
    }
}
