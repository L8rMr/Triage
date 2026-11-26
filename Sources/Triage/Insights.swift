import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

// MARK: - Screen time per app (which app is in front, and for how long)

/// Credits the frontmost app with the seconds it spends in front. Tiny: one notification and a 30 s tick.
final class AppTime: ObservableObject {
    static let shared = AppTime()
    struct Day: Codable { var date: String; var seconds: [String: Double]; var names: [String: String] }
    @Published private(set) var days: [Day] = []
    private var current: (id: String, name: String, since: Date)?
    private var timer: Timer?
    private var started = false
    private let file = Shell.supportDir.appendingPathComponent("apptime.json")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    func start() {
        guard !started else { return }
        started = true
        if let d = try? Data(contentsOf: file), let v = try? JSONDecoder().decode([Day].self, from: d) { days = v }
        if let app = NSWorkspace.shared.frontmostApplication { begin(app) }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.flush(); self?.begin(app)
        }
        // the screen sleeping or locking isn't screen time
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.flush(); self?.current = nil }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let app = NSWorkspace.shared.frontmostApplication { self?.begin(app) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, let c = self.current else { return }
            self.flush(); self.current = (c.id, c.name, Date())
        }
        timer?.tolerance = 5
    }

    private func begin(_ app: NSRunningApplication) {
        if ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"].contains(app.bundleIdentifier ?? "") { current = nil; return }
        current = (app.bundleIdentifier ?? app.localizedName ?? "?", app.localizedName ?? "App", Date())
    }

    private func flush() {
        guard let c = current else { return }
        let secs = min(Date().timeIntervalSince(c.since), 120)   // never credit a long gap (sleep the observers missed)
        guard secs > 0.5 else { return }
        let key = Self.fmt.string(from: Date())
        if days.last?.date != key { days.append(Day(date: key, seconds: [:], names: [:])); if days.count > 30 { days.removeFirst(days.count - 30) } }
        days[days.count - 1].seconds[c.id, default: 0] += secs
        days[days.count - 1].names[c.id] = c.name
        current = (c.id, c.name, Date())
        if let d = try? JSONEncoder().encode(days) { try? d.write(to: file, options: .atomic) }
    }

    struct AppSpan: Identifiable { let id: String; let name: String; let secs: Double }
    struct DaySpan: Identifiable { let label: String; let secs: Double; var id: String { label } }

    var today: Day? { days.last { $0.date == Self.fmt.string(from: Date()) } }
    func top(_ day: Day?, _ n: Int = 5) -> [AppSpan] {
        guard let day else { return [] }
        return day.seconds.sorted { $0.value > $1.value }.prefix(n).map { AppSpan(id: $0.key, name: day.names[$0.key] ?? $0.key, secs: $0.value) }
    }
    /// Total front-of-screen time for each of the last 7 days, oldest first.
    var week: [DaySpan] {
        let cal = Calendar.current
        return (0..<7).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: Date())!
            let k = Self.fmt.string(from: d)
            let total = days.first { $0.date == k }?.seconds.values.reduce(0, +) ?? 0
            return DaySpan(label: back == 0 ? "Today" : d.formatted(.dateTime.weekday(.abbreviated)), secs: total)
        }
    }
}

// MARK: - Facts about the machine

enum MacFacts {
    /// The real boot time (the system uptime clock stops while the Mac sleeps, so it reads far too short).
    static var bootDate: Date {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 { return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)) }
        return Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
    }
    static var uptime: TimeInterval { Date().timeIntervalSince(bootDate) }
    /// When this Mac was first set up: the setup assistant leaves a marker file behind.
    static let setupDate: Date? = {
        for p in ["/var/db/.AppleSetupDone", "/private/var/db/.AppleSetupDone"] {
            if let a = try? FileManager.default.attributesOfItem(atPath: p), let d = (a[.creationDate] ?? a[.modificationDate]) as? Date { return d }
        }
        return nil
    }()
    static let chip = SystemStats.sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"
    static let model = SystemStats.sysctlString("hw.model") ?? "Mac"
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }
    static func span(_ seconds: TimeInterval) -> String {
        let d = Int(seconds / 86_400), h = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600), m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    static func age(since d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d, to: Date())
        let y = c.year ?? 0, mo = c.month ?? 0
        switch (y, mo) {
        case (0, 0): return "Brand new"
        case (0, _): return "\(mo) month\(mo == 1 ? "" : "s")"
        case (_, 0): return "\(y) year\(y == 1 ? "" : "s")"
        default: return "\(y)y \(mo)m"
        }
    }
    /// The operating system and its own background processes: never ranked as an "app".
    static func isSystem(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["macos", "kernel_task", "windowserver", "launchd", "mds", "mds_stores", "mdworker", "backupd", "softwareupdated",
                "spotlight", "system", "coreaudiod", "bluetoothd", "photoanalysisd", "trustd", "cloudd", "bird"].contains(n)
    }

    static func icon(for id: String) -> NSImage {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: u.path) }
        return NSWorkspace.shared.icon(for: .application)
    }
    static func icon(named name: String) -> NSImage {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let i = app.icon { return i }
        return NSWorkspace.shared.icon(for: .application)
    }
}

// MARK: - The dashboard on Home

struct GlanceDashboard: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: AppModel
    @ObservedObject private var time = AppTime.shared
    @ObservedObject private var log = HealthLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AT A GLANCE").font(.ui(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                screenTime
                heartDay
                upTime
                yourMac
                hungriest
                if let b = monitor.snap.battery, b.cycles != nil || b.health != nil { battery(b) }
            }
        }
    }

    // Screen time today: total + top apps with their icons
    private var screenTime: some View {
        let top = time.top(time.today)
        let total = time.today?.seconds.values.reduce(0, +) ?? 0
        let maxSecs = max(top.first?.secs ?? 1, 1)
        let tint = Color(hex6: 0x7C5CFF)
        return Tile(title: "SCREEN TIME TODAY", symbol: "hourglass", tint: tint) {
            Text(total < 60 ? "Just started" : MacFacts.span(total)).font(.ui(size: 28, weight: .bold, design: .rounded))
            if top.isEmpty {
                Text("Counting the apps you use from now on. Check back in a bit.").font(.ui(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(top) { a in
                HStack(spacing: 8) {
                    Image(nsImage: MacFacts.icon(for: a.id)).resizable().frame(width: 18, height: 18)
                    Text(a.name).font(.ui(size: 12)).lineLimit(1).frame(width: 96, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(LinearGradient(colors: [tint, tint.opacity(0.45)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, g.size.width * a.secs / maxSecs))
                    }
                    .frame(height: 8)
                    Text(MacFacts.span(a.secs)).font(.ui(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
            let week = time.week
            if week.contains(where: { $0.secs > 0 }) {
                Chart(week) { d in
                    BarMark(x: .value("Day", d.label), y: .value("Hours", d.secs / 3600))
                        .foregroundStyle(LinearGradient(colors: [tint, tint.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                        .cornerRadius(4)
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.ui(size: 9)) } }
                .frame(height: 54)
            }
        }
    }

    // The heart over the last 24 hours, from the health log
    private var heartDay: some View {
        let since = Date().addingTimeInterval(-86_400)
        let pts = log.samples.filter { $0.t >= since }
        let color = monitor.heart?.color ?? Theme.accent
        let avg = pts.isEmpty ? monitor.bpm : pts.map(\.bpm).reduce(0, +) / Double(pts.count)
        let peak = pts.max { $0.bpm < $1.bpm }
        let calm = pts.isEmpty ? 0 : Double(pts.filter { $0.bpm < 80 }.count) / Double(pts.count)
        return Tile(title: "HEART, LAST 24 HOURS", symbol: "waveform.path.ecg", tint: color, action: { model.route = .heart }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(avg.rounded()))").font(.ui(size: 28, weight: .bold, design: .rounded))
                Text("bpm average").font(.ui(size: 12)).foregroundStyle(.secondary)
            }
            if pts.count > 2 {
                Chart(pts) { p in
                    AreaMark(x: .value("Time", p.t), y: .value("bpm", p.bpm))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.t), y: .value("bpm", p.bpm))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()).font(.ui(size: 9)) } }
                .frame(height: 70)
            } else {
                PulseLine(bpm: monitor.bpm, color: color).frame(height: 40)
            }
            HStack(spacing: 14) {
                stat("Calm", "\(Int(calm * 100))%")
                if let peak { stat("Peak", "\(Int(peak.bpm)) at \(peak.t.formatted(date: .omitted, time: .shortened))") }
            }
        }
    }

    // How long since the last restart, and a fun count of heartbeats
    private var upTime: some View {
        let up = MacFacts.uptime
        let beats = Int(up / 60 * max(monitor.bpm, 40))
        let days = up / 86_400
        let tint = days > 7 ? Theme.heat : Theme.good
        return Tile(title: "UP AND RUNNING", symbol: "power", tint: tint) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(tint.opacity(0.15), lineWidth: 8)
                    Circle().trim(from: 0, to: min(1, days / 14)).stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                    Image(systemName: "power").font(.system(size: 16, weight: .bold)).foregroundStyle(tint)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MacFacts.span(up)).font(.ui(size: 28, weight: .bold, design: .rounded))
                    Text("since \(MacFacts.bootDate.formatted(.dateTime.month(.abbreviated).day().hour().minute()))").font(.ui(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("≈ \(beats.formatted()) heartbeats since then").font(.ui(size: 12, weight: .medium)).foregroundStyle(tint)
            Text(days > 7 ? "A restart would clear out swap and stuck background work." : "Fresh enough. No restart needed.")
                .font(.ui(size: 11)).foregroundStyle(.secondary)
        }
    }

    // The machine itself: age, chip, memory, macOS
    private var yourMac: some View {
        let tint = Color(hex6: 0x2FA8FF)
        let s = monitor.snap
        return Tile(title: "YOUR MAC", symbol: "laptopcomputer", tint: tint) {
            if let d = MacFacts.setupDate {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(MacFacts.age(since: d)).font(.ui(size: 28, weight: .bold, design: .rounded))
                    Text("old").font(.ui(size: 12)).foregroundStyle(.secondary)
                }
                Text("Set up \(d.formatted(date: .long, time: .omitted))").font(.ui(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(MacFacts.model).font(.ui(size: 22, weight: .bold, design: .rounded))
            }
            VStack(alignment: .leading, spacing: 5) {
                fact("cpu", MacFacts.chip)
                fact("memorychip", "\(Fmt.bytes(s.memTotal)) memory · \(ProcessInfo.processInfo.activeProcessorCount) cores")
                fact("internaldrive", "\(Fmt.bytes(s.diskTotal)) disk · \(Int(s.diskUsedFraction * 100))% used")
                fact("apple.logo", "\(MacFacts.macOS) · \(MacFacts.model)")
            }
            .padding(.top, 2)
        }
    }

    // Which app most often had the Mac working hardest this week
    private var hungriest: some View {
        let since = Date().addingTimeInterval(-7 * 86_400)
        // macOS is the operating system, not an app: count its share separately instead of ranking it
        var counts: [String: Int] = [:]
        var system = 0, all = 0
        for s in log.samples where s.t >= since {
            guard let t = s.top, !t.isEmpty else { continue }
            all += 1
            if MacFacts.isSystem(t) { system += 1 } else { counts[t, default: 0] += 1 }
        }
        let ranked = counts.sorted { $0.value > $1.value }.prefix(4).map { Hungry(name: $0.key, count: $0.value) }
        let total = max(all, 1)
        let tint = Theme.heat
        return Tile(title: "HUNGRIEST THIS WEEK", symbol: "flame.fill", tint: tint, action: { model.route = .apps }) {
            if let first = ranked.first {
                HStack(spacing: 10) {
                    Image(nsImage: MacFacts.icon(named: first.name)).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(first.name).font(.ui(size: 20, weight: .bold, design: .rounded)).lineLimit(1)
                        Text("busiest app \(Int(Double(first.count) / Double(total) * 100))% of the time").font(.ui(size: 12)).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(ranked.dropFirst())) { h in
                    HStack(spacing: 8) {
                        Image(nsImage: MacFacts.icon(named: h.name)).resizable().frame(width: 16, height: 16)
                        Text(h.name).font(.ui(size: 12)).lineLimit(1)
                        Spacer()
                        Text("\(Int(Double(h.count) / Double(total) * 100))%").font(.ui(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Nothing yet").font(.ui(size: 20, weight: .bold, design: .rounded))
                Text("Triage notes which app works your Mac hardest as the week goes on.").font(.ui(size: 12)).foregroundStyle(.secondary)
            }
            if system > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "apple.logo").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("macOS itself (indexing, updates, backups) led \(Int(Double(system) / Double(total) * 100))% of the time")
                        .font(.ui(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.top, 2)
            }
        }
    }

    private struct Hungry: Identifiable { let name: String; let count: Int; var id: String { name } }

    private func battery(_ b: BatteryInfo) -> some View {
        let health = b.health ?? 1
        let tint = health > 0.85 ? Theme.good : health > 0.75 ? Theme.net : Theme.heat
        return Tile(title: "BATTERY", symbol: "battery.100.bolt", tint: tint) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(health * 100))%").font(.ui(size: 28, weight: .bold, design: .rounded))
                Text("of its original capacity").font(.ui(size: 12)).foregroundStyle(.secondary)
            }
            if let c = b.cycles {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.15))
                        Capsule().fill(tint).frame(width: g.size.width * min(1, Double(c) / 1000))
                    }
                }
                .frame(height: 8)
                Text("\(c) of about 1,000 charge cycles").font(.ui(size: 12)).foregroundStyle(.secondary)
            }
            Text("\(Int(b.percent))% now · \(b.charging ? "charging" : b.onAC ? "plugged in" : "on battery")").font(.ui(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k.uppercased()).font(.ui(size: 9, weight: .semibold)).kerning(0.5).foregroundStyle(.tertiary)
            Text(v).font(.ui(size: 12, weight: .medium))
        }
    }
    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.ui(size: 12)).lineLimit(1)
        }
    }
}

/// A dashboard card: soft tinted glow in the corner, a small labelled header, then the content.
struct Tile<Content: View>: View {
    let title: String, symbol: String, tint: Color
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 22, height: 22).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title).font(.ui(size: 10, weight: .semibold)).kerning(0.7).foregroundStyle(.secondary)
                Spacer()
                if action != nil { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(alignment: .topTrailing) {
            Circle().fill(tint.opacity(0.16)).frame(width: 180, height: 180).blur(radius: 50).offset(x: 50, y: -60).allowsHitTesting(false)
        }
        .glass(18)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}
