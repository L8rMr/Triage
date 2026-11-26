import SwiftUI
import AppKit
import CoreWLAN
import CoreLocation

struct WiFiNet: Identifiable, Hashable {
    let ssid: String
    let rssi: Int
    let secure: Bool
    let known: Bool
    let channel: String
    var id: String { ssid }
    var bars: Int { rssi > -55 ? 3 : rssi > -67 ? 2 : 1 }
}

final class WiFiModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WiFiModel()
    @Published var ssid: String?
    @Published var powerOn = false
    @Published var rssi = 0
    @Published var txRate = 0.0
    @Published var ip: String?
    @Published var networks: [WiFiNet] = []
    @Published var scanning = false
    @Published var joining: String?
    @Published var message: String?
    @Published var locationAllowed = false

    private let client = CWWiFiClient.shared()
    private let location = CLLocationManager()
    private var iface: CWInterface? { client.interface() }
    var interfaceName: String { iface?.interfaceName ?? "en0" }

    override init() {
        super.init()
        location.delegate = self
        refresh()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        locationAllowed = s == .authorizedAlways || s == .authorized
        refresh()
    }

    /// macOS only reveals network names to apps you've allowed to use Location.
    func askForLocation() {
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        }
    }

    func refresh() {
        let i = iface
        powerOn = i?.powerOn() ?? false
        ssid = i?.ssid()
        rssi = i?.rssiValue() ?? 0
        txRate = i?.transmitRate() ?? 0
        ip = Self.address(for: interfaceName)
    }

    static func address(for name: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let a = p.pointee
            if String(cString: a.ifa_name) == name, let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(sa.pointee.sa_len)
                if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
            }
            cur = a.ifa_next
        }
        return nil
    }

    func scan() {
        guard let i = iface, i.powerOn() else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = (try? i.scanForNetworks(withSSID: nil)) ?? []
            let known = Set((i.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap(\.ssid))
            var best: [String: WiFiNet] = [:]
            for n in found {
                guard let name = n.ssid, !name.isEmpty else { continue }
                let secure = !n.supportsSecurity(.none)
                let net = WiFiNet(ssid: name, rssi: n.rssiValue, secure: secure, known: known.contains(name),
                                  channel: n.wlanChannel.map { $0.channelBand == .band5GHz ? "5 GHz" : ($0.channelBand == .band2GHz ? "2.4 GHz" : "6 GHz") } ?? "")
                if (best[name]?.rssi ?? -999) < net.rssi { best[name] = net }
            }
            let list = best.values.sorted { $0.known != $1.known ? $0.known : $0.rssi > $1.rssi }
            DispatchQueue.main.async {
                self.networks = list
                self.scanning = false
                if list.isEmpty && !self.locationAllowed { self.message = "Allow Location access so macOS shares nearby network names." }
            }
        }
    }

    func setPower(_ on: Bool) {
        try? iface?.setPower(on)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh(); if on { self.scan() } }
    }

    func join(_ net: WiFiNet, password: String?) {
        guard let i = iface else { return }
        joining = net.ssid
        message = nil
        let name = i.interfaceName ?? "en0"
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false
            if let target = (try? i.scanForNetworks(withSSID: net.ssid.data(using: .utf8)))?.first {
                ok = (try? i.associate(to: target, password: password)) != nil
            }
            if !ok && password == nil {
                // Saved networks: let macOS use the password it already has.
                Shell.run("/usr/sbin/networksetup", ["-setairportnetwork", name, net.ssid], timeout: 30)
                ok = i.ssid() == net.ssid
            }
            DispatchQueue.main.async {
                self.joining = nil
                self.refresh()
                self.message = ok || self.ssid == net.ssid ? "Joined \(net.ssid)" : "Couldn't join \(net.ssid). Check the password."
            }
        }
    }
}

struct WiFiPanel: View {
    @ObservedObject var wifi = WiFiModel.shared
    var compact = true
    @State private var passwordFor: WiFiNet?
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: wifi.powerOn ? "wifi" : "wifi.slash").foregroundStyle(wifi.powerOn ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wifi.powerOn ? (wifi.ssid ?? (wifi.rssi != 0 ? "Connected" : "Not connected")) : "Wi-Fi is off")
                        .font(.ui(size: 13, weight: .semibold))
                    if wifi.powerOn, wifi.rssi != 0 {
                        Text("\(wifi.ip ?? "No IP") · \(Int(wifi.txRate)) Mbps · signal \(wifi.rssi) dBm")
                            .font(.ui(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { wifi.powerOn }, set: { wifi.setPower($0) })).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if wifi.powerOn && wifi.ssid == nil && wifi.rssi != 0 && !wifi.locationAllowed {
                HStack {
                    Text("macOS hides network names until Triage can use Location.").font(.ui(size: 10)).foregroundStyle(.secondary)
                    Button("Allow") { wifi.askForLocation() }.controlSize(.mini)
                }
            }
            if wifi.powerOn {
                HStack {
                    Text("NETWORKS").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                    Spacer()
                    if wifi.scanning { ProgressView().controlSize(.mini) }
                    Button { wifi.scan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).controlSize(.small)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(wifi.networks) { n in
                            HStack(spacing: 8) {
                                Image(systemName: n.bars == 3 ? "wifi" : n.bars == 2 ? "wifi.exclamationmark" : "wifi")
                                    .opacity(n.bars == 1 ? 0.45 : 1)
                                Text(n.ssid).font(.ui(size: 12, weight: n.ssid == wifi.ssid ? .semibold : .regular)).lineLimit(1)
                                if n.known { Text("Saved").font(.ui(size: 9)).foregroundStyle(.secondary) }
                                Spacer()
                                Text(n.channel).font(.ui(size: 9)).foregroundStyle(.tertiary)
                                if n.secure { Image(systemName: "lock.fill").font(.ui(size: 9)).foregroundStyle(.secondary) }
                                if wifi.joining == n.ssid { ProgressView().controlSize(.mini) }
                                else if n.ssid == wifi.ssid { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(n.ssid == wifi.ssid ? Theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard n.ssid != wifi.ssid else { return }
                                if n.secure && !n.known { password = ""; passwordFor = n } else { wifi.join(n, password: nil) }
                            }
                            .contextMenu {
                                Button("Join") { if n.secure && !n.known { passwordFor = n } else { wifi.join(n, password: nil) } }
                                Button("Join with Password…") { password = ""; passwordFor = n }
                                Button("Copy Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(n.ssid, forType: .string) }
                            }
                        }
                        if wifi.networks.isEmpty && !wifi.scanning {
                            Text("Press ↻ to look for networks.").font(.ui(size: 11)).foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .frame(maxHeight: compact ? 180 : 420)
            }
            if let p = passwordFor {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Password for \(p.ssid)").font(.ui(size: 11, weight: .semibold))
                    SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                        .onSubmit { wifi.join(p, password: password); passwordFor = nil }
                    HStack {
                        Button("Cancel") { passwordFor = nil }
                        Spacer()
                        Button("Join") { wifi.join(p, password: password); passwordFor = nil }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            if let m = wifi.message { Text(m).font(.ui(size: 10)).foregroundStyle(.secondary) }
            Button("Wi-Fi Settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!) }
                .buttonStyle(.borderless).font(.ui(size: 11))
        }
        .onAppear {
            wifi.refresh()
            if wifi.networks.isEmpty { wifi.scan() }
            if !wifi.locationAllowed { wifi.askForLocationIfFirstTime() }
        }
    }
}

extension WiFiModel {
    func askForLocationIfFirstTime() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
    }
}

struct WiFiView: View {
    var body: some View {
        ToolPage(tool: .wifi, subtitle: "See your connection and nearby networks, switch networks, or turn Wi-Fi off.") {
            WiFiPanel(compact: false)
                .padding(16)
                .frame(maxWidth: 560, alignment: .topLeading)
                .glass(12)
        }
    }
}
