import SwiftUI
import AppKit

// MARK: - Free Up Space

struct CleanTarget: Identifiable {
    enum Source {
        case contents(URL)
        case files([URL])
        case trash
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let safe: Bool
    let source: Source
    var size: Int64?
    var count = 0
    /// What the size is made of, biggest first: the files and folders a clear would move to the Trash.
    var parts: [CleanPart] = []
}

struct CleanPart: Identifiable, Hashable {
    let url: URL
    let size: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum Cleaner {
    /// includeDownloads: reading Downloads can wait on a macOS permission prompt, so the rest of the list never waits for it.
    static func targets(includeDownloads: Bool = true) -> [CleanTarget] {
        let h = Places.home
        let lib = h.appendingPathComponent("Library")
        let dev = lib.appendingPathComponent("Developer")
        let ninetyDays = Date().addingTimeInterval(-90 * 86_400)
        let downloads = includeDownloads ? FS.list(Places.downloads, showHidden: false) : []
        let old = downloads.filter { $0.added < ninetyDays }.map(\.url)
        let big = downloads.filter { !$0.isDir && $0.size > 500_000_000 && $0.added >= ninetyDays }.map(\.url)

        return [
            CleanTarget(id: "derived", title: "Xcode DerivedData", detail: "Build products. Xcode rebuilds them next time.",
                        symbol: "hammer", safe: true, source: .contents(dev.appendingPathComponent("Xcode/DerivedData"))),
            CleanTarget(id: "simcache", title: "Simulator caches", detail: "CoreSimulator caches, recreated on demand.",
                        symbol: "iphone", safe: true, source: .contents(dev.appendingPathComponent("CoreSimulator/Caches"))),
            CleanTarget(id: "npm", title: "npm cache", detail: "Downloaded packages npm can fetch again.",
                        symbol: "shippingbox", safe: true, source: .contents(h.appendingPathComponent(".npm/_cacache"))),
            CleanTarget(id: "brew", title: "Homebrew downloads", detail: "Old bottles and installers left by brew.",
                        symbol: "mug", safe: true, source: .contents(lib.appendingPathComponent("Caches/Homebrew"))),
            CleanTarget(id: "pip", title: "pip cache", detail: "Python wheels pip keeps around.",
                        symbol: "chevron.left.forwardslash.chevron.right", safe: true,
                        source: .contents(lib.appendingPathComponent("Caches/pip"))),
            CleanTarget(id: "logs", title: "App logs", detail: "Diagnostic logs apps write and rarely read.",
                        symbol: "doc.text", safe: true, source: .contents(lib.appendingPathComponent("Logs"))),
            CleanTarget(id: "archives", title: "Xcode Archives", detail: "Old app builds. Keep any you may need to re-submit.",
                        symbol: "archivebox", safe: false, source: .contents(dev.appendingPathComponent("Xcode/Archives"))),
            CleanTarget(id: "olddl", title: "Downloads older than 90 days", detail: "Things you grabbed a season ago.",
                        symbol: "calendar.badge.clock", safe: false, source: .files(old)),
            CleanTarget(id: "bigdl", title: "Large recent downloads", detail: "Files over 500 MB from the last 90 days.",
                        symbol: "externaldrive.badge.exclamationmark", safe: false, source: .files(big)),
            CleanTarget(id: "trash", title: "Trash", detail: "Emptying is permanent. Triage will ask Finder to do it.",
                        symbol: "trash", safe: false, source: .trash),
        ]
    }

    static func resolve(_ s: CleanTarget.Source) -> [URL] {
        let fm = FileManager.default
        switch s {
        case .contents(let u): return (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
        case .files(let f): return f
        case .trash: return (try? fm.contentsOfDirectory(at: Places.home.appendingPathComponent(".Trash"), includingPropertiesForKeys: nil)) ?? []
        }
    }

    static func measure(_ t: CleanTarget) -> CleanTarget {
        var t = t
        let items = resolve(t.source)
        t.count = items.count
        t.parts = items.map { CleanPart(url: $0, size: FS.size(of: $0)) }.sorted { $0.size > $1.size }
        t.size = t.parts.reduce(0) { $0 + $1.size }
        return t
    }
}

struct CleanView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var targets: [CleanTarget] = []
    @State private var confirm: CleanTarget?
    @State private var working: String?
    @State private var sort = ColumnSort(key: "size", ascending: false)
    /// nil until you touch a checkbox: then "everything safe" is the default pick.
    @State private var checked: Set<String>?
    @State private var confirmPicked = false
    /// Opened suggestions, and per-suggestion picks when you've chosen only some of its items.
    @State private var expanded: Set<String> = []
    @State private var partPicks: [String: Set<URL>] = [:]

    private var pickedIDs: Set<String> { checked ?? Set(targets.filter(\.safe).map(\.id)) }
    private var picked: [CleanTarget] { targets.filter { pickedIDs.contains($0.id) && $0.id != "trash" && ($0.size ?? 0) > 0 } }
    private func bytes(_ t: CleanTarget) -> Int64 {
        if let p = partPicks[t.id] { return t.parts.filter { p.contains($0.url) }.reduce(0) { $0 + $1.size } }
        return t.size ?? 0
    }
    private var pickedBytes: Int64 { picked.reduce(0) { $0 + bytes($1) } }
    private func toggle(_ t: CleanTarget) {
        var s = pickedIDs
        if s.contains(t.id) && partPicks[t.id] == nil { s.remove(t.id) } else { s.insert(t.id) }
        partPicks[t.id] = nil
        checked = s
    }
    private func isPartPicked(_ t: CleanTarget, _ p: CleanPart) -> Bool {
        guard pickedIDs.contains(t.id) else { return false }
        return partPicks[t.id]?.contains(p.url) ?? true
    }
    private func togglePart(_ t: CleanTarget, _ p: CleanPart) {
        let all = Set(t.parts.map(\.url))
        var set = partPicks[t.id] ?? (pickedIDs.contains(t.id) ? all : [])
        if set.contains(p.url) { set.remove(p.url) } else { set.insert(p.url) }
        setParts(t, set)
    }
    private func setParts(_ t: CleanTarget, _ set: Set<URL>) {
        var s = pickedIDs
        if set.isEmpty { s.remove(t.id); partPicks[t.id] = nil }
        else if set.count == t.parts.count { s.insert(t.id); partPicks[t.id] = nil }
        else { s.insert(t.id); partPicks[t.id] = set }
        checked = s
    }
    private func clearPicked() {
        if picked.contains(where: { !$0.safe }) { confirmPicked = true } else { clearMany(picked); checked = nil; partPicks = [:] }
    }
    @State private var fName = ""
    @State private var fSizes: Set<String> = []

    private var sizeOptions: [FilterOption] { FilterOption.sizes(targets.compactMap(\.size)) }

    private func arranged(_ items: [CleanTarget]) -> [CleanTarget] {
        var list = items
        let q = fName.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if !q.isEmpty { list = list.filter { t in q.contains { (t.title + " " + t.detail).lowercased().contains($0) } } }
        if !fSizes.isEmpty { list = list.filter { t in fSizes.contains(SizeBucket.of(t.size ?? 0).rawValue) } }
        list.sort { a, b in
            let r: Bool
            switch sort.key {
            case "name": r = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case "count": r = a.count < b.count
            default: r = (a.size ?? -1) < (b.size ?? -1)
            }
            return sort.ascending ? r : !r
        }
        return list
    }

    private var reclaimable: Int64 { targets.filter(\.safe).compactMap(\.size).reduce(0, +) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "Free Up Space",
                          subtitle: "Everything goes to the Trash first, and every clear has an Undo.")

                HStack(spacing: 22) {
                    ZStack {
                        Ring(value: monitor.snap.diskUsedFraction, color: Theme.load(monitor.snap.diskUsedFraction * 100), lineWidth: 12)
                        VStack(spacing: 0) {
                            Text(Fmt.bytes(monitor.snap.diskFree)).font(.ui(size: 16, weight: .semibold, design: .rounded))
                            Text("free").font(.ui(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(targets.isEmpty || targets.contains { $0.size == nil } ? "Measuring…" : "\(Fmt.bytes(reclaimable)) comes back on its own")
                            .font(.ui(size: 22, weight: .semibold, design: .rounded))
                        Text("Ticked items are safe: caches and build products your apps quietly recreate. Tick anything marked Your call to add it.")
                            .font(.ui(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(working ?? (pickedBytes > 0 ? "Clear \(Fmt.bytes(pickedBytes))" : "Nothing ticked")) { clearPicked() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                            .disabled(pickedBytes == 0 || working != nil)
                    }
                    Spacer()
                }
                .padding(18)
                .glass()

                HStack(spacing: 14) {
                    Color.clear.frame(width: 26, height: 1)
                    ColumnHeader("Item", sortKey: "name", sort: $sort, text: $fName)
                    ColumnHeader("Size", width: 90, sortKey: "size", sort: $sort, options: sizeOptions, selection: $fSizes, defaultAscending: false)
                    ColumnHeader("Items", width: 64, sortKey: "count", sort: $sort, defaultAscending: false)
                    Color.clear.frame(width: 90, height: 1)
                }
                .padding(.horizontal, 14)
                if !fName.isEmpty || !fSizes.isEmpty {
                    Button("Clear filters") { fName = ""; fSizes = [] }.buttonStyle(.borderless).font(.ui(size: 11))
                }
                section("\(targets.count) suggestions", arranged(targets))
            }
            .padding(28)
            .padding(.top, 8)
        }
        .task { await refresh() }
        .confirmationDialog("Clear \(Fmt.bytes(pickedBytes))?", isPresented: $confirmPicked) {
            Button("Move to Trash", role: .destructive) { clearMany(picked); checked = nil; partPicks = [:] }
        } message: {
            Text("Includes items marked Your call: " + picked.filter { !$0.safe }.map(\.title).joined(separator: ", ") + ". You can Undo right after.")
        }
        .confirmationDialog(confirm.map { "Clear \($0.title)?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm?.id == "trash" ? "Empty Trash" : "Move to Trash", role: .destructive) {
                if let t = confirm { clear(t) }
                confirm = nil
            }
        } message: {
            Text(confirm?.id == "trash" ? "This can't be undone." : "You can Undo this right after.")
        }
    }

    private func section(_ title: String, _ items: [CleanTarget]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            ForEach(items) { t in
                HStack(spacing: 14) {
                    if t.id == "trash" {
                        Image(systemName: t.symbol).font(.ui(size: 16)).foregroundStyle(Theme.net).frame(width: 26)
                    } else {
                        Button { toggle(t) } label: {
                            Image(systemName: !pickedIDs.contains(t.id) ? "square" : partPicks[t.id] != nil ? "minus.square.fill" : "checkmark.square.fill")
                                .font(.system(size: 18)).foregroundStyle(pickedIDs.contains(t.id) ? Theme.accent : Color.secondary)
                                .frame(width: 26)
                        }
                        .buttonStyle(.plain).help(pickedIDs.contains(t.id) ? "Untick to keep" : "Tick to clear")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(t.title).font(.ui(size: 13, weight: .semibold))
                            if !t.parts.isEmpty {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(expanded.contains(t.id) ? 90 : 0))
                            }
                        }
                        Text(partPicks[t.id].map { "\($0.count) of \(t.parts.count) picked · \(Fmt.bytes(bytes(t)))" } ?? t.detail)
                            .font(.ui(size: 11)).foregroundStyle(partPicks[t.id] != nil ? Theme.accent : Color.secondary)
                    }
                    Spacer()
                    Text(t.safe ? "Comes back on its own" : "Your call")
                        .font(.ui(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((t.safe ? Theme.good : Theme.heat).opacity(0.15), in: Capsule())
                        .foregroundStyle(t.safe ? Theme.good : Theme.heat)
                    if let s = t.size {
                        Text(t.id == "trash" && t.count == 0 ? "—" : Fmt.bytes(s))
                            .font(.ui(size: 13, weight: .medium)).monospacedDigit()
                        Text("\(t.count) item\(t.count == 1 ? "" : "s")").font(.ui(size: 11)).foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if t.id == "trash" {
                        Button("Empty") { confirm = t }.disabled(working != nil || t.count == 0).frame(width: 64)
                    }
                    if t.id != "trash", case .contents(let u) = t.source {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(.borderless).help("Show in Finder")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !t.parts.isEmpty else { return }
                    withAnimation(.snappy(duration: 0.22)) { if expanded.contains(t.id) { expanded.remove(t.id) } else { expanded.insert(t.id) } }
                }
                .modifier(Accordion(open: expanded.contains(t.id) && !t.parts.isEmpty) { breakdown(t) })
                .glass(12)
                .contextMenu {
                    Button(t.id == "trash" ? "Empty Trash…" : "Clear") { if t.safe { clear(t) } else { confirm = t } }
                        .disabled(t.id != "trash" && (t.size ?? 0) == 0)
                    if case .contents(let u) = t.source {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                    }
                    if case .files(let f) = t.source, !f.isEmpty {
                        Button("Show \(f.count) Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting(f) }
                    }
                    Button("Measure Again") { Task { await refresh() } }
                }
            }
        }
    }

    /// What's inside a suggestion: every file or folder, its size, and a tick box.
    private func breakdown(_ t: CleanTarget) -> some View {
        let shown = Array(t.parts.prefix(300))
        let selectable = t.id != "trash"
        return VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Text("\(t.parts.count) item\(t.parts.count == 1 ? "" : "s") make up \(Fmt.bytes(t.size ?? 0))")
                    .font(.ui(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if selectable {
                    Button("Select all") { setParts(t, Set(t.parts.map(\.url))) }.buttonStyle(.borderless).font(.ui(size: 11))
                    Button("None") { setParts(t, []) }.buttonStyle(.borderless).font(.ui(size: 11))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            ForEach(shown) { p in
                HStack(spacing: 10) {
                    if selectable {
                        Button { togglePart(t, p) } label: {
                            Image(systemName: isPartPicked(t, p) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 14)).foregroundStyle(isPartPicked(t, p) ? Theme.accent : Color.secondary)
                        }.buttonStyle(.plain)
                    }
                    Image(nsImage: NSWorkspace.shared.icon(forFile: p.url.path)).resizable().frame(width: 16, height: 16)
                    Text(p.name).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Fmt.bytes(p.size)).font(.ui(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([p.url]) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { if selectable { togglePart(t, p) } }
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.url.path, forType: .string) }
                }
            }
            if t.parts.count > shown.count {
                Text("…and \(t.parts.count - shown.count) smaller items (\(Fmt.bytes(t.parts.dropFirst(shown.count).reduce(0) { $0 + $1.size })))")
                    .font(.ui(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
        .padding(.bottom, 8)
    }

    private func refresh() async {
        // everything except Downloads shows up immediately
        let quick = await Work.run { Cleaner.targets(includeDownloads: false) }
        if targets.isEmpty { targets = quick }
        let base = await Work.run { Cleaner.targets() }
        targets = base
        for t in base {
            let measured = await Work.runHeavy { Cleaner.measure(t) }
            if let i = targets.firstIndex(where: { $0.id == measured.id }) { targets[i] = measured }
        }
    }

    private func clear(_ t: CleanTarget) {
        if case .trash = t.source {
            FileOps.emptyTrash()
            UndoCenter.shared.show("Asked Finder to empty the Trash")
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await refresh() }
            return
        }
        clearMany([t])
    }

    private func clearAllSafe() { clearMany(targets.filter(\.safe)) }

    private func clearMany(_ list: [CleanTarget]) {
        let urls = list.flatMap { t in partPicks[t.id].map { Array($0) } ?? Cleaner.resolve(t.source) }
        guard !urls.isEmpty else { return }
        let freed = list.reduce(0) { $0 + bytes($1) }
        working = "Clearing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let moved = FileOps.trash(urls)
            DispatchQueue.main.async {
                working = nil
                Task { await refresh() }
                UndoCenter.shared.show("Moved \(Fmt.bytes(freed)) to the Trash") {
                    FileOps.moveBack(moved)
                    Task { await refresh() }
                }
            }
        }
    }
}

// MARK: - Tidy Downloads

enum FileKind: String, CaseIterable {
    case images = "Images", videos = "Videos", audio = "Audio", documents = "Documents"
    case archives = "Archives", installers = "Installers", code = "Code", other = "Other"

    var symbol: String {
        switch self {
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "waveform"
        case .documents: return "doc.richtext"
        case .archives: return "doc.zipper"
        case .installers: return "shippingbox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "questionmark.folder"
        }
    }

    static func of(_ ext: String) -> FileKind {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg", "raw", "psd": return .images
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": return .videos
        case "mp3", "m4a", "wav", "aiff", "flac", "aac", "ogg": return .audio
        case "pdf", "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "md", "epub": return .documents
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz": return .archives
        case "dmg", "pkg", "mpkg", "app", "iso": return .installers
        case "swift", "py", "js", "ts", "json", "html", "css", "sh", "yml", "yaml", "xml", "sql", "ipynb", "rb", "go", "rs": return .code
        default: return .other
        }
    }
}

struct TidyItem: Identifiable {
    let url: URL
    let size: Int64
    let kind: FileKind
    let flags: [String]
    let added: Date
    let source: String?
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum Tidier {
    static let inProgress: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    static func plan() -> [TidyItem] {
        let fm = FileManager.default
        let items = FS.list(Places.downloads, showHidden: false).filter { !$0.isDir || $0.url.pathExtension == "app" }
        let names = Set(items.map { $0.name.lowercased() })
        let apps = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []).map { $0.lowercased() }
        let ninety = Date().addingTimeInterval(-90 * 86_400)

        return items.compactMap { f in
            let ext = f.url.pathExtension.lowercased()
            if inProgress.contains(ext) { return nil }
            let kind = FileKind.of(ext)
            var flags: [String] = []
            if kind == .installers {
                let token = f.name.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
                if token.count > 2, apps.contains(where: { $0.hasPrefix(token) }) { flags.append("Installed?") }
            }
            let stripped = f.name.replacingOccurrences(of: #" ?\(\d+\)(?=\.[^.]+$|$)"#, with: "", options: .regularExpression)
            if stripped != f.name, names.contains(stripped.lowercased()) { flags.append("Duplicate?") }
            if f.added < ninety { flags.append("90+ days old") }
            let froms = NSMetadataItem(url: f.url)?.value(forAttribute: "kMDItemWhereFroms") as? [String]
            let host = froms?.compactMap { URL(string: $0)?.host }.first.map {
                $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0
            }
            return TidyItem(url: f.url, size: f.isDir ? FS.size(of: f.url) : f.size, kind: kind, flags: flags,
                            added: f.added, source: host)
        }
    }

    static func apply(_ plan: [TidyItem]) -> [Moved] {
        let fm = FileManager.default
        var moved: [Moved] = []
        for item in plan {
            let dir = Places.downloads.appendingPathComponent(item.kind.rawValue)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = FileOps.unique(dir.appendingPathComponent(item.url.lastPathComponent))
            if (try? fm.moveItem(at: item.url, to: dest)) != nil { moved.append(Moved(from: item.url, to: dest)) }
        }
        return moved
    }
}

struct TidyView: View {
    @EnvironmentObject var model: AppModel
    @State private var plan: [TidyItem] = []
    @State private var loaded = false
    @State private var excluded: Set<URL> = []

    @State private var sort = ColumnSort(key: "size", ascending: false)
    @State private var fName = ""
    @State private var fKinds: Set<String> = []
    @State private var fSizes: Set<String> = []
    @State private var fAdded: Set<String> = []
    @State private var fSources: Set<String> = []
    @State private var fFlags: Set<String> = []

    private let wCheck: CGFloat = 28, wKind: CGFloat = 112, wSize: CGFloat = 88
    private let wAdded: CGFloat = 132, wSource: CGFloat = 128, wFlags: CGFloat = 132
    private static let unknownSource = "Unknown"
    private static let noFlags = "No flags"

    private var filtersOn: Bool {
        !fName.isEmpty || !fKinds.isEmpty || !fSizes.isEmpty || !fAdded.isEmpty || !fSources.isEmpty || !fFlags.isEmpty
    }
    private func clearFilters() { fName = ""; fKinds = []; fSizes = []; fAdded = []; fSources = []; fFlags = [] }

    // options with live counts
    private var kindOptions: [FilterOption] {
        FileKind.allCases.compactMap { k in
            let n = plan.filter { $0.kind == k }.count
            return n > 0 ? FilterOption(id: k.rawValue, label: k.rawValue, symbol: k.symbol, count: n) : nil
        }
    }
    private var sourceOptions: [FilterOption] {
        var counts: [String: Int] = [:]
        plan.forEach { counts[$0.source ?? Self.unknownSource, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map {
            FilterOption(id: $0.key, label: $0.key, symbol: $0.key == Self.unknownSource ? "questionmark.circle" : "globe", count: $0.value)
        }
    }
    private var flagOptions: [FilterOption] {
        var counts: [String: Int] = [:]
        plan.forEach { t in
            if t.flags.isEmpty { counts[Self.noFlags, default: 0] += 1 }
            t.flags.forEach { counts[$0, default: 0] += 1 }
        }
        return counts.sorted { $0.key < $1.key }.map { FilterOption(id: $0.key, label: $0.key, symbol: "flag", count: $0.value) }
    }

    private var visible: [TidyItem] {
        let list = plan.filter { t in
            if !TextFilter.matches(t.name, fName) { return false }
            if !fKinds.isEmpty && !fKinds.contains(t.kind.rawValue) { return false }
            if !fSizes.isEmpty && !fSizes.contains(SizeBucket.of(t.size).rawValue) { return false }
            if !fAdded.isEmpty && !fAdded.contains(DateBucket.of(t.added).rawValue) { return false }
            if !fSources.isEmpty && !fSources.contains(t.source ?? Self.unknownSource) { return false }
            if !fFlags.isEmpty {
                let tags = t.flags.isEmpty ? [Self.noFlags] : t.flags
                if !tags.contains(where: { fFlags.contains($0) }) { return false }
            }
            return true
        }
        let sorted: [TidyItem]
        switch sort.key {
        case "name": sorted = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "kind": sorted = list.sorted { ($0.kind.rawValue, $1.size) < ($1.kind.rawValue, $0.size) }
        case "added": sorted = list.sorted { $0.added < $1.added }
        case "source": sorted = list.sorted { ($0.source ?? "~") < ($1.source ?? "~") }
        default: sorted = list.sorted { $0.size < $1.size }
        }
        return sort.ascending ? sorted : sorted.reversed()
    }

    private var toMove: [TidyItem] { visible.filter { !excluded.contains($0.url) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                PageTitle(title: "Tidy Downloads",
                          subtitle: "Each ticked file moves into Downloads/<Kind>/. Filters narrow what moves. Undo puts it all back.")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.bytes(toMove.reduce(0) { $0 + $1.size })).font(.ui(size: 20, weight: .semibold))
                    Text("\(toMove.count) of \(plan.count) files").font(.ui(size: 11)).foregroundStyle(.secondary)
                }
                Button("Tidy \(toMove.count) file\(toMove.count == 1 ? "" : "s")") { tidy() }
                    .buttonStyle(.borderedProminent)
                    .disabled(toMove.isEmpty)
            }

            if loaded && plan.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.ui(size: 34)).foregroundStyle(Theme.accent)
                    Text("Downloads is already tidy.").font(.ui(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity).padding(40).glass()
            } else {
                VStack(spacing: 0) {
                    headerRow
                    Rectangle().fill(Theme.stroke).frame(height: 0.5)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { item in row(item) }
                            if loaded && visible.isEmpty {
                                VStack(spacing: 6) {
                                    Text("No files match these filters.").font(.ui(size: 12)).foregroundStyle(.secondary)
                                    Button("Clear filters") { clearFilters() }
                                }
                                .padding(30)
                            }
                            if !loaded { ProgressView().padding(30) }
                        }
                        .padding(.vertical, 4)
                    }
                    Rectangle().fill(Theme.stroke).frame(height: 0.5)
                    Group {
                        if filtersOn {
                            FilterSummary(shown: visible.count, total: plan.count,
                                          bytes: visible.reduce(0) { $0 + $1.size }, clear: clearFilters)
                        } else {
                            HStack {
                                Text("\(plan.count) loose files · \(Fmt.bytes(plan.reduce(0) { $0 + $1.size }))")
                                Spacer()
                                Text("Click a column title to sort, its funnel to filter")
                            }
                            .font(.ui(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .glass(12)
            }
        }
        .padding(28)
        .padding(.top, 8)
        .task { await load() }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Toggle("", isOn: Binding(
                get: { !visible.isEmpty && visible.allSatisfy { !excluded.contains($0.url) } },
                set: { on in visible.forEach { if on { excluded.remove($0.url) } else { excluded.insert($0.url) } } }))
                .labelsHidden().toggleStyle(.checkbox)
                .frame(width: wCheck, alignment: .leading)
                .help("Tick or untick everything shown")
            ColumnHeader("Name", sortKey: "name", sort: $sort, text: $fName)
            ColumnHeader("Kind", width: wKind, sortKey: "kind", sort: $sort, options: kindOptions, selection: $fKinds)
            ColumnHeader("Size", width: wSize, sortKey: "size", sort: $sort,
                         options: FilterOption.sizes(plan.map(\.size)), selection: $fSizes, defaultAscending: false)
            ColumnHeader("Added", width: wAdded, sortKey: "added", sort: $sort,
                         options: FilterOption.dates(plan.map(\.added)), selection: $fAdded, defaultAscending: false)
            ColumnHeader("From", width: wSource, sortKey: "source", sort: $sort, options: sourceOptions, selection: $fSources)
            ColumnHeader("Flags", width: wFlags, sort: $sort, options: flagOptions, selection: $fFlags)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func row(_ item: TidyItem) -> some View {
        let off = excluded.contains(item.url)
        return HStack(spacing: 0) {
            Toggle("", isOn: Binding(get: { !off },
                                     set: { on in if on { excluded.remove(item.url) } else { excluded.insert(item.url) } }))
                .labelsHidden().toggleStyle(.checkbox)
                .frame(width: wCheck, alignment: .leading)
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 18, height: 18)
                Text(item.name).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            Label(item.kind.rawValue, systemImage: item.kind.symbol)
                .font(.ui(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: wKind, alignment: .leading)
            Text(Fmt.bytes(item.size)).font(.ui(size: 12, weight: item.size > 500_000_000 ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(item.size > 500_000_000 ? Theme.net : Color.secondary)
                .frame(width: wSize, alignment: .leading)
            Text(item.added, format: .relative(presentation: .numeric))
                .font(.ui(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: wAdded, alignment: .leading)
            Text(item.source ?? "—").font(.ui(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: wSource, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(item.flags, id: \.self) { f in
                    Text(f).font(.ui(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.net.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.net)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: wFlags, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .opacity(off ? 0.45 : 1)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Peek") { model.route = .files; model.peek = item.url }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Only show \(item.kind.rawValue)") { fKinds = [item.kind.rawValue] }
            Button("Only show files from \(item.source ?? Self.unknownSource)") { fSources = [item.source ?? Self.unknownSource] }
        }
    }

    private func load() async {
        plan = await Work.run { Tidier.plan() }
        loaded = true
    }

    private func tidy() {
        let list = toMove
        DispatchQueue.global(qos: .userInitiated).async {
            let moved = Tidier.apply(list)
            DispatchQueue.main.async {
                Task { await load() }
                model.reloadAll()
                UndoCenter.shared.show("Tidied \(moved.count) file\(moved.count == 1 ? "" : "s") into folders") {
                    FileOps.moveBack(moved)
                    model.reloadAll()
                    Task { await load() }
                }
            }
        }
    }
}


/// Hangs a panel under a row that opens and closes in place.
struct Accordion<Panel: View>: ViewModifier {
    let open: Bool
    @ViewBuilder let panel: () -> Panel
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            if open { panel().transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .clipped()
    }
}
