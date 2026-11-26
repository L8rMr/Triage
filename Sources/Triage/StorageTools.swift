import SwiftUI
import AppKit
import CryptoKit

// MARK: - Shared: trash with a safety check

enum SafeTrash {
    /// Trash with Undo; risky items need confirmation first (handled by callers via verdicts).
    static func trash(_ urls: [URL], label: String, then: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let moved = FileOps.trash(urls)
            DispatchQueue.main.async {
                then()
                let bytes = moved.reduce(Int64(0)) { $0 + FS.size(of: $1.to) }
                UndoCenter.shared.show("Moved \(moved.count) \(label) (\(Fmt.bytes(bytes))) to the Trash") {
                    FileOps.moveBack(moved); then()
                }
            }
        }
    }
}

// MARK: - Disk Map

struct DiskNode: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let isDir: Bool
    var id: URL { url }
    var name: String { url.path == "/" ? "Macintosh HD" : url.lastPathComponent }
}

final class DiskMapModel: ObservableObject {
    @Published var root: URL = Places.home
    @Published var nodes: [DiskNode] = []
    @Published var loading = false
    @Published var scanned = 0
    private var cache: [String: [DiskNode]] = [:]
    private var token = UUID()

    func load(_ u: URL, force: Bool = false) {
        root = u
        if !force, let c = cache[u.path] { nodes = c; loading = false; return }
        let t = UUID(); token = t
        loading = true; nodes = []; scanned = 0
        Work.quick.async {
            let kids = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            var out: [DiskNode] = []
            let lock = NSLock()
            let group = DispatchGroup()
            for k in kids {
                group.enter()
                Work.heavy.addOperation {
                    defer { group.leave() }
                    guard self.token == t else { return }
                    let n = DiskNode(url: k, size: FS.size(of: k), isDir: FS.isFolder(k))
                    lock.lock(); out.append(n); let snap = out.sorted { $0.size > $1.size }; let c = out.count; lock.unlock()
                    DispatchQueue.main.async { if self.token == t { self.nodes = snap; self.scanned = c } }
                }
            }
            group.wait()
            guard self.token == t else { return }
            let done = out.filter { $0.size > 0 }.sorted { $0.size > $1.size }
            DispatchQueue.main.async {
                guard self.token == t else { return }
                self.cache[u.path] = done
                self.nodes = done
                self.loading = false
            }
        }
    }
}

enum Treemap {
    /// Squarified treemap: keeps tiles close to square so they're easy to read and click.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max($0 * scale, 0.0001) }
        var out: [CGRect] = []
        var r = rect
        var row: [Double] = []
        func worst(_ row: [Double], _ w: Double) -> Double {
            let s = row.reduce(0, +)
            guard let mx = row.max(), let mn = row.min(), s > 0, w > 0 else { return .infinity }
            return max(w * w * mx / (s * s), (s * s) / (w * w * mn))
        }
        func place(_ row: [Double]) {
            let s = row.reduce(0, +)
            if r.width >= r.height {
                let colW = CGFloat(s) / r.height
                var y = r.minY
                for a in row { let h = CGFloat(a) / colW; out.append(CGRect(x: r.minX, y: y, width: colW, height: h)); y += h }
                r = CGRect(x: r.minX + colW, y: r.minY, width: max(r.width - colW, 0), height: r.height)
            } else {
                let rowH = CGFloat(s) / r.width
                var x = r.minX
                for a in row { let w = CGFloat(a) / rowH; out.append(CGRect(x: x, y: r.minY, width: w, height: rowH)); x += w }
                r = CGRect(x: r.minX, y: r.minY + rowH, width: r.width, height: max(r.height - rowH, 0))
            }
        }
        var i = 0
        while i < areas.count {
            let w = Double(min(r.width, r.height))
            if row.isEmpty || worst(row + [areas[i]], w) <= worst(row, w) {
                row.append(areas[i]); i += 1
            } else {
                place(row); row = []
            }
        }
        if !row.isEmpty { place(row) }
        return out
    }
}

struct DiskMapView: View {
    @StateObject private var m = DiskMapModel()
    @EnvironmentObject var model: AppModel
    @State private var hovered: URL?
    @State private var confirm: DiskNode?

    private var shown: [DiskNode] { Array(m.nodes.prefix(60)) }
    private var total: Int64 { m.nodes.reduce(0) { $0 + $1.size } }

    var body: some View {
        ToolPage(tool: .diskmap, trailing: {
            HStack {
                Menu {
                    Button("Home folder") { m.load(Places.home) }
                    Button("Whole disk") { m.load(URL(fileURLWithPath: "/")) }
                    Divider()
                    ForEach(Places.favorites + model.pinned, id: \.self) { u in Button(Places.name(u)) { m.load(u) } }
                    Divider()
                    Button("Choose a folder…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { m.load(u) }
                    }
                } label: { Label("Map", systemImage: "scope") }
                .fixedSize()
                Button { m.load(m.root, force: true) } label: { Image(systemName: "arrow.clockwise") }
            }
        }) {
            HStack(spacing: 6) {
                ForEach(crumbs, id: \.self) { u in
                    Button(u.path == "/" ? "Macintosh HD" : (u.path == Places.home.path ? NSUserName() : u.lastPathComponent)) { m.load(u) }
                        .buttonStyle(.plain).font(.ui(size: 12, weight: u == m.root ? .semibold : .regular))
                    if u != m.root { Image(systemName: "chevron.right").font(.ui(size: 9)).foregroundStyle(.tertiary) }
                }
                Spacer()
                if m.loading { ProgressView().controlSize(.small); Text("Measuring… \(m.scanned) items").font(.ui(size: 11)).foregroundStyle(.secondary) }
                Text(Fmt.bytes(total)).font(.ui(size: 12, weight: .semibold))
            }
            HStack(alignment: .top, spacing: 14) {
                GeometryReader { g in
                    let rects = Treemap.layout(shown.map { Double($0.size) }, in: CGRect(origin: .zero, size: g.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, n in
                            if i < rects.count { tile(n, rects[i]) }
                        }
                    }
                }
                .frame(minHeight: 360)
                .glass(12)
                list.frame(width: 280)
            }
        }
        .onAppear { if m.nodes.isEmpty && !m.loading { m.load(m.root) } }
        .confirmationDialog("Move \(confirm?.name ?? "") to the Trash?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let c = confirm { SafeTrash.trash([c.url], label: "item") { m.load(m.root, force: true) } }
                confirm = nil
            }
        } message: {
            Text(confirm.map { DeleteAdvisor.assess($0.url).reasons.joined(separator: " ") } ?? "")
        }
    }

    private var crumbs: [URL] {
        var out: [URL] = []
        var u = m.root.standardizedFileURL
        for _ in 0..<30 {
            out.insert(u, at: 0)
            if u.path == "/" || u.path == Places.home.path { break }
            u = u.deletingLastPathComponent()
        }
        return out
    }

    private func color(_ n: DiskNode) -> Color {
        if n.isDir { return Theme.cpu }
        switch FileKind.of(n.url.pathExtension) {
        case .images, .videos, .audio: return Theme.mem
        case .installers, .archives: return Theme.net
        case .documents: return Theme.good
        case .code: return Theme.heat
        default: return Color.gray
        }
    }

    private func tile(_ n: DiskNode, _ r: CGRect) -> some View {
        let c = color(n)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(c.opacity(hovered == n.url ? 0.55 : 0.32))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(c.opacity(0.7), lineWidth: 0.5)
            if r.width > 70 && r.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.name).font(.ui(size: 11, weight: .semibold)).lineLimit(1)
                    Text(Fmt.bytes(n.size)).font(.ui(size: 10)).foregroundStyle(.secondary)
                }
                .padding(6)
            }
        }
        .frame(width: max(r.width - 2, 0), height: max(r.height - 2, 0))
        .offset(x: r.minX + 1, y: r.minY + 1)
        .onHover { hovered = $0 ? n.url : (hovered == n.url ? nil : hovered) }
        .onTapGesture { if n.isDir { m.load(n.url) } else { NSWorkspace.shared.activateFileViewerSelecting([n.url]) } }
        .help("\(n.name)\n\(Fmt.bytes(n.size))\(n.isDir ? "\nClick to open" : "")")
        .contextMenu { menu(n) }
    }

    @ViewBuilder private func menu(_ n: DiskNode) -> some View {
        if n.isDir { Button("Map this folder") { m.load(n.url) } }
        Button("Open in Files") { model.route = .files; model.active.go(n.isDir ? n.url : n.url.deletingLastPathComponent()) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
        Divider()
        Button("Move to Trash…", role: .destructive) { confirm = n }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BIGGEST ITEMS").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                .padding(12)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(m.nodes.prefix(40)) { n in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path)).resizable().frame(width: 16, height: 16)
                            Text(n.name).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            SafetyBadge(url: n.url)
                            Text(Fmt.bytes(n.size)).font(.ui(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(hovered == n.url ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? n.url : (hovered == n.url ? nil : hovered) }
                        .onTapGesture { if n.isDir { m.load(n.url) } }
                        .contextMenu { menu(n) }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .glass(12)
    }
}

// MARK: - Duplicate Finder

struct DupFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: URL { url }
}

final class DupModel: ObservableObject {
    @Published var root: URL = Places.home
    @Published var groups: [[DupFile]] = []
    @Published var scanning = false
    @Published var status = ""
    @Published var marked: Set<URL> = []
    @Published var minSizeMB = 1.0
    private var cancel = false

    var wasted: Int64 { groups.reduce(0) { $0 + $1.dropFirst().reduce(0) { $0 + $1.size } } }
    var markedBytes: Int64 { groups.flatMap { $0 }.filter { marked.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func stop() { cancel = true }

    func scan() {
        cancel = false
        scanning = true; groups = []; marked = []; status = "Listing files…"
        let root = self.root, minSize = Int64(minSizeMB * 1_000_000)
        DispatchQueue.global(qos: .userInitiated).async {
            var bySize: [Int64: [DupFile]] = [:]
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
            var count = 0
            while let u = e?.nextObject() as? URL {
                if self.cancel { break }
                if u.path.contains("/Library/") || u.path.contains("/node_modules/") { e?.skipDescendants(); continue }
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let s = v.fileSize, Int64(s) >= minSize else { continue }
                bySize[Int64(s), default: []].append(DupFile(url: u, size: Int64(s), modified: v.contentModificationDate ?? .distantPast))
                count += 1
                if count % 500 == 0 { DispatchQueue.main.async { self.status = "Looked at \(count) files…" } }
            }
            let candidates = bySize.values.filter { $0.count > 1 }
            var found: [[DupFile]] = []
            for (i, group) in candidates.enumerated() {
                if self.cancel { break }
                if i % 20 == 0 { DispatchQueue.main.async { self.status = "Comparing contents… \(i)/\(candidates.count)" } }
                var byHead: [String: [DupFile]] = [:]
                for f in group { if let h = Self.hash(f.url, limit: 65_536) { byHead[h, default: []].append(f) } }
                for same in byHead.values where same.count > 1 {
                    var byFull: [String: [DupFile]] = [:]
                    for f in same { if let h = Self.hash(f.url, limit: nil) { byFull[h, default: []].append(f) } }
                    for d in byFull.values where d.count > 1 {
                        found.append(d.sorted { $0.modified < $1.modified })   // oldest first = the original
                    }
                }
            }
            found.sort { ($0.first?.size ?? 0) * Int64($0.count - 1) > ($1.first?.size ?? 0) * Int64($1.count - 1) }
            DispatchQueue.main.async {
                self.groups = found
                self.marked = Set(found.flatMap { $0.dropFirst().map(\.url) })
                self.scanning = false
                self.status = found.isEmpty ? "No duplicates over \(Int(self.minSizeMB)) MB." : ""
            }
        }
    }

    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            let chunk = h.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            read += chunk.count
            if let limit, read >= limit { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func keep(_ rule: String) {
        marked = []
        for g in groups {
            let keep: DupFile?
            switch rule {
            case "newest": keep = g.max { $0.modified < $1.modified }
            case "shortest": keep = g.min { $0.url.path.count < $1.url.path.count }
            default: keep = g.min { $0.modified < $1.modified }
            }
            for f in g where f.url != keep?.url { marked.insert(f.url) }
        }
    }
}

struct DuplicatesView: View {
    @StateObject private var m = DupModel()
    @State private var confirm = false

    var body: some View {
        ToolPage(tool: .duplicates, subtitle: "Compares file contents, not just names. One copy in every group is always kept.", trailing: {
            HStack {
                Button { pick() } label: { Label(Places.name(m.root), systemImage: "folder") }
                Picker("", selection: $m.minSizeMB) {
                    Text("Over 100 KB").tag(0.1); Text("Over 1 MB").tag(1.0); Text("Over 10 MB").tag(10.0); Text("Over 100 MB").tag(100.0)
                }
                .labelsHidden().fixedSize()
                if m.scanning { Button("Stop") { m.stop() } } else { Button("Scan") { m.scan() }.buttonStyle(.borderedProminent) }
            }
        }) {
            if m.scanning || !m.status.isEmpty {
                HStack { if m.scanning { ProgressView().controlSize(.small) }; Text(m.status).foregroundStyle(.secondary) }.font(.ui(size: 12))
            }
            if !m.groups.isEmpty {
                HStack {
                    Text("\(m.groups.count) groups · \(Fmt.bytes(m.wasted)) in extra copies").font(.ui(size: 13, weight: .semibold))
                    Spacer()
                    Menu("Keep in each group") {
                        Button("The oldest (likely the original)") { m.keep("oldest") }
                        Button("The newest") { m.keep("newest") }
                        Button("The one with the shortest path") { m.keep("shortest") }
                    }
                    .fixedSize()
                    Button("Move \(m.marked.count) copies to Trash (\(Fmt.bytes(m.markedBytes)))") { confirm = true }
                        .buttonStyle(.borderedProminent).disabled(m.marked.isEmpty)
                }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(m.groups, id: \.first!.url) { g in group(g) }
                    }
                }
            } else if !m.scanning && m.status.isEmpty {
                empty("Pick a folder and press Scan. Your Library and code dependencies are skipped.")
            }
        }
        .confirmationDialog("Move \(m.marked.count) duplicate copies to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                let urls = Array(m.marked)
                SafeTrash.trash(urls, label: "duplicates") { m.scan() }
            }
        } message: { Text("One copy in each group stays where it is. You can undo this.") }
    }

    private func pick() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        if p.runModal() == .OK, let u = p.url { m.root = u }
    }

    private func group(_ g: [DupFile]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Thumb(url: g[0].url, size: 40).frame(width: 34, height: 34)
                Text(g[0].url.lastPathComponent).font(.ui(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(g.count) copies · \(Fmt.bytes(g[0].size)) each").font(.ui(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(g) { f in
                let marked = m.marked.contains(f.url)
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { marked }, set: { on in
                        if on {
                            // never let every copy be marked
                            if g.filter({ m.marked.contains($0.url) }).count < g.count - 1 { m.marked.insert(f.url) }
                        } else { m.marked.remove(f.url) }
                    }))
                    .labelsHidden().toggleStyle(.checkbox)
                    Text(marked ? "Trash" : "Keep").font(.ui(size: 10, weight: .semibold))
                        .foregroundStyle(marked ? Theme.warn : Theme.good).frame(width: 36, alignment: .leading)
                    Text(Places.abbreviate(f.url.deletingLastPathComponent().path)).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(f.modified, format: .dateTime.month().day().year()).font(.ui(size: 11)).foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Keep Only This Copy") {
                        for o in g { if o.url == f.url { m.marked.remove(o.url) } else { m.marked.insert(o.url) } }
                    }
                    Button("Open") { NSWorkspace.shared.open(f.url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.url.path, forType: .string) }
                }
            }
        }
        .padding(12)
        .glass(12)
    }
}

func empty(_ text: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: "sparkles").font(.ui(size: 28)).foregroundStyle(.tertiary)
        Text(text).font(.ui(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity).padding(40)
}

// MARK: - Forgotten Files

struct ForgottenItem: Identifiable {
    let url: URL
    let size: Int64
    let lastUsed: Date?
    let modified: Date
    var id: URL { url }
    var touched: Date { lastUsed ?? modified }
}

final class ForgottenModel: NSObject, ObservableObject {
    @Published var items: [ForgottenItem] = []
    @Published var searching = false
    @Published var months = 12
    @Published var minMB = 50
    private let query = NSMetadataQuery()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            self?.collect()
        }
    }

    func run() {
        query.stop()
        searching = true
        let days = months * 30, bytes = minMB * 1_000_000
        query.predicate = NSPredicate(fromMetadataQueryString:
            "kMDItemFSSize > \(bytes) && kMDItemContentTypeTree != \"com.apple.application-bundle\" && kMDItemContentTypeTree != \"public.folder\" && (kMDItemLastUsedDate < $time.today(-\(days)) || kMDItemFSContentChangeDate < $time.today(-\(days)))")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.start()
    }

    private func collect() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let cutoff = Date().addingTimeInterval(-Double(months) * 30 * 86_400)
        var out: [ForgottenItem] = []
        for i in 0..<min(query.resultCount, 3000) {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String,
                  !path.contains("/Library/"), !path.contains("/.") else { continue }
            let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            let mod = item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date ?? .distantPast
            if let used, used > cutoff { continue }
            if used == nil && mod > cutoff { continue }
            let size = (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value ?? 0
            out.append(ForgottenItem(url: URL(fileURLWithPath: path), size: size, lastUsed: used, modified: mod))
        }
        items = out
        searching = false
    }
}

struct ForgottenView: View {
    @StateObject private var m = ForgottenModel()
    @State private var sort = ColumnSort(key: "size", ascending: false)
    @State private var fName = ""
    @State private var fKinds: Set<String> = []
    @State private var fSizes: Set<String> = []
    @State private var fWhere: Set<String> = []
    @State private var marked: Set<URL> = []
    @State private var confirm = false

    private func place(_ u: URL) -> String {
        let p = u.path, h = Places.home.path
        for f in ["Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music", "Projects"] where p.hasPrefix("\(h)/\(f)/") { return f }
        if p.hasPrefix(Places.iCloud.path) { return "iCloud Drive" }
        return "Elsewhere"
    }

    private var visible: [ForgottenItem] {
        let l = m.items.filter {
            TextFilter.matches($0.url.lastPathComponent, fName)
                && (fKinds.isEmpty || fKinds.contains(FileKind.of($0.url.pathExtension).rawValue))
                && (fSizes.isEmpty || fSizes.contains(SizeBucket.of($0.size).rawValue))
                && (fWhere.isEmpty || fWhere.contains(place($0.url)))
        }
        let s: [ForgottenItem]
        switch sort.key {
        case "name": s = l.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        case "date": s = l.sorted { $0.touched < $1.touched }
        default: s = l.sorted { $0.size < $1.size }
        }
        return sort.ascending ? s : s.reversed()
    }

    private func options(_ values: [String]) -> [FilterOption] {
        var c: [String: Int] = [:]
        values.forEach { c[$0, default: 0] += 1 }
        return c.sorted { $0.value > $1.value }.map { FilterOption(id: $0.key, label: $0.key, count: $0.value) }
    }

    var body: some View {
        ToolPage(tool: .forgotten, trailing: {
            HStack {
                Picker("", selection: $m.months) { Text("Untouched 6 months").tag(6); Text("Untouched 1 year").tag(12); Text("Untouched 2 years").tag(24) }
                    .labelsHidden().fixedSize()
                Picker("", selection: $m.minMB) { Text("Over 10 MB").tag(10); Text("Over 50 MB").tag(50); Text("Over 500 MB").tag(500) }
                    .labelsHidden().fixedSize()
                Button("Find") { m.run() }.buttonStyle(.borderedProminent)
            }
        }) {
            HStack {
                Text("\(visible.count) files · \(Fmt.bytes(visible.reduce(0) { $0 + $1.size }))").font(.ui(size: 13, weight: .semibold))
                if m.searching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Move \(marked.count) to Trash") { confirm = true }.disabled(marked.isEmpty)
            }
            TableBox(footer: "Ticked files go to the Trash with Undo. The dot shows whether each one looks safe to delete.") {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 26, height: 1)
                    ColumnHeader("Name", sortKey: "name", sort: $sort, text: $fName)
                    ColumnHeader("Kind", width: 110, sort: $sort, options: options(m.items.map { FileKind.of($0.url.pathExtension).rawValue }), selection: $fKinds)
                    ColumnHeader("Where", width: 110, sort: $sort, options: options(m.items.map { place($0.url) }), selection: $fWhere)
                    ColumnHeader("Size", width: 90, sortKey: "size", sort: $sort, options: FilterOption.sizes(m.items.map(\.size)), selection: $fSizes, defaultAscending: false)
                    ColumnHeader("Last touched", width: 130, sortKey: "date", sort: $sort)
                    ColumnHeader("Safe?", width: 60, sort: $sort)
                }
            } rows: {
                ForEach(visible) { it in
                    HStack(spacing: 0) {
                        Toggle("", isOn: Binding(get: { marked.contains(it.url) }, set: { if $0 { marked.insert(it.url) } else { marked.remove(it.url) } }))
                            .labelsHidden().toggleStyle(.checkbox).frame(width: 26, alignment: .leading)
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: it.url.path)).resizable().frame(width: 16, height: 16)
                            Text(it.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                        Text(FileKind.of(it.url.pathExtension).rawValue).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(place(it.url)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(Fmt.bytes(it.size)).monospacedDigit().frame(width: 90, alignment: .leading)
                        Text(it.touched, format: .relative(presentation: .named)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        SafetyBadge(url: it.url).frame(width: 60, alignment: .leading)
                    }
                    .font(.ui(size: 12))
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
                    .contextMenu {
                        Button("Open") { NSWorkspace.shared.open(it.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
                        Button(marked.contains(it.url) ? "Untick" : "Tick for Trash") {
                            if marked.contains(it.url) { marked.remove(it.url) } else { marked.insert(it.url) }
                        }
                        Divider()
                        Button("Move to Trash") { SafeTrash.trash([it.url], label: "file") { m.run() } }
                    }
                }
            }
        }
        .onAppear { if m.items.isEmpty { m.run() } }
        .confirmationDialog("Move \(marked.count) files to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                SafeTrash.trash(Array(marked), label: "files") { marked = []; m.run() }
            }
        } message: { Text("You can undo this from the message that appears.") }
    }
}

// MARK: - App Uninstaller

struct InstalledApp: Identifiable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    var size: Int64 = 0
    var lastUsed: Date?
    var leftovers: [URL] = []
    var leftoverBytes: Int64 = 0
    var id: URL { url }
}

final class UninstallModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false

    func load() {
        loading = true
        Work.quick.async {
            var out: [InstalledApp] = []
            for dir in ["/Applications", Places.home.appendingPathComponent("Applications").path] {
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".app") {
                    let u = URL(fileURLWithPath: dir).appendingPathComponent(f)
                    let b = Bundle(url: u)
                    var a = InstalledApp(url: u, name: String(f.dropLast(4)), bundleID: b?.bundleIdentifier,
                                         version: b?.infoDictionary?["CFBundleShortVersionString"] as? String)
                    a.lastUsed = NSMetadataItem(url: u)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
                    out.append(a)
                }
            }
            out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.apps = out }
            // sizes + leftovers fill in progressively, a few at a time
            let group = DispatchGroup()
            for i in out.indices {
                group.enter()
                Work.heavy.addOperation {
                    defer { group.leave() }
                    var a = out[i]
                    a.size = FS.size(of: a.url)
                    a.leftovers = Self.leftovers(name: a.name, id: a.bundleID)
                    a.leftoverBytes = a.leftovers.reduce(0) { $0 + FS.size(of: $1) }
                    DispatchQueue.main.async { if let j = self.apps.firstIndex(where: { $0.url == a.url }) { self.apps[j] = a } }
                }
            }
            group.wait()
            DispatchQueue.main.async { self.loading = false }
        }
    }

    static func leftovers(name: String, id: String?) -> [URL] {
        let lib = Places.home.appendingPathComponent("Library")
        var c: [URL] = []
        let keys = [name] + (id.map { [$0] } ?? [])
        for k in keys {
            c += [lib.appendingPathComponent("Application Support/\(k)"),
                  lib.appendingPathComponent("Caches/\(k)"),
                  lib.appendingPathComponent("Logs/\(k)"),
                  lib.appendingPathComponent("HTTPStorages/\(k)"),
                  lib.appendingPathComponent("WebKit/\(k)")]
        }
        if let id {
            c += [lib.appendingPathComponent("Preferences/\(id).plist"),
                  lib.appendingPathComponent("Containers/\(id)"),
                  lib.appendingPathComponent("Saved Application State/\(id).savedState"),
                  lib.appendingPathComponent("HTTPStorages/\(id).binarycookies")]
            let gc = lib.appendingPathComponent("Group Containers")
            for g in (try? FileManager.default.contentsOfDirectory(atPath: gc.path)) ?? [] where g.hasSuffix(id) {
                c.append(gc.appendingPathComponent(g))
            }
        }
        return Array(Set(c.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path))).sorted().map { URL(fileURLWithPath: $0) }
    }

    func uninstall(_ a: InstalledApp, done: @escaping () -> Void) {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL == a.url }?.terminate()
        let all = [a.url] + a.leftovers
        NSWorkspace.shared.recycle(all) { trashed, _ in
            DispatchQueue.main.async {
                let moved = trashed.map { Moved(from: $0.key, to: $0.value) }
                self.apps.removeAll { $0.url == a.url }
                UndoCenter.shared.show("Removed \(a.name) and \(a.leftovers.count) leftover item\(a.leftovers.count == 1 ? "" : "s")") {
                    FileOps.moveBack(moved); self.load()
                }
                done()
            }
        }
    }
}

struct UninstallerView: View {
    @StateObject private var m = UninstallModel()
    @State private var sort = ColumnSort(key: "size", ascending: false)
    @State private var fName = ""
    @State private var fUsed: Set<String> = []
    @State private var fSize: Set<String> = []
    @State private var selected: URL?
    @State private var confirm: InstalledApp?

    private func usedBucket(_ d: Date?) -> String {
        guard let d else { return "Never or unknown" }
        let age = -d.timeIntervalSinceNow / 86_400
        return age < 30 ? "This month" : age < 180 ? "Last 6 months" : age < 365 ? "6–12 months ago" : "Over a year ago"
    }

    private var visible: [InstalledApp] {
        let l = m.apps.filter {
            TextFilter.matches($0.name, fName)
                && (fUsed.isEmpty || fUsed.contains(usedBucket($0.lastUsed)))
                && (fSize.isEmpty || fSize.contains(SizeBucket.of($0.size + $0.leftoverBytes).rawValue))
        }
        let s: [InstalledApp]
        switch sort.key {
        case "name": s = l.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "used": s = l.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        default: s = l.sorted { $0.size + $0.leftoverBytes < $1.size + $1.leftoverBytes }
        }
        return sort.ascending ? s : s.reversed()
    }

    private var usedOptions: [FilterOption] {
        ["This month", "Last 6 months", "6–12 months ago", "Over a year ago", "Never or unknown"].map { b in
            FilterOption(id: b, label: b, symbol: "clock", count: m.apps.filter { usedBucket($0.lastUsed) == b }.count)
        }
    }

    var body: some View {
        ToolPage(tool: .uninstaller, trailing: {
            Button { m.load() } label: { Image(systemName: "arrow.clockwise") }
        }) {
            HStack(alignment: .top, spacing: 14) {
                TableBox(footer: "Tip: filter Last opened by “Over a year ago” to find apps you've forgotten about.") {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 30, height: 1)
                        ColumnHeader("App", sortKey: "name", sort: $sort, text: $fName)
                        ColumnHeader("Last opened", width: 130, sortKey: "used", sort: $sort, options: usedOptions, selection: $fUsed)
                        ColumnHeader("Size", width: 100, sortKey: "size", sort: $sort,
                                     options: FilterOption.sizes(m.apps.map { $0.size + $0.leftoverBytes }), selection: $fSize, defaultAscending: false)
                    }
                } rows: {
                    ForEach(visible) { a in
                        HStack(spacing: 0) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 22, height: 22).frame(width: 30, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).font(.ui(size: 12, weight: .medium)).lineLimit(1)
                                Text(a.version.map { "Version \($0)" } ?? "").font(.ui(size: 10)).foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                            Text(a.lastUsed.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "—")
                                .foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            Text(a.size == 0 ? "…" : Fmt.bytes(a.size + a.leftoverBytes)).monospacedDigit().frame(width: 100, alignment: .leading)
                        }
                        .font(.ui(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selected == a.url ? Theme.accent.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = a.url }
                        .contextMenu {
                            Button("Open \(a.name)") { NSWorkspace.shared.open(a.url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([a.url]) }
                            if !a.leftovers.isEmpty {
                                Button("Show Leftover Files") { NSWorkspace.shared.activateFileViewerSelecting(a.leftovers) }
                            }
                            Divider()
                            Button("Uninstall…", role: .destructive) { selected = a.url; confirm = a }
                        }
                    }
                }
                detail.frame(width: 300)
            }
        }
        .onAppear { if m.apps.isEmpty { m.load() } }
        .confirmationDialog("Uninstall \(confirm?.name ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Move App and Leftovers to Trash", role: .destructive) {
                if let a = confirm { m.uninstall(a) { selected = nil } }
                confirm = nil
            }
        } message: { Text("The app quits first. Everything goes to the Trash, and you can undo.") }
    }

    @ViewBuilder private var detail: some View {
        if let a = m.apps.first(where: { $0.url == selected }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading) {
                        Text(a.name).font(.ui(size: 15, weight: .semibold))
                        Text(a.bundleID ?? "").font(.ui(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack { Text("App"); Spacer(); Text(Fmt.bytes(a.size)) }.font(.ui(size: 12))
                HStack { Text("Leftovers"); Spacer(); Text(Fmt.bytes(a.leftoverBytes)) }.font(.ui(size: 12))
                Text("FILES IT LEAVES BEHIND").font(.ui(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                if a.leftovers.isEmpty {
                    Text("None found.").font(.ui(size: 11)).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(a.leftovers, id: \.self) { u in
                            Text(Places.abbreviate(u.path)).font(.ui(size: 10, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
                Spacer()
                Button("Uninstall \(a.name)…") { confirm = a }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            .padding(14).glass(12)
        } else {
            empty("Pick an app to see everything it installed.").glass(12)
        }
    }
}
