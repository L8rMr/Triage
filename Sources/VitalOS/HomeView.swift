import SwiftUI
import AppKit

enum HomeData {
    static func recentFiles() -> [FileItem] {
        let dirs = ["Desktop", "Documents", "Downloads"].map { Places.home.appendingPathComponent($0) }
        let all = dirs.flatMap { FS.list($0, showHidden: false) }.filter { !$0.isDir }
        return Array(all.sorted { $0.modified > $1.modified }.prefix(12))
    }

    static func downloads() -> [FileItem] {
        Array(FS.list(Places.downloads, showHidden: false).sorted { $0.added > $1.added }.prefix(5))
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    @ObservedObject private var search: SmartSearch

    init() { search = HomeView.engine }
    static let engine = SmartSearch()
    @State private var recents: [FileItem] = []
    @State private var downloads: [FileItem] = []

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        return "\(part), \(first)"
    }

    private var mood: String {
        if let h = monitor.heart { return "\(Int(monitor.bpm.rounded())) bpm, \(h.status.lowercased()). \(h.diagnosis)" }
        let c = monitor.snap.cpu, m = monitor.snap.memFraction
        if c > 80 { return "Your Mac is sprinting. \(monitor.topByCPU.first?.name ?? "Something") is doing most of the running." }
        if m > 0.85 { return "Memory is tight. A few apps could stand to be closed." }
        if monitor.snap.diskUsedFraction > 0.9 { return "The disk is nearly full. Free Up Space has suggestions." }
        return "Everything's calm. Resting heart rate."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: greeting, subtitle: mood)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    ClockWidget()
                    VitalsWidget().onTapGesture { model.route = .apps }
                    DiskWidget().onTapGesture { model.route = .clean }
                    TopAppsWidget().onTapGesture { model.route = .apps }
                    DownloadsWidget(items: downloads)
                    PinnedWidget()
                }

                if !recents.isEmpty {
                    Text("Recent").font(.ui(size: 15, weight: .semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(recents) { item in
                                FileCard(item: item, selected: false)
                                    .onTapGesture(count: 2) { model.open(item.url) }
                                    .contextMenu {
                                        Button("Open") { model.open(item.url) }
                                        Button("Show in Browser") { model.open(item.url.deletingLastPathComponent()) }
                                    }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .padding(.top, 8)
        }
        .task {
            let r = await Work.run { HomeData.recentFiles() }
            let d = await Work.run { HomeData.downloads() }
            recents = r
            downloads = d
        }
    }
}

struct Widget<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.ui(size: 10, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.secondary)
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 176, maxHeight: 176, alignment: .topLeading)
        .glass()
        .contentShape(Rectangle())
    }
}

struct ClockWidget: View {
    private let zones: [(String, String)] = [("London", "Europe/London"), ("Moscow", "Europe/Moscow"), ("Tokyo", "Asia/Tokyo")]

    private static func time(_ d: Date, _ tz: String?, _ fmt: String) -> String {
        let f = DateFormatter()
        if let tz { f.timeZone = TimeZone(identifier: tz) }
        f.dateFormat = fmt
        return f.string(from: d)
    }

    var body: some View {
        Widget(title: "Today", symbol: "clock") {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.time(ctx.date, nil, "h:mm")).font(.ui(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(Self.time(ctx.date, nil, "ss")).font(.ui(size: 16, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(Self.time(ctx.date, nil, "EEEE, MMMM d")).font(.ui(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        ForEach(zones.indices, id: \.self) { i in
                            let z = zones[i]
                            VStack(alignment: .leading, spacing: 1) {
                                Text(z.0).font(.ui(size: 10)).foregroundStyle(.secondary)
                                Text(Self.time(ctx.date, z.1, "h:mm a")).font(.ui(size: 12, weight: .medium)).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }
}

struct VitalsWidget: View {
    @EnvironmentObject var monitor: SystemMonitor
    var body: some View {
        Widget(title: "Vitals", symbol: "waveform.path.ecg") {
            HStack(spacing: 14) {
                mini("CPU", Fmt.pct(monitor.snap.cpu), monitor.cpuHistory, Theme.cpu)
                mini("Memory", Fmt.pct(monitor.snap.memFraction * 100), monitor.memHistory, Theme.mem)
            }
        }
    }

    private func mini(_ t: String, _ v: String, _ h: [Double], _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.ui(size: 11)).foregroundStyle(.secondary)
            Text(v).font(.ui(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Sparkline(values: h, maxValue: 100, color: c).frame(height: 54)
        }
    }
}

struct DiskWidget: View {
    @EnvironmentObject var monitor: SystemMonitor
    var body: some View {
        Widget(title: "Disk Space", symbol: "internaldrive") {
            HStack(spacing: 18) {
                ZStack {
                    Ring(value: monitor.snap.diskUsedFraction, color: Theme.load(monitor.snap.diskUsedFraction * 100), lineWidth: 10)
                    Text(Fmt.pct(monitor.snap.diskUsedFraction * 100)).font(.ui(size: 15, weight: .semibold, design: .rounded))
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Fmt.bytes(monitor.snap.diskFree)).font(.ui(size: 22, weight: .semibold, design: .rounded))
                    Text("free of \(Fmt.bytes(monitor.snap.diskTotal))").font(.ui(size: 12)).foregroundStyle(.secondary)
                    Text("Free Up Space →").font(.ui(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

struct TopAppsWidget: View {
    @EnvironmentObject var monitor: SystemMonitor
    var body: some View {
        Widget(title: "Working hardest", symbol: "flame") {
            VStack(spacing: 7) {
                ForEach(Array(monitor.topByCPU.prefix(4))) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: Icons.icon(for: app)).resizable().frame(width: 18, height: 18)
                        Text(app.name).font(.ui(size: 12)).lineLimit(1)
                        Spacer()
                        Text(Fmt.pct(app.cpu)).font(.ui(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(Theme.load(app.cpu))
                    }
                }
            }
        }
    }
}

struct DownloadsWidget: View {
    @EnvironmentObject var model: AppModel
    let items: [FileItem]
    var body: some View {
        Widget(title: "Downloads Inbox", symbol: "arrow.down.circle") {
            VStack(spacing: 6) {
                if items.isEmpty {
                    Text("Nothing new. Inbox zero.").font(.ui(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(items) { item in
                    Button { model.open(item.url) } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 16, height: 16)
                            Text(item.name).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.added, format: .relative(presentation: .numeric)).font(.ui(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Spacer()
                    Button("Tidy →") { model.route = .tidy }.buttonStyle(.plain).font(.ui(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

struct PinnedWidget: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Widget(title: "Pinned", symbol: "pin") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array((model.pinned + Places.favorites).prefix(6)), id: \.self) { u in
                    Button { model.route = .place(u) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Places.symbol(u)).foregroundStyle(Theme.cpu).frame(width: 16)
                            Text(Places.name(u)).font(.ui(size: 12)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
