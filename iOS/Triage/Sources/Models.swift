import SwiftUI

struct MacInfo: Decodable {
    var name: String
    var model: String?
    var chip: String?
    var os: String?
    var boot: Double?
    var setup: Double?
    var memTotal: Double?
    var home: String?
    var user: String?
}

struct Factor: Decodable, Identifiable {
    var id: String
    var channel: String
    var label: String
    var stress: Double
    var reading: String
    var cause: String?
}

struct Battery: Decodable {
    var percent: Double
    var charging: Bool
    var onAC: Bool
    var minutesLeft: Int?
    var cycles: Int?
    var health: Double?
}

struct AppInfo: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var cpu: Double
    var memory: Double
    var processes: Int?
    var system: Bool?
    var bundle: String?
}

struct Vitals: Decodable {
    var t: Double
    var bpm: Double
    var bpmHistory: [Double]?
    var cpu: Double
    var cpuHistory: [Double]?
    var memUsed: Double
    var memTotal: Double
    var swap: Double?
    var pressure: Int?
    var netIn: Double?
    var netOut: Double?
    var diskFree: Double
    var diskTotal: Double
    var thermal: Int?
    var uptime: Double?
    var keepAwake: Bool?
    var top: [AppInfo]?
    var health: Int?
    var status: String?
    var factors: [Factor]?
    var battery: Battery?

    var memFraction: Double { memTotal > 0 ? memUsed / memTotal : 0 }
    var diskFreeFraction: Double { diskTotal > 0 ? diskFree / diskTotal : 0 }
}

struct FileEntry: Decodable, Identifiable, Hashable {
    var name: String
    var path: String
    var dir: Bool?
    var size: Double?
    var modified: Double?
    var used: Double?
    var type: String?
    var trashable: Bool?
    var id: String { path }
    var isDir: Bool { dir ?? (type == "public.folder") }

    var symbol: String {
        if isDir { return "folder.fill" }
        let t = type ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if t.contains("image") || ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(ext) { return "photo" }
        if t.contains("movie") || t.contains("video") || ["mov", "mp4", "mkv", "avi"].contains(ext) { return "film" }
        if t.contains("audio") || ["mp3", "m4a", "wav", "flac"].contains(ext) { return "waveform" }
        if t.contains("pdf") || ext == "pdf" { return "doc.richtext" }
        if t.contains("application") || ext == "app" { return "app.dashed" }
        if ["zip", "dmg", "pkg", "gz", "tar"].contains(ext) { return "shippingbox" }
        if ["swift", "js", "ts", "py", "json", "sh"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        return "doc"
    }
}

// MARK: - Look (follows the active theme)

extension Color {
    static var phosphor: Color { ThemeModel.current.accent }
    static var healthy: Color { ThemeModel.current.good }
    static var amber: Color { ThemeModel.current.heat }
    static var coral: Color { ThemeModel.current.warn }
    static var glass900: Color { ThemeModel.current.bg }
    static var glass700: Color { ThemeModel.current.card }
    static var stroke: Color { ThemeModel.current.stroke }

    /// Same three states as the Mac: normal, elevated, critical.
    static func vital(_ stress: Double) -> Color {
        stress < 0.45 ? .healthy : stress < 0.75 ? .amber : .coral
    }
    static func pulse(_ bpm: Double) -> Color {
        bpm < 100 ? .healthy : bpm < 140 ? .amber : .coral
    }
}

enum Fmt {
    static func bytes(_ v: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
    }
    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    static func span(_ s: Double) -> String {
        let d = Int(s / 86_400), h = Int(s.truncatingRemainder(dividingBy: 86_400) / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    static func date(_ t: Double?) -> String {
        guard let t else { return "" }
        return Date(timeIntervalSince1970: t).formatted(.relative(presentation: .named))
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    var fill = false
    @ViewBuilder var content: Content
    var body: some View {
        let p = ThemeModel.current
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(p.card, in: RoundedRectangle(cornerRadius: p.radius + 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: p.radius + 6, style: .continuous).stroke(p.stroke.opacity(p.id == "mac1bit" ? 1 : 0.6), lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.bold)).kerning(1).foregroundStyle(.secondary)
    }
}

// MARK: - More of the Mac

struct Glance: Decodable {
    struct Span: Decodable, Identifiable { var id: String; var name: String; var secs: Double }
    struct Day: Decodable, Identifiable { var label: String; var secs: Double; var id: String { label } }
    struct Beat: Decodable, Identifiable { var t: Double; var bpm: Double; var id: Double { t } }
    struct Hungry: Decodable, Identifiable { var name: String; var share: Double; var system: Bool?; var id: String { name } }
    var todayTotal: Double
    var today: [Span]
    var week: [Day]
    var heart: [Beat]
    var heartAvg: Double
    var heartPeak: Double
    var beats: Double?
    var hungry: [Hungry]
    var boot: Double?
    var setup: Double?
    var model: String?
    var chip: String?
    var os: String?
    var memTotal: Double?
}

struct SpaceTarget: Decodable, Identifiable {
    struct Part: Decodable, Identifiable, Hashable { var path: String; var name: String; var size: Double; var id: String { path } }
    var id: String
    var title: String
    var detail: String
    var symbol: String
    var safe: Bool
    var size: Double
    var count: Int
    var parts: [Part]
}

struct Clip: Decodable, Identifiable {
    var id: String
    var kind: String
    var text: String
    var date: Double
    var source: String?
    var pinned: Bool?
}

struct Place: Decodable, Identifiable, Hashable {
    var name: String
    var path: String
    var symbol: String
    var id: String { path }
}
