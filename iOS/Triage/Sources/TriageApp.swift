import SwiftUI

@main
struct TriageRemoteApp: App {
    @StateObject private var link = MacLink.shared
    @StateObject private var browser = MacBrowser()
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
            .environmentObject(link)
            .preferredColorScheme(.dark)
            .tint(.phosphor)
            .background(Color.glass900.ignoresSafeArea())
            .onAppear { browser.start() }
            .onChange(of: scenePhase) { _, p in
                switch p {
                case .active: browser.start(); link.resume()
                case .background: link.suspend(); browser.stop()
                default: break
                }
            }
            // Paired before? Walk straight back in as soon as Bonjour sees that Mac.
            .onChange(of: browser.macs) { _, macs in
                guard link.phase == .idle, let want = link.rememberedMac, let mac = macs.first(where: { $0.id == want }) else { return }
                link.connect(mac)
            }
        }
    }
}

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case heart, apps, files, mac
    var id: String { rawValue }
    var title: String {
        switch self {
        case .heart: return "Heart"
        case .apps: return "Apps"
        case .files: return "Files"
        case .mac: return "Mac"
        }
    }
    var symbol: String {
        switch self {
        case .heart: return "waveform.path.ecg"
        case .apps: return "square.stack.3d.up.fill"
        case .files: return "folder.fill"
        case .mac: return "laptopcomputer"
        }
    }
}

/// Closed iPhone Duo (or any iPhone): tabs. Open Duo, iPad, landscape Max: sidebar + detail.
/// Decided by size class, never by screen size, so folding mid-use just reflows.
struct MainView: View {
    @EnvironmentObject var link: MacLink
    @Environment(\.horizontalSizeClass) private var hsc
    @SceneStorage("section") private var section: Pane = .heart

    var body: some View {
        Group {
            if hsc == .regular {
                NavigationSplitView {
                    List(selection: Binding(get: { Optional(section) }, set: { section = $0 ?? .heart })) {
                        Section {
                            ForEach(Pane.allCases) { s in
                                Label(s.title, systemImage: s.symbol).tag(s)
                            }
                        } header: {
                            MacHeader()
                        }
                    }
                    .navigationTitle("Triage")
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    NavigationStack { screen(section) }
                }
            } else {
                TabView(selection: $section) {
                    ForEach(Pane.allCases) { s in
                        Tab(s.title, systemImage: s.symbol, value: s) {
                            NavigationStack { screen(s) }
                        }
                    }
                }
            }
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
        case .heart: HeartScreen()
        case .apps: AppsScreen()
        case .files: FilesScreen(path: nil)
        case .mac: MacScreen()
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
