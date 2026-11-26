import SwiftUI

struct FilesScreen: View {
    let path: String?
    @EnvironmentObject var link: MacLink
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var entries: [FileEntry] = []
    @State private var shownPath = ""
    @State private var loading = true
    @State private var query = ""
    @State private var results: [FileEntry]?
    @State private var searching = false
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var inspected: FileEntry?
    @State private var confirmTrash = false
    @State private var error: String?
    @State private var toast: String?

    private var shown: [FileEntry] { results ?? entries }
    private var title: String {
        if results != nil { return "Results" }
        if path == nil { return "Home" }
        return (shownPath as NSString).lastPathComponent
    }
    private var picked: [FileEntry] { shown.filter { selection.contains($0.id) } }

    var body: some View {
        List(selection: $selection) {
            if path == nil && results == nil && query.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(["largest videos", "big files in Downloads", "screenshots this week", "pdfs from last month", "dmg installers"], id: \.self) { s in
                                Button(s) { query = s; Task { await search() } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } header: { Text("Try asking") }
            }
            Section {
                ForEach(shown) { e in
                    if e.isDir {
                        NavigationLink(value: e) { row(e) }
                    } else {
                        Button { inspected = e } label: { row(e) }.buttonStyle(.plain)
                    }
                }
            } footer: {
                if !loading && shown.isEmpty { Text(results != nil ? "Nothing matched." : "This folder is empty.") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(path == nil ? .large : .inline)
        .navigationDestination(for: FileEntry.self) { e in FilesScreen(path: e.path) }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Ask your Mac: largest videos in Downloads")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, q in if q.isEmpty { results = nil } }
        .overlay { if loading || searching { ProgressView() } }
        .toolbar {
            if link.canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode.isEditing ? "Done" : "Select") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active; selection = [] }
                    }
                }
            }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Text(selection.isEmpty ? "Select items" : "\(selection.count) selected · \(Fmt.bytes(picked.compactMap(\.size).reduce(0, +)))")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { confirmTrash = true } label: { Label("Move to Trash", systemImage: "trash") }
                        .disabled(picked.filter { $0.trashable == true }.isEmpty)
                }
            }
        }
        .task(id: path) { await load() }
        .refreshable { if results != nil { await search() } else { await load() } }
        .inspector(isPresented: Binding(get: { inspected != nil && hsc == .regular }, set: { if !$0 { inspected = nil } })) {
            if let e = inspected { FileDetail(entry: e, onTrash: { trash([e]) }) }
        }
        .sheet(isPresented: Binding(get: { inspected != nil && hsc != .regular }, set: { if !$0 { inspected = nil } })) {
            if let e = inspected {
                NavigationStack { FileDetail(entry: e, onTrash: { trash([e]) }) }
                    .presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog(trashTitle, isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { trash(picked) }
        } message: {
            Text("They go to the Trash on \(link.macName), so you can still put them back from there.")
        }
        .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toast)
    }

    private var trashTitle: String {
        let ok = picked.filter { $0.trashable == true }
        let size = Fmt.bytes(ok.compactMap(\.size).reduce(0, +))
        return ok.count == 1 ? "Move \(ok[0].name) (\(size)) to the Trash?" : "Move \(ok.count) items (\(size)) to the Trash?"
    }

    private func row(_ e: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: e.symbol)
                .font(.title3)
                .foregroundStyle(e.isDir ? Color.phosphor : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).lineLimit(1)
                Text(subtitle(e)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let s = e.size, !e.isDir {
                Text(Fmt.bytes(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func subtitle(_ e: FileEntry) -> String {
        if results != nil {
            return ((e.path as NSString).deletingLastPathComponent as NSString).tildePath(home: link.info?.home)
        }
        return e.modified.map { "Modified \(Fmt.date($0))" } ?? ""
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await link.call("list", path.map { ["path": $0] } ?? [:])
            shownPath = d["path"] as? String ?? ""
            entries = decode(d["entries"] ?? []) ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; return }
        searching = true
        defer { searching = false }
        // inside a folder, search that folder; at Home, the whole Mac
        var args: [String: Any] = ["q": q, "limit": 150]
        if path != nil { args["scope"] = shownPath }
        do {
            let d = try await link.call("search", args)
            results = decode(d["hits"] ?? []) ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func trash(_ items: [FileEntry]) {
        let paths = items.filter { $0.trashable == true }.map(\.path)
        guard !paths.isEmpty else { return }
        Task {
            do {
                let d = try await link.call("trash", ["paths": paths])
                let done = (d["trashed"] as? [String]) ?? []
                let failed = (d["failed"] as? [[String: String]]) ?? []
                UINotificationFeedbackGenerator().notificationOccurred(failed.isEmpty ? .success : .warning)
                let freed = items.filter { done.contains($0.path) }.compactMap(\.size).reduce(0, +)
                toast = failed.isEmpty ? "Breathing room: \(Fmt.bytes(freed)) moved to the Trash" : "\(done.count) moved, \(failed.count) couldn't be"
                entries.removeAll { done.contains($0.path) }
                results?.removeAll { done.contains($0.path) }
                selection = []
                inspected = nil
                withAnimation { editMode = .inactive }
                try? await Task.sleep(for: .seconds(2.5))
                toast = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct FileDetail: View {
    let entry: FileEntry
    let onTrash: () -> Void
    @EnvironmentObject var link: MacLink
    @State private var confirm = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: entry.symbol).font(.system(size: 54)).foregroundStyle(Color.phosphor)
                    Text(entry.name).font(.headline).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
            Section {
                if let s = entry.size { LabeledContent("Size", value: Fmt.bytes(s)) }
                if let m = entry.modified { LabeledContent("Modified", value: Date(timeIntervalSince1970: m).formatted(date: .abbreviated, time: .shortened)) }
                if let u = entry.used { LabeledContent("Last opened", value: Date(timeIntervalSince1970: u).formatted(date: .abbreviated, time: .shortened)) }
                if let t = entry.type { LabeledContent("Kind", value: t) }
                LabeledContent("Where", value: (entry.path as NSString).deletingLastPathComponent)
            }
            if link.canEdit {
                Section {
                    Button(role: .destructive) { confirm = true } label: { Label("Move to Trash", systemImage: "trash") }
                        .disabled(entry.trashable != true)
                } footer: {
                    if entry.trashable != true { Text("Triage protects system and Library files from remote deletes.") }
                }
            }
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Move \(entry.name) to the Trash on \(link.macName)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive, action: onTrash)
        }
    }
}

extension NSString {
    func tildePath(home: String?) -> String {
        guard let home, (self as String).hasPrefix(home) else { return self as String }
        return "~" + (self as String).dropFirst(home.count)
    }
}
