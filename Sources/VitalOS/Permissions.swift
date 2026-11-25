import SwiftUI
import AppKit
import CoreLocation
import CoreAudio
import AudioToolbox
import UserNotifications
import ApplicationServices

/// Every macOS permission VitalOS uses, what it unlocks, and how to grant it.
enum Perm: String, CaseIterable, Identifiable {
    case files, location, audio, screen, accessibility, notifications, fullDisk
    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Desktop, Documents & Downloads"
        case .location: return "Location"
        case .audio: return "System Audio"
        case .screen: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        case .fullDisk: return "Full Disk Access"
        }
    }
    var symbol: String {
        switch self {
        case .files: return "folder"
        case .location: return "wifi"
        case .audio: return "slider.vertical.3"
        case .screen: return "text.viewfinder"
        case .accessibility: return "doc.on.clipboard"
        case .notifications: return "bell.badge"
        case .fullDisk: return "externaldrive"
        }
    }
    var why: String {
        switch self {
        case .files: return "Browse, tidy and clean your everyday folders."
        case .location: return "macOS only shares Wi-Fi network names with apps that have it. Never used to track you."
        case .audio: return "Sets each app's own volume in the Sound Mixer. Nothing is recorded."
        case .screen: return "Copy text from anywhere on screen (⌘⇧2)."
        case .accessibility: return "Paste straight from the clipboard panel (⌥⇧V) into the app you're in."
        case .notifications: return "Alerts when your Mac's heart rate stays strained."
        case .fullDisk: return "Lets Free Up Space, Disk Map and search see everything, like Mail and app caches."
        }
    }
    /// Permissions macOS can't prompt for: the person flips a switch in System Settings.
    var settingsOnly: Bool { self == .fullDisk }
    var optional: Bool { self == .fullDisk || self == .accessibility }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .files: pane = "Privacy_FilesAndFolders"
        case .location: pane = "Privacy_LocationServices"
        case .audio: pane = "Privacy_AudioCapture"
        case .screen: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        case .notifications: pane = "Notifications"
        case .fullDisk: pane = "Privacy_AllFiles"
        }
        if self == .notifications { return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")! }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

enum PermState { case granted, denied, unknown }

final class Permissions: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Permissions()
    @Published var state: [Perm: PermState] = [:]
    @Published var asking: Perm?
    private let location = CLLocationManager()
    private var locationWait: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        location.delegate = self
        refresh()
    }

    var allGood: Bool { Perm.allCases.filter { !$0.optional }.allSatisfy { state[$0] == .granted } }

    func refresh() {
        var s: [Perm: PermState] = [:]
        // Folders: reading the directory is the check (and the prompt).
        s[.files] = UserDefaults.standard.bool(forKey: "perm.files.asked") ? (canRead("Desktop") && canRead("Documents") && canRead("Downloads") ? .granted : .denied) : .unknown
        switch location.authorizationStatus {
        case .authorizedAlways, .authorized: s[.location] = .granted
        case .denied, .restricted: s[.location] = .denied
        default: s[.location] = .unknown
        }
        s[.audio] = UserDefaults.standard.bool(forKey: "perm.audio.ok") ? .granted : (UserDefaults.standard.bool(forKey: "perm.audio.asked") ? .denied : .unknown)
        s[.screen] = CGPreflightScreenCaptureAccess() ? .granted : (UserDefaults.standard.bool(forKey: "perm.screen.asked") ? .denied : .unknown)
        s[.accessibility] = AXIsProcessTrusted() ? .granted : (UserDefaults.standard.bool(forKey: "perm.ax.asked") ? .denied : .unknown)
        s[.fullDisk] = hasFullDisk() ? .granted : .unknown
        state = s
        UNUserNotificationCenter.current().getNotificationSettings { st in
            let v: PermState = st.authorizationStatus == .authorized || st.authorizationStatus == .provisional ? .granted
                : st.authorizationStatus == .denied ? .denied : .unknown
            DispatchQueue.main.async { self.state[.notifications] = v }
        }
    }

    private func canRead(_ name: String) -> Bool {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
        return (try? FileManager.default.contentsOfDirectory(atPath: u.path)) != nil
    }

    private func hasFullDisk() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in ["\(home)/Library/Safari", "\(home)/Library/Mail", "/Library/Application Support/com.apple.TCC/TCC.db"] {
            if FileManager.default.fileExists(atPath: p) {
                if FileManager.default.isReadableFile(atPath: p), (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil || p.hasSuffix(".db") { return true }
            }
        }
        return false
    }

    /// Ask for one permission. Shows the macOS prompt where one exists.
    @MainActor
    func ask(_ p: Perm) async {
        asking = p
        defer { asking = nil; refresh() }
        switch p {
        case .files:
            UserDefaults.standard.set(true, forKey: "perm.files.asked")
            for n in ["Desktop", "Documents", "Downloads"] {
                _ = canRead(n)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        case .location:
            guard location.authorizationStatus == .notDetermined else { NSWorkspace.shared.open(p.settingsURL); return }
            await withCheckedContinuation { c in
                locationWait = c
                location.requestWhenInUseAuthorization()
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.finishLocation() }
            }
        case .audio:
            UserDefaults.standard.set(true, forKey: "perm.audio.asked")
            if #available(macOS 14.2, *) {
                // Creating a tap is what makes macOS ask. It's destroyed right away.
                let ok = await Task.detached { () -> Bool in
                    let d = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                    d.isPrivate = true
                    var tap = AudioObjectID(kAudioObjectUnknown)
                    let st = AudioHardwareCreateProcessTap(d, &tap)
                    if st == noErr { AudioHardwareDestroyProcessTap(tap) }
                    return st == noErr
                }.value
                UserDefaults.standard.set(ok, forKey: "perm.audio.ok")
                if !ok { NSWorkspace.shared.open(p.settingsURL) }
            }
        case .screen:
            UserDefaults.standard.set(true, forKey: "perm.screen.asked")
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(p.settingsURL) }
        case .accessibility:
            UserDefaults.standard.set(true, forKey: "perm.ax.asked")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        case .notifications:
            let st = await UNUserNotificationCenter.current().notificationSettings()
            if st.authorizationStatus == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } else if st.authorizationStatus == .denied {
                NSWorkspace.shared.open(p.settingsURL)
            }
        case .fullDisk:
            NSWorkspace.shared.open(p.settingsURL)
        }
    }

    /// One after another, so the macOS prompts don't stack on top of each other.
    @MainActor
    func askAll() async {
        for p in Perm.allCases where !p.settingsOnly && state[p] != .granted && !(p == .accessibility && state[p] == .denied) {
            await ask(p)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func finishLocation() {
        locationWait?.resume()
        locationWait = nil
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        DispatchQueue.main.async {
            if m.authorizationStatus != .notDetermined { self.finishLocation() }
            self.refresh()
            WiFiModel.shared.refresh()
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var perms = Permissions.shared
    @Environment(\.dismiss) private var dismiss
    var firstRun = false
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill").font(.ui(size: 28)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(firstRun ? "Let's get VitalOS set up" : "Permissions").font(.ui(size: 20, weight: .bold, design: .rounded))
                    Text("macOS asks once for each of these. Everything stays on your Mac.")
                        .font(.ui(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                ForEach(Perm.allCases) { p in row(p) }
            }
            HStack {
                Button("Refresh") { perms.refresh() }.buttonStyle(.borderless).font(.ui(size: 11))
                Spacer()
                Button(firstRun ? "Later" : "Done") { finish() }
                Button {
                    running = true
                    Task { await perms.askAll(); running = false }
                } label: {
                    Text(running ? "Asking…" : "Allow All").frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || perms.allGood)
                .keyboardShortcut(.defaultAction)
            }
            Text("Full Disk Access is the only one macOS won't prompt for. Click Open, then switch on VitalOS (use + to add it if it's not listed).")
                .font(.ui(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { perms.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in perms.refresh() }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "perm.onboarded")
        dismiss()
    }

    private func row(_ p: Perm) -> some View {
        let st = perms.state[p] ?? .unknown
        return HStack(spacing: 12) {
            Image(systemName: p.symbol).font(.ui(size: 15)).foregroundStyle(Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.title).font(.ui(size: 13, weight: .semibold))
                    if p.optional { Text("Optional").font(.ui(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1).background(Color.primary.opacity(0.08), in: Capsule()) }
                }
                Text(p.why).font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if perms.asking == p {
                ProgressView().controlSize(.small)
            } else if st == .granted {
                Label("On", systemImage: "checkmark.circle.fill").font(.ui(size: 11, weight: .medium)).foregroundStyle(Theme.good)
            } else if st == .denied || p.settingsOnly {
                Button(p.settingsOnly ? "Open" : "Fix in Settings") { NSWorkspace.shared.open(p.settingsURL) }.controlSize(.small)
            } else {
                Button("Allow") { Task { await perms.ask(p) } }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glass(10)
        .contextMenu {
            Button("Allow") { Task { await perms.ask(p) } }
            Button("Open in System Settings") { NSWorkspace.shared.open(p.settingsURL) }
        }
    }
}
