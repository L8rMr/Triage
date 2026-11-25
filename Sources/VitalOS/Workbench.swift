import SwiftUI
import AppKit

// MARK: - Themed segmented control (menu panel tabs, Settings pickers)

/// A tab strip that follows the theme. Labels always have a readable color, selected or not.
struct ThemeSegments<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String, symbol: String?)]
    /// Icons only; the label becomes the tooltip and the VoiceOver name.
    var iconOnly = false
    @Namespace private var ns

    init(selection: Binding<T>, options: [(T, String, String?)], iconOnly: Bool = false) {
        _selection = selection
        self.options = options.map { (value: $0.0, label: $0.1, symbol: $0.2) }
        self.iconOnly = iconOnly
    }
    init(selection: Binding<T>, options: [(T, String)]) {
        self.init(selection: selection, options: options.map { ($0.0, $0.1, nil) })
    }

    var body: some View {
        let chrome = ThemeStore.shared.current.chrome
        HStack(spacing: chrome == .win95 || chrome == .mac1bit ? 0 : 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.value == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { selection = o.value }
                } label: {
                    HStack(spacing: 5) {
                        if let s = o.symbol { Image(systemName: s).font(.system(size: iconOnly ? 14 : 11, weight: .semibold)) }
                        if !iconOnly || o.symbol == nil { Text(o.label).font(.ui(size: 12, weight: on ? .semibold : .medium)).lineLimit(1) }
                    }
                    .foregroundStyle(textColor(on, chrome))
                    .frame(maxWidth: .infinity, minHeight: 28.d)
                    .padding(.horizontal, 6)
                    .background { segmentBackground(on, chrome) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(o.label)
                .accessibilityLabel(o.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(trackPadding(chrome))
        .background { track(chrome) }
    }

    private func textColor(_ on: Bool, _ c: ChromeStyle) -> Color {
        let t = ThemeStore.shared.current
        switch c {
        case .win95, .xp, .win11, .aqua, .gnome: return Color(hex6: on ? 0x000000 : 0x3A3A3A)
        case .mac1bit: return on ? .white : .black
        case .terminal: return on ? t.bg : t.accent
        case .braun: return on ? .white : Color(hex6: 0x2B2B2B)
        case .vitalos: return on ? t.selectionText : Color(hex6: 0x9AA3B2)
        case .apple: return on ? .primary : .secondary
        }
    }

    private func trackPadding(_ c: ChromeStyle) -> CGFloat {
        switch c { case .win95, .mac1bit, .terminal: return 0; default: return 3 }
    }

    @ViewBuilder private func track(_ c: ChromeStyle) -> some View {
        let t = ThemeStore.shared.current
        switch c {
        case .win95: Color.clear
        case .mac1bit: Rectangle().stroke(.black, lineWidth: 1)
        case .terminal: Rectangle().strokeBorder(t.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .xp: RoundedRectangle(cornerRadius: 4).fill(Color(hex6: 0xECE9D8)).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex6: 0x919B9C)))
        case .aqua: Capsule().fill(LinearGradient(colors: [Color(hex6: 0xF4F4F4), Color(hex6: 0xD9D9D9)], startPoint: .top, endPoint: .bottom)).overlay(Capsule().stroke(Color(hex6: 0x9A9A9A)))
        case .braun: Capsule().fill(Color(hex6: 0xE3DFD5))
        case .vitalos: RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex6: 0x0B0D10)).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(hex6: 0x1E242C)))
        default: RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07))
        }
    }

    @ViewBuilder private func segmentBackground(_ on: Bool, _ c: ChromeStyle) -> some View {
        let t = ThemeStore.shared.current
        switch c {
        case .win95:
            Color(hex6: on ? 0xDFDFDF : 0xC0C0C0).modifier(Bevel(raised: !on))
        case .mac1bit:
            Rectangle().fill(on ? Color.black : .white).overlay(Rectangle().stroke(.black, lineWidth: 0.5))
        case .terminal:
            if on { Rectangle().fill(t.accent) }
        case .xp:
            if on {
                RoundedRectangle(cornerRadius: 3).fill(.white)
                    .overlay(alignment: .top) { Rectangle().fill(Color(hex6: 0xF7B852)).frame(height: 2) }
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(hex6: 0x919B9C)))
                    .matchedGeometryEffect(id: "seg", in: ns)
            }
        case .aqua:
            if on {
                Capsule().fill(LinearGradient(stops: [.init(color: Color(hex6: 0x9CCBFF), location: 0), .init(color: Color(hex6: 0x3A8EE6), location: 0.5), .init(color: Color(hex6: 0x1F6FD1), location: 0.51), .init(color: Color(hex6: 0x6AB4FF), location: 1)], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().stroke(Color(hex6: 0x1D5FB8)))
                    .matchedGeometryEffect(id: "seg", in: ns)
            }
        case .braun:
            if on { Capsule().fill(Color(hex6: 0xF25C05)).matchedGeometryEffect(id: "seg", in: ns) }
        case .win11:
            if on {
                RoundedRectangle(cornerRadius: 6).fill(.white).shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    .overlay(alignment: .bottom) { Capsule().fill(ThemeStore.shared.accent).frame(width: 16, height: 3).offset(y: -1) }
                    .matchedGeometryEffect(id: "seg", in: ns)
            }
        case .vitalos:
            if on {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex6: 0x1E2E27))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(hex6: 0x3DDC97).opacity(0.35)))
                    .matchedGeometryEffect(id: "seg", in: ns)
            }
        default:
            if on {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    .matchedGeometryEffect(id: "seg", in: ns)
            }
        }
    }
}

// MARK: - Shell pieces

/// Top strip: command bar, back/forward, help, and the heart-rate pill.
struct WorkbenchHeader: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    @ObservedObject var store = ThemeStore.shared

    var body: some View {
        let color = monitor.heart?.color ?? Theme.accent
        ZStack {
            DragArea()
            HStack(spacing: 12) {
                NavButtons()
                InlineSearchField(engine: model.search, placeholder: "Search files, or type what you want: \u{201C}free up space\u{201D}, \u{201C}100 usd to eur\u{201D}",
                                  size: 14, focusToken: model.searchFocus) { model.route = .search }
                    .padding(.horizontal, 12).frame(height: 36.d).frame(maxWidth: 620)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: min(10, store.current.radius + 4), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: min(10, store.current.radius + 4), style: .continuous).stroke(Theme.stroke))
                Spacer(minLength: 8)
                Button { model.route = .heart } label: {
                    HStack(spacing: 8) {
                        PulseLine(bpm: monitor.bpm, color: color).frame(width: 56, height: 18)
                        Text("\(Int(monitor.bpm.rounded())) bpm").font(.ui(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(color)
                        Text(monitor.heart?.status ?? "").font(.ui(size: 11)).foregroundStyle(color.opacity(0.85))
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(color.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(color.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .help("Your Mac's heart rate. Click for the full monitor.")
                HelpButton()
            }
            .padding(.leading, store.usesCustomChrome ? 14 : 84)
            .padding(.trailing, 16)
        }
        .frame(height: 52.d)
        .padding(.top, store.usesCustomChrome ? WindowChrome.height(store.current.chrome) : 0)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

struct RailItem: Identifiable {
    let id: String, label: String, symbol: String, route: Route
}

/// The column of big icons on the left.
struct WorkbenchRail: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    @Environment(\.openSettings) private var openSettings

    static let items: [RailItem] = [
        RailItem(id: "home", label: "Home", symbol: "house.fill", route: .home),
        RailItem(id: "heart", label: "Heart", symbol: "heart.fill", route: .heart),
        RailItem(id: "files", label: "Files", symbol: "folder.fill", route: .files),
        RailItem(id: "space", label: "Space", symbol: "internaldrive.fill", route: .clean),
        RailItem(id: "apps", label: "Apps", symbol: "square.grid.2x2.fill", route: .apps),
        RailItem(id: "mac", label: "Mac", symbol: "cpu.fill", route: .hardware),
        RailItem(id: "tools", label: "Tools", symbol: "wrench.and.screwdriver.fill", route: .utilities),
        RailItem(id: "pdf", label: "PDF", symbol: "doc.richtext.fill", route: .tool(.pdf)),
    ]

    private func isOn(_ r: Route) -> Bool {
        switch (model.route ?? .home, r) {
        case (.place, .files), (.files, .files): return true
        case (.tidy, .clean): return true
        case (.tool(.pdf), .tool(.pdf)): return true
        case (.tool(let x), .utilities): return x != .pdf
        case let (a, b): return a == b
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.items) { item in
                let on = isOn(item.route)
                Button { model.route = item.route } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 18))
                        Text(item.label).font(.ui(size: 10, weight: .medium))
                    }
                    .frame(width: 64.d, height: 56.d)
                    .foregroundStyle(on ? Theme.selectionText : Color.secondary)
                    .background(on ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: min(14, ThemeStore.shared.current.radius + 4), style: .continuous))
                    .overlay(alignment: .topTrailing) { badge(item) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.label)
                .contextMenu {
                    Button("Open \(item.label)") { model.route = item.route }
                    if item.id == "files" { Button("Open in Two Panes") { model.route = .files; if model.panes.count < 2 { model.toggleSplit() } } }
                }
            }
            Spacer()
            Button { openSettings() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 16)).frame(width: 64, height: 44).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Settings (⌘,)")
        }
        .padding(.vertical, 12)
        .frame(width: 84.d)
        .background(SidebarFill())
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
    }

    @ViewBuilder private func badge(_ item: RailItem) -> some View {
        if item.id == "heart", (monitor.heart?.stress ?? 0) >= 0.65 {
            Circle().fill(Theme.warn).frame(width: 9, height: 9).offset(x: -10, y: 8)
        } else if item.id == "space", monitor.snap.diskTotal > 0, Double(monitor.snap.diskFree) / Double(monitor.snap.diskTotal) < 0.12 {
            Circle().fill(Theme.heat).frame(width: 9, height: 9).offset(x: -10, y: 8)
        }
    }
}

// MARK: - Home

struct WorkbenchHome: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    @AppStorage("utilities.pinned") private var pinnedTools = "clean,tidy,clipboard,pdf"

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        return "\(part), \(NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName())"
    }

    var body: some View {
        let s = monitor.snap
        let heart = monitor.heart
        let color = heart?.color ?? Theme.accent
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day()).font(.ui(size: 13)).foregroundStyle(.secondary)
                    Text(greeting).font(.ui(size: 30, weight: .bold))
                    Text(heart.map { $0.stress >= 0.65 ? "Your Mac is \($0.status.lowercased()). \($0.diagnosis)" : "Your Mac is running easy. Nothing needs you right now." } ?? " ")
                        .font(.ui(size: 14)).foregroundStyle(.secondary).lineLimit(2)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    card("HEART", value: "\(Int(monitor.bpm.rounded())) bpm", color: color,
                         note: heart?.status ?? "", cta: (heart?.stress ?? 0) >= 0.45 ? "See why" : "Open") { model.route = .heart } extra: {
                        PulseLine(bpm: monitor.bpm, color: color).frame(height: 30)
                    }
                    let free = s.diskFree, total = max(s.diskTotal, 1)
                    card("STORAGE", value: Fmt.bytes(free), color: Double(free) / Double(total) < 0.12 ? Theme.heat : Theme.good,
                         note: "free of \(Fmt.bytes(total))", cta: "Free up space") { model.route = .clean } extra: {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.stroke.opacity(0.6))
                                Capsule().fill(Double(free) / Double(total) < 0.12 ? Theme.heat : Theme.accent)
                                    .frame(width: g.size.width * (1 - Double(free) / Double(total)))
                            }
                        }
                        .frame(height: 8)
                    }
                    card("MEMORY", value: Fmt.bytes(s.memUsed), color: s.memFraction > 0.85 ? Theme.warn : Theme.mem,
                         note: "of \(Fmt.bytes(s.memTotal)) · swap \(Fmt.bytes(s.swapUsed))", cta: "See apps") { model.route = .apps } extra: {
                        Sparkline(values: monitor.memHistory, maxValue: 100, color: Theme.mem).frame(height: 30)
                    }
                }

                if let h = heart {
                    let tips = Coach.suggestions(h, s, apps: monitor.apps)
                    if !tips.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SUGGESTED RIGHT NOW").font(.ui(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                            ForEach(tips.prefix(4)) { t in
                                HStack(spacing: 14) {
                                    Image(systemName: t.symbol).font(.system(size: 15)).foregroundStyle(color).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.title).font(.ui(size: 14, weight: .semibold))
                                        Text(t.detail).font(.ui(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    if let label = t.actionLabel {
                                        Button(label) { run(t.action) }.controlSize(.large)
                                    }
                                }
                                .padding(12.d)
                                .glass(14)
                                .contextMenu {
                                    if let label = t.actionLabel { Button(label) { run(t.action) } }
                                    Button("Open Heart") { model.route = .heart }
                                }
                            }
                        }
                        .frame(maxWidth: 900, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("JUMP TO").font(.ui(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(pinnedTools.split(separator: ",").compactMap { ToolID(rawValue: String($0)) }) { t in
                            Button { model.route = t.route } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: t.symbol).foregroundStyle(Theme.accent).frame(width: 20)
                                    Text(t.title).font(.ui(size: 13)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).frame(height: 40.d).glass(10).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open \(t.title)") { model.route = t.route }
                                Button("Unpin from Home") { pinnedTools = pinnedTools.split(separator: ",").filter { $0 != t.rawValue }.joined(separator: ",") }
                            }
                        }
                        ForEach(Places.favorites + model.pinned, id: \.path) { u in
                            Button { model.route = .files; model.active.go(u) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: Places.symbol(u)).foregroundStyle(Theme.accent).frame(width: 20)
                                    Text(Places.name(u)).font(.ui(size: 13)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).frame(height: 40.d).glass(10).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open") { model.route = .files; model.active.go(u) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                                Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.path, forType: .string) }
                            }
                        }
                    }
                }
            }
            .padding(28.d)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func run(_ a: Suggestion.Action) {
        switch a {
        case .quit(let app): monitor.quit(app); UndoCenter.shared.show("Quit \(app.name)")
        case .route(let r): model.route = r
        case .openSettings(let u): if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case .none: break
        }
    }

    private func card<Extra: View>(_ label: String, value: String, color: Color, note: String, cta: String,
                                   action: @escaping () -> Void, @ViewBuilder extra: () -> Extra) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.ui(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                Text(value).font(.ui(size: 30, weight: .semibold, design: .monospaced)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
                extra()
                Text(note).font(.ui(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text(cta + " →").font(.ui(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 170.d, alignment: .topLeading)
            .glass(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Files workspace with locations sidebar

struct SavedServer: Codable, Hashable, Identifiable {
    var id: String { url }
    let name: String
    let url: String
    let proto: String
}

final class Locations: ObservableObject {
    static let shared = Locations()
    @Published private(set) var volumes: [URL] = []
    @Published private(set) var network: [URL] = []
    @Published private(set) var cloud: [URL] = []
    @Published var servers: [SavedServer] = (try? JSONDecoder().decode([SavedServer].self, from: UserDefaults.standard.data(forKey: "servers") ?? Data())) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: "servers") }
    }

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
    }

    func refresh() {
        Work.quick.async {
            let vols = Places.volumes
            let local = vols.filter { (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true }
            let remote = vols.filter { (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false }
            let cloud = Places.cloudRoots
            DispatchQueue.main.async { self.volumes = local; self.network = remote; self.cloud = cloud }
        }
    }

    func free(_ u: URL) -> String? {
        guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return nil }
        return Fmt.bytes(v) + " free"
    }

    func eject(_ u: URL) {
        Work.quick.async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: u)
                DispatchQueue.main.async { UndoCenter.shared.show("\(u.lastPathComponent) is safe to unplug"); self.refresh() }
            } catch {
                DispatchQueue.main.async { UndoCenter.shared.show("Couldn’t eject \(u.lastPathComponent): something on it is still open") }
            }
        }
    }

    /// macOS mounts SMB, AFP, WebDAV and FTP itself and asks for the password in its own sheet (saved to Keychain if you like).
    func connect(_ s: SavedServer) {
        guard let url = URL(string: s.url) else { return }
        if !servers.contains(s) { servers.append(s) }
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
    }
}

struct FilesWorkspace: View {
    var body: some View {
        HStack(spacing: 0) {
            LocationsSidebar().frame(width: 232.d)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            BrowserView()
        }
    }
}

struct LocationsSidebar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var places = Locations.shared
    @State private var connecting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                section("Favorites")
                ForEach(Places.favorites, id: \.path) { row($0) }
                ForEach(model.pinned, id: \.path) { u in
                    row(u).contextMenu {
                        common(u)
                        Divider()
                        Button("Remove from Sidebar") { model.unpin(u) }
                    }
                }
                if !places.cloud.isEmpty {
                    section("iCloud & Cloud")
                    ForEach(places.cloud, id: \.path) { row($0) }
                }
                section("Locations")
                row(URL(fileURLWithPath: "/"), note: places.free(URL(fileURLWithPath: "/")))
                ForEach(places.volumes, id: \.path) { u in
                    row(u, note: places.free(u), eject: { places.eject(u) }).contextMenu {
                        common(u)
                        Divider()
                        Button("Eject \(u.lastPathComponent)") { places.eject(u) }
                    }
                }
                section("Network")
                ForEach(places.network, id: \.path) { u in
                    row(u, symbol: "server.rack", dot: Theme.good, eject: { places.eject(u) }).contextMenu {
                        common(u)
                        Divider()
                        Button("Disconnect") { places.eject(u) }
                    }
                }
                ForEach(places.servers.filter { s in !places.network.contains { $0.lastPathComponent.lowercased() == (URL(string: s.url)?.lastPathComponent.lowercased() ?? "") } }) { s in
                    Button { places.connect(s) } label: {
                        label(s.name, symbol: "server.rack", note: s.proto, dot: Theme.stroke, on: false)
                    }
                    .buttonStyle(.plain)
                    .help("Click to connect to \(s.url)")
                    .contextMenu {
                        Button("Connect") { places.connect(s) }
                        Button("Copy Address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.url, forType: .string) }
                        Divider()
                        Button("Forget This Server") { places.servers.removeAll { $0 == s } }
                    }
                }

                VStack(spacing: 6) {
                    Button { model.chooseFolders() } label: { addLabel("Add a folder to the sidebar") }.buttonStyle(.plain)
                    Button { connecting = true } label: { addLabel("Connect to a server") }.buttonStyle(.plain)
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
        }
        .background(SidebarFill())
        .sheet(isPresented: $connecting) { ConnectServerSheet().themedPanel() }
    }

    private func section(_ t: String) -> some View {
        Text(t.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
    }

    private func isCurrent(_ u: URL) -> Bool {
        if case .files? = model.route {} else if case .place? = model.route {} else { return false }
        return model.active.url.standardizedFileURL.path == u.standardizedFileURL.path
    }

    private func row(_ u: URL, symbol: String? = nil, note: String? = nil, dot: Color? = nil, eject: (() -> Void)? = nil) -> some View {
        Button { model.route = .files; model.active.go(u) } label: {
            label(Places.name(u), symbol: symbol ?? Places.symbol(u), note: note, dot: dot, on: isCurrent(u), eject: eject)
        }
        .buttonStyle(.plain)
        .contextMenu { common(u) }
        .dropDestination(for: URL.self) { urls, _ in model.drop(urls, into: u); return true }
    }

    @ViewBuilder private func common(_ u: URL) -> some View {
        Button("Open") { model.route = .files; model.active.go(u) }
        Button("Open in Second Pane") {
            model.route = .files
            if model.panes.count < 2 { model.toggleSplit() }
            model.panes.last?.go(u)
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.path, forType: .string) }
        if !Places.favorites.contains(u) && !model.pinned.contains(u) { Button("Add to Sidebar") { model.pin(u) } }
    }

    private func label(_ name: String, symbol: String, note: String?, dot: Color?, on: Bool, eject: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(on ? Theme.selectionText : Theme.accent).frame(width: 18)
            Text(name).font(.ui(size: 13, weight: on ? .semibold : .regular)).lineLimit(1).foregroundStyle(on ? Theme.selectionText : Color.primary)
            Spacer(minLength: 4)
            if let note { Text(note).font(.ui(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let eject {
                Button(action: eject) { Image(systemName: "eject.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Eject")
            }
        }
        .padding(.horizontal, 10).frame(height: 32.d)
        .background(on ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: min(8, ThemeStore.shared.current.radius), style: .continuous))
        .contentShape(Rectangle())
    }

    private func addLabel(_ t: String) -> some View {
        HStack { Image(systemName: "plus"); Text(t).font(.ui(size: 12, weight: .semibold)); Spacer() }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 34)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
    }
}

struct ConnectServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var proto = "SMB"
    @State private var address = ""
    @State private var name = ""

    private let protos: [(String, String, String, String)] = [
        ("SMB", "smb://", "Windows PCs, NAS boxes, shared Macs", "192.168.1.20/Share"),
        ("WebDAV", "https://", "Nextcloud, Synology WebDAV, many web drives", "cloud.example.com/remote.php/dav"),
        ("FTP", "ftp://", "Older file servers (macOS mounts FTP read-only)", "files.example.com"),
        ("AFP", "afp://", "Older Macs and Time Capsules", "192.168.1.30"),
        ("SFTP", "sftp://", "Linux servers over SSH", "user@server.com"),
    ]

    var body: some View {
        let p = protos.first { $0.0 == proto } ?? protos[0]
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to a server").font(.ui(size: 18, weight: .bold))
            ThemeSegments(selection: $proto, options: protos.map { ($0.0, $0.0) })
            Text(p.2).font(.ui(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(p.1).font(.ui(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                TextField(p.3, text: $address).textFieldStyle(.roundedBorder)
            }
            TextField("Name in the sidebar (optional)", text: $name).textFieldStyle(.roundedBorder)
            if proto == "SFTP" {
                Text("macOS can't mount SFTP by itself. Install macFUSE and SSHFS, then mount the server to a folder and add that folder to the sidebar.")
                    .font(.ui(size: 11)).foregroundStyle(Theme.heat).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("macOS asks for your username and password and can save them in your Keychain. The server then shows up under Network.")
                    .font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    let clean = address.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^[a-z]+://"#, with: "", options: .regularExpression)
                    let label = name.isEmpty ? (clean.split(separator: "/").first.map(String.init) ?? clean) : name
                    Locations.shared.connect(SavedServer(name: label, url: p.1 + clean, proto: proto))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || proto == "SFTP")
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}


// MARK: - Apps: what's running, and what's installed

struct AppsHub: View {
    @AppStorage("apps.tab") private var tab = "running"
    var body: some View {
        VStack(spacing: 0) {
            ThemeSegments(selection: $tab, options: [("running", "Running now", "bolt.fill"), ("installed", "Installed · uninstall", "trash")])
                .frame(width: 380)
                .padding(.top, 16)
            if tab == "installed" { ToolID.uninstaller.page } else { AppsView() }
        }
    }
}
