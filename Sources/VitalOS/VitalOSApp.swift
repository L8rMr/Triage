import SwiftUI
import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppBundler.relaunchAsBundleIfNeeded() { exit(0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Dock icon when run straight from Xcode (build.sh bakes it into the .app instead).
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/AppIcon-1024.png")
            if let img = NSImage(contentsOf: icon) { NSApp.applicationIconImage = img }
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open-pdf"), i + 1 < args.count { Self.openInEditor(URL(fileURLWithPath: args[i + 1])) }
        HotKey.shared.action = { GlobalSearch.shared.toggle() }
        HotKey.shared.register()
        RuleStore.shared.start()
        ClipboardStore.shared.start()
        // ⌘⇧2: grab text from anywhere on screen · ⌥⇧V: clipboard history
        HotKey.shared.register(id: 2, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey)) {
            ClipboardStore.shared.captureScreenText()
        }
        HotKey.shared.register(id: 3, keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | shiftKey)) {
            ClipboardPanel.shared.toggle()
        }
    }

    /// Finder "Open With → VitalOS", or launched with --open-pdf <path>.
    func application(_ app: NSApplication, open urls: [URL]) { urls.forEach(Self.openInEditor) }

    static func openInEditor(_ u: URL) {
        let ext = u.pathExtension.lowercased()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if ext == "pdf" { PDFEditorModel.shared.open(u) } else { PDFEditorModel.shared.openImage(u) }
            NotificationCenter.default.post(name: .vitalOSShowPDF, object: nil)
        }
    }

    // Closing the window keeps VitalOS alive in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct VitalOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = SystemMonitor.shared
    @StateObject private var model = AppModel()
    @StateObject private var undo = UndoCenter.shared

    private static func fnKey(_ code: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt32(code)) ?? " "))
    }

    var body: some Scene {
        Window("VitalOS", id: "main") {
            RootView()
                .environmentObject(monitor)
                .environmentObject(model)
                .environmentObject(undo)
                .frame(minWidth: 1020, minHeight: 660)
                .themed()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Search…") { model.searchFocus += 1 }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Search From Anywhere (⌥Space)") { GlobalSearch.shared.show() }
                Button("New Folder") { model.route = model.isInBrowser ? model.route : .files; model.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button(model.panes.count > 1 ? "Close Second Pane" : "Split Into Two Panes") {
                    if !model.isInBrowser { model.route = .files }
                    model.toggleSplit()
                }
                .keyboardShortcut("d", modifiers: .command)
                Button("Copy to Other Pane") { model.transfer(Array(model.active.selection), move: false) }
                    .keyboardShortcut(Self.fnKey(NSF5FunctionKey), modifiers: [])
                Button("Move to Other Pane") { model.transfer(Array(model.active.selection), move: true) }
                    .keyboardShortcut(Self.fnKey(NSF6FunctionKey), modifiers: [])
                Divider()
                Button("Open in Terminal") { FileOps.openTerminal(at: model.active.url) }
                    .keyboardShortcut("t", modifiers: [.command, .option, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("How to Use VitalOS") { model.showHelp = true }
                Button("Permissions…") { model.showPermissions = true }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
                Button("Quick Tour") { model.startTour(.quick) }
                Button("In-Depth Tour") { model.startTour(.deep) }
            }
            CommandGroup(before: .sidebar) {
                Button("Back") { model.goBack() }.keyboardShortcut("[", modifiers: .command)
                Button("Forward") { model.goForward() }.keyboardShortcut("]", modifiers: .command)
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Button("Home") { model.route = .home }.keyboardShortcut("1", modifiers: .command)
                Button("Heart") { model.route = .heart }.keyboardShortcut("0", modifiers: .command)
                Button("Apps") { model.route = .apps }.keyboardShortcut("2", modifiers: .command)
                Button("Hardware") { model.route = .hardware }.keyboardShortcut("3", modifiers: .command)
                Button("Files") { model.route = .files }.keyboardShortcut("4", modifiers: .command)
                Button("Utilities") { model.route = .utilities }.keyboardShortcut("5", modifiers: .command)
                Button("Free Up Space") { model.route = .clean }
                Button("Tidy Downloads") { model.route = .tidy }.keyboardShortcut("6", modifiers: .command)
                Button("Show Hidden Files") { model.active.showHidden.toggle() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .themedPanel()
        }

        MenuBarExtra {
            MenuPanel()
                .environmentObject(monitor)
                .themedPanel()
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var undo: UndoCenter

    /// Pages opened from Smart Search actions.
    private func go(_ p: String) {
        UserDefaults.standard.removeObject(forKey: "pending.route")
        switch p {
        case "home": model.route = .home
        case "heart": model.route = .heart
        case "apps": model.route = .apps
        case "hardware": model.route = .hardware
        case "files": model.route = .files
        case "utilities": model.route = .utilities
        case "clean": model.route = .clean
        case "tidy": model.route = .tidy
        default: if let t = ToolID(rawValue: p) { model.route = .tool(t) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchHeader()
            HStack(spacing: 0) {
                WorkbenchRail()
                ZStack(alignment: .bottom) {
                    Theme.bg.ignoresSafeArea()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    TourOverlay()
                        .animation(.spring(duration: 0.35), value: model.tourIndex)
                        .animation(.spring(duration: 0.35), value: model.tourActive)
                    if let t = undo.toast {
                        ToastView(toast: t, center: undo)
                            .padding(.bottom, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.3), value: undo.toast?.id)
            }
        }
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: Binding(get: { !model.pendingTrash.isEmpty }, set: { if !$0 { model.pendingTrash = [] } })) {
            TrashReview().environmentObject(model)
        }
        .sheet(isPresented: $model.showHelp) {
            HelpCenter().environmentObject(model)
        }
        .sheet(isPresented: $model.showPermissions, onDismiss: {
            UserDefaults.standard.set(true, forKey: "perm.onboarded")
            if !UserDefaults.standard.bool(forKey: "tour.seen") { model.startTour(.quick) }
        }) {
            PermissionsView(firstRun: !UserDefaults.standard.bool(forKey: "perm.onboarded"))
        }
        .task {
            if !UserDefaults.standard.bool(forKey: "perm.onboarded") {
                try? await Task.sleep(nanoseconds: 600_000_000)
                model.showPermissions = true
            } else if !UserDefaults.standard.bool(forKey: "tour.seen") {
                try? await Task.sleep(nanoseconds: 800_000_000)
                model.startTour(.quick)
            }
        }
        .onChange(of: model.route) { _, r in
            if case .place(let u)? = r { model.active.go(u) }
        }
        .onAppear { NavInput.install(model) }
        .onReceive(NotificationCenter.default.publisher(for: .vitalOSShowPDF)) { _ in model.route = .tool(.pdf) }
        .onReceive(NotificationCenter.default.publisher(for: .vitalOSGo)) { n in if let p = n.object as? String { go(p) } }
        .onAppear { if let p = UserDefaults.standard.string(forKey: "pending.route") { go(p) } }
        .onChange(of: model.showSearch) { _, show in
            guard show else { return }
            model.showSearch = false
            model.searchFocus += 1
        }
        .onAppear {
            let m = model
            let openHere: (URL) -> Void = { url in
                let isFolder = FS.isFolder(url)
                m.route = .files
                m.active.go(isFolder ? url : url.deletingLastPathComponent())
                if !isFolder { m.active.selection = [url] }
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "VitalOS" }?.makeKeyAndOrderFront(nil)
            }
            GlobalSearch.shared.engine.onOpenInVitalOS = openHere
            model.search.onOpenInVitalOS = openHere
            HomeView.engine.onOpenInVitalOS = openHere
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.route ?? .home {
        case .home: WorkbenchHome()
        case .search: SearchPage()
        case .heart: HeartView()
        case .apps: AppsHub()
        case .hardware: HardwareView()
        case .files, .place: FilesWorkspace()
        case .clean: CleanView()
        case .tidy: TidyView()
        case .utilities: UtilitiesView()
        case .tool(let t): t.page
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    @AppStorage("utilities.pinned") private var pinnedRaw = "clean,tidy,clipboard,pdf"
    @State private var showMoreTools = false
    @State private var showAddFolder = false

    private var starredTools: [ToolID] {
        pinnedRaw.split(separator: ",").compactMap { ToolID(rawValue: String($0)) }
    }


    var body: some View {
        VStack(spacing: 0) {
            Button { model.route = .heart } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "heart.text.square.fill").foregroundStyle(Theme.heart)
                    Text("VitalOS").font(.ui(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(Int(monitor.bpm.rounded())) bpm")
                        .font(.ui(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                PulseLine(bpm: monitor.bpm, color: monitor.heart?.color ?? Theme.accent)
                    .frame(height: 26)
                Text(monitor.heart.map { "\($0.status) · health \($0.health)" } ?? " ")
                    .font(.ui(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Your Mac's heartbeat, from processor, memory, heat, disk and battery. Click for the full monitor.")
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 6)

            InlineSearchField(engine: model.search, placeholder: "Search your Mac",
                              size: 13, focusToken: model.searchFocus,
                              onType: { if model.route != .search { model.route = .search } })
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row("Home", "sparkles", .home)
                    header("Vitals")
                    row("Heart", "heart.text.square", .heart)
                    row("Apps", "waveform.path.ecg", .apps)
                    row("Hardware", "cpu", .hardware)
                    header("Files")
                    row("Browser", "rectangle.split.2x1", .files)
                    ForEach(Places.favorites, id: \.self) { u in
                        row(Places.name(u), Places.symbol(u), .place(u))
                    }
                    ForEach(model.pinned, id: \.self) { u in
                        row(Places.name(u), Places.symbol(u), .place(u))
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                                Button("Remove from Sidebar") { model.unpin(u) }
                            }
                    }
                    addFolderMenu
                    header("Utilities")
                    row("All Utilities", "square.grid.2x2", .utilities)
                    ForEach(starredTools) { t in row(t.title, t.symbol, t.route) }
                    if showMoreTools {
                        ForEach(ToolID.allCases.filter { !starredTools.contains($0) }) { t in row(t.title, t.symbol, t.route) }
                    }
                    Button { withAnimation(.easeOut(duration: 0.2)) { showMoreTools.toggle() } } label: {
                        HStack(spacing: 9) {
                            Image(systemName: showMoreTools ? "chevron.up" : "ellipsis").frame(width: 18)
                            Text(showMoreTools ? "Show less" : "Show \(ToolID.allCases.count - starredTools.count) more")
                            Spacer(minLength: 0)
                        }
                        .font(.ui(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }


        }
        .background(VisualEffect(material: .sidebar).ignoresSafeArea())
    }

    private var addFolderMenu: some View {
        Button { showAddFolder.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus").frame(width: 18)
                Text("Add Folder")
                Spacer(minLength: 0)
            }
            .font(.ui(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAddFolder, arrowEdge: .trailing) { AddFolderPopover(close: { showAddFolder = false }) }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.ui(size: 10, weight: .semibold)).kerning(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func row(_ title: String, _ symbol: String, _ r: Route) -> some View {
        let selected = (model.route ?? .home) == r
        return Button {
            model.route = r
            if case .place(let u) = r { model.active.go(u) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.ui(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Color.primary.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .opacity(model.tourActive && selected ? 1 : 0)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Sidebar tags must match the List's Optional<Route> selection.
    func route(_ r: Route) -> some View { tag(Optional(r)) }
}


struct AddFolderPopover: View {
    @EnvironmentObject var model: AppModel
    let close: () -> Void

    private var suggestions: [URL] {
        (Places.cloudRoots + Places.volumes).filter { c in
            !(Places.favorites + model.pinned).contains { $0.path == c.path }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to sidebar").font(.ui(size: 13, weight: .semibold))
            Button {
                close()
                DispatchQueue.main.async { model.chooseFolders() }
            } label: {
                Label("Choose a folder…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("CLOUD DRIVES & DISKS").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            if suggestions.isEmpty {
                Text("None found. Google Drive, Dropbox, OneDrive, Box and iDrive appear here once their Mac apps are installed and syncing.")
                    .font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(suggestions, id: \.self) { u in
                    Button { model.pin(u); close() } label: {
                        HStack {
                            Image(systemName: Places.symbol(u)).foregroundStyle(Theme.accent).frame(width: 18)
                            Text(Places.name(u)).lineLimit(1)
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        }
                        .font(.ui(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// Back / forward arrows by the ? button.
struct NavButtons: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 2) {
            navButton("chevron.left", enabled: model.canGoBack, help: "Back (⌘[)") { model.goBack() }
            navButton("chevron.right", enabled: model.canGoForward, help: "Forward (⌘])") { model.goForward() }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func navButton(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.ui(size: 11, weight: .bold)).frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
        .help(help)
    }
}

/// Mouse side buttons and three-finger swipes move back and forward, like Safari.
enum NavInput {
    private static var monitor: Any?
    static func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { e in
            if NSApp.keyWindow is SearchPanel { return e }
            switch e.type {
            case .otherMouseDown where e.buttonNumber == 3: model.goBack(); return nil
            case .otherMouseDown where e.buttonNumber == 4: model.goForward(); return nil
            case .swipe where e.deltaX > 0: model.goBack(); return nil
            case .swipe where e.deltaX < 0: model.goForward(); return nil
            default: return e
            }
        }
    }
}


/// Shown before deleting anything that looks risky, with the reasons.
struct TrashReview: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.ui(size: 22)).foregroundStyle(Theme.net)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check before you delete").font(.ui(size: 17, weight: .bold))
                    Text("Some of these look like things you or your apps still need.").font(.ui(size: 12)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.pendingTrash.sorted { $0.verdict.level > $1.verdict.level }) { c in
                        HStack(alignment: .top, spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: c.url.path)).resizable().frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(c.url.lastPathComponent).font(.ui(size: 12, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Label(c.verdict.level.title, systemImage: c.verdict.level.symbol)
                                        .font(.ui(size: 11, weight: .medium)).foregroundStyle(c.verdict.level.color)
                                }
                                ForEach(c.verdict.reasons, id: \.self) { r in
                                    Text(r).font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(10)
                        .background(c.verdict.level.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                let safe = model.pendingTrash.filter { $0.verdict.level < .caution }.map(\.url)
                Button("Cancel") { model.pendingTrash = [] }.keyboardShortcut(.cancelAction)
                Spacer()
                if !safe.isEmpty && safe.count < model.pendingTrash.count {
                    Button("Only the safe ones (\(safe.count))") { model.trashNow(safe) }
                }
                Button("Move All to Trash") { model.trashNow(model.pendingTrash.map(\.url)) }
                    .buttonStyle(.borderedProminent).tint(Theme.warn)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

extension Notification.Name { static let vitalOSShowPDF = Notification.Name("VitalOSShowPDF") }
