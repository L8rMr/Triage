import Foundation
import AppKit

enum Route: Hashable {
    case home, search, heart, apps, hardware, files, clean, tidy, utilities
    case place(URL)
    case tool(ToolID)
}

/// One stop in the app-wide history: the page, plus the folder when it's the file browser.
struct NavEntry: Equatable {
    let route: Route
    let folder: URL?
}

final class AppModel: ObservableObject {
    @Published var route: Route? = .home { didSet { if route != oldValue { scheduleRecord() } } }
    @Published var showSearch = false
    @Published var panes: [Pane]
    @Published var activePane = 0
    @Published var busy: String?
    @Published var peek: URL?
    @Published var searchFocus = 0
    @Published var showHelp = false
    @Published var showPermissions = false
    @Published var pinned: [URL] = (UserDefaults.standard.stringArray(forKey: "pinned.folders") ?? [])
        .map { URL(fileURLWithPath: $0) }

    func pin(_ u: URL) {
        let known = (Places.favorites + pinned).contains { $0.path == u.path }
        if !known {
            pinned.append(u)
            UserDefaults.standard.set(pinned.map(\.path), forKey: "pinned.folders")
        }
        route = .place(u)
    }

    func unpin(_ u: URL) {
        pinned.removeAll { $0.path == u.path }
        UserDefaults.standard.set(pinned.map(\.path), forKey: "pinned.folders")
    }

    func chooseFolders() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Add to Sidebar"
        p.message = "Choose folders to keep in the VitalOS sidebar. Cloud folders work too."
        if p.runModal() == .OK { p.urls.forEach(pin) }
    }
    @Published var tourActive = false
    @Published var tourIndex = 0
    @Published private(set) var tourSteps: [TourStep] = []

    func startTour(_ kind: TourKind) {
        tourSteps = TourScript.steps(kind)
        tourIndex = 0
        tourActive = true
        applyTourStep()
    }

    func tourStep(_ d: Int) {
        tourIndex = min(max(tourIndex + d, 0), tourSteps.count - 1)
        applyTourStep()
    }

    func endTour() {
        tourActive = false
        UserDefaults.standard.set(true, forKey: "tour.seen")
    }

    private func applyTourStep() {
        guard tourSteps.indices.contains(tourIndex) else { return }
        let s = tourSteps[tourIndex]
        route = s.route
        s.action?(self)
    }
    let search = SmartSearch()

    init() {
        panes = [Pane(Places.home)]
        hookPanes()
        current = NavEntry(route: .home, folder: nil)
    }

    // MARK: browser-style back / forward across the whole app

    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    private var backStack: [NavEntry] = []
    private var forwardStack: [NavEntry] = []
    private var current: NavEntry?
    private var navigating = false
    private var pendingRecord: DispatchWorkItem?

    private func hookPanes() {
        panes.forEach { $0.onNavigate = { [weak self] in self?.scheduleRecord() } }
    }

    private func snapshot() -> NavEntry {
        NavEntry(route: route ?? .home, folder: isInBrowser ? active.url.standardizedFileURL : nil)
    }

    /// Coalesces a route change and the folder change it causes into one history entry.
    func scheduleRecord() {
        guard !navigating else { return }
        pendingRecord?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.record() }
        pendingRecord = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    private func record() {
        guard !navigating else { return }
        let e = snapshot()
        guard e != current else { return }
        if let c = current { backStack.append(c) }
        if backStack.count > 200 { backStack.removeFirst() }
        forwardStack.removeAll()
        current = e
        updateNavFlags()
    }

    func goBack() {
        guard let e = backStack.popLast() else { NSSound.beep(); return }
        if let c = current { forwardStack.append(c) }
        apply(e)
    }

    func goForward() {
        guard let e = forwardStack.popLast() else { NSSound.beep(); return }
        if let c = current { backStack.append(c) }
        apply(e)
    }

    private func apply(_ e: NavEntry) {
        pendingRecord?.cancel()
        navigating = true
        current = e
        route = e.route
        if let f = e.folder { active.go(f) }
        updateNavFlags()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.navigating = false }
    }

    private func updateNavFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    var active: Pane { panes[min(activePane, panes.count - 1)] }
    var other: Pane? { panes.count > 1 ? panes[activePane == 0 ? 1 : 0] : nil }

    var isInBrowser: Bool {
        switch route {
        case .files?, .place?: return true
        default: return false
        }
    }

    var isUtility: Bool {
        switch route {
        case .utilities?, .tool?, .clean?, .tidy?: return true
        default: return false
        }
    }

    func toggleSplit() {
        if panes.count > 1 {
            panes = [active]
            activePane = 0
        } else {
            panes.append(Pane(active.url))
        }
        hookPanes()
    }

    func open(_ url: URL, in pane: Pane? = nil) {
        if FS.isFolder(url) {
            (pane ?? active).go(url)
            if !isInBrowser { route = .files }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func reloadAll() { panes.forEach { $0.reload() } }

    func transfer(_ urls: [URL], move: Bool) {
        guard let dst = other, !urls.isEmpty else {
            if other == nil { UndoCenter.shared.show("Press ⌘D to open a second pane first") }
            return
        }
        run(urls, into: dst.url, move: move)
    }

    func drop(_ urls: [URL], into dir: URL) {
        run(urls, into: dir, move: true)
    }

    private func run(_ urls: [URL], into dir: URL, move: Bool) {
        let n = urls.count
        busy = "\(move ? "Moving" : "Copying") \(n) item\(n == 1 ? "" : "s") to \(dir.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = FileOps.transfer(urls, to: dir, move: move)
            DispatchQueue.main.async {
                self.busy = nil
                self.reloadAll()
                guard !r.done.isEmpty || !r.errors.isEmpty else { return }
                let renamed = r.done.filter { $0.from.lastPathComponent != $0.to.lastPathComponent }.count
                var msg = "\(move ? "Moved" : "Copied") \(r.done.count) item\(r.done.count == 1 ? "" : "s")"
                if renamed > 0 { msg += " · \(renamed) renamed to avoid a clash" }
                if !r.errors.isEmpty { msg += " · \(r.errors.count) failed" }
                let done = r.done
                UndoCenter.shared.show(msg) {
                    if move { FileOps.moveBack(done) } else { _ = FileOps.trash(done.map(\.to)) }
                    self.reloadAll()
                }
            }
        }
    }

    struct TrashCheck: Identifiable {
        let url: URL
        let verdict: Verdict
        var id: URL { url }
    }
    @Published var pendingTrash: [TrashCheck] = []
    @Published var inspect: URL?

    /// Checks each item first; anything risky waits for confirmation with the reasons shown.
    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let checks = urls.prefix(40).map { TrashCheck(url: $0, verdict: DeleteAdvisor.assess($0)) }
        if checks.contains(where: { $0.verdict.level >= .caution }) {
            pendingTrash = checks
            return
        }
        trashNow(urls)
    }

    func trashNow(_ urls: [URL]) {
        pendingTrash = []
        let moved = FileOps.trash(urls)
        reloadAll()
        UndoCenter.shared.show("Moved \(moved.count) item\(moved.count == 1 ? "" : "s") to the Trash") { [weak self] in
            FileOps.moveBack(moved)
            self?.reloadAll()
        }
    }

    func newFolder() {
        let dest = FileOps.unique(active.url.appendingPathComponent("untitled folder"))
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            active.reload()
            active.selection = [dest]
        } catch {
            UndoCenter.shared.show("Couldn't create a folder here")
        }
    }
}
