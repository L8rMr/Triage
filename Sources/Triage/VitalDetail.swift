import SwiftUI
import AppKit

// MARK: - What to do about it

struct Suggestion: Identifiable {
    enum Action { case quit(AppUsage), route(Route), openSettings(String), none }
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let action: Action
    let actionLabel: String?
}

enum Coach {
    static func suggestions(_ h: HeartReading, _ s: SystemSnapshot, apps: [AppUsage]) -> [Suggestion] {
        var out: [Suggestion] = []
        let f = Dictionary(uniqueKeysWithValues: h.factors.map { ($0.id, $0.stress) })
        let real = apps.filter { !$0.isSystem }
        let uptimeDays = ProcessInfo.processInfo.systemUptime / 86_400
        let browsers = ["Google Chrome", "Safari", "Firefox", "Arc", "Microsoft Edge", "Brave Browser"]

        if (f["cpu"] ?? 0) > 0.4 || (f["thermal"] ?? 0) > 0.3, let top = real.max(by: { $0.cpu < $1.cpu }), top.cpu > 8 {
            if browsers.contains(top.name) {
                out.append(Suggestion(id: "cpu-browser", symbol: "rectangle.stack.badge.minus",
                                      title: "Close heavy tabs in \(top.name)",
                                      detail: "\(top.name) is using \(Fmt.pct(top.cpu)) CPU across \(top.processes.count) processes. Video, maps and web apps are the usual culprits.",
                                      action: .route(.apps), actionLabel: "See its processes"))
            } else {
                out.append(Suggestion(id: "cpu-top", symbol: "flame",
                                      title: "Quit \(top.name)",
                                      detail: "It's using \(Fmt.pct(top.cpu)) CPU right now, more than anything else.",
                                      action: .quit(top), actionLabel: "Quit"))
            }
        }
        if (f["mem"] ?? 0) > 0.35, let hog = real.max(by: { $0.memory < $1.memory }) {
            out.append(Suggestion(id: "mem-top", symbol: "memorychip",
                                  title: "Free memory from \(hog.name)",
                                  detail: "It's holding \(Fmt.bytes(hog.memory)). Quitting and reopening it hands that back to macOS.",
                                  action: .quit(hog), actionLabel: "Quit"))
        }
        if s.swapUsed > 2_000_000_000 || ((f["mem"] ?? 0) > 0.5 && uptimeDays > 3) {
            out.append(Suggestion(id: "restart", symbol: "arrow.clockwise.circle",
                                  title: "Restart when you get a chance",
                                  detail: "Your Mac has been up \(Int(uptimeDays)) days with \(Fmt.bytes(s.swapUsed)) in swap. A restart clears both.",
                                  action: .none, actionLabel: nil))
        }
        if (f["thermal"] ?? 0) >= 0.4 {
            out.append(Suggestion(id: "heat", symbol: "wind",
                                  title: "Let it cool down",
                                  detail: "macOS is slowing the chip to protect it. Close heavy apps, keep vents clear and off soft surfaces like a bed or couch.",
                                  action: .route(.apps), actionLabel: "Heaviest apps"))
        }
        if (f["disk"] ?? 0) > 0.2 {
            out.append(Suggestion(id: "disk", symbol: "externaldrive.badge.minus",
                                  title: "Clear some disk space",
                                  detail: "Only \(Fmt.bytes(s.diskFree)) free. macOS needs room for swap, caches and updates; aim for 15% free.",
                                  action: .route(.clean), actionLabel: "Free Up Space"))
            out.append(Suggestion(id: "tidy", symbol: "tray.and.arrow.down",
                                  title: "Sweep old downloads",
                                  detail: "Installers and duplicates in Downloads add up fast.",
                                  action: .route(.tidy), actionLabel: "Tidy Downloads"))
        }
        if let b = s.battery {
            if !b.onAC && b.percent < 25 {
                out.append(Suggestion(id: "plug", symbol: "powerplug", title: "Plug in soon",
                                      detail: "Battery is at \(Int(b.percent))%. Low Power Mode also buys time.",
                                      action: .openSettings("x-apple.systempreferences:com.apple.preference.battery"),
                                      actionLabel: "Battery settings"))
            }
            if let hl = b.health, hl < 80 {
                out.append(Suggestion(id: "service", symbol: "battery.25", title: "Battery is wearing out",
                                      detail: "It holds \(Int(hl))% of its original charge after \(b.cycles ?? 0) cycles. Apple replaces batteries under 80%.",
                                      action: .none, actionLabel: nil))
            }
        }
        if out.isEmpty && h.stress >= 0.45 {
            out.append(Suggestion(id: "general", symbol: "leaf", title: "Close what you're not using",
                                  detail: "Nothing single is to blame. Several things are busy at once.",
                                  action: .route(.apps), actionLabel: "See apps"))
        }
        return out
    }
}

struct SuggestionsCard: View {
    let reading: HeartReading
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: AppModel
    @State private var confirm: AppUsage?

    var body: some View {
        let list = Coach.suggestions(reading, monitor.snap, apps: monitor.apps)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(reading.stress >= 0.65 ? "How to bring the heart rate down" : "Ways to keep it calm",
                      systemImage: "cross.case")
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundStyle(reading.color)
                ForEach(list) { s in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: s.symbol).font(.ui(size: 16)).foregroundStyle(reading.color).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.ui(size: 13, weight: .semibold))
                            Text(s.detail).font(.ui(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let label = s.actionLabel {
                            Button(label) { run(s.action) }.controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(14)
            .glass()
            .confirmationDialog("Quit \(confirm?.name ?? "")?",
                                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button("Quit", role: .destructive) {
                    if let a = confirm { monitor.quit(a) }
                    confirm = nil
                }
            } message: { Text("Unsaved work in this app may be lost.") }
        }
    }

    private func run(_ a: Suggestion.Action) {
        switch a {
        case .quit(let app): confirm = app
        case .route(let r): model.route = r
        case .openSettings(let u): if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case .none: break
        }
    }
}

struct VitalID: Identifiable, Hashable {
    let id: String
}

extension View {
    /// Shows the "what's behind this number" sheet for a vital.
    func vitalDetail(_ item: Binding<VitalID?>, monitor: SystemMonitor, model: AppModel) -> some View {
        sheet(item: item) { v in
            VitalDetailSheet(factorID: v.id)
                .environmentObject(monitor)
                .environmentObject(model)
        }
    }
}

struct FolderSize: Hashable {
    let name: String
    let size: Int64
}

// MARK: - Drill-down: what's behind each vital

struct VitalDetailSheet: View {
    let factorID: String
    @EnvironmentObject var monitor: SystemMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [FolderSize] = []
    @State private var measuring = false

    private var factor: HeartReading.Factor? { monitor.heart?.factors.first { $0.id == factorID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let f = factor {
                HStack(alignment: .firstTextBaseline) {
                    Text(f.channel).font(.ui(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(f.color)
                    Text(f.label).font(.ui(size: 22, weight: .bold, design: .rounded))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(Int((f.stress * 100).rounded()))").font(.ui(size: 30, weight: .semibold, design: .monospaced))
                            .foregroundStyle(f.stress > 0.65 ? Theme.warn : f.color)
                        Text("stress / 100").font(.ui(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text(f.reading).font(.ui(size: 13)).foregroundStyle(.secondary)
                Sparkline(values: monitor.factorHistory[f.id] ?? [], maxValue: 1, color: f.color).frame(height: 50)
                formula(f)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                ScrollView { breakdown(f).frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 600)
        .background(Theme.bg)
        .task { if factorID == "disk" { await measureFolders() } }
    }

    private func formula(_ f: HeartReading.Factor) -> some View {
        let text: String
        switch f.id {
        case "cpu": text = "Stress = CPU load. 0 when idle, 100 when every core is busy. Weight in the heart rate: 35%."
        case "mem": text = "Stress = macOS memory pressure (warning 70, critical 100), or how full memory is past 60% plus swap, whichever is higher. Weight: 25%."
        case "thermal": text = "Stress = macOS thermal state: Cool 0, Warm 40, Hot 80, Critical 100. Weight: 20%."
        case "disk": text = "Stress starts when the disk is 80% full and maxes out at 97%. Weight: 10%."
        default: text = "Stress rises below 25% charge on battery, or when battery health drops under 80%. Weight: 10%."
        }
        let worst = monitor.heart?.driver?.id == f.id
        return VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if worst {
                Text("This is your worst vital right now, so it sets most of the pace (65% of the heart rate).")
                    .font(.ui(size: 11, weight: .medium)).foregroundStyle(f.color)
            }
        }
    }

    @ViewBuilder private func breakdown(_ f: HeartReading.Factor) -> some View {
        let s = monitor.snap
        switch f.id {
        case "cpu":
            section("Apps using the processor", appBars(monitor.apps.sorted { $0.cpu > $1.cpu }.prefix(10), value: { $0.cpu },
                                                        label: { Fmt.pct($0.cpu) }, max: 100, color: f.color))
            note("Each app's number is its share of your whole Mac (all \(ProcessInfo.processInfo.activeProcessorCount) cores), so they add up to the total above. “macOS” groups every system process together.")
        case "mem":
            VStack(alignment: .leading, spacing: 8) {
                kv("App memory", Fmt.bytes(s.memApp))
                kv("Wired (macOS itself)", Fmt.bytes(s.memWired))
                kv("Compressed", Fmt.bytes(s.memCompressed))
                kv("Free or cached", Fmt.bytes(s.memTotal > s.memUsed ? s.memTotal - s.memUsed : 0))
                kv("Swap on disk", Fmt.bytes(s.swapUsed))
                kv("macOS pressure level", s.pressureLevel >= 4 ? "Critical" : s.pressureLevel >= 2 ? "Warning" : "Normal")
            }
            section("Apps holding the most memory", appBars(monitor.apps.sorted { $0.memory > $1.memory }.prefix(10),
                                                            value: { Double($0.memory) }, label: { Fmt.bytes($0.memory) },
                                                            max: Double(s.memTotal), color: f.color))
        case "thermal":
            VStack(alignment: .leading, spacing: 6) {
                kv("Thermal state", f.reading)
                note("Macs report four states: Cool (normal), Warm (fans up), Hot (the chip slows itself down) and Critical. Heat almost always comes from sustained CPU or GPU work.")
            }
            section("Likely heat sources", appBars(monitor.apps.sorted { $0.cpu > $1.cpu }.prefix(6), value: { $0.cpu },
                                                   label: { Fmt.pct($0.cpu) }, max: 100, color: f.color))
        case "disk":
            VStack(alignment: .leading, spacing: 6) {
                kv("Free", Fmt.bytes(s.diskFree))
                kv("Used", Fmt.bytes(s.diskTotal - s.diskFree))
                kv("Total", Fmt.bytes(s.diskTotal))
            }
            section(measuring ? "Measuring your folders…" : "Where the space goes",
                    VStack(alignment: .leading, spacing: 6) {
                        let top = Double(folders.first?.size ?? 1)
                        ForEach(folders, id: \.name) { item in
                            bar(item.name, Fmt.bytes(item.size), Double(item.size) / max(top, 1), f.color)
                        }
                        if measuring { ProgressView().controlSize(.small) }
                    })
        default:
            if let b = s.battery {
                VStack(alignment: .leading, spacing: 8) {
                    kv("Charge", "\(Int(b.percent))%")
                    kv("Power", b.charging ? "Charging" : b.onAC ? "Plugged in" : "On battery")
                    if let m = b.minutesLeft { kv("Time left", Fmt.duration(TimeInterval(m * 60))) }
                    if let c = b.cycles { kv("Charge cycles", "\(c)") }
                    if let h = b.health { kv("Health", "\(Int(h))% of original capacity") }
                }
            } else {
                note("This Mac has no battery.")
            }
        }
    }

    private func section<C: View>(_ title: String, _ content: C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.7).foregroundStyle(.secondary)
            content
        }
        .padding(.top, 10)
    }

    private func appBars(_ apps: ArraySlice<AppUsage>, value: @escaping (AppUsage) -> Double,
                         label: @escaping (AppUsage) -> String, max mx: Double, color: Color) -> some View {
        let top = Swift.max(apps.map(value).max() ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(apps)) { a in
                HStack(spacing: 8) {
                    Image(nsImage: Icons.icon(for: a)).resizable().frame(width: 16, height: 16)
                    bar(a.name, label(a), value(a) / top, color)
                }
            }
        }
    }

    private func bar(_ name: String, _ value: String, _ frac: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.ui(size: 12)).lineLimit(1)
                Spacer()
                Text(value).font(.ui(size: 12, weight: .medium)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(color.opacity(0.8)).frame(width: Swift.max(3, g.size.width * Swift.min(frac, 1)))
                }
            }
            .frame(height: 4)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.ui(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.ui(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func measureFolders() async {
        measuring = true
        let targets = Places.favorites + ["Movies", "Music", "Pictures", "Library"].map { Places.home.appendingPathComponent($0) }
        let unique = Array(Set(targets.map(\.path))).filter { $0 != Places.home.path }
        for path in unique {
            let size = await Work.runHeavy { FS.size(of: URL(fileURLWithPath: path)) }
            let name = path == "/Applications" ? "Applications" : Places.abbreviate(path)
            folders.append(FolderSize(name: name, size: size))
            folders.sort { $0.size > $1.size }
        }
        measuring = false
    }
}

// MARK: - Menu bar customisation

enum BarItem: String, CaseIterable, Identifiable {
    case heart, cpu, memory, network, disk, temp, battery, wifi, volume, headphones, mouse
    var id: String { rawValue }
    var title: String {
        switch self {
        case .heart: return "Heart rate"
        case .cpu: return "CPU %"
        case .memory: return "Memory %"
        case .network: return "Download speed"
        case .disk: return "Free disk"
        case .temp: return "Thermal state"
        case .battery: return "Battery %"
        case .wifi: return "Wi-Fi network"
        case .volume: return "Volume %"
        case .headphones: return "Headphone battery"
        case .mouse: return "Mouse / keyboard battery"
        }
    }
}


extension BarItem {
    var short: String {
        switch self {
        case .heart: return "bpm"
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .network: return "Net"
        case .disk: return "Disk"
        case .temp: return "Heat"
        case .battery: return "Batt"
        case .wifi: return "Wi-Fi"
        case .volume: return "Vol"
        case .headphones: return "Buds"
        case .mouse: return "Mouse"
        }
    }
    static func toggle(_ item: BarItem, in items: String) -> String {
        var s = items.split(separator: ",").compactMap { BarItem(rawValue: String($0)) }.filter { $0 != item }
        if !items.split(separator: ",").contains(Substring(item.rawValue)) { s.append(item) }
        return BarItem.allCases.filter { s.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

enum MenuBarText {
    static func compose(_ m: SystemMonitor, items: String, icon: Bool) -> String {
        let s = m.snap
        let parts: [String] = items.split(separator: ",").compactMap { raw in
            switch BarItem(rawValue: String(raw)) {
            case .heart?: return "\(Int(m.bpm.rounded()))"
            case .cpu?: return "CPU \(Int(s.cpu))%"
            case .memory?: return "MEM \(Int(s.memFraction * 100))%"
            case .network?: return "↓\(Fmt.rate(s.netIn))"
            case .disk?: return "\(Fmt.bytes(s.diskFree)) free"
            case .temp?: return m.heart?.factors.first { $0.id == "thermal" }?.reading ?? "—"
            case .battery?: return s.battery.map { "\(Int($0.percent))%" }
            case .wifi?: return WiFiModel.shared.ssid ?? (WiFiModel.shared.powerOn ? "Wi-Fi" : "Wi-Fi off")
            case .volume?: return "VOL \(Int(CA.volume(CA.defaultOutput) * 100))%"
            case .headphones?: return BluetoothModel.shared.headphones.map { d in d.battery.map { "\(Self.shortName(d.name)) \($0)%" } ?? Self.shortName(d.name) } ?? "No buds"
            case .mouse?: return BluetoothModel.shared.lowestInput.map { "\(Self.shortName($0.name)) \($0.battery ?? 0)%" } ?? "—"
            case nil: return nil
            }
        }
        return parts.isEmpty && !icon ? "Triage" : parts.joined(separator: "  ")
    }

    /// "Alen’s AirPods Pro" → "AirPods", "MX Master 3S" → "MX"
    static func shortName(_ n: String) -> String {
        let base = n.components(separatedBy: "’s ").last ?? n
        return base.split(separator: " ").first.map(String.init) ?? base
    }
}
