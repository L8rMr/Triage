import Foundation
import AppKit

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Date
    let added: Date
    var id: URL { url }
    var kindName: String { isDir ? "0 Folder" : FileKind.of(url.pathExtension).rawValue }
}

// MARK: - Smart grouping, used by the browser, Tidy and Home

enum GroupBy: String, CaseIterable, Identifiable {
    case none = "No grouping", kind = "Kind", date = "Date modified", size = "Size"
    var id: String { rawValue }
}

struct FileGroup: Identifiable {
    let id: String
    let symbol: String
    let items: [FileItem]
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

enum Grouper {
    static func group(_ items: [FileItem], by g: GroupBy) -> [FileGroup] {
        switch g {
        case .none:
            return [FileGroup(id: "", symbol: "", items: items)]
        case .kind:
            var out: [FileGroup] = []
            let dirs = items.filter(\.isDir)
            if !dirs.isEmpty { out.append(FileGroup(id: "Folders", symbol: "folder", items: dirs)) }
            for k in FileKind.allCases {
                let m = items.filter { !$0.isDir && FileKind.of($0.url.pathExtension) == k }
                if !m.isEmpty { out.append(FileGroup(id: k.rawValue, symbol: k.symbol, items: m)) }
            }
            return out
        case .date:
            let cal = Calendar.current
            let now = Date()
            let today = cal.startOfDay(for: now)
            let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
            let week = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            let month = cal.dateInterval(of: .month, for: now)?.start ?? today
            let year = cal.dateInterval(of: .year, for: now)?.start ?? today
            let buckets: [(String, String, (Date) -> Bool)] = [
                ("Today", "sun.max", { $0 >= today }),
                ("Yesterday", "moon", { $0 >= yesterday && $0 < today }),
                ("Earlier this week", "calendar", { $0 >= week && $0 < yesterday }),
                ("Earlier this month", "calendar", { $0 >= month && $0 < week && $0 < yesterday }),
                ("Earlier this year", "calendar.badge.clock", { $0 >= year && $0 < month }),
                ("Older", "archivebox", { $0 < year }),
            ]
            var used = Set<URL>()
            return buckets.compactMap { b in
                let m = items.filter { !used.contains($0.url) && b.2($0.modified) }
                m.forEach { used.insert($0.url) }
                return m.isEmpty ? nil : FileGroup(id: b.0, symbol: b.1, items: m)
            }
        case .size:
            let buckets: [(String, String, (FileItem) -> Bool)] = [
                ("Folders", "folder", { $0.isDir }),
                ("Huge · over 1 GB", "externaldrive.fill", { !$0.isDir && $0.size >= 1_000_000_000 }),
                ("Large · 100 MB to 1 GB", "shippingbox.fill", { !$0.isDir && $0.size >= 100_000_000 && $0.size < 1_000_000_000 }),
                ("Medium · 1 to 100 MB", "doc.fill", { !$0.isDir && $0.size >= 1_000_000 && $0.size < 100_000_000 }),
                ("Small · under 1 MB", "doc", { !$0.isDir && $0.size < 1_000_000 }),
            ]
            return buckets.compactMap { b in
                let m = items.filter(b.2)
                return m.isEmpty ? nil : FileGroup(id: b.0, symbol: b.1, items: m)
            }
        }
    }
}

struct Moved {
    let from: URL
    let to: URL
}

enum Places {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var downloads: URL { home.appendingPathComponent("Downloads") }

    static var favorites: [URL] {
        let named = ["Desktop", "Documents", "Downloads", "Projects"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return [home] + named + [URL(fileURLWithPath: "/Applications")]
    }

    static let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

    /// iCloud Drive, everything under ~/Library/CloudStorage (Google Drive, Dropbox, OneDrive, Box…),
    /// plus older home-folder sync locations (iDrive, Dropbox, Google Drive).
    static var cloudRoots: [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        if fm.fileExists(atPath: iCloud.path) { out.append(iCloud) }
        let cs = home.appendingPathComponent("Library/CloudStorage")
        if let items = try? fm.contentsOfDirectory(at: cs, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            out += items.filter { FS.isFolder($0) }
        }
        for legacy in ["IDrive-Sync", "IDrive Sync", "IDriveSync", "IDrive", "Dropbox", "Google Drive", "OneDrive", "Box", "pCloud Drive", "Sync"] {
            let u = home.appendingPathComponent(legacy)
            if fm.fileExists(atPath: u.path) && !out.contains(where: { $0.path == u.path }) { out.append(u) }
        }
        return out
    }

    static var volumes: [URL] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { (try? $0.resourceValues(forKeys: Set(keys)).volumeIsRootFileSystem) != true }
    }

    static func cloudName(_ u: URL) -> String? {
        if u.path == iCloud.path { return "iCloud Drive" }
        let n = u.lastPathComponent
        guard u.path.contains("/Library/CloudStorage/") else {
            if n.lowercased().hasPrefix("idrive") { return "iDrive" }
            return nil
        }
        let parts = n.split(separator: "-", maxSplits: 1).map(String.init)
        let provider: String
        switch parts.first?.lowercased() ?? "" {
        case "googledrive": provider = "Google Drive"
        case "onedrive": provider = "OneDrive"
        case "dropbox": provider = "Dropbox"
        case "box": provider = "Box"
        case let p where p.hasPrefix("idrive"): provider = "iDrive"
        default: provider = parts.first ?? n
        }
        if parts.count > 1, parts[1].contains("@") { return "\(provider) · \(parts[1])" }
        if parts.count > 1, !["personal", "box"].contains(parts[1].lowercased()) { return "\(provider) · \(parts[1])" }
        return provider
    }

    static func name(_ u: URL) -> String {
        if let c = cloudName(u) { return c }
        if u.path == home.path { return NSUserName() }
        if u.path == "/" { return "Macintosh HD" }
        return u.lastPathComponent
    }

    static func symbol(_ u: URL) -> String {
        if u.path == home.path { return "house" }
        if u.path == iCloud.path { return "icloud" }
        if cloudName(u) != nil { return "cloud" }
        if u.path.hasPrefix("/Volumes/") { return "externaldrive" }
        switch u.lastPathComponent {
        case "Desktop": return "menubar.dock.rectangle"
        case "Documents": return "doc"
        case "Downloads": return "arrow.down.circle"
        case "Projects": return "hammer"
        case "Applications": return "square.grid.2x2"
        default: return "folder"
        }
    }

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }
}

enum FS {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                         .isPackageKey, .addedToDirectoryDateKey]

    static func list(_ url: URL, showHidden: Bool) -> [FileItem] {
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: opts) else { return [] }
        let keySet = Set(keys)
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: keySet)
            let pkg = v?.isPackage ?? false
            let mod = v?.contentModificationDate ?? .distantPast
            return FileItem(url: u, name: u.lastPathComponent,
                            isDir: (v?.isDirectory ?? false) && !pkg,
                            size: Int64(v?.fileSize ?? 0),
                            modified: mod,
                            added: v?.addedToDirectoryDate ?? mod)
        }
        .sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func isFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
    }

    static func gitBranch(_ start: URL) -> String? {
        var dir = start.standardizedFileURL
        for _ in 0..<16 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let s = try? String(contentsOf: head, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.hasPrefix("ref: refs/heads/") ? String(t.dropFirst(16)) : String(t.prefix(7))
            }
            if dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                    options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

enum FileOps {
    private static var fm: FileManager { .default }

    static func unique(_ url: URL) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        for i in 2...9999 {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let c = dir.appendingPathComponent(n)
            if !fm.fileExists(atPath: c.path) { return c }
        }
        return url
    }

    static func transfer(_ urls: [URL], to dir: URL, move: Bool) -> (done: [Moved], errors: [String]) {
        var done: [Moved] = []
        var errs: [String] = []
        for u in urls {
            if move && u.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL { continue }
            let dest = unique(dir.appendingPathComponent(u.lastPathComponent))
            do {
                if move { try fm.moveItem(at: u, to: dest) } else { try fm.copyItem(at: u, to: dest) }
                done.append(Moved(from: u, to: dest))
            } catch {
                errs.append(error.localizedDescription)
            }
        }
        return (done, errs)
    }

    /// Moves items to the Trash and remembers where they went, so Undo can bring them back.
    static func trash(_ urls: [URL]) -> [Moved] {
        urls.compactMap { u in
            var out: NSURL?
            do {
                try fm.trashItem(at: u, resultingItemURL: &out)
                if let o = out as URL? { return Moved(from: u, to: o) }
            } catch {}
            return nil
        }
    }

    static func moveBack(_ moved: [Moved]) {
        for m in moved where fm.fileExists(atPath: m.to.path) {
            try? fm.createDirectory(at: m.from.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: m.to, to: unique(m.from))
        }
    }

    static func openTerminal(at dir: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func emptyTrash() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        try? p.run()
    }
}

/// One folder view. Two of these side by side make dual-pane mode.
final class Pane: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var url: URL
    @Published var items: [FileItem] = []
    @Published var accessDenied = false
    @Published var waiting = false        // listing is taking a while (usually macOS asking for permission)
    private var loadToken = UUID()
    @Published var selection: Set<URL> = []
    @Published var showHidden = UserDefaults.standard.bool(forKey: "files.hidden") { didSet { reload() } }
    @Published private(set) var gitBranch: String?
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.name, comparator: .localizedStandard)] {
        didSet { items = Self.sorted(items, by: sortOrder) }
    }
    @Published var filterText = ""
    @Published var filterKinds: Set<String> = []
    @Published var filterSizes: Set<String> = []
    @Published var filterDates: Set<String> = []

    var isFiltered: Bool { !filterText.isEmpty || !filterKinds.isEmpty || !filterSizes.isEmpty || !filterDates.isEmpty }
    var visible: [FileItem] { isFiltered ? items.filter(matches) : items }

    func clearFilters() { filterText = ""; filterKinds = []; filterSizes = []; filterDates = [] }

    var kindOptions: [FilterOption] {
        var out: [FilterOption] = []
        let dirs = items.filter(\.isDir).count
        if dirs > 0 { out.append(FilterOption(id: "Folder", label: "Folders", symbol: "folder", count: dirs)) }
        for k in FileKind.allCases {
            let n = items.filter { !$0.isDir && FileKind.of($0.url.pathExtension) == k }.count
            if n > 0 { out.append(FilterOption(id: k.rawValue, label: k.rawValue, symbol: k.symbol, count: n)) }
        }
        return out
    }
    var sizeOptions: [FilterOption] { FilterOption.sizes(items.filter { !$0.isDir }.map(\.size)) }
    var dateOptions: [FilterOption] { FilterOption.dates(items.map(\.modified)) }

    private func matches(_ f: FileItem) -> Bool {
        if !TextFilter.matches(f.name, filterText) { return false }
        if !filterKinds.isEmpty && !filterKinds.contains(f.isDir ? "Folder" : FileKind.of(f.url.pathExtension).rawValue) { return false }
        if !filterSizes.isEmpty && (f.isDir || !filterSizes.contains(SizeBucket.of(f.size).rawValue)) { return false }
        if !filterDates.isEmpty && !filterDates.contains(DateBucket.of(f.modified).rawValue) { return false }
        return true
    }

    var sortKey: String {
        let k = sortOrder.first?.keyPath
        if k == \FileItem.size { return "size" }
        if k == \FileItem.modified { return "modified" }
        if k == \FileItem.added { return "added" }
        if k == \FileItem.kindName { return "kind" }
        return "name"
    }
    var sortAscending: Bool { sortOrder.first?.order != .reverse }

    private var backStack: [URL] = []
    private var fwdStack: [URL] = []
    var onNavigate: (() -> Void)?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !fwdStack.isEmpty }

    var crumbs: [URL] {
        var out: [URL] = []
        var u = url.standardizedFileURL
        for _ in 0..<64 {
            out.insert(u, at: 0)
            if u.path == "/" { break }
            u = u.deletingLastPathComponent()
        }
        return out
    }

    init(_ url: URL) {
        self.url = url
        reload()
    }

    func go(_ u: URL) {
        guard u.standardizedFileURL.path != url.standardizedFileURL.path else { return }
        backStack.append(url)
        fwdStack.removeAll()
        url = u
        selection = []
        reload()
        onNavigate?()
    }

    func goBack() {
        guard let u = backStack.popLast() else { return }
        fwdStack.append(url)
        url = u
        reload()
        onNavigate?()
    }

    func goForward() {
        guard let u = fwdStack.popLast() else { return }
        backStack.append(url)
        url = u
        reload()
        onNavigate?()
    }

    func goUp() {
        guard url.standardizedFileURL.path != "/" else { return }
        go(url.deletingLastPathComponent())
    }

    /// Folders stay on top; everything else follows the chosen column.
    static func sorted(_ list: [FileItem], by order: [KeyPathComparator<FileItem>]) -> [FileItem] {
        let dirs = list.filter(\.isDir).sorted(using: order)
        let files = list.filter { !$0.isDir }.sorted(using: order)
        return dirs + files
    }

    func setSort(_ key: String, ascending: Bool) {
        let o: SortOrder = ascending ? .forward : .reverse
        switch key {
        case "size": sortOrder = [KeyPathComparator(\.size, order: o)]
        case "modified": sortOrder = [KeyPathComparator(\.modified, order: o)]
        case "added": sortOrder = [KeyPathComparator(\.added, order: o)]
        case "kind": sortOrder = [KeyPathComparator(\.kindName, order: o), KeyPathComparator(\.name, comparator: .localizedStandard)]
        default: sortOrder = [KeyPathComparator(\.name, comparator: .localizedStandard, order: o)]
        }
    }

    func reload() {
        let u = url
        let hidden = showHidden
        let t = UUID(); loadToken = t
        accessDenied = false
        // never leave the previous folder's files on screen while this one loads
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if self.loadToken == t { self.items = []; self.waiting = true } }
        Work.quick.async {
            var denied = false
            do { _ = try FileManager.default.contentsOfDirectory(atPath: u.path) }
            catch { denied = (error as NSError).code == NSFileReadNoPermissionError }
            let list = denied ? [] : FS.list(u, showHidden: hidden)
            let branch = denied ? nil : FS.gitBranch(u)
            DispatchQueue.main.async {
                guard self.url == u, self.loadToken == t else { return }
                self.loadToken = UUID()
                self.waiting = false
                self.accessDenied = denied
                self.items = Self.sorted(list, by: self.sortOrder)
                self.gitBranch = branch
                let present = Set(list.map(\.url))
                self.selection = self.selection.filter { present.contains($0) }
            }
        }
    }
}

/// Toast with a one-tap Undo — every destructive action in the app goes through here.
final class UndoCenter: ObservableObject {
    static let shared = UndoCenter()

    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let undo: (() -> Void)?
    }

    @Published var toast: Toast?

    func show(_ message: String, undo: (() -> Void)? = nil) {
        let t = Toast(message: message, undo: undo)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }
}
