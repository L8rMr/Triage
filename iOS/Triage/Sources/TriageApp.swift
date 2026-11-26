import SwiftUI

@main
struct TriageRemoteApp: App {
    @StateObject private var link = MacLink.shared
    @StateObject private var browser = MacBrowser()
    @StateObject private var cloud = CloudDirectory.shared
    @ObservedObject private var theme = ThemeModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if link.phase == .ready {
                    MainView()
                } else {
                    ConnectView(browser: browser)
                }
            }
            .id(theme.activeID)                       // repaint everything when the theme changes
            .environmentObject(link)
            .preferredColorScheme(theme.palette.scheme)
            .tint(theme.palette.accent)
            .fontDesign(theme.palette.mono ? .monospaced : .default)
            .background(Color.glass900.ignoresSafeArea())
            .onAppear {
                browser.start()
                PathWatch.shared.changed = { link.networkChanged(); cloud.refreshSoon() }
                Task { await cloud.refresh(); fallBackToHost() }
            }
            .onChange(of: scenePhase) { _, p in
                switch p {
                case .active: browser.start(); link.resume(); Task { await cloud.refresh(); fallBackToHost() }
                case .background: link.suspend(); browser.stop()
                default: break
                }
            }
            // Paired before? Walk straight back in as soon as Bonjour sees that Mac.
            .onChange(of: browser.macs) { _, macs in
                // Already in over the internet and now home: hop onto Wi-Fi.
                if link.phase == .ready, link.viaInternet, let mac = macs.first(where: { $0.id == link.macName }) {
                    link.upgrade(to: mac); return
                }
                guard link.phase == .idle, let want = link.rememberedMac, let mac = macs.first(where: { $0.id == want }) else { return }
                link.connect(mac)
            }
        }
    }
}

extension TriageRemoteApp {
    /// Not on the Mac's Wi-Fi? If Bonjour hasn't found it after a moment, go the long way round:
    /// your Macs in iCloud (Tailscale, then straight across the internet), else the typed Tailscale name.
    func fallBackToHost() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard link.phase == .idle || { if case .failed = link.phase { return true }; return false }() else { return }
            if let want = link.rememberedMac, browser.macs.contains(where: { $0.id == want }) { return }
            let mine = cloud.macs.first { $0.name == link.rememberedMac } ?? (cloud.macs.count == 1 ? cloud.macs.first : nil)
            if let mine {
                link.connect(anywhere: mine, lan: browser.macs)
            } else if !link.remoteHost.isEmpty {
                link.connect(host: link.remoteHost)
            }
        }
    }
}

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case home, heart, files, remote, tools, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .heart: return "Heart"
        case .files: return "Files"
        case .remote: return "Remote"
        case .tools: return "Tools"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .heart: return "waveform.path.ecg"
        case .files: return "folder.fill"
        case .remote: return "display"
        case .tools: return "wrench.and.screwdriver.fill"
        case .settings: return "gearshape.fill"
        }
    }
    /// The phone's tab bar holds five; the heart monitor lives on Home (and in the sidebar when there's room).
    static let tabs: [Pane] = [.home, .files, .remote, .tools, .settings]
}

/// Closed iPhone Duo (or any iPhone): tabs. Open Duo, iPad: sidebar + detail, and Remote goes edge to edge.
/// Decided by size class, never by screen size, so folding mid-use just reflows.
struct MainView: View {
    @EnvironmentObject var link: MacLink
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var section: Pane = .home      // every fresh open starts on Home
    @State private var previous: Pane = .home
    @State private var columns: NavigationSplitViewVisibility = .automatic

    var body: some View {
        Group {
            if hsc == .regular {
                NavigationSplitView(columnVisibility: $columns) {
                    List(selection: Binding(get: { Optional(section) }, set: { section = $0 ?? .home })) {
                        Section {
                            ForEach(Pane.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s) }
                        } header: { MacHeader() }
                    }
                    .navigationTitle("Triage")
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    NavigationStack { screen(section) }
                }
            } else {
                TabView(selection: $section) {
                    ForEach(Pane.tabs) { s in
                        Tab(s.title, systemImage: s.symbol, value: s) {
                            NavigationStack { screen(s) }
                        }
                    }
                }
            }
        }
        .onChange(of: section) { old, new in
            if new == .remote { previous = old == .remote ? .home : old; columns = .detailOnly } else { columns = .automatic }
            if hsc != .regular && new == .heart { section = .home }
        }
        .overlay(alignment: .top) {
            if link.reconnecting {
                Label("Reconnecting to \(link.macName)…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: link.reconnecting)
    }

    @ViewBuilder private func screen(_ s: Pane) -> some View {
        switch s {
        case .home: HomeScreen(go: { section = $0 })
        case .heart: HeartScreen()
        case .files: FilesScreen(path: nil)
        case .remote: RemoteScreen(exit: { section = previous })
        case .tools: ToolsScreen()
        case .settings: SettingsScreen()
        }
    }
}

private struct MacHeader: View {
    @EnvironmentObject var link: MacLink
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").foregroundStyle(Color.phosphor)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.macName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if let v = link.vitals {
                    Text("\(Int(v.bpm)) bpm · \(v.status ?? "")").font(.caption.monospacedDigit()).foregroundStyle(Color.pulse(v.bpm))
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }
}
