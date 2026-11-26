import SwiftUI
import AppKit

struct AppsView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: AppModel
    @State private var detail: VitalID?
    @State private var sort = ColumnSort(key: "cpu", ascending: false)
    @State private var expanded: Set<String> = []
    @State private var filter = ""
    @State private var types: Set<String> = []
    @State private var loads: Set<String> = []
    @State private var confirmQuit: AppUsage?

    private static func type(_ a: AppUsage) -> String {
        a.isSystem ? "macOS" : (a.bundlePath != nil ? "Apps" : "Tools & services")
    }
    private static func load(_ a: AppUsage) -> String {
        a.cpu >= 20 ? "Busy (20%+ CPU)" : a.cpu >= 2 ? "Active (2–20%)" : "Idle (under 2%)"
    }
    private var typeOptions: [FilterOption] {
        ["Apps", "Tools & services", "macOS"].compactMap { t in
            let n = monitor.apps.filter { Self.type($0) == t }.count
            let sym = t == "Apps" ? "app" : t == "macOS" ? "apple.logo" : "terminal"
            return n > 0 ? FilterOption(id: t, label: t, symbol: sym, count: n) : nil
        }
    }
    private var loadOptions: [FilterOption] {
        ["Busy (20%+ CPU)", "Active (2–20%)", "Idle (under 2%)"].map { l in
            FilterOption(id: l, label: l, symbol: "gauge.with.dots.needle.33percent", count: monitor.apps.filter { Self.load($0) == l }.count)
        }
    }
    private var memOptions: [FilterOption] {
        let buckets = ["Over 1 GB", "100 MB – 1 GB", "Under 100 MB"]
        func b(_ m: UInt64) -> String { m >= 1_000_000_000 ? buckets[0] : m >= 100_000_000 ? buckets[1] : buckets[2] }
        return buckets.map { x in FilterOption(id: x, label: x, symbol: "memorychip", count: monitor.apps.filter { b($0.memory) == x }.count) }
    }
    @State private var mems: Set<String> = []
    private static func memBucket(_ m: UInt64) -> String { m >= 1_000_000_000 ? "Over 1 GB" : m >= 100_000_000 ? "100 MB – 1 GB" : "Under 100 MB" }

    private var filtersOn: Bool { !filter.isEmpty || !types.isEmpty || !loads.isEmpty || !mems.isEmpty }

    private var sorted: [AppUsage] {
        let list = monitor.apps.filter {
            TextFilter.matches($0.name, filter)
                && (types.isEmpty || types.contains(Self.type($0)))
                && (loads.isEmpty || loads.contains(Self.load($0)))
                && (mems.isEmpty || mems.contains(Self.memBucket($0.memory)))
        }
        let s: [AppUsage]
        switch sort.key {
        case "name": s = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "memory": s = list.sorted { $0.memory < $1.memory }
        default: s = list.sorted { $0.cpu == $1.cpu ? $0.memory < $1.memory : $0.cpu < $1.cpu }
        }
        return sort.ascending ? s : s.reversed()
    }

    var body: some View {
        page
            .onAppear { SystemMonitor.liveApps = true }
            .onDisappear { SystemMonitor.liveApps = false }
    }

    @ViewBuilder private var page: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PageTitle(title: "Apps",
                          subtitle: "\(monitor.apps.count) apps instead of \(monitor.processCount) processes. Every helper is counted under the app that owns it.")
                Spacer()
            }

            HStack(spacing: 14) {
                StatCard(title: "CPU", value: Fmt.pct(monitor.snap.cpu),
                         detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                         history: monitor.cpuHistory, color: Theme.cpu)
                    .contentShape(Rectangle()).onTapGesture { detail = VitalID(id: "cpu") }
                StatCard(title: "Memory", value: Fmt.bytes(monitor.snap.memUsed),
                         detail: "of \(Fmt.bytes(monitor.snap.memTotal)) · swap \(Fmt.bytes(monitor.snap.swapUsed))",
                         history: monitor.memHistory, color: Theme.mem)
                    .contentShape(Rectangle()).onTapGesture { detail = VitalID(id: "mem") }
                StatCard(title: "Network", value: Fmt.rate(monitor.snap.netIn),
                         detail: "↑ \(Fmt.rate(monitor.snap.netOut))",
                         history: monitor.netInHistory, maxValue: nil, color: Theme.net)
            }

            HStack(spacing: 12) {
                Color.clear.frame(width: 28, height: 1)
                ColumnHeader("App", sortKey: "name", sort: $sort, options: typeOptions, selection: $types, text: $filter)
                ColumnHeader("Last 90 seconds", width: 120, sort: $sort, options: loadOptions, selection: $loads)
                ColumnHeader("CPU", width: 60, sortKey: "cpu", sort: $sort, defaultAscending: false)
                ColumnHeader("Memory", width: 84, sortKey: "memory", sort: $sort,
                             options: memOptions, selection: $mems, defaultAscending: false)
                Color.clear.frame(width: 18, height: 1)
            }
            .padding(.horizontal, 14)

            if filtersOn {
                FilterSummary(shown: sorted.count, total: monitor.apps.count, bytes: nil) {
                    filter = ""; types = []; loads = []; mems = []
                }
                .padding(.horizontal, 14)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(sorted) { app in
                        AppRow(app: app,
                               expanded: expanded.contains(app.id),
                               onToggle: {
                                   if expanded.contains(app.id) { expanded.remove(app.id) } else { expanded.insert(app.id) }
                               },
                               onQuit: { confirmQuit = app })
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .padding(28)
        .padding(.top, 8)
        .vitalDetail($detail, monitor: monitor, model: model)
        .confirmationDialog("Quit \(confirmQuit?.name ?? "")?",
                            isPresented: Binding(get: { confirmQuit != nil }, set: { if !$0 { confirmQuit = nil } })) {
            Button("Quit", role: .destructive) {
                if let a = confirmQuit { monitor.quit(a) }
                confirmQuit = nil
            }
        } message: {
            Text("Unsaved work in this app may be lost.")
        }
    }
}

struct AppRow: View {
    let app: AppUsage
    let expanded: Bool
    var onToggle: () -> Void
    var onQuit: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: Icons.icon(for: app)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.ui(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(app.processes.count) process\(app.processes.count == 1 ? "" : "es")")
                        .font(.ui(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Sparkline(values: app.history, maxValue: max(100, app.history.max() ?? 0), color: Theme.cpu)
                    .frame(width: 120, height: 24, alignment: .leading)
                Text(Fmt.pct(app.cpu))
                    .font(.ui(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(app.cpu > 40 ? Theme.warn : Color.primary)
                    .frame(width: 60, alignment: .leading)
                Text(Fmt.bytes(app.memory))
                    .font(.ui(size: 12)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                Button(action: onQuit) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(hover && !app.isSystem ? 1 : 0)
                    .disabled(app.isSystem)
                    .help("Quit \(app.name)")
                    .frame(width: 18)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .contextMenu {
                Button(expanded ? "Hide Processes" : "Show Processes", action: onToggle)
                if let p = app.bundlePath {
                    Button("Bring to Front") {
                        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == p }?.activate()
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                }
                Button("Copy Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(app.name, forType: .string) }
                if !app.isSystem {
                    Divider()
                    Button("Quit \(app.name)…", action: onQuit)
                }
            }

            if expanded {
                VStack(spacing: 4) {
                    ForEach(app.processes.prefix(12)) { p in
                        HStack {
                            Text(p.name).font(.ui(size: 11)).lineLimit(1).truncationMode(.middle)
                            Text("\(p.pid)").font(.ui(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                            Spacer()
                            Text(Fmt.pct(p.cpu)).font(.ui(size: 11)).monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text(Fmt.bytes(p.memory)).font(.ui(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .trailing)
                            Color.clear.frame(width: 18, height: 1)
                        }
                    }
                    if app.processes.count > 12 {
                        Text("+ \(app.processes.count - 12) more").font(.ui(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 54).padding(.trailing, 14).padding(.bottom, 10)
            }
        }
        .glass(12)
        .onHover { hover = $0 }
    }
}

struct HardwareView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: AppModel
    @State private var detail: VitalID?

    private let chip = SystemStats.sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"
    private let modelID = SystemStats.sysctlString("hw.model") ?? "Mac"

    private var thermal: (String, Color) {
        switch monitor.snap.thermal {
        case .nominal: return ("Cool", Theme.accent)
        case .fair: return ("Warm", Theme.net)
        case .serious: return ("Hot: throttling likely", Theme.warn)
        case .critical: return ("Critical", Theme.warn)
        @unknown default: return ("Unknown", .secondary)
        }
    }

    /// Inside the Heart page: no scroll view or page title of its own, just a section.
    var embedded = false
    private var macLine: String { "\(chip) · \(modelID) · macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)" }

    var body: some View {
        if embedded {
            content.vitalDetail($detail, monitor: monitor, model: model)
        } else {
            ScrollView { content.padding(28).padding(.top, 8) }
                .vitalDetail($detail, monitor: monitor, model: model)
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                if embedded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("YOUR MAC").font(.ui(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                        Text(macLine).font(.ui(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                } else {
                    PageTitle(title: "Hardware", subtitle: macLine)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                    StatCard(title: "Processor", value: Fmt.pct(monitor.snap.cpu),
                             detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores active",
                             history: monitor.cpuHistory, color: Theme.cpu)
                        .contentShape(Rectangle()).onTapGesture { detail = VitalID(id: "cpu") }

                    memoryCard
                        .contentShape(Rectangle()).onTapGesture { detail = VitalID(id: "mem") }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("NETWORK").font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                        HStack(spacing: 18) {
                            VStack(alignment: .leading) {
                                Text("↓ \(Fmt.rate(monitor.snap.netIn))").font(.ui(size: 18, weight: .semibold, design: .rounded))
                                Sparkline(values: monitor.netInHistory, color: Theme.net).frame(height: 40)
                            }
                            VStack(alignment: .leading) {
                                Text("↑ \(Fmt.rate(monitor.snap.netOut))").font(.ui(size: 18, weight: .semibold, design: .rounded))
                                Sparkline(values: monitor.netOutHistory, color: Theme.accent).frame(height: 40)
                            }
                        }
                    }
                    .padding(14).glass()

                    batteryCard
                        .contentShape(Rectangle()).onTapGesture { detail = VitalID(id: "battery") }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("THERMALS").font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Image(systemName: "thermometer.medium").font(.ui(size: 30)).foregroundStyle(thermal.1)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(thermal.0).font(.ui(size: 20, weight: .semibold, design: .rounded))
                                Text("macOS thermal state").font(.ui(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Text("Up \(Fmt.duration(ProcessInfo.processInfo.systemUptime)) since last restart")
                            .font(.ui(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass()
                    .contentShape(Rectangle()).onTapGesture { detail = VitalID(id: "thermal") }

                    HStack(spacing: 16) {
                        ZStack {
                            Ring(value: monitor.snap.diskUsedFraction, color: Theme.load(monitor.snap.diskUsedFraction * 100), lineWidth: 9)
                            Image(systemName: "internaldrive").foregroundStyle(.secondary)
                        }
                        .frame(width: 70, height: 70)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("STARTUP DISK").font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                            Text("\(Fmt.bytes(monitor.snap.diskFree)) free").font(.ui(size: 20, weight: .semibold, design: .rounded))
                            Text("of \(Fmt.bytes(monitor.snap.diskTotal))").font(.ui(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14).glass()
                    .contentShape(Rectangle()).onTapGesture { detail = VitalID(id: "disk") }
                }
                Text("Click any card to see what's behind it.").font(.ui(size: 11)).foregroundStyle(.tertiary)
            }
    }

    private var memoryCard: some View {
        let s = monitor.snap
        let total = Double(max(s.memTotal, 1))
        return VStack(alignment: .leading, spacing: 8) {
            Text("MEMORY").font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            Text("\(Fmt.bytes(s.memUsed)) of \(Fmt.bytes(s.memTotal))").font(.ui(size: 20, weight: .semibold, design: .rounded))
            GeometryReader { g in
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.mem).frame(width: g.size.width * Double(s.memApp) / total)
                    Rectangle().fill(Theme.net).frame(width: g.size.width * Double(s.memWired) / total)
                    Rectangle().fill(Theme.cpu).frame(width: g.size.width * Double(s.memCompressed) / total)
                    Rectangle().fill(Color.primary.opacity(0.08))
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                legend("App", s.memApp, Theme.mem)
                legend("Wired", s.memWired, Theme.net)
                legend("Compressed", s.memCompressed, Theme.cpu)
            }
            Text("Swap used: \(Fmt.bytes(s.swapUsed))").font(.ui(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass()
    }

    private func legend(_ t: String, _ v: UInt64, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(t) \(Fmt.bytes(v))").font(.ui(size: 11)).foregroundStyle(.secondary)
        }
    }

    private static func powerStatus(_ b: BatteryInfo) -> String {
        if b.charging { return "Charging" }
        if b.onAC { return "On power adapter" }
        if let m = b.minutesLeft { return "\(Fmt.duration(TimeInterval(m * 60))) left" }
        return "On battery"
    }

    @ViewBuilder private var batteryCard: some View {
        if let b = monitor.snap.battery {
            HStack(spacing: 16) {
                ZStack {
                    Ring(value: b.percent / 100, color: b.percent < 20 ? Theme.warn : Theme.accent, lineWidth: 9)
                    Image(systemName: b.charging ? "bolt.fill" : "battery.100").foregroundStyle(.secondary)
                }
                .frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BATTERY").font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                    Text(Fmt.pct(b.percent)).font(.ui(size: 20, weight: .semibold, design: .rounded))
                    Text(Self.powerStatus(b))
                        .font(.ui(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if let c = b.cycles { Text("\(c) cycles") }
                        if let h = b.health { Text("Health \(Fmt.pct(h))") }
                    }
                    .font(.ui(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14).glass()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("POWER").font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                Text("Plugged in, no battery").font(.ui(size: 18, weight: .semibold, design: .rounded))
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass()
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var monitor: SystemMonitor
    @AppStorage("bar.items") private var items = "heart"
    @AppStorage("bar.icon") private var showIcon = true
    @ObservedObject private var remote = RemoteServer.shared

    var body: some View {
        let text = MenuBarText.compose(monitor, items: items, icon: showIcon)
        // the menu bar drops images that sit inside Text, so draw heart + reading as one template image
        Image(nsImage: MenuBarImage.make(icon: showIcon || text.isEmpty, text: text, phone: !remote.connected.isEmpty))
    }
}

enum MenuBarImage {
    static func make(icon: Bool, text: String, phone: Bool = false) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let t = text as NSString
        let ts = text.isEmpty ? .zero : t.size(withAttributes: attrs)
        let heart = icon ? NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Triage")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) : nil
        let hs = heart?.size ?? .zero
        let gap: CGFloat = heart != nil && !text.isEmpty ? 4 : 0
        // a paired iPhone is looking: say so right in the menu bar
        let iphone = phone ? NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: "iPhone connected")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) : nil
        let ps = iphone?.size ?? .zero
        let pgap: CGFloat = iphone != nil ? 5 : 0
        let size = NSSize(width: ceil(hs.width + gap + ts.width + pgap + ps.width), height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            if let heart { heart.draw(in: NSRect(x: 0, y: (18 - hs.height) / 2, width: hs.width, height: hs.height)) }
            if !text.isEmpty { t.draw(at: NSPoint(x: hs.width + gap, y: (18 - ts.height) / 2), withAttributes: attrs) }
            if let iphone { iphone.draw(in: NSRect(x: hs.width + gap + ts.width + pgap, y: (18 - ps.height) / 2, width: ps.width, height: ps.height)) }
            return true
        }
        img.isTemplate = true   // the menu bar tints it for light, dark and highlighted
        return img
    }
}

struct MenuPanel: View {
    @EnvironmentObject var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("panel.tab") private var tab = "vitals"
    @AppStorage("bar.items") private var barItems = "heart"
    @AppStorage("bar.icon") private var showIcon = true
    @ObservedObject private var bt = BluetoothModel.shared
    @ObservedObject private var wifi = WiFiModel.shared
    @State private var customizing = false
    @State private var cacheBytes: Int64?
    @State private var clearing = false
    @State private var micMuted = false
    @State private var speed: String?
    @State private var testing = false
    @State private var showNetworks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ThemeSegments(selection: Binding(get: { customizing ? "" : (tab == "wifi" ? "net" : tab) }, set: { tab = $0; customizing = false }),
                              options: [("vitals", "Vitals", "heart.fill"), ("net", "Wi-Fi & Bluetooth", "wifi"), ("sound", "Sound", "speaker.wave.2.fill")], iconOnly: true)
                Button { customizing.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 26, height: 22)
                        .foregroundStyle(customizing ? Theme.accent : .secondary)
                }
                .buttonStyle(.borderless).help("Choose what shows in the menu bar")
            }
            // Fixed height: the menu bar window re-anchors when its size changes, so every tab gets the same box.
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if customizing { customize }
                    else {
                        switch tab {
                        case "net", "wifi": connectivity
                        case "sound": sound
                        default: vitals
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 352)
            footer
        }
        .padding(10)
        .frame(width: 340)
        .background(Theme.bg)
        .onAppear { bt.start(); micMuted = Mic.muted; measureCaches() }
        .onDisappear { bt.stop() }
    }

    // MARK: Vitals

    private var vitals: some View {
        let s = monitor.snap
        let color = monitor.heart?.color ?? Theme.accent
        return VStack(alignment: .leading, spacing: 8) {
            Button { openMain() } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Int(monitor.bpm.rounded()))")
                            .font(.ui(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
                        Text("bpm · \(monitor.heart?.status ?? "—")").font(.ui(size: 10)).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    PulseLine(bpm: monitor.bpm, color: color).frame(height: 36)
                }
                .padding(8)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Your Mac's heartbeat. Click for the full monitor.")

            HStack(spacing: 6) {
                stat("CPU", Fmt.pct(s.cpu), Theme.cpu)
                stat("Memory", Fmt.bytes(s.memUsed), Theme.mem)
                stat("Heat", monitor.heart?.factors.first { $0.id == "thermal" }?.reading ?? "—", Theme.net)
                stat("Disk free", Fmt.bytes(s.diskFree), Theme.accent)
            }

            Text("USING THE MOST").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary).padding(.top, 2)
            ForEach(Array(monitor.topByCPU.filter { !$0.isSystem }.prefix(3))) { app in
                HStack(spacing: 8) {
                    Image(nsImage: Icons.icon(for: app)).resizable().frame(width: 18, height: 18)
                    Text(app.name).font(.ui(size: 12)).lineLimit(1)
                    Spacer()
                    Text(Fmt.pct(app.cpu)).font(.ui(size: 11)).monospacedDigit().foregroundStyle(Theme.load(app.cpu))
                    Text(Fmt.bytes(app.memory)).font(.ui(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                    Button {
                        monitor.quit(app)
                        UndoCenter.shared.show("Quit \(app.name) · \(Fmt.bytes(app.memory)) of memory back")
                    } label: {
                        Image(systemName: "xmark").font(.ui(size: 9, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain).help("Quit \(app.name)")
                }
                .frame(minHeight: 28)
            }
            fixes.padding(.top, 2)
        }
    }

    private func stat(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.ui(size: 9)).foregroundStyle(.secondary)
            Text(v).font(.ui(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(c)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var fixes: some View {
        let idle = QuickFix.idleApps(monitor.apps)
        let idleBytes = idle.reduce(UInt64(0)) { $0 + $1.1 }
        let swap = monitor.snap.swapUsed
        return HStack(spacing: 6) {
            fix(idle.isEmpty ? "No idle apps" : "Quit \(idle.count) idle",
                idle.isEmpty ? "memory (RAM) in use" : "frees \(Fmt.bytes(idleBytes)) RAM",
                help: idle.isEmpty ? "Every open app is in use." : "Quits apps with no windows open: " + idle.compactMap { $0.0.localizedName }.joined(separator: ", "),
                enabled: !idle.isEmpty) {
                idle.forEach { $0.0.terminate() }
                UndoCenter.shared.show("Quit \(idle.count) idle app\(idle.count == 1 ? "" : "s") · \(Fmt.bytes(idleBytes)) of memory back")
            }
            fix("Restart tonight", swap > 0 ? "resets \(Fmt.bytes(swap)) swap" : "a fresh start",
                help: "Reminds you at 10 pm. A restart clears swap, the overflow memory macOS writes to disk.", enabled: true) {
                QuickFix.remindRestartTonight()
            }
            fix(clearing ? "Clearing…" : cacheBytes.map { "Clear \(Fmt.bytes($0))" } ?? "Clear caches", "of disk (caches)",
                help: "Developer and app caches that rebuild on their own. They go to the Trash, so you can undo.",
                enabled: (cacheBytes ?? 0) > 0 && !clearing) { clearCaches() }
        }
    }

    private func fix(_ title: String, _ sub: String, help: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 1) {
                Text(title).font(.ui(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(sub).font(.ui(size: 9)).opacity(0.75).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(enabled ? Theme.accent.opacity(0.9) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain).disabled(!enabled).help(help)
    }

    private func measureCaches() {
        Task {
            let list = await Work.run { Cleaner.targets(includeDownloads: false).filter { $0.safe } }
            var total: Int64 = 0
            for t in list { let m = await Work.runHeavy { Cleaner.measure(t) }; total += m.size ?? 0 }
            cacheBytes = total
        }
    }

    private func clearCaches() {
        clearing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = Cleaner.targets(includeDownloads: false).filter { $0.safe }.flatMap { Cleaner.resolve($0.source) }
            let moved = FileOps.trash(urls)
            DispatchQueue.main.async {
                clearing = false
                let freed = cacheBytes ?? 0
                cacheBytes = 0
                UndoCenter.shared.show("Moved \(Fmt.bytes(freed)) of caches to the Trash") { FileOps.moveBack(moved); measureCaches() }
            }
        }
    }

    // MARK: Connectivity

    private var connectivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: wifi.powerOn ? "wifi" : "wifi.slash").frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wifi.powerOn ? (wifi.ssid ?? "Not connected") : "Wi-Fi is off").font(.ui(size: 13, weight: .semibold)).lineLimit(1)
                    Text(wifiDetail).font(.ui(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { wifi.powerOn }, set: { wifi.setPower($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            .padding(8)
            .background((wifi.powerOn ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.05)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if wifi.powerOn {
                HStack(spacing: 6) {
                    tool(testing ? "Testing…" : "Speed test", speed ?? "about 15 s") { runSpeedTest() }
                    tool("Copy IP", wifi.ip ?? "—") {
                        if let ip = wifi.ip { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ip, forType: .string); UndoCenter.shared.show("Copied \(ip)") }
                    }
                    tool("Wi-Fi settings", "passwords, sharing") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") { NSWorkspace.shared.open(u) }
                    }
                }
                Button { showNetworks.toggle(); if showNetworks { wifi.scan() } } label: {
                    HStack { Text("Other networks").font(.ui(size: 12, weight: .semibold)); Spacer(); Image(systemName: showNetworks ? "chevron.down" : "chevron.right").font(.ui(size: 10)) }
                        .foregroundStyle(.secondary).frame(minHeight: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showNetworks { WiFiPanel(compact: true) }
            }

            Divider().padding(.vertical, 2)
            HStack(spacing: 10) {
                Image(systemName: "wave.3.right").foregroundStyle(Theme.cpu).frame(width: 20)
                Text("Bluetooth").font(.ui(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { bt.powerOn }, set: { bt.setPower($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if bt.powerOn {
                if bt.devices.isEmpty {
                    Text("No paired devices yet. Pair new ones in System Settings › Bluetooth.").font(.ui(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(bt.devices) { d in
                    Button { bt.toggle(d) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: d.symbol).font(.ui(size: 11))
                                .frame(width: 26, height: 26)
                                .background(d.connected ? Theme.cpu : Color.primary.opacity(0.08), in: Circle())
                                .foregroundStyle(d.connected ? Color.white : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(.ui(size: 12, weight: .semibold)).lineLimit(1)
                                Text(bt.busy == d.id ? "Working…" : d.connected ? (d.detail ?? "Connected") : "Not connected · click to connect")
                                    .font(.ui(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if d.connected, let b = d.battery {
                                Text("\(b)%").font(.ui(size: 11, design: .monospaced)).foregroundStyle(b < 25 ? Theme.warn : Color.secondary)
                            }
                        }
                        .frame(minHeight: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(d.connected ? 1 : 0.65)
                    .help(d.connected ? "Click to disconnect \(d.name)" : "Click to connect \(d.name)")
                }
            }
        }
    }

    private var wifiDetail: String {
        guard wifi.powerOn, wifi.ssid != nil else { return wifi.powerOn ? "Pick a network below" : "Turn it on with the switch" }
        let bars = wifi.rssi > -60 ? "strong" : wifi.rssi > -72 ? "good" : "weak"
        return "\(Int(wifi.txRate)) Mbps link · \(bars) signal"
    }

    private func tool(_ t: String, _ sub: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 1) {
                Text(t).font(.ui(size: 11, weight: .semibold)).lineLimit(1)
                Text(sub).font(.ui(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func runSpeedTest() {
        guard !testing else { return }
        testing = true
        Work.quick.async {
            let out = Shell.run("/usr/bin/networkQuality", ["-c", "-s"], timeout: 40)
            var text = "couldn’t test"
            if let d = out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let dl = (j["dl_throughput"] as? Double ?? 0) / 1_000_000, ul = (j["ul_throughput"] as? Double ?? 0) / 1_000_000
                text = String(format: "%.0f↓ %.0f↑ Mbps", dl, ul)
            }
            DispatchQueue.main.async { speed = text; testing = false }
        }
    }

    // MARK: Sound

    private var sound: some View {
        VStack(alignment: .leading, spacing: 10) {
            MixerPanel(compact: true)
            HStack(spacing: 10) {
                Button { Mic.setMuted(!micMuted); micMuted = Mic.muted } label: {
                    Image(systemName: micMuted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 26, height: 26)
                        .background((micMuted ? Theme.warn : Theme.accent).opacity(0.9), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain).help(micMuted ? "Unmute the microphone" : "Mute the microphone for every app")
                VStack(alignment: .leading, spacing: 1) {
                    Text(Mic.name).font(.ui(size: 12, weight: .semibold)).lineLimit(1)
                    Text(micMuted ? "Muted for every app" : "On · click to mute it everywhere").font(.ui(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: Customize

    private var customize: some View {
        let on = Set(barItems.split(separator: ",").map(String.init))
        return VStack(alignment: .leading, spacing: 2) {
            Text("SHOW IN MENU BAR").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            Text("Pick what you want to see without opening anything.").font(.ui(size: 11)).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(BarItem.allCases) { item in
                let sel = on.contains(item.rawValue)
                Button { barItems = BarItem.toggle(item, in: barItems) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: sel ? "checkmark.square.fill" : "square").foregroundStyle(sel ? Theme.accent : Color.secondary)
                        Text(item.title).font(.ui(size: 12))
                        Spacer()
                        Text(MenuBarText.compose(monitor, items: item.rawValue, icon: true))
                            .font(.ui(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Toggle("Show the heart icon", isOn: $showIcon).font(.ui(size: 12)).padding(.top, 4)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button { GlobalSearch.shared.show() } label: { Image(systemName: "magnifyingglass") }
                .help("Smart Search (⌥Space)")
            SettingsLink { Image(systemName: "gearshape") }
                .help("Settings")
            Button("Open Triage") { openMain() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
