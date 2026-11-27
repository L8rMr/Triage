import Foundation

/// What the Home Screen widgets show: the Mac's latest vitals, written by the app (live while it's open, and from
/// background refreshes while it isn't) into the shared app group, and read by the widget extension.
struct WidgetSnap: Codable {
    var t: Date
    var mac: String
    var connected: Bool
    var bpm: Double
    var bpmHistory: [Double]
    var cpu: Double
    var cpuHistory: [Double]
    var memUsed: Double
    var memTotal: Double
    var pressure: Int?
    var diskFree: Double
    var diskTotal: Double
    var netIn: Double
    var netOut: Double
    var battery: Double?
    var charging: Bool?
    var health: Int?
    var status: String?
    var uptime: Double?
    var thermal: Int?
    var top: [TopApp]
    var themeID: String

    struct TopApp: Codable, Hashable { var name: String; var cpu: Double; var memory: Double }

    var memFraction: Double { memTotal > 0 ? memUsed / memTotal : 0 }
    var diskUsedFraction: Double { diskTotal > 0 ? 1 - diskFree / diskTotal : 0 }

    static let sample = WidgetSnap(
        t: Date(), mac: "MacBook Air", connected: true, bpm: 72,
        bpmHistory: (0..<60).map { 68 + 10 * sin(Double($0) / 5) + Double($0 % 7) },
        cpu: 18, cpuHistory: (0..<60).map { 12 + 9 * sin(Double($0) / 4) },
        memUsed: 11.2e9, memTotal: 16e9, pressure: 1, diskFree: 112e9, diskTotal: 494e9,
        netIn: 320_000, netOut: 41_000, battery: 86, charging: false, health: 92, status: "Running easy",
        uptime: 80_000, thermal: 0,
        top: [TopApp(name: "Safari", cpu: 8.2, memory: 1.4e9), TopApp(name: "Xcode", cpu: 5.1, memory: 3.2e9),
              TopApp(name: "Mail", cpu: 1.3, memory: 0.4e9)],
        themeID: "vitalos")
}

enum SnapStore {
    static let group = "group.com.alenlvovich.triage"
    static let kind = "TriageVitals"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func save(_ s: WidgetSnap) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        defaults?.set(d, forKey: "snap")
    }

    static func load() -> WidgetSnap? {
        guard let d = defaults?.data(forKey: "snap") else { return nil }
        return try? JSONDecoder().decode(WidgetSnap.self, from: d)
    }

    /// The shortest refresh any widget on the Home Screen asked for (minutes); the app schedules background
    /// refreshes around it.
    static var refreshMinutes: Int {
        get { defaults?.integer(forKey: "refresh").nonZero ?? 15 }
        set { defaults?.set(newValue, forKey: "refresh") }
    }
}

private extension Int { var nonZero: Int? { self == 0 ? nil : self } }
