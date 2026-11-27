import SwiftUI
import UIKit

struct ToolsScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var askEmpty = false
    @State private var reallyEmpty = false
    @State private var askSleep = false
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            Section("Everyday") {
                tool("PDF Editor", "doc.richtext", "Mark up, sign, redact, fill and rearrange") { PDFEditorScreen() }
                tool("Converter", "arrow.triangle.2.circlepath", "Images, PDFs, documents, audio, video, data") { ConverterScreen() }
                tool("Batch Rename", "character.cursor.ibeam", "Patterns, numbering, find and replace") { RenameScreen() }
                tool("Clipboard", "doc.on.clipboard", "The Mac's clipboard history") { ClipsScreen() }
                tool("Tidy Downloads", "tray.and.arrow.down", "Sort loose downloads into folders") { TidyScreen() }
                tool("Folder Autopilot", "wand.and.stars", "Rules that tidy folders on their own") { AutopilotScreen() }
                tool("Wi-Fi", "wifi", "The Mac's network, signal and nearby networks") { WiFiScreen() }
                tool("Sound Mixer", "slider.vertical.3", "Volume for every app and the output") { SoundScreen() }
            }
            Section("Make room") {
                tool("Free Up Space", "sparkles", "Cleanup suggestions, safe and undoable") { SpaceScreen() }
                tool("Disk Map", "square.grid.3x3.square", "What's eating the disk, as a map") { DiskMapScreen() }
                tool("Duplicate Finder", "doc.on.doc", "Identical files, keep just one") { DuplicatesScreen() }
                tool("Forgotten Files", "clock.badge.questionmark", "Big files you haven't opened in ages") { ForgottenScreen() }
                tool("App Uninstaller", "trash.square", "Remove apps and what they leave behind") { UninstallerScreen() }
            }
            Section("Fix a slow Mac") {
                tool("Heart monitor", "waveform.path.ecg", "How hard the Mac is working right now") { HeartScreen() }
                tool("Apps", "square.stack.3d.up.fill", "What's running, and quit what's stuck") { AppsScreen() }
                tool("Health History", "chart.xyaxis.line", "Heart rate over days, peaks and a report card") { HistoryScreen() }
                tool("Startup Items", "power", "What opens at login or runs in the background") { StartupScreen() }
                tool("Network by App", "network", "Who's uploading and downloading right now") { NetworkScreen() }
                tool("Servers & Ports", "server.rack", "Local servers and Docker, with one-tap stop") { PortsScreen() }
                tool("Drive Health", "stethoscope", "SMART status, wear, hours and temperature") { DrivesScreen() }
            }
            Section {
                Toggle(isOn: Binding(get: { link.vitals?.keepAwake ?? false }, set: { on in
                    Task { do { try await link.setKeepAwake(on) } catch { self.error = error.localizedDescription } }
                })) { Label("Keep awake", systemImage: "cup.and.saucer.fill") }
                if link.canEdit {
                    Button { act("sleepDisplay", "Display off") } label: { Label("Turn off display", systemImage: "display") }
                    Button { askSleep = true } label: { Label("Put to sleep", systemImage: "moon.fill") }
                    Button(role: .destructive) { askEmpty = true } label: { Label("Empty Trash", systemImage: "trash.slash") }
                }
            } header: { Text(link.macName) } footer: {
                Text(link.canEdit ? "Keep awake stops the Mac from sleeping while you're away, so it stays reachable."
                     : "View only. Turn on Full control in Triage › Settings › iPhone on the Mac for these.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.glass900)
        .navigationTitle("Tools")
        .confirmationDialog("Put \(link.macName) to sleep?", isPresented: $askSleep, titleVisibility: .visible) {
            Button("Sleep") { act("sleepMac", "Sleeping") }
        } message: { Text("The phone loses its connection until the Mac wakes up.") }
        // two steps on purpose: emptying the Trash can't be undone
        .confirmationDialog("Empty the Trash on \(link.macName)?", isPresented: $askEmpty, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { reallyEmpty = true }
        } message: { Text("Everything in it is deleted for good.") }
        .alert("This can't be undone", isPresented: $reallyEmpty) {
            Button("Empty Trash", role: .destructive) { act("emptyTrash", "Trash emptied", ["confirm": "EMPTY"]) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Files in the Trash on \(link.macName) will be permanently deleted.") }
        .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .overlay(alignment: .bottom) { Toast(text: toast) }
    }

    private func tool<D: View>(_ title: String, _ symbol: String, _ blurb: String, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink { dest() } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(blurb).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: { Image(systemName: symbol).foregroundStyle(Color.phosphor) }
        }
    }

    private func act(_ op: String, _ done: String, _ args: [String: Any] = [:]) {
        Task {
            do {
                _ = try await link.call(op, args)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                toast = done
                try? await Task.sleep(for: .seconds(2)); toast = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct Toast: View {
    let text: String?
    var body: some View {
        Group {
            if let text {
                Text(text).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: text)
    }
}

// MARK: - Free Up Space (same suggestions as the Mac, with the files behind each one)

struct SpaceScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var targets: [SpaceTarget] = []
    @State private var loading = true
    @State private var open: Set<String> = []
    @State private var picks: Set<String> = []          // part paths
    @State private var confirm = false
    @State private var error: String?
    @State private var toast: String?

    private var cleanable: [SpaceTarget] { targets.filter { $0.id != "trash" && $0.size > 0 } }
    private var pickedBytes: Double { cleanable.flatMap(\.parts).filter { picks.contains($0.path) }.map(\.size).reduce(0, +) }

    var body: some View {
        List {
            if loading { HStack { ProgressView(); Text("Measuring \(link.macName)…").foregroundStyle(.secondary) } }
            ForEach(cleanable) { t in
                Section {
                    DisclosureGroup(isExpanded: Binding(get: { open.contains(t.id) }, set: { if $0 { open.insert(t.id) } else { open.remove(t.id) } })) {
                        ForEach(t.parts) { p in
                            Button { toggle(p.path) } label: {
                                HStack {
                                    Image(systemName: picks.contains(p.path) ? "checkmark.circle.fill" : "circle").foregroundStyle(picks.contains(p.path) ? Color.phosphor : .secondary)
                                    Text(p.name).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.bytes(p.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if t.count > t.parts.count { Text("+ \(t.count - t.parts.count) smaller items").font(.caption).foregroundStyle(.secondary) }
                    } label: {
                        HStack(spacing: 12) {
                            Button { toggleAll(t) } label: {
                                Image(systemName: state(t)).font(.title3).foregroundStyle(state(t) == "circle" ? .secondary : Color.phosphor)
                            }
                            .buttonStyle(.plain)
                            Image(systemName: t.symbol).foregroundStyle(t.safe ? Color.phosphor : Color.amber).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.subheadline.weight(.semibold))
                                Text(t.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Text(Fmt.bytes(t.size)).font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                    }
                }
            }
            if let trash = targets.first(where: { $0.id == "trash" }), trash.size > 0 {
                Section {
                    HStack {
                        Label("Trash", systemImage: "trash")
                        Spacer()
                        Text(Fmt.bytes(trash.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                } footer: { Text("Empty it from Tools when you're sure.") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.glass900)
        .navigationTitle("Free Up Space")
        .safeAreaInset(edge: .bottom) {
            if link.canEdit && !picks.isEmpty {
                Button { confirm = true } label: {
                    Text("Move \(Fmt.bytes(pickedBytes)) to the Trash").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16).padding(.bottom, 8)
                .background(.bar)
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Move \(picks.count) items (\(Fmt.bytes(pickedBytes))) to the Trash on \(link.macName)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { clean() }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .overlay(alignment: .bottom) { Toast(text: toast) }
    }

    private func state(_ t: SpaceTarget) -> String {
        let n = t.parts.filter { picks.contains($0.path) }.count
        return n == 0 ? "circle" : n == t.parts.count ? "checkmark.circle.fill" : "minus.circle.fill"
    }
    private func toggle(_ p: String) { if picks.contains(p) { picks.remove(p) } else { picks.insert(p) } }
    private func toggleAll(_ t: SpaceTarget) {
        let all = Set(t.parts.map(\.path))
        if all.isSubset(of: picks) { picks.subtract(all) } else { picks.formUnion(all) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await link.call("space")
            targets = decode(d["targets"] ?? []) ?? []
            if picks.isEmpty { picks = Set(targets.filter { $0.safe && $0.id != "trash" }.flatMap(\.parts).map(\.path)) }   // safe ones start picked
        } catch { self.error = error.localizedDescription }
    }

    private func clean() {
        Task {
            do {
                let d = try await link.call("clean", ["paths": Array(picks)])
                let freed = d["freed"] as? Double ?? Double(d["freed"] as? Int ?? 0)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                toast = "Breathing room: \(Fmt.bytes(freed)) freed. Your Mac thanks you."
                picks = []
                await load()
                try? await Task.sleep(for: .seconds(3)); toast = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Clipboard (the Mac's history, both directions)

struct ClipsScreen: View {
    @EnvironmentObject var link: MacLink
    @State private var clips: [Clip] = []
    @State private var toast: String?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button { sendPhoneClipboard() } label: { Label("Send iPhone clipboard to \(link.macName)", systemImage: "iphone.and.arrow.forward") }
                    .disabled(!link.canEdit)
            }
            Section("\(link.macName)'s clipboard history") {
                if clips.isEmpty { Text("Nothing copied yet.").foregroundStyle(.secondary) }
                ForEach(clips) { c in
                    Button {
                        UIPasteboard.general.string = c.text
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        flash("Copied to iPhone")
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.text).lineLimit(3).foregroundStyle(.primary)
                            Text([c.source, Fmt.date(c.date)].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.glass900)
        .navigationTitle("Clipboard")
        .task { await load() }
        .refreshable { await load() }
        .overlay(alignment: .bottom) { Toast(text: toast) }
        .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func load() async {
        if let d = try? await link.call("clips") { clips = decode(d["clips"] ?? []) ?? [] }
    }

    private func flash(_ s: String) {
        toast = s
        Task { try? await Task.sleep(for: .seconds(1.8)); if toast == s { toast = nil } }
    }

    private func sendPhoneClipboard() {
        guard let s = UIPasteboard.general.string, !s.isEmpty else { flash("The iPhone clipboard is empty"); return }
        Task {
            do { _ = try await link.call("setClipboard", ["text": s]); flash("On \(link.macName)'s clipboard"); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}
