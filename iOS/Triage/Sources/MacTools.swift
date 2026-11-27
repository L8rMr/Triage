import SwiftUI
import Charts
import UIKit

// MARK: - Shared bits

/// Pick files on the Mac: browse its places and folders, tick what you want.
final class PickState: ObservableObject {
    @Published var picked: [String: FileEntry] = [:]
    let exts: Set<String>?
    let multiple: Bool
    init(exts: Set<String>?, multiple: Bool) { self.exts = exts; self.multiple = multiple }
    func allows(_ e: FileEntry) -> Bool { exts.map { $0.contains((e.name as NSString).pathExtension.lowercased()) } ?? true }
    func toggle(_ e: FileEntry) {
        if picked[e.path] != nil { picked[e.path] = nil; return }
        if !multiple { picked = [:] }
        picked[e.path] = e
    }
}

struct MacFilePicker: View {
    var title = "Choose Files"
    var exts: Set<String>? = nil
    var multiple = true
    var onPick: ([FileEntry]) -> Void
    @EnvironmentObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: PickState
    @State private var places: [Place] = []

    init(title: String = "Choose Files", exts: Set<String>? = nil, multiple: Bool = true, onPick: @escaping ([FileEntry]) -> Void) {
        self.title = title; self.exts = exts; self.multiple = multiple; self.onPick = onPick
        _state = StateObject(wrappedValue: PickState(exts: exts, multiple: multiple))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("On \(link.macName)") {
                    ForEach(places) { p in
                        NavigationLink(value: FileEntry(name: p.name, path: p.path, dir: true)) { Label(p.name, systemImage: p.symbol) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FileEntry.self) { e in PickFolder(path: e.path, title: e.name) }
            .toolbar { bar }
            .task { if let d = try? await link.call("favorites"), let p: [Place] = decode(d["places"] ?? []) { places = p } }
        }
        .environmentObject(state)
    }

    @ToolbarContentBuilder private var bar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
            Button(state.picked.isEmpty ? "Choose" : "Choose \(state.picked.count)") {
                onPick(Array(state.picked.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
                dismiss()
            }
            .disabled(state.picked.isEmpty)
            .fontWeight(.semibold)
        }
    }
}

private struct PickFolder: View {
    let path: String
    let title: String
    @EnvironmentObject var link: MacLink
    @EnvironmentObject var state: PickState
    @State private var entries: [FileEntry] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading { ProgressView() }
            ForEach(entries) { e in
                if e.isDir {
                    NavigationLink(value: e) { Label(e.name, systemImage: "folder.fill") }
                } else {
                    let ok = state.allows(e)
                    Button { state.toggle(e) } label: {
                        HStack {
                            Image(systemName: state.picked[e.path] != nil ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(state.picked[e.path] != nil ? Color.phosphor : .secondary)
                            Image(systemName: e.symbol).frame(width: 22).foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(e.name).lineLimit(1)
                                Text(Fmt.bytes(e.size ?? 0) + " · " + Fmt.date(e.modified)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!ok)
                    .opacity(ok ? 1 : 0.35)
                }
            }
        }
        .navigationTitle(title)
        .task {
            if let d = try? await link.call("list", ["path": path]), let all: [FileEntry] = decode(d["entries"] ?? []) {
                entries = all.sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
            }
            loading = false
        }
    }
}

/// A row with a size bar: the bigger it is, the more of the row it fills.
struct SizeBar: View {
    let fraction: Double
    var color: Color = .phosphor
    var body: some View {
        GeometryReader { g in
            Capsule().fill(color.opacity(0.18))
                .overlay(alignment: .leading) { Capsule().fill(color).frame(width: max(3, g.size.width * min(max(fraction, 0), 1))) }
        }
        .frame(height: 5)
    }
}

/// Things every tool screen does: the error alert and the little "done" toast.
struct ToolChrome: ViewModifier {
    @Binding var error: String?
    @Binding var toast: String?
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.glass900)
            .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .overlay(alignment: .bottom) { Toast(text: toast) }
    }
}

extension View {
    func toolChrome(error: Binding<String?>, toast: Binding<String?>) -> some View { modifier(ToolChrome(error: error, toast: toast)) }
}

@MainActor func flash(_ toast: Binding<String?>, _ text: String) {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    toast.wrappedValue = text
    Task { try? await Task.sleep(for: .seconds(2)); toast.wrappedValue = nil }
}

private func name(_ path: String) -> String { (path as NSString).lastPathComponent }
private func folder(_ path: String, home: String?) -> String { (path as NSString).deletingLastPathComponent.tildePath(home: home) }

// MARK: - Disk Map: a map of what's eating the disk, tap to go inside

struct DiskNodeR: Decodable, Identifiable, Hashable { var path: String; var name: String; var size: Double; var dir: Bool; var id: String { path } }

struct DiskMapScreen: View {
    var path: String? = nil
    @EnvironmentObject var link: MacLink
    @State private var nodes: [DiskNodeR] = []
    @State private var here = ""
    @State private var loading = true
    @State private var error: String?
    @State private var toast: String?

    private var total: Double { nodes.reduce(0) { $0 + $1.size } }

    var body: some View {
        List {
            Section {
                Treemap(nodes: Array(nodes.prefix(40)))
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } footer: {
                Text(loading ? "Measuring… \(nodes.count) items so far" : "\(Fmt.bytes(total)) in \(nodes.count) items. Tap a folder to go inside.")
            }
            Section {
                ForEach(nodes) { n in
                    let row = VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: n.dir ? "folder.fill" : "doc").foregroundStyle(n.dir ? Color.phosphor : .secondary).frame(width: 22)
                            Text(n.name).lineLimit(1)
                            Spacer()
                            Text(Fmt.bytes(n.size)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        SizeBar(fraction: n.size / max(nodes.first?.size ?? 1, 1))
                    }
                    if n.dir { NavigationLink(value: n) { row } } else { row }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(here.isEmpty ? "Disk Map" : name(here))
        .helpTip("Bigger boxes are bigger folders. Tap a folder to go inside; pull ↻ to measure again.")
        .navigationDestination(for: DiskNodeR.self) { n in DiskMapScreen(path: n.path) }
        .toolbar { Button { Task { await load(refresh: true) } } label: { Image(systemName: "arrow.clockwise") } }
        .toolChrome(error: $error, toast: $toast)
        .task { await poll() }
    }

    private func poll() async {
        await load(refresh: false)
        while loading && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(700))
            await load(refresh: false)
        }
    }

    private func load(refresh: Bool) async {
        do {
            var a: [String: Any] = ["refresh": refresh]
            if let path { a["path"] = path }
            let d = try await link.call("toolDiskMap", a)
            nodes = decode(d["nodes"] ?? []) ?? []
            here = d["path"] as? String ?? ""
            loading = (d["loading"] as? Bool) ?? false
            if refresh { await poll() }
        } catch { self.error = error.localizedDescription; loading = false }
    }
}

/// Squarified treemap: big things look big. Tap a tile to open it.
struct Treemap: View {
    let nodes: [DiskNodeR]

    var body: some View {
        GeometryReader { g in
            let rects = Self.layout(nodes.map(\.size), in: CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(nodes.indices, rects)), id: \.0) { i, r in
                    let n = nodes[i]
                    NavigationLink(value: n) {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.phosphor.opacity(n.dir ? 0.85 - Double(i % 6) * 0.1 : 0.25))
                            if r.width > 54 && r.height > 30 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.name).font(.caption2.weight(.semibold)).lineLimit(1)
                                    Text(Fmt.bytes(n.size)).font(.caption2.monospacedDigit()).opacity(0.8)
                                }
                                .foregroundStyle(n.dir ? Color.glass900 : .primary)
                                .padding(5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!n.dir)
                    .frame(width: max(r.width - 2, 1), height: max(r.height - 2, 1))
                    .offset(x: r.minX + 1, y: r.minY + 1)
                }
            }
        }
    }

    /// Squarified layout (Bruls et al.): rows that keep tiles close to square.
    static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        var areas = sizes.map { $0 * scale }
        var out: [CGRect] = []
        var r = rect
        while !areas.isEmpty {
            let side = Double(min(r.width, r.height))
            var row: [Double] = []
            func worst(_ row: [Double]) -> Double {
                let s = row.reduce(0, +), mx = row.max() ?? 0, mn = row.min() ?? 1
                return max(side * side * mx / (s * s), (s * s) / (side * side * max(mn, 0.0001)))
            }
            while let next = areas.first, row.isEmpty || worst(row + [next]) <= worst(row) {
                row.append(next); areas.removeFirst()
            }
            let s = row.reduce(0, +)
            let thick = CGFloat(s / side)
            var pos: CGFloat = 0
            for a in row {
                let len = CGFloat(a / Double(thick))
                if r.width >= r.height {
                    out.append(CGRect(x: r.minX, y: r.minY + pos, width: thick, height: len))
                } else {
                    out.append(CGRect(x: r.minX + pos, y: r.minY, width: len, height: thick))
                }
                pos += len
            }
            if r.width >= r.height { r = CGRect(x: r.minX + thick, y: r.minY, width: r.width - thick, height: r.height) }
            else { r = CGRect(x: r.minX, y: r.minY + thick, width: r.width, height: r.height - thick) }
        }
        return out
    }
}

// MARK: - Duplicate Finder

struct DupFileR: Decodable, Hashable { var path: String; var size: Double; var modified: Double }

struct DuplicatesScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var groups: [[DupFileR]] = []
    @State private var running = false
    @State private var status = ""
    @State private var minMB = 1.0
    @State private var root: String?
    @State private var marked: Set<String> = []
    @State private var started = false
    @State private var choosing = false
    @State private var confirm = false
    @State private var error: String?
    @State private var toast: String?

    private var markedBytes: Double { groups.flatMap { $0 }.filter { marked.contains($0.path) }.reduce(0) { $0 + $1.size } }

    var body: some View {
        List {
            Section {
                Button { choosing = true } label: {
                    LabeledContent("Look in", value: root.map { name($0) } ?? "Your home folder")
                }
                Picker("Ignore files under", selection: $minMB) {
                    Text("100 KB").tag(0.1); Text("1 MB").tag(1.0); Text("10 MB").tag(10.0); Text("100 MB").tag(100.0)
                }
                Button(running ? "Stop" : (started ? "Scan again" : "Find duplicates")) { Task { if running { await stop() } else { await start() } } }
                    .fontWeight(.semibold)
            } footer: {
                Text(running ? (status.isEmpty ? "Looking…" : status)
                     : "Files count as duplicates only when their contents are identical, byte for byte. The oldest copy is kept.")
            }
            if !groups.isEmpty {
                Section {
                    Menu("Keep in each group…") {
                        Button("The oldest copy") { keep { $0.min { $0.modified < $1.modified } } }
                        Button("The newest copy") { keep { $0.max { $0.modified < $1.modified } } }
                        Button("The one with the shortest path") { keep { $0.min { $0.path.count < $1.path.count } } }
                    }
                }
                ForEach(groups.indices, id: \.self) { gi in
                    Section(name(groups[gi].first?.path ?? "") + " · " + Fmt.bytes(groups[gi].first?.size ?? 0) + " × \(groups[gi].count)") {
                        ForEach(groups[gi], id: \.path) { f in
                            Button { if marked.contains(f.path) { marked.remove(f.path) } else { marked.insert(f.path) } } label: {
                                HStack {
                                    Image(systemName: marked.contains(f.path) ? "trash.circle.fill" : "checkmark.circle")
                                        .foregroundStyle(marked.contains(f.path) ? Color.coral : Color.healthy)
                                    VStack(alignment: .leading) {
                                        Text(folder(f.path, home: link.info?.home)).font(.subheadline).lineLimit(2)
                                        Text("Modified " + Fmt.date(f.modified)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if started && !running {
                Text("No duplicates found.").foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Duplicate Finder")
        .helpTip("Finds files whose contents are identical, byte for byte. One copy of each always stays; the rest go to the Trash.")
        .safeAreaInset(edge: .bottom) {
            if link.canEdit && !marked.isEmpty && !running {
                Button { confirm = true } label: {
                    Text("Move \(marked.count) copies (\(Fmt.bytes(markedBytes))) to the Trash").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.coral).padding()
            }
        }
        .confirmationDialog("Move \(marked.count) duplicate copies to the Trash?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await trash() } }
        } message: { Text("One copy of every file stays. You can put them back from the Trash on the Mac.") }
        .sheet(isPresented: $choosing) { FolderChooser(title: "Look in") { root = $0 } }
        .toolChrome(error: $error, toast: $toast)
        .task { await state() }
    }

    private func keep(_ pick: ([DupFileR]) -> DupFileR?) {
        marked = []
        for g in groups { let k = pick(g); for f in g where f.path != k?.path { marked.insert(f.path) } }
    }

    private func start() async {
        started = true
        var a: [String: Any] = ["kind": "dupes", "action": "start", "minMB": minMB]
        if let root { a["root"] = root }
        _ = try? await link.call("toolScan", a)
        await poll()
    }
    private func stop() async { _ = try? await link.call("toolScan", ["kind": "dupes", "action": "stop"]); await state() }
    private func poll() async {
        repeat {
            try? await Task.sleep(for: .milliseconds(900))
            await state()
        } while running && !Task.isCancelled
    }
    private func state() async {
        do {
            let d = try await link.call("toolScan", ["kind": "dupes", "action": "state"])
            let wasRunning = running
            running = (d["running"] as? Bool) ?? false
            status = d["status"] as? String ?? ""
            let g: [[DupFileR]] = decode(d["groups"] ?? []) ?? []
            if g != groups || (wasRunning && !running) {
                groups = g
                keep { $0.min { $0.modified < $1.modified } }
            }
            if running { started = true; if !wasRunning { Task { await poll() } } }
        } catch { self.error = error.localizedDescription }
    }
    private func trash() async {
        do {
            let d = try await link.call("trash", ["paths": Array(marked)])
            let done = (d["trashed"] as? [String]) ?? []
            groups = groups.map { $0.filter { !done.contains($0.path) } }.filter { $0.count > 1 }
            marked.subtract(done)
            flash($toast, "Moved \(done.count) to the Trash")
        } catch { self.error = error.localizedDescription }
    }
}

/// Pick a folder on the Mac (for scans).
struct FolderChooser: View {
    var title: String
    var pick: (String) -> Void
    @EnvironmentObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var places: [Place] = []
    var body: some View {
        NavigationStack {
            List(places) { p in
                Button { pick(p.path); dismiss() } label: { Label(p.name, systemImage: p.symbol) }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { if let d = try? await link.call("favorites"), let p: [Place] = decode(d["places"] ?? []) { places = p } }
        }
    }
}

// MARK: - Forgotten Files

struct ForgottenR: Decodable, Identifiable, Hashable { var path: String; var size: Double; var used: Double; var id: String { path } }

struct ForgottenScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var items: [ForgottenR] = []
    @State private var running = false
    @State private var months = 12
    @State private var minMB = 50
    @State private var picks: Set<String> = []
    @State private var confirm = false
    @State private var searched = false
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                Picker("Not opened in", selection: $months) {
                    Text("6 months").tag(6); Text("1 year").tag(12); Text("2 years").tag(24); Text("3 years").tag(36)
                }
                Picker("Bigger than", selection: $minMB) {
                    Text("10 MB").tag(10); Text("50 MB").tag(50); Text("200 MB").tag(200); Text("1 GB").tag(1000)
                }
                Button(running ? "Searching…" : "Find forgotten files") { Task { await start() } }.disabled(running).fontWeight(.semibold)
            } footer: { Text("Big files in your home folder that you haven't opened in a long time.") }
            if !items.isEmpty {
                Section("\(items.count) files · \(Fmt.bytes(items.reduce(0) { $0 + $1.size }))") {
                    ForEach(items) { f in
                        Button { if picks.contains(f.path) { picks.remove(f.path) } else { picks.insert(f.path) } } label: {
                            HStack {
                                Image(systemName: picks.contains(f.path) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picks.contains(f.path) ? Color.phosphor : .secondary)
                                VStack(alignment: .leading) {
                                    Text(name(f.path)).lineLimit(1)
                                    Text(folder(f.path, home: link.info?.home) + " · last opened " + Fmt.date(f.used))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(Fmt.bytes(f.size)).font(.subheadline.monospacedDigit())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if searched && !running {
                Text("Nothing forgotten that big. Nice.").foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Forgotten Files")
        .helpTip("Big files in your home folder you haven't opened in a long time: good candidates to delete or move off.")
        .safeAreaInset(edge: .bottom) {
            if link.canEdit && !picks.isEmpty {
                Button { confirm = true } label: {
                    Text("Move \(picks.count) to the Trash").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.coral).padding()
            }
        }
        .confirmationDialog("Move \(picks.count) files to the Trash?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await trash() } }
        }
        .toolChrome(error: $error, toast: $toast)
    }

    private func start() async {
        searched = true; running = true; picks = []
        do {
            var d = try await link.call("toolScan", ["kind": "forgotten", "action": "start", "months": months, "minMB": minMB])
            while (d["running"] as? Bool) == true && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                d = try await link.call("toolScan", ["kind": "forgotten", "action": "state"])
            }
            items = decode(d["items"] ?? []) ?? []
        } catch { self.error = error.localizedDescription }
        running = false
    }

    private func trash() async {
        do {
            let d = try await link.call("trash", ["paths": Array(picks)])
            let done = Set((d["trashed"] as? [String]) ?? [])
            items.removeAll { done.contains($0.path) }
            picks.subtract(done)
            flash($toast, "Moved \(done.count) to the Trash")
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - App Uninstaller

struct InstalledR: Decodable, Identifiable, Hashable {
    var path: String; var name: String; var size: Double; var leftovers: Int; var leftoverBytes: Double
    var version: String?; var bundleID: String?; var used: Double?
    var id: String { path }
}

struct UninstallerScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var apps: [InstalledR] = []
    @State private var loading = true
    @State private var query = ""
    @State private var sortBySize = true
    @State private var removing: InstalledR?
    @State private var error: String?
    @State private var toast: String?

    private var shown: [InstalledR] {
        let f = query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return sortBySize ? f.sorted { $0.size + $0.leftoverBytes > $1.size + $1.leftoverBytes } : f
    }

    var body: some View {
        List {
            if loading { HStack { ProgressView(); Text("Measuring apps…").foregroundStyle(.secondary) } }
            ForEach(shown) { a in
                HStack(spacing: 12) {
                    AppIconView(path: a.path)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.subheadline.weight(.semibold))
                        Text([a.version.map { "v\($0)" }, a.used.map { "used " + Fmt.date($0) } ?? "never opened",
                              a.leftovers > 0 ? "\(a.leftovers) leftovers" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.bytes(a.size + a.leftoverBytes)).font(.subheadline.monospacedDigit())
                }
                .swipeActions {
                    if link.canEdit { Button("Uninstall", role: .destructive) { removing = a } }
                }
                .contextMenu { if link.canEdit { Button("Uninstall…", role: .destructive) { removing = a } } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Uninstaller")
        .helpTip("Swipe an app to uninstall it along with the settings and caches it left behind. Everything goes to the Trash.")
        .searchable(text: $query, prompt: "Find an app")
        .toolbar {
            Menu {
                Picker("Sort", selection: $sortBySize) { Text("Biggest first").tag(true); Text("A to Z").tag(false) }
            } label: { Image(systemName: "arrow.up.arrow.down") }
        }
        .confirmationDialog("Uninstall \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { a in
            Button("Uninstall \(a.name)", role: .destructive) { Task { await remove(a) } }
        } message: { a in
            Text("The app (\(Fmt.bytes(a.size))) and \(a.leftovers) leftover item\(a.leftovers == 1 ? "" : "s") (\(Fmt.bytes(a.leftoverBytes))) go to the Trash. Undo is on the Mac.")
        }
        .toolChrome(error: $error, toast: $toast)
        .task { await poll() }
        .refreshable { await load(refresh: true); await poll() }
    }

    private func poll() async {
        await load(refresh: false)
        while loading && !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); await load(refresh: false) }
    }
    private func load(refresh: Bool) async {
        do {
            let d = try await link.call("toolApps", ["refresh": refresh])
            apps = decode(d["apps"] ?? []) ?? []
            loading = (d["loading"] as? Bool) ?? false
        } catch { self.error = error.localizedDescription; loading = false }
    }
    private func remove(_ a: InstalledR) async {
        do {
            _ = try await link.call("uninstallApp", ["path": a.path, "confirm": "REMOVE"])
            apps.removeAll { $0.path == a.path }
            flash($toast, "\(a.name) is in the Trash")
        } catch { self.error = error.localizedDescription }
    }
}

/// The Mac app's own icon, fetched as a thumbnail.
struct AppIconView: View {
    let path: String
    @EnvironmentObject var link: MacLink
    @State private var img: UIImage?
    var body: some View {
        Group {
            if let img { Image(uiImage: img).resizable() } else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: 34, height: 34)
        .task(id: path) {
            guard img == nil, let d = try? await link.call("thumb", ["path": path, "size": 96]),
                  let b = d["jpg"] as? String, let data = Data(base64Encoded: b) else { return }
            img = UIImage(data: data)
        }
    }
}

// MARK: - Startup Items

struct StartupR: Decodable, Identifiable, Hashable {
    var id: String; var label: String; var program: String; var scope: String; var kind: String
    var enabled: Bool; var running: Bool; var canToggle: Bool; var vendor: String
}

struct StartupScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var items: [StartupR] = []
    @State private var login: [String] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                if login.isEmpty { Text(loaded ? "None" : "Loading…").foregroundStyle(.secondary) }
                ForEach(login, id: \.self) { n in
                    Label(n, systemImage: "power").swipeActions {
                        if link.canEdit { Button("Remove", role: .destructive) { Task { await removeLogin(n) } } }
                    }
                }
            } header: { Text("Opens at login") } footer: { Text("Swipe to stop one opening when you log in.") }
            ForEach(["You", "All users", "System"], id: \.self) { scope in
                let list = items.filter { $0.scope == scope }
                if !list.isEmpty {
                    Section {
                        ForEach(list) { i in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Circle().fill(i.running ? Color.healthy : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                                        Text(i.vendor).font(.subheadline.weight(.semibold))
                                    }
                                    Text(i.label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if i.canToggle && link.canEdit {
                                    Toggle("", isOn: Binding(get: { i.enabled }, set: { on in Task { await set(i, on) } })).labelsHidden()
                                } else {
                                    Text(i.enabled ? "On" : "Off").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(scope == "You" ? "Your background items" : scope == "All users" ? "For everyone" : "System services")
                    } footer: {
                        if scope != "You" { Text("These need an admin to change. Shown so you know what's running.") }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Startup Items")
        .helpTip("What opens at login and what runs in the background. Your own items can be switched off; system ones are shown so you know.")
        .toolChrome(error: $error, toast: $toast)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let d = try await link.call("toolStartup")
            items = (decode(d["items"] ?? []) ?? [StartupR]()).sorted { $0.vendor.localizedStandardCompare($1.vendor) == .orderedAscending }
            login = d["login"] as? [String] ?? []
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    private func set(_ i: StartupR, _ on: Bool) async {
        do {
            _ = try await link.call("startupSet", ["id": i.id, "on": on])
            try? await Task.sleep(for: .milliseconds(600))
            await load()
            flash($toast, on ? "Turned on" : "Turned off")
        } catch { self.error = error.localizedDescription }
    }
    private func removeLogin(_ n: String) async {
        do { _ = try await link.call("loginItemRemove", ["name": n]); login.removeAll { $0 == n }; flash($toast, "Removed") }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Network by App

struct NetR: Decodable, Identifiable { var name: String; var down: Double; var up: Double; var received: Double; var sent: Double; var id: String { name } }

struct NetworkScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var apps: [NetR] = []
    @State private var available = true
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            if !available { Text("This Mac doesn't have nettop, so per-app traffic isn't available.").foregroundStyle(.secondary) }
            let peak = max(apps.map { $0.down + $0.up }.max() ?? 1, 1)
            ForEach(apps) { a in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Label(Self.rate(a.down), systemImage: "arrow.down").font(.caption.monospacedDigit()).foregroundStyle(Color.phosphor)
                        Label(Self.rate(a.up), systemImage: "arrow.up").font(.caption.monospacedDigit()).foregroundStyle(Color.amber)
                    }
                    SizeBar(fraction: (a.down + a.up) / peak)
                    Text("\(Fmt.bytes(a.received)) in · \(Fmt.bytes(a.sent)) out since it started").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Network by App")
        .helpTip("Which apps are uploading (amber) and downloading (green) right now, updated every 2 seconds.")
        .toolChrome(error: $error, toast: $toast)
        .task {
            while !Task.isCancelled {
                if let d = try? await link.call("toolNetwork") {
                    available = (d["available"] as? Bool) ?? true
                    apps = decode(d["apps"] ?? []) ?? []
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    static func rate(_ bps: Double) -> String { bps < 1 ? "0" : Fmt.bytes(bps) + "/s" }
}

// MARK: - Dev Servers & Ports

struct ListenerR: Decodable, Identifiable { var pid: Int; var command: String; var app: String; var host: String; var port: Int; var local: Bool; var id: String { "\(pid):\(host):\(port)" } }
struct ContainerR: Decodable, Identifiable { var id: String; var name: String; var image: String; var status: String; var ports: String; var running: Bool }

struct PortsScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var listeners: [ListenerR] = []
    @State private var containers: [ContainerR] = []
    @State private var docker = false
    @State private var stopping: ListenerR?
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                if listeners.isEmpty { Text("Nothing is listening.").foregroundStyle(.secondary) }
                ForEach(listeners.sorted { $0.port < $1.port }) { l in
                    HStack {
                        Text(":\(l.port)").font(.headline.monospacedDigit()).frame(minWidth: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.app).font(.subheadline.weight(.semibold))
                            Text(l.local ? "This Mac only" : "Open to the network (\(l.host))").font(.caption)
                                .foregroundStyle(l.local ? Color.secondary : Color.amber)
                        }
                        Spacer()
                    }
                    .swipeActions { if link.canEdit { Button("Stop", role: .destructive) { stopping = l } } }
                }
            } header: { Text("Listening") } footer: { Text("Swipe to stop a server.") }
            if docker {
                Section("Docker") {
                    if containers.isEmpty { Text("No containers.").foregroundStyle(.secondary) }
                    ForEach(containers) { c in
                        HStack {
                            Circle().fill(c.running ? Color.healthy : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.subheadline.weight(.semibold))
                                Text(c.image + (c.ports.isEmpty ? "" : " · " + c.ports)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if link.canEdit {
                                Menu {
                                    if c.running {
                                        Button("Restart") { Task { await dock(c, "restart") } }
                                        Button("Stop", role: .destructive) { Task { await dock(c, "stop") } }
                                    } else {
                                        Button("Start") { Task { await dock(c, "start") } }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Servers & Ports")
        .helpTip("Things listening for connections on the Mac (dev servers, databases) and Docker containers. Swipe to stop one.")
        .confirmationDialog("Stop \(stopping?.app ?? "") on port \(stopping?.port ?? 0)?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible, presenting: stopping) { l in
            Button("Stop", role: .destructive) { Task { await kill(l) } }
        } message: { _ in Text("Unsaved work in that app may be lost.") }
        .toolChrome(error: $error, toast: $toast)
        .task {
            while !Task.isCancelled {
                if let d = try? await link.call("toolPorts") {
                    listeners = decode(d["listeners"] ?? []) ?? []
                    containers = decode(d["containers"] ?? []) ?? []
                    docker = (d["docker"] as? Bool) ?? false
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func kill(_ l: ListenerR) async {
        do { _ = try await link.call("portKill", ["pid": l.pid]); flash($toast, "Stopped \(l.app)") } catch { self.error = error.localizedDescription }
    }
    private func dock(_ c: ContainerR, _ verb: String) async {
        do { _ = try await link.call("docker", ["id": c.id, "verb": verb]); flash($toast, "\(verb.capitalized): \(c.name)") }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Health History

struct SampleR: Decodable, Identifiable { var t: Double; var bpm: Double; var cpu: Double; var mem: Double; var health: Double; var top: String?; var id: Double { t } }

struct HistoryScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var hours = 24.0
    @State private var samples: [SampleR] = []
    @State private var error: String?
    @State private var toast: String?

    private var peak: SampleR? { samples.max { $0.bpm < $1.bpm } }
    private var avg: Double { samples.isEmpty ? 0 : samples.reduce(0) { $0 + $1.bpm } / Double(samples.count) }
    private var calm: Double { samples.isEmpty ? 0 : Double(samples.filter { $0.bpm < 100 }.count) / Double(samples.count) }

    var body: some View {
        List {
            Picker("Range", selection: $hours) {
                Text("Day").tag(24.0); Text("3 days").tag(72.0); Text("Week").tag(168.0); Text("2 weeks").tag(336.0)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            Section {
                Chart(samples) { s in
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: s.t)), y: .value("bpm", s.bpm))
                        .foregroundStyle(Color.pulse(s.bpm))
                        .interpolationMethod(.monotone)
                    if let p = peak, p.t == s.t {
                        PointMark(x: .value("Time", Date(timeIntervalSince1970: s.t)), y: .value("bpm", s.bpm))
                            .annotation(position: .top) { Text("\(Int(s.bpm))").font(.caption2.weight(.bold)) }
                    }
                }
                .chartYAxisLabel("bpm")
                .frame(height: 200)
            } header: { Text("Heart rate") }
            Section("Report card") {
                LabeledContent("Average", value: "\(Int(avg)) bpm")
                LabeledContent("Calm (under 100 bpm)", value: Fmt.pct(calm * 100))
                if let p = peak {
                    LabeledContent("Busiest moment", value: "\(Int(p.bpm)) bpm, " + Date(timeIntervalSince1970: p.t).formatted(date: .abbreviated, time: .shortened))
                    if let top = p.top, !top.isEmpty { LabeledContent("Working hardest then", value: top) }
                }
            }
            Section {
                Chart(samples) { s in
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: s.t)), y: .value("%", s.cpu), series: .value("", "CPU"))
                        .foregroundStyle(Color.phosphor)
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: s.t)), y: .value("%", s.mem), series: .value("", "Memory"))
                        .foregroundStyle(Color.amber)
                }
                .frame(height: 160)
            } header: { Text("CPU and memory") } footer: { Text("Green is CPU, amber is memory, as a percentage.") }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Health History")
        .helpTip("Your Mac's heart rate (how hard it's working) over days, with the busiest moment and what caused it.")
        .toolChrome(error: $error, toast: $toast)
        .task(id: hours) {
            do { let d = try await link.call("toolHistory", ["hours": hours]); samples = decode(d["samples"] ?? []) ?? [] }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Drive Health

struct DriveR: Decodable, Identifiable {
    var id: String; var name: String; var bus: String; var isInternal: Bool; var ssd: Bool; var size: Double; var smart: String
    var level: String; var summary: String; var notes: [String]
    var trim: String?; var percentUsed: Int?; var hours: Int?; var written: Double?; var temp: Int?; var spare: Int?; var mediaErrors: Int?; var unsafeShutdowns: Int?
    enum CodingKeys: String, CodingKey {
        case id, name, bus, isInternal = "internal", ssd, size, smart, level, summary, notes, trim, percentUsed, hours, written, temp, spare, mediaErrors, unsafeShutdowns
    }
}
struct VolumeR: Decodable, Identifiable { var name: String; var path: String; var format: String; var total: Double; var free: Double; var importantFree: Double; var id: String { path } }

struct DrivesScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var drives: [DriveR] = []
    @State private var volumes: [VolumeR] = []
    @State private var snapshots = 0
    @State private var smartctl = true
    @State private var loading = true
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            if loading && drives.isEmpty { HStack { ProgressView(); Text("Asking the drives…").foregroundStyle(.secondary) } }
            ForEach(drives) { d in
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: d.ssd ? "internaldrive.fill" : "externaldrive.fill").font(.title2).foregroundStyle(color(d.level))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.headline)
                            Text("\(Fmt.bytes(d.size)) · \(d.bus) · \(d.isInternal ? "internal" : "external")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(d.summary).font(.subheadline.weight(.semibold)).foregroundStyle(color(d.level)).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("SMART status", value: d.smart)
                    if let v = d.percentUsed { LabeledContent("Wear", value: "\(v)% used") }
                    if let v = d.hours { LabeledContent("Hours in use", value: "\(v.formatted()) h") }
                    if let v = d.written { LabeledContent("Data written", value: Fmt.bytes(v)) }
                    if let v = d.temp { LabeledContent("Temperature", value: "\(v) °C") }
                    if let v = d.spare { LabeledContent("Spare blocks left", value: "\(v)%") }
                    if let v = d.mediaErrors { LabeledContent("Media errors", value: "\(v)") }
                    if let v = d.unsafeShutdowns { LabeledContent("Unsafe shutdowns", value: "\(v)") }
                    if let t = d.trim { LabeledContent("TRIM", value: t) }
                    ForEach(d.notes, id: \.self) { n in Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !smartctl && !drives.isEmpty {
                Section { Text("Install smartctl from Triage › Drive Health on the Mac for wear, hours and temperature.").font(.footnote).foregroundStyle(.secondary) }
            }
            if !volumes.isEmpty {
                Section("Volumes") {
                    ForEach(volumes) { v in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(v.name).font(.subheadline.weight(.semibold)); Text(v.format).font(.caption).foregroundStyle(.secondary); Spacer()
                                Text("\(Fmt.bytes(v.importantFree)) free").font(.caption.monospacedDigit()) }
                            SizeBar(fraction: v.total > 0 ? (v.total - v.importantFree) / v.total : 0)
                        }
                    }
                    if snapshots > 0 { LabeledContent("Local Time Machine snapshots", value: "\(snapshots)") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Drive Health")
        .helpTip("SMART status and wear for each drive, plus free space per volume. Wear and temperature need smartctl on the Mac.")
        .toolChrome(error: $error, toast: $toast)
        .task { await load(false) }
        .refreshable { await load(true) }
    }

    private func color(_ level: String) -> Color { level == "good" ? .healthy : level == "critical" ? .coral : level == "watch" ? .amber : .secondary }

    private func load(_ refresh: Bool) async {
        do {
            let d = try await link.call("toolDrives", ["refresh": refresh])
            drives = decode(d["drives"] ?? []) ?? []
            volumes = decode(d["volumes"] ?? []) ?? []
            snapshots = d["snapshots"] as? Int ?? 0
            smartctl = (d["smartctl"] as? Bool) ?? true
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

// MARK: - Wi-Fi

struct WiFiR: Decodable, Identifiable, Hashable { var ssid: String; var rssi: Int; var secure: Bool; var known: Bool; var channel: String; var bars: Int; var id: String { ssid } }

struct WiFiScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var ssid: String?
    @State private var power = true
    @State private var rssi = 0
    @State private var tx = 0.0
    @State private var ip: String?
    @State private var nets: [WiFiR] = []
    @State private var scanning = false
    @State private var locationAllowed = true
    @State private var joining: WiFiR?
    @State private var password = ""
    @State private var busy: String?
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { power }, set: { on in Task { await setPower(on) } })) { Label("Wi-Fi", systemImage: "wifi") }
                    .disabled(!link.canEdit)
                if let ssid {
                    LabeledContent("Network", value: ssid)
                    LabeledContent("Signal", value: "\(rssi) dBm · " + (rssi > -55 ? "excellent" : rssi > -67 ? "good" : rssi > -75 ? "fair" : "weak"))
                    LabeledContent("Speed", value: "\(Int(tx)) Mbps")
                    if let ip { LabeledContent("IP address", value: ip) }
                } else if power {
                    Text("Not connected").foregroundStyle(.secondary)
                }
            } header: { Text(link.macName) }
            if power {
                Section {
                    ForEach(nets) { n in
                        Button { if n.ssid != ssid { if n.secure && !n.known { password = ""; joining = n } else { Task { await join(n, nil) } } } } label: {
                            HStack {
                                Image(systemName: n.bars >= 3 ? "wifi" : n.bars == 2 ? "wifi" : "wifi.exclamationmark")
                                    .symbolVariant(.none).foregroundStyle(n.bars >= 2 ? Color.phosphor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.ssid).fontWeight(n.ssid == ssid ? .semibold : .regular)
                                    Text([n.channel, n.known ? "saved" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if busy == n.ssid { ProgressView() }
                                else if n.ssid == ssid { Image(systemName: "checkmark").foregroundStyle(Color.phosphor) }
                                else if n.secure { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!link.canEdit)
                    }
                } header: {
                    HStack { Text("Networks nearby"); Spacer(); if scanning { ProgressView() } }
                } footer: {
                    if !locationAllowed && nets.isEmpty { Text("Allow Location for Triage on the Mac (System Settings › Privacy) so macOS shares network names.") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Wi-Fi")
        .helpTip("The Mac's Wi-Fi: signal, speed and nearby networks. Tap one to make the Mac join it.")
        .toolbar { Button { Task { await load(scan: true) } } label: { Image(systemName: "arrow.clockwise") } }
        .alert("Join \(joining?.ssid ?? "")", isPresented: Binding(get: { joining != nil }, set: { if !$0 { joining = nil } })) {
            SecureField("Password", text: $password)
            Button("Join") { if let n = joining { Task { await join(n, password) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The Mac joins this network. If your phone reaches the Mac over this Wi-Fi, it may drop for a moment.") }
        .toolChrome(error: $error, toast: $toast)
        .task { await load(scan: false); await load(scan: true) }
    }

    private func load(scan: Bool) async {
        if scan { scanning = true }
        do {
            let d = try await link.call("toolWifi", ["scan": scan])
            ssid = d["ssid"] as? String
            power = (d["power"] as? Bool) ?? false
            rssi = d["rssi"] as? Int ?? 0
            tx = d["txRate"] as? Double ?? 0
            ip = d["ip"] as? String
            locationAllowed = (d["locationAllowed"] as? Bool) ?? true
            let n: [WiFiR] = decode(d["networks"] ?? []) ?? []
            if !n.isEmpty || scan { nets = n }
        } catch { self.error = error.localizedDescription }
        scanning = false
    }
    private func setPower(_ on: Bool) async {
        do { _ = try await link.call("wifiPower", ["on": on]); power = on; try? await Task.sleep(for: .seconds(2)); await load(scan: on) }
        catch { self.error = error.localizedDescription }
    }
    private func join(_ n: WiFiR, _ pw: String?) async {
        busy = n.ssid
        do {
            var a: [String: Any] = ["ssid": n.ssid]
            if let pw { a["password"] = pw }
            let d = try await link.call("wifiJoin", a)
            flash($toast, d["message"] as? String ?? "Done")
            await load(scan: false)
        } catch { self.error = error.localizedDescription }
        busy = nil
    }
}

// MARK: - Sound Mixer

struct AudioAppR: Decodable, Identifiable { var id: String; var name: String; var playing: Bool; var level: Double }
struct DeviceR: Decodable, Identifiable, Hashable { var id: Int; var name: String }

struct SoundScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var master = 0.5
    @State private var muted = false
    @State private var output = 0
    @State private var devices: [DeviceR] = []
    @State private var apps: [AudioAppR] = []
    @State private var supported = true
    @State private var problem: String?
    @State private var dragging = false
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Button { Task { await set(["muted": !muted]) } } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 26)
                    }
                    .buttonStyle(.plain).foregroundStyle(muted ? Color.coral : Color.phosphor)
                    Slider(value: $master, in: 0...1) { e in dragging = e; if !e { Task { await set(["master": master]) } } }
                    Text(Fmt.pct(master * 100)).font(.caption.monospacedDigit()).frame(width: 40)
                }
                if !devices.isEmpty {
                    Picker("Output", selection: Binding(get: { output }, set: { o in output = o; Task { await set(["output": o]) } })) {
                        ForEach(devices) { Text($0.name).tag($0.id) }
                    }
                }
            } header: { Text("\(link.macName) volume") }
            Section {
                if !supported { Text("Per-app volume needs macOS 14.2 or later.").foregroundStyle(.secondary) }
                if apps.isEmpty && supported { Text("Nothing is playing sound.").foregroundStyle(.secondary) }
                ForEach(apps) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(a.playing ? Color.healthy : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                            Text(a.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(Fmt.pct(a.level * 100)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { a.level }, set: { v in if let i = apps.firstIndex(where: { $0.id == a.id }) { apps[i].level = v } }),
                               in: 0...1) { e in dragging = e; if !e, let v = apps.first(where: { $0.id == a.id })?.level { Task { await set(["app": a.id, "level": v]) } } }
                    }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Color.amber) }
            } header: { Text("Apps") } footer: {
                if !apps.isEmpty { Button("Reset all to 100%") { Task { await set(["reset": true]) } }.font(.footnote) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sound Mixer")
        .helpTip("Volume for the whole Mac and for each app, and which speakers it plays through.")
        .disabled(!link.canEdit)
        .toolChrome(error: $error, toast: $toast)
        .task {
            while !Task.isCancelled {
                if !dragging, let d = try? await link.call("toolSound") { apply(d) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func apply(_ d: [String: Any]) {
        master = d["master"] as? Double ?? master
        muted = (d["muted"] as? Bool) ?? false
        output = d["output"] as? Int ?? output
        devices = decode(d["devices"] ?? []) ?? devices
        apps = decode(d["apps"] ?? []) ?? []
        supported = (d["supported"] as? Bool) ?? true
        problem = d["problem"] as? String
    }
    private func set(_ a: [String: Any]) async {
        do { apply(try await link.call("soundSet", a)) } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Tidy Downloads

struct TidyR: Decodable, Identifiable, Hashable { var path: String; var name: String; var size: Double; var kind: String; var added: Double; var source: String?; var flags: [String]; var id: String { path } }

struct TidyScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var items: [TidyR] = []
    @State private var picks: Set<String> = []
    @State private var loading = true
    @State private var error: String?
    @State private var toast: String?

    private var kinds: [String] { Array(Set(items.map(\.kind))).sorted() }

    var body: some View {
        List {
            if loading { HStack { ProgressView(); Text("Looking in Downloads…").foregroundStyle(.secondary) } }
            else if items.isEmpty { Text("Downloads is already tidy.").foregroundStyle(.secondary) }
            ForEach(kinds, id: \.self) { k in
                let list = items.filter { $0.kind == k }
                Section {
                    ForEach(list) { i in
                        Button { if picks.contains(i.path) { picks.remove(i.path) } else { picks.insert(i.path) } } label: {
                            HStack {
                                Image(systemName: picks.contains(i.path) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picks.contains(i.path) ? Color.phosphor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(i.name).lineLimit(1)
                                    Text([Fmt.bytes(i.size), "added " + Fmt.date(i.added), i.source].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("\(k) → Downloads/\(k)")
                        Spacer()
                        Button(list.allSatisfy { picks.contains($0.path) } ? "None" : "All") {
                            if list.allSatisfy({ picks.contains($0.path) }) { picks.subtract(list.map(\.path)) } else { picks.formUnion(list.map(\.path)) }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tidy Downloads")
        .helpTip("Sorts loose downloads into folders by kind (Images, Documents…). Things in progress or just opened stay unticked. Undo is on the Mac.")
        .safeAreaInset(edge: .bottom) {
            if link.canEdit && !picks.isEmpty {
                Button { Task { await apply() } } label: {
                    Text("Tidy \(picks.count) file\(picks.count == 1 ? "" : "s") into folders").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).padding()
            }
        }
        .toolChrome(error: $error, toast: $toast)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let d = try await link.call("toolTidy")
            items = decode(d["items"] ?? []) ?? []
            picks = Set(items.filter { $0.flags.isEmpty }.map(\.path))   // flagged ones (in progress, opened recently) stay unticked
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func apply() async {
        do {
            let d = try await link.call("tidyApply", ["paths": Array(picks)])
            flash($toast, "Tidied \(d["moved"] as? Int ?? 0) files. Undo is on the Mac.")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Folder Autopilot

struct RuleR: Decodable, Identifiable { var id: String; var name: String; var enabled: Bool; var sentence: String; var action: String; var lastCount: Int; var waiting: Int; var lastRun: Double? }

struct AutopilotScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var rules: [RuleR] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            if loaded && rules.isEmpty {
                Text("No rules yet. Make them in Triage › Folder Autopilot on the Mac; they run every 15 minutes.").foregroundStyle(.secondary)
            }
            ForEach(rules) { r in
                Section {
                    Toggle(isOn: Binding(get: { r.enabled }, set: { on in Task { await set(r, on) } })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.name).font(.headline)
                            Text(r.sentence).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!link.canEdit)
                    HStack {
                        Text(r.waiting == 0 ? "Nothing waiting" : "\(r.waiting) file\(r.waiting == 1 ? "" : "s") waiting").font(.caption)
                        if let t = r.lastRun { Text("· last ran \(Fmt.date(t)) (\(r.lastCount))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if link.canEdit {
                            Button("Run now") { Task { await run(r) } }.buttonStyle(.bordered).controlSize(.small).disabled(r.waiting == 0)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Folder Autopilot")
        .helpTip("Rules that keep folders tidy on their own, every 15 minutes. Make rules on the Mac; switch them on and run them here.")
        .toolChrome(error: $error, toast: $toast)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { let d = try await link.call("toolRules"); rules = decode(d["rules"] ?? []) ?? [] } catch { self.error = error.localizedDescription }
        loaded = true
    }
    private func set(_ r: RuleR, _ on: Bool) async {
        do { let d = try await link.call("ruleSet", ["id": r.id, "enabled": on]); rules = decode(d["rules"] ?? []) ?? rules }
        catch { self.error = error.localizedDescription }
    }
    private func run(_ r: RuleR) async {
        do {
            let d = try await link.call("ruleRun", ["id": r.id])
            flash($toast, "Moved \(d["moved"] as? Int ?? 0) files. Undo is on the Mac.")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Converter

struct ConvTarget: Hashable { var ext: String; var label: String }
struct RenameRow: Hashable { var path: String; var name: String; var clash: Bool }

struct ConverterScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var files: [FileEntry] = []
    @State private var targets: [ConvTarget] = []
    @State private var to = ""
    @State private var quality = 0.85
    @State private var picking = false
    @State private var running = false
    @State private var progress = 0.0
    @State private var outputs: [String] = []
    @State private var failed: [String] = []
    @State private var error: String?
    @State private var toast: String?

    private var hasImages: Bool { ["jpg", "heic", "jp2", "mp4", "mov", "m4v", "gif"].contains(to) }

    var body: some View {
        List {
            Section {
                Button { picking = true } label: { Label(files.isEmpty ? "Choose files on \(link.macName)" : "Change files", systemImage: "plus.circle") }
                ForEach(files) { f in Label(f.name, systemImage: f.symbol).lineLimit(1) }
                    .onDelete { files.remove(atOffsets: $0); Task { await loadTargets() } }
            } header: { Text("Files") } footer: {
                Text("Images, PDFs, documents (Word, RTF, HTML, Markdown), audio, video and data (CSV, TSV, JSON). The new files land next to the originals.")
            }
            if !targets.isEmpty {
                Section("Convert to") {
                    Picker("Format", selection: $to) { ForEach(targets, id: \.ext) { Text($0.label).tag($0.ext) } }
                    if hasImages {
                        VStack(alignment: .leading) {
                            Text("Quality \(Int(quality * 100))%").font(.subheadline)
                            Slider(value: $quality, in: 0.3...1)
                        }
                    }
                }
                Section {
                    Button { Task { await convert() } } label: {
                        HStack { Text(running ? "Converting…" : "Convert \(files.count) file\(files.count == 1 ? "" : "s")").fontWeight(.semibold); Spacer(); if running { ProgressView(value: progress).frame(width: 90) } }
                    }
                    .disabled(running || to.isEmpty || !link.canEdit)
                }
            }
            if !outputs.isEmpty {
                Section("Made") { ForEach(outputs, id: \.self) { Label(name($0), systemImage: "checkmark.circle.fill").foregroundStyle(Color.healthy) } }
            }
            if !failed.isEmpty {
                Section("Didn't work") { ForEach(failed, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.coral) } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Converter")
        .helpTip("Converts images, PDFs, documents, audio, video and data files. The new files land next to the originals.")
        .sheet(isPresented: $picking) {
            MacFilePicker(title: "Files to convert") { picked in files = picked; outputs = []; failed = []; Task { await loadTargets() } }
        }
        .toolChrome(error: $error, toast: $toast)
    }

    private func loadTargets() async {
        targets = []; to = ""
        guard !files.isEmpty else { return }
        do {
            let d = try await link.call("convertTargets", ["paths": files.map(\.path)])
            targets = ((d["targets"] as? [[String: String]]) ?? []).compactMap { t in t["ext"].map { ConvTarget(ext: $0, label: t["label"] ?? $0) } }
            to = targets.first?.ext ?? ""
        } catch { self.error = error.localizedDescription }
    }

    private func convert() async {
        running = true; progress = 0; outputs = []; failed = []
        do {
            let d = try await link.call("convert", ["paths": files.map(\.path), "to": to, "quality": quality])
            guard let job = d["job"] as? String else { throw LinkError("The Mac didn't start the job") }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                let s = try await link.call("jobState", ["job": job])
                progress = Double(s["finished"] as? Int ?? 0) / Double(max(s["total"] as? Int ?? 1, 1))
                outputs = s["outputs"] as? [String] ?? []
                failed = s["failed"] as? [String] ?? []
                if (s["running"] as? Bool) != true { break }
            }
            flash($toast, "Converted \(outputs.count) file\(outputs.count == 1 ? "" : "s")")
        } catch { self.error = error.localizedDescription }
        running = false
    }
}

// MARK: - Batch Rename

struct RenameScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var files: [FileEntry] = []
    @State private var pattern = "{name}"
    @State private var find = ""
    @State private var replace = ""
    @State private var regex = false
    @State private var caseMode = "keep"
    @State private var start = 1
    @State private var pad = 2
    @State private var preview: [RenameRow] = []
    @State private var picking = false
    @State private var error: String?
    @State private var toast: String?

    private var key: String { [pattern, find, replace, "\(regex)", caseMode, "\(start)", "\(pad)", files.map(\.path).joined()].joined(separator: "|") }

    var body: some View {
        List {
            Section {
                Button { picking = true } label: { Label(files.isEmpty ? "Choose files on \(link.macName)" : "\(files.count) files · change", systemImage: "plus.circle") }
            }
            if !files.isEmpty {
                Section {
                    TextField("Pattern", text: $pattern).textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(["{name}", "{n}", "{date}", "{created}", "{folder}"], id: \.self) { t in
                                Button(t) { pattern += t }.buttonStyle(.bordered).controlSize(.small).font(.caption.monospaced())
                            }
                        }
                    }
                    Stepper("Numbers start at \(start)", value: $start, in: 0...9999)
                    Stepper("Digits: \(pad)", value: $pad, in: 1...6)
                } header: { Text("New name") } footer: { Text("{n} numbers the files in the order shown. {date} is the date modified.") }
                Section("Find and replace") {
                    TextField("Find", text: $find).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Replace with", text: $replace).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Regular expression", isOn: $regex)
                    Picker("Letters", selection: $caseMode) {
                        Text("Keep").tag("keep"); Text("lowercase").tag("lower"); Text("UPPERCASE").tag("upper"); Text("Title Case").tag("title"); Text("kebab-case").tag("kebab")
                    }
                }
                Section("Preview") {
                    ForEach(preview, id: \.path) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name(p.path)).font(.caption).foregroundStyle(.secondary).strikethrough(name(p.path) != p.name)
                            Text(p.name).font(.subheadline).foregroundStyle(p.clash ? Color.coral : .primary)
                        }
                    }
                    .onMove { from, to in files.move(fromOffsets: from, toOffset: to) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Batch Rename")
        .helpTip("Renames many files at once. {name} keeps the old name, {n} numbers them, {date} adds the date. Red means that name is taken.")
        .toolbar { if !files.isEmpty { EditButton() } }
        .safeAreaInset(edge: .bottom) {
            if link.canEdit && !files.isEmpty {
                let clashes = preview.filter(\.clash).count
                Button { Task { await apply() } } label: {
                    Text(clashes > 0 ? "Rename (\(clashes) clash\(clashes == 1 ? "" : "es") skipped)" : "Rename \(files.count) files")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).padding()
            }
        }
        .sheet(isPresented: $picking) { MacFilePicker(title: "Files to rename") { files = $0 } }
        .toolChrome(error: $error, toast: $toast)
        .task(id: key) {
            try? await Task.sleep(for: .milliseconds(250))     // let typing settle
            await load(apply: false)
        }
    }

    private var args: [String: Any] {
        ["paths": files.map(\.path), "pattern": pattern, "find": find, "replace": replace, "regex": regex, "case": caseMode, "start": start, "pad": pad]
    }

    private func load(apply: Bool) async {
        guard !files.isEmpty else { preview = []; return }
        if let d = try? await link.call("renamePreview", args), let p = d["preview"] as? [[String: Any]] {
            preview = p.map { RenameRow(path: $0["path"] as? String ?? "", name: $0["name"] as? String ?? "", clash: ($0["clash"] as? Bool) ?? false) }
        }
    }

    private func apply() async {
        do {
            let d = try await link.call("batchRename", args)
            let n = d["renamed"] as? Int ?? 0
            let skipped = (d["skipped"] as? [String]) ?? []
            flash($toast, "Renamed \(n)" + (skipped.isEmpty ? "" : ", skipped \(skipped.count)"))
            files = []; preview = []
        } catch { self.error = error.localizedDescription }
    }
}
