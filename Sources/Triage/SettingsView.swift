import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case appearance = "Appearance", general = "General", menubar = "Menu Bar", heart = "Heart & Readings", iphone = "iPhone"
        case files = "Files", privacy = "Privacy & Permissions", shortcuts = "Shortcuts", advanced = "Advanced"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .appearance: return "paintpalette.fill"
            case .general: return "gearshape.fill"
            case .menubar: return "menubar.rectangle"
            case .heart: return "heart.fill"
            case .iphone: return "iphone.gen3"
            case .files: return "folder.fill"
            case .privacy: return "hand.raised.fill"
            case .shortcuts: return "command"
            case .advanced: return "wrench.and.screwdriver.fill"
            }
        }
        var tint: Color {
            switch self {
            case .appearance: return Color(hex6: 0x5E5CE6)
            case .general: return Color(hex6: 0x8E8E93)
            case .menubar: return Color(hex6: 0x0A84FF)
            case .heart: return Color(hex6: 0xFF375F)
            case .iphone: return Color(hex6: 0x30D158)
            case .files: return Color(hex6: 0x64D2FF)
            case .privacy: return Color(hex6: 0x636366)
            case .shortcuts: return Color(hex6: 0xAC8E68)
            case .advanced: return Color(hex6: 0x48484A)
            }
        }
    }

    @AppStorage("settings.section") private var section = Section.appearance.rawValue

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { s in
                    let on = section == s.rawValue
                    Button { section = s.rawValue } label: {
                        HStack(spacing: 10) {
                            Image(systemName: s.symbol).font(.system(size: 12)).foregroundStyle(.white)
                                .frame(width: 24, height: 24).background(s.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(s.rawValue).font(.ui(size: 13, weight: on ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 8).frame(height: 34)
                        .background(on ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(on ? Theme.selectionText : Color.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 220.d)
            .background(Theme.sidebar)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    page
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 860.d, height: 620.d)
    }

    @ViewBuilder private var page: some View {
        switch Section(rawValue: section) ?? .appearance {
        case .appearance: AppearancePage()
        case .general: GeneralPage()
        case .menubar: MenuBarPage()
        case .heart: HeartPage()
        case .iphone: IPhonePage()
        case .files: FilesPage()
        case .privacy: PermissionsView(firstRun: false)
        case .shortcuts: ShortcutsPage()
        case .advanced: AdvancedPage()
        }
    }
}

// MARK: - Building blocks

private struct PageHeader: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(size: 24, weight: .bold))
            Text(subtitle).font(.ui(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct Group_<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(12)
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(size: 13))
                if let hint { Text(hint).font(.ui(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14).frame(minHeight: 46)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke.opacity(0.5)).frame(height: 0.5) }
    }
}

// MARK: - Appearance

private struct AppearancePage: View {
    @ObservedObject var store = ThemeStore.shared
    private let accents: [String] = ["", "0A84FF", "BF5AF2", "FF375F", "FF9F0A", "30D158", "64D2FF"]

    var body: some View {
        PageHeader(title: "Appearance", subtitle: "Each theme changes colors, type, cards, buttons and the window frame. Your files and settings stay the same.")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            ForEach(AppTheme.all) { t in
                Button { store.themeID = t.id; store.accentHex = "" } label: { ThemeTile(theme: t, selected: store.themeID == t.id) }
                    .buttonStyle(.plain)
                    .help(t.about)
            }
        }
        Text(store.current.about).font(.ui(size: 12)).foregroundStyle(.secondary)

        Group_(title: "Look") {
            Row(title: "Mode", hint: store.current.scheme == nil ? "Follows your Mac, or pick one" : "This theme has its own look") {
                ThemeSegments(selection: $store.mode, options: [("auto", "Auto"), ("light", "Light"), ("dark", "Dark")])
                    .frame(width: 220.d).disabled(store.current.scheme != nil).opacity(store.current.scheme != nil ? 0.5 : 1)
            }
            Row(title: "Accent color", hint: "The first one uses the theme's own color") {
                HStack(spacing: 8) {
                    ForEach(accents, id: \.self) { hex in
                        Button { store.accentHex = hex } label: {
                            Circle()
                                .fill(hex.isEmpty ? AnyShapeStyle(AngularGradient(colors: [.green, .blue, .pink, .orange, .green], center: .center)) : AnyShapeStyle(Color(hexString: hex) ?? .gray))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary, lineWidth: store.accentHex == hex ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Row(title: "Layout density", hint: "Touch makes every control larger") {
                ThemeSegments(selection: $store.density, options: [("compact", "Compact"), ("comfortable", "Comfortable"), ("touch", "Touch")]).frame(width: 300.d)
            }
            Row(title: "Text size", hint: "\(Int(store.textScale * 100))%") {
                Slider(value: $store.textScale, in: 0.85...1.3, step: 0.05).frame(width: 220.d)
            }
        }
        Group_(title: "Effects") {
            Row(title: "Theme window frames", hint: "Draw the theme's own title bar and window buttons") { Toggle("", isOn: $store.chromeOn).labelsHidden().toggleStyle(.switch) }
            Row(title: "Phosphor glow", hint: "Soft glow on the CRT theme") { Toggle("", isOn: $store.glowOn).labelsHidden().toggleStyle(.switch) }
            Row(title: "Reduce motion", hint: "Stops the moving heart line") { Toggle("", isOn: $store.reduceMotion).labelsHidden().toggleStyle(.switch) }
        }
    }
}

private struct ThemeTile: View {
    let theme: AppTheme, selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                theme.swatch.desk
                VStack(spacing: 0) {
                    theme.swatch.bar.frame(height: 10)
                    HStack(alignment: .top, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(theme.sidebar).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(theme.selectionText == .white ? Color.black.opacity(0.6) : Color.gray.opacity(0.6)).frame(width: 40, height: 5)
                            RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.45)).frame(width: 56, height: 4)
                            RoundedRectangle(cornerRadius: theme.radius == 0 ? 0 : 3).fill(theme.swatch.accent).frame(width: 30, height: 9)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(5)
                    Spacer(minLength: 0)
                }
                .background(theme.swatch.window)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius == 0 ? 0 : 4))
                .overlay(RoundedRectangle(cornerRadius: theme.radius == 0 ? 0 : 4).stroke(theme.chrome == .mac1bit ? Color.black : .clear, lineWidth: 1))
                .padding(.horizontal, 10).padding(.top, 10)
            }
            .frame(height: 74).clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(theme.name).font(.system(size: 12, weight: .semibold))
                Text(theme.era).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8)
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? Theme.accent : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
    }
}

// MARK: - Other pages

private struct GeneralPage: View {
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage("tour.seen") private var tourSeen = false

    var body: some View {
        PageHeader(title: "General", subtitle: "Make Triage yours.")
        Group_(title: "Startup") {
            Row(title: "Open at login", hint: loginError ?? "Starts quietly in the menu bar") {
                Toggle("", isOn: Binding(get: { login }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil }
                    catch { loginError = "macOS said no: \(error.localizedDescription)" }
                    login = SMAppService.mainApp.status == .enabled
                })).labelsHidden().toggleStyle(.switch)
            }
            Row(title: "Show the welcome tour again", hint: "Next time Triage opens") {
                Button("Show") { tourSeen = false }
            }
        }
    }
}

private struct MenuBarPage: View {
    @AppStorage("bar.items") private var items = "heart"
    @AppStorage("bar.icon") private var showIcon = true
    @AppStorage("panel.tab") private var tab = "vitals"
    private var on: Set<String> { Set(items.split(separator: ",").map(String.init)) }

    var body: some View {
        PageHeader(title: "Menu Bar", subtitle: "What sits at the top of your screen. Preview: \(MenuBarText.compose(SystemMonitor.shared, items: items, icon: false))")
        Group_(title: "In the menu bar") {
            ForEach(BarItem.allCases) { item in
                Row(title: item.title) {
                    Toggle("", isOn: Binding(get: { on.contains(item.rawValue) }, set: { _ in items = BarItem.toggle(item, in: items) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            Row(title: "Heart icon") { Toggle("", isOn: $showIcon).labelsHidden().toggleStyle(.switch) }
        }
        Group_(title: "Panel") {
            Row(title: "Opens on") {
                ThemeSegments(selection: $tab, options: [("vitals", "Vitals"), ("net", "Connectivity"), ("sound", "Sound")]).frame(width: 320.d)
            }
        }
    }
}

private struct HeartPage: View {
    @AppStorage("heart.rate") private var rate = 1.5
    @AppStorage("heart.bgrate") private var bgRate = 5.0
    @ObservedObject var store = ThemeStore.shared

    var body: some View {
        PageHeader(title: "Heart & Readings", subtitle: "How often Triage checks your Mac. Slower readings use less battery.")
        Group_(title: "Readings") {
            Row(title: "While a window is open", hint: "Every \(rate.formatted()) seconds") {
                ThemeSegments(selection: $rate, options: [(1.0, "1 s"), (1.5, "1.5 s"), (3.0, "3 s")]).frame(width: 220.d)
            }
            Row(title: "In the background", hint: "Menu bar numbers update at this pace") {
                ThemeSegments(selection: $bgRate, options: [(5.0, "5 s"), (15.0, "15 s"), (60.0, "60 s")]).frame(width: 220.d)
            }
            Row(title: "Still heart line", hint: "Same as Reduce motion in Appearance") { Toggle("", isOn: $store.reduceMotion).labelsHidden().toggleStyle(.switch) }
        }
    }
}

private struct IPhonePage: View {
    @ObservedObject private var remote = RemoteServer.shared

    var body: some View {
        PageHeader(title: "iPhone", subtitle: "Check on this Mac from your iPhone over Wi-Fi: vitals, files, apps. Everything stays on your network, encrypted end to end.")
        Group_(title: "Remote access") {
            Row(title: "Your iPhone can", hint: remote.mode == .full ? "Quit apps and move files to the Trash. Every action is logged below."
                    : remote.mode == .view ? "Look, but not touch" : "Nothing: Triage isn't listening") {
                ThemeSegments(selection: Binding(get: { remote.mode.rawValue }, set: { remote.mode = RemoteMode(rawValue: $0) ?? .off }),
                              options: RemoteMode.allCases.map { ($0.rawValue, $0.title) }).frame(width: 320.d)
            }
            if let w = remote.watcher {
                Row(title: "Remote desktop", hint: "\(w) is viewing and controlling this Mac") {
                    Button("Stop") { remote.endDesktop() }
                }
            }
            Row(title: "Status", hint: remote.keepAwake ? "Kept awake from the iPhone" : nil) {
                HStack(spacing: 6) {
                    Circle().fill(remote.listening ? (remote.connected.isEmpty ? Color.orange : Color.green) : Color.secondary).frame(width: 8, height: 8)
                    Text(remote.status).font(.ui(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        Group_(title: "Paired iPhones") {
            if remote.devices.isEmpty {
                Row(title: "None yet", hint: "Open Triage on your iPhone. This Mac shows a 6-digit code to type in.") { EmptyView() }
            }
            ForEach(remote.devices) { d in
                Row(title: d.name, hint: "Paired \(d.paired.formatted(date: .abbreviated, time: .omitted))"
                        + (d.lastSeen.map { " · last seen \($0.formatted(.relative(presentation: .named)))" } ?? "")) {
                    Button("Forget") { remote.forget(d) }
                }
            }
        }
        Group_(title: "Activity") {
            if remote.log.isEmpty { Row(title: "Nothing yet") { EmptyView() } }
            ForEach(remote.log.prefix(40)) { e in
                Row(title: e.action, hint: "\(e.device) · \(e.t.formatted(date: .abbreviated, time: .shortened))") { EmptyView() }
            }
        }
    }
}

private struct FilesPage: View {
    @AppStorage("files.hidden") private var hidden = false
    var body: some View {
        PageHeader(title: "Files", subtitle: "How the file manager starts out.")
        Group_(title: "Browsing") {
            Row(title: "Show hidden files", hint: "Files that start with a dot. ⇧⌘. switches it in any window") {
                Toggle("", isOn: $hidden).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

private struct ShortcutsPage: View {
    private let keys: [(String, String, String)] = [
        ("Smart Search from any app", "Works anywhere on your Mac", "⌥ Space"),
        ("Search inside Triage", "", "⌘ K"),
        ("Home", "", "⌘ 1"), ("Heart", "", "⌘ 0"), ("Apps", "", "⌘ 2"), ("Files", "", "⌘ 4"),
        ("New folder", "", "⇧⌘ N"), ("Show hidden files", "", "⇧⌘ ."), ("Settings", "", "⌘ ,"),
    ]
    var body: some View {
        PageHeader(title: "Shortcuts", subtitle: "Keys that save you a trip to the mouse.")
        Group_(title: "Keys") {
            ForEach(keys, id: \.0) { k in
                Row(title: k.0, hint: k.1.isEmpty ? nil : k.1) { Text(k.2).font(.ui(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct AdvancedPage: View {
    @AppStorage("perf.log") private var perfLog = true
    @State private var usage = ""
    @State private var confirmReset = false

    var body: some View {
        PageHeader(title: "Advanced", subtitle: "For tinkerers.")
        Group_(title: "Performance") {
            Row(title: "Triage right now", hint: "Its own memory use, the same number Activity Monitor shows") { Text(usage).font(.ui(size: 12, design: .monospaced)) }
            Row(title: "Usage log", hint: "Writes Triage's CPU and memory to TestFiles/perf.log once a minute") { Toggle("", isOn: $perfLog).labelsHidden().toggleStyle(.switch) }
        }
        Group_(title: "Reset") {
            Row(title: "Reset all settings", hint: "Theme, menu bar and panel choices. Files, servers and your signature stay.") {
                Button("Reset…") { confirmReset = true }
            }
        }
        .onAppear { usage = String(format: "%.0f MB", PerfLog.footprintMB()) }
        .confirmationDialog("Reset all Triage settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                for k in ["theme.id", "theme.accent", "theme.mode", "theme.density", "theme.text", "theme.motion", "theme.chrome", "theme.glow",
                          "bar.items", "bar.icon", "panel.tab", "heart.rate", "heart.bgrate", "files.hidden", "perf.log"] {
                    UserDefaults.standard.removeObject(forKey: k)
                }
                let s = ThemeStore.shared
                s.themeID = "apple"; s.accentHex = ""; s.mode = "auto"; s.density = "comfortable"; s.textScale = 1; s.reduceMotion = false; s.chromeOn = true; s.glowOn = true
            }
        }
    }
}
