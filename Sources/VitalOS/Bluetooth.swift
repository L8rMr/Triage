import Foundation
import AppKit
import IOBluetooth
import CoreAudio
import UserNotifications

struct BTDevice: Identifiable, Equatable {
    enum Kind { case headphones, keyboard, mouse, phone, other }
    let id: String          // Bluetooth address
    let name: String
    var connected: Bool
    var kind: Kind
    var battery: Int?       // main level, or the lower earbud
    var detail: String?     // "L 80% · R 76% · case 40%"

    var symbol: String {
        switch kind {
        case .headphones: return "airpodspro"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .phone: return "iphone"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

/// Paired Bluetooth devices, their connection state and battery levels.
final class BluetoothModel: ObservableObject {
    static let shared = BluetoothModel()
    @Published private(set) var devices: [BTDevice] = []
    @Published private(set) var powerOn = true
    @Published var busy: String?
    private var timer: Timer?
    private var levels: [String: (Int?, String?)] = [:]   // by address
    private var lastLevels = Date.distantPast
    private var readingLevels = false

    func start() {
        refresh(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    /// Cheap list from IOBluetooth; battery levels from system_profiler at most once a minute.
    func refresh(force: Bool = false) {
        powerOn = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        devices = paired.compactMap { d in
            guard let addr = d.addressString, let name = d.name else { return nil }
            let lv = levels[Self.norm(addr)]
            return BTDevice(id: addr, name: name, connected: d.isConnected(), kind: Self.kind(d), battery: lv?.0, detail: lv?.1)
        }
        .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
        if (force || Date().timeIntervalSince(lastLevels) > 60), !readingLevels, devices.contains(where: \.connected) {
            readingLevels = true
            Work.quick.async { [weak self] in
                let found = Self.readLevels()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.levels = found; self.lastLevels = Date(); self.readingLevels = false
                    self.devices = self.devices.map { var d = $0; let lv = found[Self.norm(d.id)]; d.battery = lv?.0; d.detail = lv?.1; return d }
                }
            }
        }
    }

    func toggle(_ dev: BTDevice) {
        guard let d = IOBluetoothDevice(addressString: dev.id) else { return }
        busy = dev.id
        Work.quick.async { [weak self] in
            let r = dev.connected ? d.closeConnection() : d.openConnection()
            DispatchQueue.main.async {
                self?.busy = nil
                self?.refresh(force: !dev.connected)
                UndoCenter.shared.show(r == kIOReturnSuccess ? "\(dev.connected ? "Disconnected" : "Connected") \(dev.name)" : "Couldn’t reach \(dev.name). Is it on and nearby?")
            }
        }
    }

    /// Bluetooth power uses the same switch as Control Center. Falls back to opening Settings.
    func setPower(_ on: Bool) {
        typealias SetFn = @convention(c) (Int32) -> Void
        if let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
           let sym = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") {
            unsafeBitCast(sym, to: SetFn.self)(on ? 1 : 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refresh() }
        } else if let u = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(u)
        }
    }

    var headphones: BTDevice? { devices.first { $0.connected && $0.kind == .headphones } }
    var lowestInput: BTDevice? { devices.filter { $0.connected && ($0.kind == .mouse || $0.kind == .keyboard) && $0.battery != nil }.min { $0.battery! < $1.battery! } }

    /// IOBluetooth says "aa-bb-cc…", system_profiler says "AA:BB:CC…".
    static func norm(_ a: String) -> String { a.lowercased().replacingOccurrences(of: "-", with: ":") }

    private static func kind(_ d: IOBluetoothDevice) -> BTDevice.Kind {
        let major = d.deviceClassMajor, minor = d.deviceClassMinor
        if major == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) { return .headphones }
        if major == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone) { return .phone }
        if major == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPeripheral) {
            if minor & 0x10 != 0 { return .keyboard }
            if minor & 0x20 != 0 { return .mouse }
        }
        let n = (d.name ?? "").lowercased()
        if n.contains("airpods") || n.contains("buds") || n.contains("beats") || n.contains("headphone") { return .headphones }
        if n.contains("keyboard") { return .keyboard }
        if n.contains("mouse") || n.contains("trackpad") || n.contains("mx ") { return .mouse }
        return .other
    }

    private static func readLevels() -> [String: (Int?, String?)] {
        let out = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 12)
        guard let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: (Int?, String?)] = [:]
        func pct(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) } }
        for sec in sections {
            for entry in (sec["device_connected"] as? [[String: Any]]) ?? [] {
                for (_, value) in entry {
                    guard let info = value as? [String: Any], let raw = info["device_address"] as? String else { continue }
                    let addr = norm(raw)
                    let l = pct(info["device_batteryLevelLeft"]), r = pct(info["device_batteryLevelRight"]), c = pct(info["device_batteryLevelCase"])
                    let main = pct(info["device_batteryLevelMain"]) ?? pct(info["device_batteryLevel"])
                    if l != nil || r != nil {
                        let parts = [l.map { "L \($0)%" }, r.map { "R \($0)%" }, c.map { "case \($0)%" }].compactMap { $0 }
                        result[addr] = ([l, r].compactMap { $0 }.min(), parts.joined(separator: " · "))
                    } else if let main {
                        result[addr] = (main, nil)
                    }
                }
            }
        }
        return result
    }
}

// MARK: - Microphone mute (default input device)

enum Mic {
    static var device: AudioDeviceID { CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)) }
    static var name: String { CA.string(device, kAudioObjectPropertyName) ?? "Microphone" }
    static var muted: Bool {
        let d = device
        if CA.get(d, kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput, UInt32(0)) != 0 { return true }
        return CA.get(d, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, Float32(1)) < 0.01
    }
    private static var savedLevel: Float32 = 0.7
    static func setMuted(_ m: Bool) {
        let d = device
        if CA.set(d, kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput, UInt32(m ? 1 : 0)) { return }
        // Built-in mics often have no mute switch: drop the input volume instead.
        if m { savedLevel = max(CA.get(d, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, Float32(0.7)), 0.1) }
        _ = CA.set(d, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, m ? Float32(0) : savedLevel)
    }
}

// MARK: - Quick fixes behind the menu bar buttons

enum QuickFix {
    /// Regular apps with no windows on screen and almost no CPU: safe to quit, and they give back their memory.
    static func idleApps(_ apps: [AppUsage]) -> [(NSRunningApplication, UInt64)] {
        let onScreen = Set(((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])
            .compactMap { ($0[kCGWindowLayer as String] as? Int) == 0 ? $0[kCGWindowOwnerPID as String] as? pid_t : nil })
        let skip: Set<String> = ["com.apple.finder", "com.alenlvovich.vitalos", "com.apple.dt.Xcode", "com.apple.Terminal"]
        return NSWorkspace.shared.runningApplications.compactMap { r in
            guard r.activationPolicy == .regular, !r.isActive, !onScreen.contains(r.processIdentifier),
                  let id = r.bundleIdentifier, !skip.contains(id), let path = r.bundleURL?.path,
                  let use = apps.first(where: { $0.bundlePath == path }), use.cpu < 1 else { return nil }
            return (r, use.memory)
        }
        .sorted { $0.1 > $1.1 }
    }

    static func remindRestartTonight() {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async {
                guard ok else { UndoCenter.shared.show("Turn on notifications for VitalOS to get the reminder"); return }
                let content = UNMutableNotificationContent()
                content.title = "Time to restart your Mac"
                content.body = "A restart clears the swap file and gives your Mac a fresh start."
                var when = DateComponents(); when.hour = 22; when.minute = 0
                c.add(UNNotificationRequest(identifier: "vitalos.restart", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
                UndoCenter.shared.show("I’ll remind you at 10 pm") { c.removePendingNotificationRequests(withIdentifiers: ["vitalos.restart"]) }
            }
        }
    }
}
