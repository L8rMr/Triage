import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var link: MacLink
    @ObservedObject private var theme = ThemeModel.shared
    @AppStorage("device.name") private var deviceName = ""
    @AppStorage("heart.haptics") private var haptics = false
    @AppStorage("pulse.strength") private var strength = 2
    @AppStorage("remote.quality") private var quality = "balanced"
    @AppStorage("remote.sensitivity") private var sensitivity = 1.6
    @AppStorage("remote.mode") private var pointer = "trackpad"
    @AppStorage("remote.clipAuto") private var clipAuto = true
    @State private var confirmForget = false
    @State private var note: String?

    var body: some View {
        Form {
            appearance
            Section {
                TextField("Name", text: $deviceName, prompt: Text("Alen's iPhone Duo"))
                    .textInputAutocapitalization(.words)
            } header: { Text("This iPhone") } footer: {
                Text("What your Mac calls this phone in its iPhone settings and activity log. iOS doesn't share the phone's real name with apps.")
            }
            Section {
                Toggle("Feel the pulse", isOn: $haptics)
                Picker("Strength", selection: $strength) {
                    Text("Soft").tag(0); Text("Medium").tag(1); Text("Strong").tag(2)
                }
                .pickerStyle(.segmented)
                Button("Feel it") { Pulse.beat(bpm: link.vitals?.bpm ?? 72) }
            } header: { Text("Heart") } footer: {
                Text("A lub-dub tap for every beat of your Mac's heart while the monitor is on screen. It beats harder when the Mac is working hard.")
            }
            remote
            connection
            Section("About") {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.glass900)
        .navigationTitle("Settings")
        .overlay(alignment: .bottom) { Toast(text: note) }
        .confirmationDialog("Forget \(link.macName)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { link.forgetMac() }
        } message: { Text("You'll need a new code from the Mac to connect again.") }
    }

    // MARK: Appearance

    private var appearance: some View {
        Section {
            Button { withAnimation { theme.choice = "mac" } } label: {
                HStack(spacing: 12) {
                    Swatch(p: theme.macPalette)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Match Mac").foregroundStyle(.primary)
                        Text("Now \(theme.macPalette.name). Changes when the Mac's does.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if theme.followsMac { Image(systemName: "checkmark").foregroundStyle(Color.phosphor) }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 12) {
                ForEach(Palette.all) { p in
                    Button { withAnimation { theme.choice = p.id } } label: {
                        VStack(spacing: 6) {
                            Swatch(p: p, big: true)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(!theme.followsMac && theme.choice == p.id ? Color.phosphor : .clear, lineWidth: 3))
                            Text(p.name).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                            Text(p.era).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            if !theme.followsMac && theme.choice != theme.macThemeID && link.canEdit {
                Button {
                    Task {
                        _ = try? await link.call("setTheme", ["id": theme.choice])
                        flash("\(link.macName) is wearing \(theme.palette.name) too")
                    }
                } label: { Label("Use \(theme.palette.name) on the Mac too", systemImage: "laptopcomputer") }
            }
        } header: { Text("Theme") } footer: {
            Text("Follow the Mac, or give the phone its own look. Each device keeps its own choice.")
        }
    }

    // MARK: Remote desktop

    private var remote: some View {
        Section {
            Picker("Picture", selection: $quality) {
                Text("Fastest").tag("fast"); Text("Balanced").tag("balanced"); Text("Sharpest").tag("sharp")
            }
            Picker("Pointer", selection: $pointer) {
                Text("Trackpad").tag("trackpad"); Text("Touch").tag("touch")
            }
            VStack(alignment: .leading) {
                Text("Trackpad speed")
                Slider(value: $sensitivity, in: 0.6...3.2) { Text("Speed") } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
            }
            Toggle("Copy from Mac to iPhone automatically", isOn: $clipAuto)
            DisclosureGroup("Trackpad gestures") {
                VStack(alignment: .leading, spacing: 6) {
                    gesture("Tap", "Click")
                    gesture("Two-finger tap", "Right-click")
                    gesture("Two-finger drag", "Scroll")
                    gesture("Hold, then drag", "Drag and select")
                    gesture("Pinch", "Zoom in or out")
                    gesture("Three-finger swipe up", "Mission Control")
                    gesture("Three-finger swipe down", "App Exposé")
                    gesture("Three-finger swipe sideways", "Switch Spaces")
                    gesture("Three-finger tap", "Look Up")
                    gesture("Four-finger swipe down", "Show desktop")
                }
                .font(.callout)
            }
        } header: { Text("Remote desktop") } footer: {
            Text("Fastest favors smooth motion, Sharpest favors crisp text. On iPhone Duo, half-fold it like a laptop for a screen up top and a keyboard and trackpad below.")
        }
    }

    private func gesture(_ g: String, _ does: String) -> some View {
        HStack { Text(g); Spacer(); Text(does).foregroundStyle(.secondary) }
    }

    // MARK: Connection

    private var connection: some View {
        Section {
            LabeledContent("Mac", value: link.macName)
            LabeledContent("Access", value: link.canEdit ? "Full control" : "View only")
            Toggle("Keep \(link.macName) awake", isOn: Binding(get: { link.vitals?.keepAwake ?? false }, set: { on in
                Task { try? await link.setKeepAwake(on) }
            }))
            Button("Disconnect") { link.disconnect() }
            Button("Forget this Mac", role: .destructive) { confirmForget = true }
        } header: { Text("Connection") } footer: {
            Text("Change what the phone may do in Triage › Settings › iPhone on the Mac.")
        }
    }

    private func flash(_ s: String) {
        note = s
        Task { try? await Task.sleep(for: .seconds(2)); if note == s { note = nil } }
    }
}

/// A tiny preview of a theme: its background, a card and the accent.
struct Swatch: View {
    let p: Palette
    var big = false
    var body: some View {
        let w: CGFloat = big ? 92 : 40, h: CGFloat = big ? 58 : 28
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: big ? 12 : 7).fill(p.bg)
            RoundedRectangle(cornerRadius: big ? 6 : 3).fill(p.card)
                .frame(width: w * 0.6, height: h * 0.45)
                .overlay(RoundedRectangle(cornerRadius: big ? 6 : 3).stroke(p.stroke, lineWidth: 0.5))
                .padding(big ? 8 : 4)
            Circle().fill(p.accent).frame(width: big ? 12 : 7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(big ? 8 : 4)
        }
        .frame(width: w, height: h)
        .overlay(RoundedRectangle(cornerRadius: big ? 12 : 7).stroke(Color.primary.opacity(0.12)))
        .environment(\.colorScheme, p.scheme ?? .light)
    }
}
