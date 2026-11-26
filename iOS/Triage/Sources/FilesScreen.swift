import SwiftUI
import QuickLook
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Places (the sidebar of the Mac's file manager)

struct FilesScreen: View {
    let path: String?
    @EnvironmentObject var link: MacLink
    @State private var places: [Place] = []
    @State private var query = ""
    @State private var results: [FileEntry]?
    @State private var searching = false

    var body: some View {
        Group {
            if let path { FolderScreen(path: path) } else { placesList }
        }
    }

    private var placesList: some View {
        List {
            if let results {
                Section("Results") {
                    if results.isEmpty { Text("Nothing matched.").foregroundStyle(.secondary) }
                    ForEach(results) { e in
                        NavigationLink(value: e.isDir ? e : FileEntry(name: (e.path as NSString).deletingLastPathComponent, path: (e.path as NSString).deletingLastPathComponent, dir: true)) {
                            FileRow(entry: e, subtitle: (e.path as NSString).deletingLastPathComponent.tildePath(home: link.info?.home))
                        }
                    }
                }
            } else {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(["largest videos", "big files in Downloads", "screenshots this week", "pdfs from last month", "dmg installers"], id: \.self) { s in
                                Button(s) { query = s; Task { await search() } }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } header: { Text("Ask your Mac") }
                Section("Places on \(link.macName)") {
                    ForEach(places) { p in
                        NavigationLink(value: FileEntry(name: p.name, path: p.path, dir: true)) {
                            Label(p.name, systemImage: p.symbol)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.glass900)
        .navigationTitle("Files")
        .navigationDestination(for: FileEntry.self) { e in FolderScreen(path: e.path) }
        .searchable(text: $query, prompt: "Ask: largest videos in Downloads")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, q in if q.isEmpty { results = nil } }
        .overlay { if searching { ProgressView() } }
        .task {
            if places.isEmpty, let d = try? await link.call("favorites"), let p: [Place] = decode(d["places"] ?? []) { places = p }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; return }
        searching = true
        defer { searching = false }
        if let d = try? await link.call("search", ["q": q, "limit": 150]) { results = decode(d["hits"] ?? []) ?? [] }
    }
}

// MARK: - One folder

struct FolderScreen: View {
    let path: String
    @EnvironmentObject var link: MacLink
    @Environment(\.horizontalSizeClass) private var hsc
    @AppStorage("files.grid") private var grid = false
    @AppStorage("files.sort") private var sort = "name"
    @AppStorage("files.hidden") private var hidden = false

    @State private var entries: [FileEntry] = []
    @State private var loading = true
    @State private var query = ""
    @State private var results: [FileEntry]?
    @State private var selection = Set<String>()
    @State private var selecting = false
    @State private var inspected: FileEntry?
    @State private var preview: URL?
    @State private var shareItems: [URL] = []
    @State private var sharing = false
    @State private var busy: String?
    @State private var progress = 0.0
    @State private var renaming: FileEntry?
    @State private var newName = ""
    @State private var makingFolder = false
    @State private var pickOp: String?
    @State private var pickItems: [FileEntry] = []
    @State private var confirmTrash: [FileEntry]?
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var error: String?
    @State private var toast: String?

    private var shown: [FileEntry] {
        let base = results ?? entries
        switch sort {
        case "date": return base.sorted { ($0.modified ?? 0) > ($1.modified ?? 0) }
        case "size": return base.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
        case "kind":
            return base.sorted {
                let a = $0.isDir ? "" : ($0.name as NSString).pathExtension.lowercased(), b = $1.isDir ? "" : ($1.name as NSString).pathExtension.lowercased()
                return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
            }
        default: return base.sorted { $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    private var picked: [FileEntry] { shown.filter { selection.contains($0.id) } }
    private var title: String { results != nil ? "Results" : (path as NSString).lastPathComponent }

    var body: some View {
        content
            .background(Color.glass900)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search this folder")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { _, q in if q.isEmpty { results = nil } }
            .toolbar { toolbar }
            .task(id: "\(path)|\(hidden)") { await load() }
            .refreshable { if results != nil { await search() } else { await load() } }
            .quickLookPreview($preview)
            .sheet(isPresented: $sharing) { ShareSheet(items: shareItems).presentationDetents([.medium, .large]) }
            .sheet(item: $inspected) { e in
                NavigationStack { FileInfo(entry: e, actions: actions(for: e)) }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: Binding(get: { pickOp != nil }, set: { if !$0 { pickOp = nil } })) {
                FolderPicker(start: path, verb: pickOp == "move" ? "Move Here" : "Copy Here") { dir in
                    if let op = pickOp { run(op, pickItems, to: dir) }
                }
                .environmentObject(link)
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName).textInputAutocapitalization(.never)
                Button("Rename") { if let e = renaming { rename(e, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New Folder", isPresented: $makingFolder) {
                TextField("Name", text: $newName)
                Button("Create") { mkdir(newName) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(trashTitle, isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }), titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { if let t = confirmTrash { trash(t) } }
            } message: { Text("They go to the Trash on \(link.macName), so you can still put them back.") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { uploadFiles(urls) }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in if !items.isEmpty { uploadPhotos(items) } }
            .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .overlay { hud }
            .overlay(alignment: .bottom) { toastView }
            .animation(.snappy, value: toast)
            .animation(.snappy, value: busy)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: hsc == .regular ? 120 : 100), spacing: 12)], spacing: 16) {
                    ForEach(shown) { e in cell(e) }
                }
                .padding(14)
                if !loading && shown.isEmpty { empty }
            }
        } else {
            List(selection: $selection) {
                ForEach(shown) { e in row(e) }
                if !loading && shown.isEmpty { empty.listRowBackground(Color.clear) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
        }
    }

    private var empty: some View {
        Text(results != nil ? "Nothing matched." : "This folder is empty.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
    }

    @ViewBuilder private func row(_ e: FileEntry) -> some View {
        Group {
            if e.isDir && !selecting {
                NavigationLink(value: e) { FileRow(entry: e) }
            } else {
                Button { tap(e) } label: { FileRow(entry: e) }.buttonStyle(.plain)
            }
        }
        .tag(e.id)
        .listRowBackground(Color.clear)
        .contextMenu { menu(e) }
        .swipeActions(edge: .trailing) {
            if link.canEdit && e.trashable == true { Button(role: .destructive) { confirmTrash = [e] } label: { Label("Trash", systemImage: "trash") } }
            Button { inspected = e } label: { Label("Info", systemImage: "info.circle") }.tint(.gray)
        }
        .swipeActions(edge: .leading) {
            if !e.isDir { Button { save([e]) } label: { Label("To iPhone", systemImage: "iphone.and.arrow.forward") }.tint(.phosphor) }
        }
    }

    private func cell(_ e: FileEntry) -> some View {
        let on = selection.contains(e.id)
        return Group {
            if e.isDir && !selecting {
                NavigationLink(value: e) { FileCell(entry: e, selected: on) }
            } else {
                Button { tap(e) } label: { FileCell(entry: e, selected: on) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { menu(e) }
    }

    private func tap(_ e: FileEntry) {
        if selecting {
            if selection.contains(e.id) { selection.remove(e.id) } else { selection.insert(e.id) }
        } else if !e.isDir {
            open(e)
        }
    }

    // MARK: Actions

    private func actions(for e: FileEntry) -> [FileAction] {
        var a: [FileAction] = []
        if !e.isDir {
            a.append(FileAction(title: "Open on iPhone", symbol: "eye") { open(e) })
            a.append(FileAction(title: "Save to iPhone or Share", symbol: "square.and.arrow.down.on.square") { save([e]) })
        }
        if link.canEdit {
            a.append(FileAction(title: "Open on Mac", symbol: "laptopcomputer") { simple("open", e, done: "Opened on \(link.macName)") })
            a.append(FileAction(title: "Show in Finder", symbol: "magnifyingglass") { simple("reveal", e, done: "Shown in Finder") })
            if e.trashable == true {
                a.append(FileAction(title: "Rename", symbol: "pencil") { newName = e.name; renaming = e })
                a.append(FileAction(title: "Move to…", symbol: "folder") { pickItems = [e]; pickOp = "move" })
            }
            a.append(FileAction(title: "Copy to…", symbol: "doc.on.doc") { pickItems = [e]; pickOp = "copy" })
            if e.trashable == true { a.append(FileAction(title: "Move to Trash", symbol: "trash", destructive: true) { confirmTrash = [e] }) }
        }
        return a
    }

    @ViewBuilder private func menu(_ e: FileEntry) -> some View {
        ForEach(actions(for: e)) { a in
            Button(role: a.destructive ? .destructive : nil, action: a.run) { Label(a.title, systemImage: a.symbol) }
        }
        Button { inspected = e } label: { Label("Get Info", systemImage: "info.circle") }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button("Done") { selecting = false; selection = [] }.fontWeight(.semibold)
            } else {
                Menu {
                    if link.canEdit {
                        Section("Send to \(link.macName)") {
                            Button { importing = true } label: { Label("Files from iPhone", systemImage: "doc.badge.arrow.up") }
                            Button { showPhotos = true } label: { Label("Photos & Videos", systemImage: "photo.badge.arrow.down") }
                            Button { newName = "New Folder"; makingFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        }
                    }
                    Section {
                        Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                        Picker(selection: $grid) {
                            Label("Icons", systemImage: "square.grid.2x2").tag(true)
                            Label("List", systemImage: "list.bullet").tag(false)
                        } label: { Text("View") }
                        Picker(selection: $sort) {
                            Text("Name").tag("name"); Text("Date Modified").tag("date"); Text("Size").tag("size"); Text("Kind").tag("kind")
                        } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
                        Toggle(isOn: $hidden) { Label("Show Hidden Files", systemImage: "eye.slash") }
                    }
                    if link.canEdit {
                        Button { simple("reveal", FileEntry(name: title, path: path, dir: true), done: "Shown in Finder") } label: { Label("Show in Finder on Mac", systemImage: "laptopcomputer") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { save(picked.filter { !$0.isDir }) } label: { Label("To iPhone", systemImage: "iphone.and.arrow.forward") }
                    .disabled(picked.filter { !$0.isDir }.isEmpty)
                Spacer()
                Button { pickItems = picked.filter { $0.trashable == true }; pickOp = "move" } label: { Label("Move", systemImage: "folder") }
                    .disabled(!link.canEdit || picked.filter { $0.trashable == true }.isEmpty)
                Spacer()
                Button { pickItems = picked; pickOp = "copy" } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(!link.canEdit || picked.isEmpty)
                Spacer()
                Text(selection.isEmpty ? "Select" : "\(selection.count) · \(Fmt.bytes(picked.compactMap(\.size).reduce(0, +)))")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { confirmTrash = picked.filter { $0.trashable == true } } label: { Label("Trash", systemImage: "trash") }
                    .disabled(!link.canEdit || picked.filter { $0.trashable == true }.isEmpty)
            }
        }
    }

    private var trashTitle: String {
        let t = confirmTrash ?? []
        let size = Fmt.bytes(t.compactMap(\.size).reduce(0, +))
        return t.count == 1 ? "Move \(t[0].name) (\(size)) to the Trash?" : "Move \(t.count) items (\(size)) to the Trash?"
    }

    @ViewBuilder private var hud: some View {
        if let busy {
            VStack(spacing: 10) {
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 180).tint(.phosphor)
                Text(busy).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if loading && entries.isEmpty {
            ProgressView()
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, selecting ? 70 : 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func say(_ s: String) {
        toast = s
        Task { try? await Task.sleep(for: .seconds(2.5)); if toast == s { toast = nil } }
    }

    // MARK: Talking to the Mac

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await link.call("list", ["path": path, "hidden": hidden])
            entries = decode(d["entries"] ?? []) ?? []
        } catch { self.error = error.localizedDescription }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; return }
        loading = true
        defer { loading = false }
        if let d = try? await link.call("search", ["q": q, "scope": path, "limit": 150]) { results = decode(d["hits"] ?? []) ?? [] }
    }

    private func fetch(_ items: [FileEntry]) async -> [URL] {
        var out: [URL] = []
        for (i, e) in items.enumerated() {
            busy = items.count == 1 ? "Getting \(e.name)…" : "Getting \(i + 1) of \(items.count): \(e.name)"
            progress = 0
            do { out.append(try await link.download(e.path) { progress = $0 }) } catch { self.error = error.localizedDescription; break }
        }
        busy = nil
        return out
    }

    private func open(_ e: FileEntry) {
        Task { if let u = await fetch([e]).first { preview = u } }
    }

    /// Mac → iPhone: download, then the share sheet's Save to Files / Photos / AirDrop / any app.
    private func save(_ items: [FileEntry]) {
        Task {
            let urls = await fetch(items)
            guard !urls.isEmpty else { return }
            shareItems = urls
            sharing = true
            selecting = false; selection = []
        }
    }

    private func simple(_ op: String, _ e: FileEntry, done: String) {
        Task {
            do { _ = try await link.call(op, ["path": e.path]); say(done) } catch { self.error = error.localizedDescription }
        }
    }

    private func rename(_ e: FileEntry, to n: String) {
        Task {
            do {
                _ = try await link.call("rename", ["path": e.path, "name": n])
                UISelectionFeedbackGenerator().selectionChanged()
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func mkdir(_ n: String) {
        Task {
            do { _ = try await link.call("mkdir", ["dir": path, "name": n]); await load() } catch { self.error = error.localizedDescription }
        }
    }

    private func run(_ op: String, _ items: [FileEntry], to dir: String) {
        Task {
            do {
                let d = try await link.call(op, ["paths": items.map(\.path), "dir": dir])
                let ok = (d["done"] as? [String])?.count ?? 0
                say("\(op == "move" ? "Moved" : "Copied") \(ok) item\(ok == 1 ? "" : "s") to \((dir as NSString).lastPathComponent)")
                selecting = false; selection = []
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func trash(_ items: [FileEntry]) {
        Task {
            do {
                let d = try await link.call("trash", ["paths": items.map(\.path)])
                let done = (d["trashed"] as? [String]) ?? []
                let freed = items.filter { done.contains($0.path) }.compactMap(\.size).reduce(0, +)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                say("Breathing room: \(Fmt.bytes(freed)) moved to the Trash")
                entries.removeAll { done.contains($0.path) }
                results?.removeAll { done.contains($0.path) }
                selecting = false; selection = []; inspected = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    /// iPhone → Mac: anything from the Files app (iCloud Drive, On My iPhone, other apps' folders).
    private func uploadFiles(_ urls: [URL]) {
        Task {
            var sent = 0
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: u) else { continue }
                busy = "Sending \(u.lastPathComponent)…"; progress = 0
                do { _ = try await link.upload(data, name: u.lastPathComponent, to: path) { progress = $0 }; sent += 1 } catch { self.error = error.localizedDescription }
            }
            busy = nil
            if sent > 0 { say("Sent \(sent) file\(sent == 1 ? "" : "s") to \(link.macName)"); await load() }
        }
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var sent = 0
            for (i, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)", timeZone: .current, calendar: .current))
                let name = "iPhone \(stamp) \(i + 1).\(ext)"
                busy = "Sending \(i + 1) of \(items.count)…"; progress = 0
                do { _ = try await link.upload(data, name: name, to: path) { progress = $0 }; sent += 1 } catch { self.error = error.localizedDescription }
            }
            busy = nil
            photoItems = []
            if sent > 0 { say("Sent \(sent) to \(link.macName)"); await load() }
        }
    }
}

// MARK: - Pieces

struct FileAction: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    var destructive = false
    let run: () -> Void
}

struct FileRow: View {
    let entry: FileEntry
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            ThumbView(entry: entry, size: 80).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                Text(subtitle ?? entry.modified.map { "Modified \(Fmt.date($0))" } ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let s = entry.size, !entry.isDir {
                Text(Fmt.bytes(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct FileCell: View {
    let entry: FileEntry
    var selected = false
    var body: some View {
        VStack(spacing: 6) {
            ThumbView(entry: entry, size: 200)
                .frame(width: 72, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.phosphor).font(.title3).offset(x: 6, y: 6) }
                }
            Text(entry.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            if let s = entry.size, !entry.isDir { Text(Fmt.bytes(s)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(selected ? Color.phosphor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Real thumbnails from the Mac's Quick Look for pictures, PDFs and videos; icons for the rest.
struct ThumbView: View {
    let entry: FileEntry
    var size = 120
    @EnvironmentObject var link: MacLink
    @State private var image: UIImage?

    private var wantsThumb: Bool {
        guard !entry.isDir else { return false }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "pdf", "mov", "mp4", "m4v", "key", "pages", "numbers", "psd", "svg"].contains(ext)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: entry.symbol)
                    .resizable().scaledToFit().padding(entry.isDir ? 2 : 6)
                    .foregroundStyle(entry.isDir ? Color.phosphor : .secondary)
            }
        }
        .task(id: entry.path) {
            guard wantsThumb else { return }
            let key = "\(entry.path)|\(size)" as NSString
            if let hit = ThumbCache.shared.object(forKey: key) { image = hit; return }
            guard let d = try? await link.call("thumb", ["path": entry.path, "size": size]),
                  let b = (d["jpg"] as? String).flatMap({ Data(base64Encoded: $0) }), let img = UIImage(data: b) else { return }
            ThumbCache.shared.setObject(img, forKey: key)
            image = img
        }
    }
}

enum ThumbCache {
    static let shared: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.countLimit = 400; return c }()
}

private struct FileInfo: View {
    let entry: FileEntry
    let actions: [FileAction]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ThumbView(entry: entry, size: 400).frame(width: 140, height: 140)
                    Text(entry.name).font(.headline).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                if let s = entry.size { LabeledContent("Size", value: Fmt.bytes(s)) }
                if let m = entry.modified { LabeledContent("Modified", value: Date(timeIntervalSince1970: m).formatted(date: .abbreviated, time: .shortened)) }
                if let u = entry.used { LabeledContent("Last opened", value: Date(timeIntervalSince1970: u).formatted(date: .abbreviated, time: .shortened)) }
                if let t = entry.type { LabeledContent("Kind", value: UTType(t)?.localizedDescription ?? t) }
                LabeledContent("Where", value: (entry.path as NSString).deletingLastPathComponent)
            }
            Section {
                ForEach(actions) { a in
                    Button(role: a.destructive ? .destructive : nil) { dismiss(); a.run() } label: { Label(a.title, systemImage: a.symbol) }
                }
            } footer: {
                if entry.trashable != true { Text("Triage protects system, Library and hidden files from remote changes.") }
            }
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Browse to a folder on the Mac to move or copy into.
struct FolderPicker: View {
    let start: String
    let verb: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PickerFolder(path: start, verb: verb) { dir in choose(dir); dismiss() }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct PickerFolder: View {
    let path: String
    let verb: String
    let choose: (String) -> Void
    @EnvironmentObject var link: MacLink
    @State private var dirs: [FileEntry] = []

    var body: some View {
        List {
            if path != "/" {
                NavigationLink { PickerFolder(path: (path as NSString).deletingLastPathComponent, verb: verb, choose: choose) } label: {
                    Label("Up to \(((path as NSString).deletingLastPathComponent as NSString).lastPathComponent)", systemImage: "arrow.turn.left.up")
                }
            }
            ForEach(dirs) { d in
                NavigationLink { PickerFolder(path: d.path, verb: verb, choose: choose) } label: { Label(d.name, systemImage: "folder.fill") }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(verb) { choose(path) } } }
        .task {
            if let d = try? await link.call("list", ["path": path]), let all: [FileEntry] = decode(d["entries"] ?? []) { dirs = all.filter(\.isDir) }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension String {
    func tildePath(home: String?) -> String {
        guard let home, hasPrefix(home) else { return self }
        return "~" + dropFirst(home.count)
    }
}

extension FileEntry {
    init(name: String, path: String, dir: Bool) {
        self.name = name; self.path = path; self.dir = dir
        size = nil; modified = nil; used = nil; type = nil; trashable = nil
    }
}
