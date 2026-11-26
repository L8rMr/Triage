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

// MARK: - Look

extension Color {
    static let phosphor = Color(red: 0x2B / 255, green: 0xF5 / 255, blue: 0x9A / 255)
    static let phosphorDim = Color(red: 0x1A / 255, green: 0x9E / 255, blue: 0x63 / 255)
    static let amber = Color(red: 1, green: 0xC2 / 255, blue: 0x4B / 255)
    static let coral = Color(red: 1, green: 0x5A / 255, blue: 0x5F / 255)
    static let glass900 = Color(red: 0x0E / 255, green: 0x15 / 255, blue: 0x13 / 255)
    static let glass700 = Color(red: 0x1B / 255, green: 0x24 / 255, blue: 0x21 / 255)

    /// Same three states as the Mac: normal, elevated, critical.
    static func vital(_ stress: Double) -> Color {
        stress < 0.45 ? .phosphor : stress < 0.75 ? .amber : .coral
    }
    static func pulse(_ bpm: Double) -> Color {
        bpm < 100 ? .phosphor : bpm < 140 ? .amber : .coral
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
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.glass700.opacity(0.75), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
