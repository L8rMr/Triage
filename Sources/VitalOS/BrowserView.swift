import SwiftUI
import AppKit
import QuickLook

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("viewMode") private var mode = "grid"
    @AppStorage("inspector") private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbar(pane: model.active, mode: $mode)
            HStack(spacing: 1) {
                ForEach(Array(model.panes.enumerated()), id: \.element.id) { i, pane in
                    PaneView(pane: pane, isActive: i == model.activePane, mode: mode)
                        .simultaneousGesture(TapGesture().onEnded { model.activePane = i })
                }
                if showInspector { InspectorSlot(pane: model.active) }
            }
            if let busy = model.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.ui(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.black.opacity(0.4))
            }
        }
        .quickLookPreview($model.peek)
    }
}

struct BrowserToolbar: View {
    @ObservedObject var pane: Pane
    @Binding var mode: String
    @EnvironmentObject var model: AppModel
    @AppStorage("inspector") private var showInspector = true
    @AppStorage("groupBy") private var groupBy = GroupBy.kind.rawValue

    private var currentSortKey: String { pane.sortKey }
    private var sortAscending: Bool { pane.sortAscending }

    var body: some View {
        HStack(spacing: 14) {
            Text(Places.name(pane.url))
                .font(.ui(size: 17, weight: .bold, design: .rounded))
            Spacer()
            Group {
                Button { model.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help("New Folder (⇧⌘N)")
                Button { model.peek = pane.selection.first } label: { Image(systemName: "eye") }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Peek (Space)")
                    .disabled(pane.selection.isEmpty)
                Button { model.trash(Array(pane.selection)) } label: { Image(systemName: "trash") }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Move to Trash (⌘⌫)")
                    .disabled(pane.selection.isEmpty)
                Button { FileOps.openTerminal(at: pane.url) } label: { Image(systemName: "terminal") }
                    .help("Open in Terminal (⌥⇧⌘T)")
            }
            Divider().frame(height: 18)
            if model.panes.count > 1 {
                Button { model.transfer(Array(pane.selection), move: false) } label: {
                    Label("Copy  F5", systemImage: "doc.on.doc")
                }
                .disabled(pane.selection.isEmpty)
                Button { model.transfer(Array(pane.selection), move: true) } label: {
                    Label("Move  F6", systemImage: "arrow.right.doc.on.clipboard")
                }
                .disabled(pane.selection.isEmpty)
            }
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .help("Info & “Can I delete this?” (⌥⌘I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button { model.toggleSplit() } label: {
                Image(systemName: model.panes.count > 1 ? "rectangle" : "rectangle.split.2x1")
            }
            .help("Dual pane (⌘D)")
            Menu {
                Picker("Sort by", selection: Binding(get: { currentSortKey }, set: { pane.setSort($0, ascending: sortAscending) })) {
                    Text("Name").tag("name"); Text("Kind").tag("kind"); Text("Date modified").tag("modified")
                    Text("Date added").tag("added"); Text("Size").tag("size")
                }
                Picker("Order", selection: Binding(get: { sortAscending }, set: { pane.setSort(currentSortKey, ascending: $0) })) {
                    Text("Ascending").tag(true); Text("Descending").tag(false)
                }
                Divider()
                Picker("Group by", selection: $groupBy) {
                    ForEach(GroupBy.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort and group")
            Picker("", selection: $mode) {
                Image(systemName: "square.grid.2x2").tag("grid")
                Image(systemName: "list.bullet").tag("list")
            }
            .pickerStyle(.segmented)
            .frame(width: 80)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

struct PaneView: View {
    @ObservedObject var pane: Pane
    let isActive: Bool
    let mode: String
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false
    @AppStorage("groupBy") private var groupBy = GroupBy.kind.rawValue

    var body: some View {
        VStack(spacing: 0) {
            PathBar(pane: pane)
            if pane.waiting && pane.items.isEmpty && !pane.accessDenied {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening \(pane.url.lastPathComponent)…").font(.ui(size: 13, weight: .medium))
                    Text("If this takes a while, macOS is probably asking whether VitalOS may open this folder. Look for the prompt and click Allow.")
                        .font(.ui(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if pane.accessDenied {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.ui(size: 28)).foregroundStyle(.secondary)
                    Text("VitalOS isn't allowed to open \(pane.url.lastPathComponent)").font(.ui(size: 14, weight: .semibold))
                    Text("macOS asks once per folder. Turn VitalOS on under Files & Folders (or Full Disk Access), then try again.")
                        .font(.ui(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    HStack {
                        Button("Open Privacy Settings") { NSWorkspace.shared.open(Perm.files.settingsURL) }
                        Button("Try Again") { pane.reload() }.buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if mode == "grid" && !pane.accessDenied {
                HStack(spacing: 8) {
                    FilterPill("Name", text: $pane.filterText)
                    FilterPill("Kind", options: pane.kindOptions, selection: $pane.filterKinds)
                    FilterPill("Size", options: pane.sizeOptions, selection: $pane.filterSizes)
                    FilterPill("Modified", options: pane.dateOptions, selection: $pane.filterDates)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            if pane.isFiltered {
                FilterSummary(shown: pane.visible.count, total: pane.items.count,
                              bytes: pane.visible.reduce(0) { $0 + $1.size }, clear: pane.clearFilters)
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
            Rectangle().fill(isActive && model.panes.count > 1 ? Theme.accent : Theme.stroke).frame(height: 1)
            Group {
                if pane.visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: pane.isFiltered ? "line.3.horizontal.decrease.circle" : "tray")
                            .font(.ui(size: 30)).foregroundStyle(.tertiary)
                        Text(pane.isFiltered ? "Nothing here matches your filters"
                                             : "Empty folder, or macOS hasn't given VitalOS access yet")
                            .font(.ui(size: 12)).foregroundStyle(.secondary)
                        if pane.isFiltered { Button("Clear filters") { pane.clearFilters() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if mode == "grid" {
                    grid
                } else {
                    table
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, lineWidth: 2)
                    .opacity(dropTargeted ? 1 : 0).padding(4)
            )
            .dropDestination(for: URL.self) { urls, _ in
                model.drop(urls, into: pane.url)
                return true
            } isTargeted: { dropTargeted = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func select(_ item: FileItem) {
        model.activePane = model.panes.firstIndex { $0.id == pane.id } ?? 0
        if NSEvent.modifierFlags.contains(.command) {
            if pane.selection.contains(item.url) { pane.selection.remove(item.url) } else { pane.selection.insert(item.url) }
        } else {
            pane.selection = [item.url]
        }
    }

    private func targets(_ item: FileItem) -> [URL] {
        pane.selection.contains(item.url) ? Array(pane.selection) : [item.url]
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Grouper.group(pane.visible, by: GroupBy(rawValue: groupBy) ?? .none)) { group in
                    if !group.id.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: group.symbol).foregroundStyle(Theme.accent)
                            Text(group.id).font(.ui(size: 13, weight: .semibold))
                            Text("\(group.items.count)").font(.ui(size: 11)).foregroundStyle(.secondary)
                            if group.total > 0 {
                                Text("· \(Fmt.bytes(group.total))").font(.ui(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 160), spacing: 14)], spacing: 14) {
                        ForEach(group.items) { item in
                            FileCard(item: item, selected: pane.selection.contains(item.url))
                                .onTapGesture(count: 2) { model.open(item.url, in: pane) }
                                .onTapGesture { select(item) }
                                .contextMenu { FileMenu(urls: targets(item), pane: pane, model: model) }
                                .draggable(item.url)
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { pane.selection = [] })
    }

    private var table: some View {
        FileListView(pane: pane, model: model)
    }
}

/// List view built from the shared column headers: sort by clicking a title, filter from the funnel in each column.
struct FileListView: View {
    @ObservedObject var pane: Pane
    let model: AppModel
    @State private var anchor: URL?
    @State private var safetyFilter: Set<String> = []
    @ObservedObject private var safety = SafetyCache.shared

    private var rows: [FileItem] {
        guard !safetyFilter.isEmpty else { return pane.visible }
        return pane.visible.filter { f in
            guard let v = safety.verdicts[f.url] else { return true }
            return safetyFilter.contains(v.level.title)
        }
    }

    private let wKind: CGFloat = 120, wSize: CGFloat = 96, wDate: CGFloat = 156

    private var sortBinding: Binding<ColumnSort> {
        Binding(get: { ColumnSort(key: pane.sortKey, ascending: pane.sortAscending) },
                set: { pane.setSort($0.key, ascending: $0.ascending) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 28, height: 1)
                ColumnHeader("Name", sortKey: "name", sort: sortBinding, text: $pane.filterText)
                ColumnHeader("Kind", width: wKind, sortKey: "kind", sort: sortBinding,
                             options: pane.kindOptions, selection: $pane.filterKinds)
                ColumnHeader("Size", width: wSize, sortKey: "size", sort: sortBinding,
                             options: pane.sizeOptions, selection: $pane.filterSizes, defaultAscending: false)
                ColumnHeader("Modified", width: wDate, sortKey: "modified", sort: sortBinding,
                             options: pane.dateOptions, selection: $pane.filterDates, defaultAscending: false)
                ColumnHeader("Delete?", width: 70, sort: sortBinding,
                             options: Safety.allCases.map { FilterOption(id: $0.title, label: $0.title, symbol: $0.symbol) },
                             selection: $safetyFilter)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            Rectangle().fill(Theme.stroke).frame(height: 0.5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { item in row(item) }
                }
                .padding(.vertical, 4)
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { pane.selection = [] })
        }
    }

    private func row(_ item: FileItem) -> some View {
        let selected = pane.selection.contains(item.url)
        return HStack(spacing: 0) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 18, height: 18)
                .frame(width: 28, alignment: .leading)
            Text(item.name).font(.ui(size: 12)).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            Text(item.isDir ? "Folder" : FileKind.of(item.url.pathExtension).rawValue)
                .font(.ui(size: 12)).foregroundStyle(.secondary)
                .frame(width: wKind, alignment: .leading)
            Text(item.isDir ? "—" : Fmt.bytes(item.size)).font(.ui(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: wSize, alignment: .leading)
            Text(item.modified, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                .font(.ui(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: wDate, alignment: .leading)
            SafetyBadge(url: item.url).frame(width: 70, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(selected ? Theme.accent.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(item.url, in: pane) }
        .onTapGesture { select(item) }
        .contextMenu {
            FileMenu(urls: selected ? Array(pane.selection) : [item.url], pane: pane, model: model)
        }
        .draggable(item.url)
    }

    private func select(_ item: FileItem) {
        model.activePane = model.panes.firstIndex { $0.id == pane.id } ?? 0
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let a = anchor,
           let i = pane.visible.firstIndex(where: { $0.url == a }),
           let j = pane.visible.firstIndex(where: { $0.url == item.url }) {
            pane.selection = Set(pane.visible[min(i, j)...max(i, j)].map(\.url))
        } else if flags.contains(.command) {
            if pane.selection.contains(item.url) { pane.selection.remove(item.url) } else { pane.selection.insert(item.url) }
            anchor = item.url
        } else {
            pane.selection = [item.url]
            anchor = item.url
        }
    }
}

struct FileMenu: View {
    let urls: [URL]
    let pane: Pane
    let model: AppModel

    var body: some View {
        Button("Open") { urls.forEach { model.open($0, in: pane) } }
        Button("Peek") { model.peek = urls.first }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        Button("Open in Terminal") {
            if let u = urls.first { FileOps.openTerminal(at: FS.isFolder(u) ? u : u.deletingLastPathComponent()) }
        }
        Button("Can I Delete This?") {
            pane.selection = Set(urls)
            UserDefaults.standard.set(true, forKey: "inspector")
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        }
        if model.panes.count > 1 {
            Divider()
            Button("Copy to Other Pane") { model.transfer(urls, move: false) }
            Button("Move to Other Pane") { model.transfer(urls, move: true) }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trash(urls) }
    }
}

struct PathBar: View {
    @ObservedObject var pane: Pane

    var body: some View {
        HStack(spacing: 6) {
            Button { pane.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!pane.canGoBack)
            Button { pane.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!pane.canGoForward)
            Button { pane.goUp() } label: { Image(systemName: "arrow.up") }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(pane.crumbs, id: \.self) { u in
                        Button(Places.name(u)) { pane.go(u) }
                            .buttonStyle(.plain)
                            .font(.ui(size: 12, weight: u.path == pane.url.standardizedFileURL.path ? .semibold : .regular))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        if u.path != pane.url.standardizedFileURL.path {
                            Image(systemName: "chevron.compact.right").font(.ui(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if let b = pane.gitBranch {
                Label(b, systemImage: "arrow.triangle.branch")
                    .font(.ui(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(Theme.accent)
                    .help("Git branch")
            }
            Text("\(pane.items.count) items").font(.ui(size: 11)).foregroundStyle(.secondary)
            Toggle(isOn: $pane.showHidden) { Image(systemName: "eye.slash") }
                .toggleStyle(.button)
                .help("Show hidden files (⇧⌘.)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct FileCard: View {
    let item: FileItem
    let selected: Bool
    @State private var count: Int?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 7) {
            Group {
                if item.isDir { FolderGlyph().frame(width: 64, height: 56) } else { Thumb(url: item.url, size: 96) }
            }
            .frame(height: 82)
            Text(item.name)
                .font(.ui(size: 12, weight: .medium))
                .lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center)
            Text(item.isDir ? (count.map { "\($0) item\($0 == 1 ? "" : "s")" } ?? " ") : Fmt.bytes(item.size))
                .font(.ui(size: 10)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 140, height: 160)
        .glass(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Theme.accent : (hover ? Color.primary.opacity(0.18) : .clear), lineWidth: selected ? 1.5 : 1)
        )
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .task(id: item.url) {
            guard item.isDir else { return }
            let path = item.url.path
            count = await Work.run {
                (try? FileManager.default.contentsOfDirectory(atPath: path).filter { !$0.hasPrefix(".") }.count) ?? 0
            }
        }
    }
}

final class SpotlightSearch: ObservableObject {
    @Published var results: [URL] = []
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var term = ""

    init() {
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                self?.collect()
            })
        }
    }

    deinit {
        query.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func search(_ text: String) {
        query.stop()
        term = text.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { results = []; return }
        query.predicate = NSPredicate(format: "(%K CONTAINS[cd] %@) OR (kMDItemTextContent CONTAINS[cd] %@)",
                                      NSMetadataItemFSNameKey, term, term)
        query.start()
    }

    private func collect() {
        query.disableUpdates()
        var out: [URL] = []
        for i in 0..<min(query.resultCount, 200) {
            if let item = query.result(at: i) as? NSMetadataItem,
               let p = item.value(forAttribute: NSMetadataItemPathKey) as? String,
               !p.contains("/Library/") {
                out.append(URL(fileURLWithPath: p))
            }
        }
        query.enableUpdates()
        let t = term.lowercased()
        // Folders whose name matches, then files whose name matches, then files that only match by content.
        func rank(_ u: URL) -> Int {
            let nameHit = u.lastPathComponent.lowercased().contains(t)
            if nameHit && u.hasDirectoryPath { return 0 }
            return nameHit ? 1 : 2
        }
        results = Array(out.sorted { rank($0) < rank($1) }.prefix(60))
    }
}

struct SearchPalette: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var search = SpotlightSearch()
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search folders, files and text inside documents", text: $text)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 18))
                    .focused($focused)
                    .onSubmit { if let u = search.results.first { open(u) } }
                Button("esc") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .font(.ui(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(search.results, id: \.self) { u in
                        Button { open(u) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(u.lastPathComponent).font(.ui(size: 13, weight: .medium)).lineLimit(1)
                                    Text(Places.abbreviate(u.deletingLastPathComponent().path))
                                        .font(.ui(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if !u.lastPathComponent.lowercased().contains(text.lowercased()) {
                                    Text("text match").font(.ui(size: 10)).foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if text.count >= 2 && search.results.isEmpty {
                        Text("Nothing yet…").font(.ui(size: 12)).foregroundStyle(.secondary).padding(20)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 640, height: 460)
        .background(Theme.bg)
        .onAppear { focused = true }
        .onChange(of: text) { _, t in search.search(t) }
    }

    private func open(_ u: URL) {
        dismiss()
        model.open(u)
    }
}


/// Shows the inspector for whatever is selected in the active pane.
struct InspectorSlot: View {
    @ObservedObject var pane: Pane
    var body: some View {
        if let u = pane.selection.count == 1 ? pane.selection.first : nil {
            FileInspector(url: u)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right").font(.ui(size: 26)).foregroundStyle(.tertiary)
                Text(pane.selection.isEmpty ? "Select a file to see its details and whether it's safe to delete."
                                            : "\(pane.selection.count) items selected")
                    .font(.ui(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(width: 270)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
        }
    }
}
