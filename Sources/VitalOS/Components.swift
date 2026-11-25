import SwiftUI
import AppKit
import QuickLookThumbnailing

/// Colors come from the chosen theme (Settings › Appearance). The view tree is rebuilt when the theme changes.
enum Theme {
    private static var t: AppTheme { ThemeStore.shared.current }
    static var bg: Color { t.bg }
    static var sidebar: Color { t.sidebar }
    static var panel: Color { t.card }
    static var stroke: Color { t.stroke }
    static var accent: Color { ThemeStore.shared.accent }
    static var good: Color { t.good }
    static var heart: Color { t.heart }
    static var cpu: Color { t.cpu }
    static var mem: Color { t.mem }
    static var net: Color { t.net }
    static var heat: Color { t.heat }
    static var warn: Color { t.warn }
    static var selection: Color { t.selection }
    static var selectionText: Color { t.selectionText }

    static func load(_ pct: Double) -> Color {
        pct > 85 ? warn : pct > 60 ? net : good
    }
}

extension View {
    func glass(_ radius: CGFloat = 16) -> some View { modifier(ThemedCard(radius: radius)) }
}

enum Fmt {
    static func bytes(_ v: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(v, 0), countStyle: .file) }
    static func bytes(_ v: UInt64) -> String { bytes(Int64(clamping: v)) }
    static func rate(_ bps: Double) -> String { bytes(Int64(max(bps, 0))) + "/s" }
    static func pct(_ v: Double) -> String { String(format: v < 10 && v > 0 ? "%.1f%%" : "%.0f%%", v) }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? "—"
    }
}

struct Sparkline: View {
    var values: [Double]
    var maxValue: Double? = nil
    var color: Color

    var body: some View {
        GeometryReader { g in
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let n = values.count
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: n < 2 ? 0 : g.size.width * CGFloat(i) / CGFloat(n - 1),
                        y: g.size.height * (1 - CGFloat(min(v / top, 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first, let l = pts.last else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: l.x, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct Ring: View {
    var value: Double
    var color: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(value, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

/// The sidebar heartbeat. Beats faster as the CPU works harder.
final class PhaseClock {
    private var phase = 0.0
    private var last: TimeInterval?

    func advance(to t: TimeInterval, bpm: Double) -> Double {
        if let l = last { phase += min(max(t - l, 0), 0.25) * max(bpm, 30) / 60 }
        last = t
        if phase > 10_000 { phase = phase.truncatingRemainder(dividingBy: 1) }
        return phase
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.ui(size: 26, weight: .bold))
            Text(subtitle).font(.ui(size: 13)).foregroundStyle(.secondary)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let history: [Double]
    var maxValue: Double? = 100
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            Text(value).font(.ui(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.ui(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Sparkline(values: history, maxValue: maxValue, color: color).frame(height: 36)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }
}

enum ThumbCache {
    static let store: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 50 * 1024 * 1024; return c }()
    static func key(_ u: URL, _ s: CGFloat) -> NSString {
        let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        return "\(u.path)|\(Int(s))|\(Int(m))" as NSString
    }
}

struct Thumb: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            }
        }
        .task(id: url) {
            let key = ThumbCache.key(url, size)
            if let hit = ThumbCache.store.object(forKey: key) { image = hit; return }
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                image = rep.nsImage
                let px = rep.cgImage.width * rep.cgImage.height * 4
                ThumbCache.store.setObject(rep.nsImage, forKey: key, cost: px)
            }
        }
    }
}

struct FolderGlyph: View {
    var tint: Color = Theme.cpu
    var body: some View {
        ZStack {
            Image(systemName: "folder.fill")
                .resizable().scaledToFit()
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.45)], startPoint: .top, endPoint: .bottom))
            Image(systemName: "folder")
                .resizable().scaledToFit()
                .foregroundStyle(Color.primary.opacity(0.25))
        }
        .shadow(color: tint.opacity(0.35), radius: 10, y: 4)
    }
}

struct ToastView: View {
    let toast: UndoCenter.Toast
    @ObservedObject var center: UndoCenter

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            Text(toast.message).font(.ui(size: 13))
            if let u = toast.undo {
                Button("Undo") {
                    u()
                    center.toast = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.black.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)
    }
}
