import SwiftUI

struct AppsScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var apps: [AppInfo] = []
    @State private var sort = "cpu"
    @State private var confirm: (app: AppInfo, force: Bool)?
    @State private var error: String?
    @State private var toast: String?

    private var sorted: [AppInfo] {
        sort == "cpu" ? apps.sorted { $0.cpu > $1.cpu } : apps.sorted { $0.memory > $1.memory }
    }

    var body: some View {
        List {
            Section {
                Picker("Sort", selection: $sort) {
                    Text("Processor").tag("cpu")
                    Text("Memory").tag("mem")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(sorted) { a in
                    row(a)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if link.canEdit && a.system != true {
                                Button("Force Quit", role: .destructive) { confirm = (a, true) }
                                Button("Quit") { confirm = (a, false) }.tint(.amber)
                            }
                        }
                        .contextMenu {
                            if link.canEdit && a.system != true {
                                Button { confirm = (a, false) } label: { Label("Quit \(a.name)", systemImage: "xmark.circle") }
                                Button(role: .destructive) { confirm = (a, true) } label: { Label("Force Quit", systemImage: "bolt.slash") }
                            }
                        }
                }
            } footer: {
                if !link.canEdit {
                    Text("View only. Turn on Full control in Triage › Settings › iPhone on your Mac to quit apps from here.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Apps")
        .task {
            // live while this screen is up
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .refreshable { await load() }
        .confirmationDialog(confirm.map { "\($0.force ? "Force quit" : "Quit") \($0.app.name) on \(link.macName)?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if let c = confirm {
                Button(c.force ? "Force Quit" : "Quit", role: .destructive) { quit(c.app, force: c.force) }
            }
        } message: {
            if confirm?.force == true { Text("Unsaved work in \(confirm?.app.name ?? "the app") will be lost.") }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toast)
    }

    private func row(_ a: AppInfo) -> some View {
        HStack(spacing: 12) {
            Text(String(a.name.prefix(1)).uppercased())
                .font(.headline)
                .frame(width: 36, height: 36)
                .background(Color.vital(min(a.cpu / 100, 1)).opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .foregroundStyle(Color.vital(min(a.cpu / 100, 1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).font(.body).lineLimit(1)
                Text(a.system == true ? "macOS itself" : "\(a.processes ?? 1) process\((a.processes ?? 1) == 1 ? "" : "es")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.pct(a.cpu)).font(.body.monospacedDigit()).foregroundStyle(Color.vital(min(a.cpu / 100, 1)))
                Text(Fmt.bytes(a.memory)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard let d = try? await link.call("apps"), let list = d["apps"], let a: [AppInfo] = decode(list) else { return }
        apps = a
    }

    private func quit(_ a: AppInfo, force: Bool) {
        Task {
            do {
                _ = try await link.call("quitApp", ["id": a.id, "force": force])
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                toast = "\(force ? "Force quit" : "Quit") \(a.name)"
                try? await Task.sleep(for: .seconds(2))
                toast = nil
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
