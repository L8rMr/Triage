import SwiftUI
import AppKit
import CoreText

// MARK: - Theme definitions

enum ChromeStyle: String { case vitalos, aqua, win95, xp, win11, mac1bit, gnome, apple, braun, terminal }
enum CardStyle { case glass, flat, bevel, oneBit, aqua, xp, dashed }
enum Backdrop { case plain, pinstripe, scanlines }

struct AppTheme: Identifiable {
    let id: String
    let name: String
    let era: String
    let about: String
    let chrome: ChromeStyle
    /// nil: follows the Mode setting (Auto / Light / Dark)
    let scheme: ColorScheme?
    let bg: Color, sidebar: Color, card: Color, stroke: Color
    let accent: Color, good: Color, heart: Color, cpu: Color, mem: Color, net: Color, heat: Color, warn: Color
    let selection: Color, selectionText: Color
    let font: String?, boldFont: String?, mono: String?
    var fontScale: CGFloat = 1
    let radius: CGFloat
    let cardStyle: CardStyle
    var backdrop: Backdrop = .plain
    var glow: Color? = nil
    /// Miniature for the gallery: desktop, window, title bar, accent
    let swatch: (desk: Color, window: Color, bar: Color, accent: Color)
}

extension Color {
    init(hex6 v: UInt32, _ a: Double = 1) {
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }
    init?(hexString s: String) {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        self.init(hex6: v)
    }
}

extension AppTheme {
    private static func sys(_ c: NSColor) -> Color { Color(nsColor: c) }

    static let all: [AppTheme] = [
        AppTheme(id: "vitalos", name: "VitalOS", era: "Clinical dark",
                 about: "The default. Calm and dark like a bedside monitor: green when healthy, coral under strain, amber for heat.",
                 chrome: .vitalos, scheme: .dark,
                 bg: Color(hex6: 0x0B0D10), sidebar: Color(hex6: 0x0D1013), card: Color(hex6: 0x12161A), stroke: Color(hex6: 0x1E242C),
                 accent: Color(hex6: 0x3DDC97), good: Color(hex6: 0x3DDC97), heart: Color(hex6: 0xFF7A6B), cpu: Color(hex6: 0x7DB4FF),
                 mem: Color(hex6: 0xC49BFF), net: Color(hex6: 0xF5A04A), heat: Color(hex6: 0xF5B451), warn: Color(hex6: 0xFF7A6B),
                 selection: Color(hex6: 0x1E2E27), selectionText: Color(hex6: 0x7FE3B8),
                 font: nil, boldFont: nil, mono: nil, radius: 16, cardStyle: .flat,
                 swatch: (Color(hex6: 0x14201B), Color(hex6: 0x0B0D10), Color(hex6: 0x0F1317), Color(hex6: 0x3DDC97))),
        AppTheme(id: "apple", name: "Apple Pro", era: "First-party, today",
                 about: "As if Apple made it: system colors, translucent sidebar, SF Pro and pill buttons. Follows Light and Dark mode.",
                 chrome: .apple, scheme: nil,
                 bg: sys(.windowBackgroundColor), sidebar: sys(.underPageBackgroundColor), card: Color.primary.opacity(0.04), stroke: sys(.separatorColor),
                 accent: .accentColor, good: sys(.systemGreen), heart: sys(.systemPink), cpu: sys(.systemBlue), mem: sys(.systemPurple),
                 net: sys(.systemOrange), heat: sys(.systemYellow), warn: sys(.systemRed),
                 selection: Color.accentColor.opacity(0.18), selectionText: .primary,
                 font: nil, boldFont: nil, mono: nil, radius: 14, cardStyle: .glass,
                 swatch: (Color(hex6: 0xD9E4F5), .white, Color(hex6: 0xECECF0), Color(hex6: 0x0071E3))),
        AppTheme(id: "aqua", name: "Aqua", era: "Mac OS X · 2001–2007",
                 about: "Pinstripes, gel buttons and glossy traffic lights. Pure Panther.",
                 chrome: .aqua, scheme: .light,
                 bg: Color(hex6: 0xECECEC), sidebar: Color(hex6: 0xD8DEE6), card: .white, stroke: Color(hex6: 0xA5A5A5),
                 accent: Color(hex6: 0x2F7FE0), good: Color(hex6: 0x2E9E3A), heart: Color(hex6: 0x1F6FD1), cpu: Color(hex6: 0x1F6FD1),
                 mem: Color(hex6: 0x7A4FC9), net: Color(hex6: 0xE07B1F), heat: Color(hex6: 0xD9A400), warn: Color(hex6: 0xD8382E),
                 selection: Color(hex6: 0x3A84E3), selectionText: .white,
                 font: "Lucida Grande", boldFont: "LucidaGrande-Bold", mono: "Monaco", radius: 8, cardStyle: .aqua, backdrop: .pinstripe,
                 swatch: (Color(hex6: 0x3F7CC8), Color(hex6: 0xECECEC), Color(hex6: 0xC9C9C9), Color(hex6: 0x3A8EE6))),
        AppTheme(id: "win95", name: "Windows 95", era: "1995 · beveled gray",
                 about: "Gray 3D bevels, a navy title bar and buttons that look pressable.",
                 chrome: .win95, scheme: .light,
                 bg: Color(hex6: 0xC0C0C0), sidebar: Color(hex6: 0xC0C0C0), card: Color(hex6: 0xC0C0C0), stroke: Color(hex6: 0x808080),
                 accent: Color(hex6: 0x000080), good: Color(hex6: 0x008000), heart: Color(hex6: 0x008000), cpu: Color(hex6: 0x000080),
                 mem: Color(hex6: 0x800080), net: Color(hex6: 0x808000), heat: Color(hex6: 0x808000), warn: Color(hex6: 0x800000),
                 selection: Color(hex6: 0x000080), selectionText: .white,
                 font: "Tahoma", boldFont: "Tahoma-Bold", mono: "Courier New", fontScale: 0.95, radius: 0, cardStyle: .bevel,
                 swatch: (Color(hex6: 0x008080), Color(hex6: 0xC0C0C0), Color(hex6: 0x000080), Color(hex6: 0xC0C0C0))),
        AppTheme(id: "xp", name: "Windows XP", era: "2001 · Luna",
                 about: "The chunky blue title bar, beige dialogs and the green Start button.",
                 chrome: .xp, scheme: .light,
                 bg: Color(hex6: 0xECE9D8), sidebar: Color(hex6: 0x6F8CDB), card: .white, stroke: Color(hex6: 0xACA899),
                 accent: Color(hex6: 0x316AC5), good: Color(hex6: 0x3C9A3C), heart: Color(hex6: 0x2A9A3A), cpu: Color(hex6: 0x316AC5),
                 mem: Color(hex6: 0x8A4FB0), net: Color(hex6: 0xE07B1F), heat: Color(hex6: 0xD9A400), warn: Color(hex6: 0xC83C14),
                 selection: Color(hex6: 0x316AC5), selectionText: .white,
                 font: "Tahoma", boldFont: "Tahoma-Bold", mono: "Courier New", radius: 3, cardStyle: .xp,
                 swatch: (Color(hex6: 0x5A9BE8), Color(hex6: 0xECE9D8), Color(hex6: 0x0058E6), Color(hex6: 0x3C9A3C))),
        AppTheme(id: "win11", name: "Windows 11", era: "2021 · Fluent",
                 about: "Soft Mica, rounded corners, and window buttons on the right.",
                 chrome: .win11, scheme: .light,
                 bg: Color(hex6: 0xF3F3F3), sidebar: Color(hex6: 0xEDEDED), card: Color(hex6: 0xFBFBFB), stroke: Color(hex6: 0xE0E0E0),
                 accent: Color(hex6: 0x0067C0), good: Color(hex6: 0x0F7B0F), heart: Color(hex6: 0x0067C0), cpu: Color(hex6: 0x0067C0),
                 mem: Color(hex6: 0x8764B8), net: Color(hex6: 0xCA5010), heat: Color(hex6: 0xC19C00), warn: Color(hex6: 0xC42B1C),
                 selection: Color(hex6: 0xE5E5E5), selectionText: Color(hex6: 0x1A1A1A),
                 font: nil, boldFont: nil, mono: "Menlo", radius: 8, cardStyle: .flat,
                 swatch: (Color(hex6: 0xB8D4F5), Color(hex6: 0xF3F3F3), Color(hex6: 0xF3F3F3), Color(hex6: 0x0067C0))),
        AppTheme(id: "mac1bit", name: "Macintosh", era: "1984–1991 · System 7",
                 about: "One bit, black on white. Striped title bars and hard drop shadows.",
                 chrome: .mac1bit, scheme: .light,
                 bg: .white, sidebar: .white, card: .white, stroke: .black,
                 accent: .black, good: .black, heart: .black, cpu: .black, mem: .black, net: .black, heat: .black, warn: .black,
                 selection: .black, selectionText: .white,
                 font: "Geneva", boldFont: nil, mono: "Monaco", radius: 0, cardStyle: .oneBit,
                 swatch: (Color(hex6: 0x808080), .white, .white, .black)),
        AppTheme(id: "gnome", name: "Linux", era: "Ubuntu · GNOME",
                 about: "GNOME header bars, the round close button, Ubuntu orange and the Ubuntu typeface.",
                 chrome: .gnome, scheme: .light,
                 bg: Color(hex6: 0xFAFAFA), sidebar: Color(hex6: 0xF0F0F0), card: .white, stroke: Color(hex6: 0xD5D5D5),
                 accent: Color(hex6: 0xE95420), good: Color(hex6: 0x26A269), heart: Color(hex6: 0xE95420), cpu: Color(hex6: 0x3584E4),
                 mem: Color(hex6: 0x9141AC), net: Color(hex6: 0xE66100), heat: Color(hex6: 0xE5A50A), warn: Color(hex6: 0xC01C28),
                 selection: Color(hex6: 0xDEDDDA), selectionText: Color(hex6: 0x2E3436),
                 font: "Ubuntu", boldFont: "Ubuntu-Bold", mono: "Menlo", radius: 12, cardStyle: .flat,
                 swatch: (Color(hex6: 0x77216F), Color(hex6: 0xFAFAFA), Color(hex6: 0xEBEBEB), Color(hex6: 0xE95420))),
        AppTheme(id: "braun", name: "Braun", era: "Surprise · Dieter Rams",
                 about: "After Rams' radios and calculators: warm off-white, charcoal, one orange control and a strict grid. Less, but better.",
                 chrome: .braun, scheme: .light,
                 bg: Color(hex6: 0xEDEAE3), sidebar: Color(hex6: 0xE3DFD5), card: Color(hex6: 0xF6F4EF), stroke: Color(hex6: 0xCFC9BC),
                 accent: Color(hex6: 0xF25C05), good: Color(hex6: 0x3B7D3A), heart: Color(hex6: 0x3B7D3A), cpu: Color(hex6: 0x2B2B2B),
                 mem: Color(hex6: 0x5A5A5A), net: Color(hex6: 0xF25C05), heat: Color(hex6: 0xC98A1A), warn: Color(hex6: 0xC8401A),
                 selection: Color(hex6: 0x2B2B2B), selectionText: Color(hex6: 0xEDEAE3),
                 font: "Space Grotesk", boldFont: nil, mono: "Space Grotesk", radius: 6, cardStyle: .flat,
                 swatch: (Color(hex6: 0xD9D4C7), Color(hex6: 0xEDEAE3), Color(hex6: 0x2B2B2B), Color(hex6: 0xF25C05))),
        AppTheme(id: "phosphor", name: "Phosphor", era: "Surprise · CRT terminal",
                 about: "A green CRT terminal with scanlines and a soft phosphor glow.",
                 chrome: .terminal, scheme: .dark,
                 bg: Color(hex6: 0x030703), sidebar: Color(hex6: 0x041004), card: Color(hex6: 0x041004), stroke: Color(hex6: 0x1E9A3E),
                 accent: Color(hex6: 0x33FF66), good: Color(hex6: 0x33FF66), heart: Color(hex6: 0x33FF66), cpu: Color(hex6: 0x33FF66),
                 mem: Color(hex6: 0x9CFF6B), net: Color(hex6: 0xFFD166), heat: Color(hex6: 0xFFD166), warn: Color(hex6: 0xFF6B4A),
                 selection: Color(hex6: 0x33FF66), selectionText: Color(hex6: 0x021402),
                 font: "VT323", boldFont: nil, mono: "VT323", fontScale: 1.3, radius: 0, cardStyle: .dashed, backdrop: .scanlines,
                 glow: Color(hex6: 0x33FF66),
                 swatch: (Color(hex6: 0x020402), Color(hex6: 0x030703), Color(hex6: 0x062006), Color(hex6: 0x33FF66))),
    ]
}

// MARK: - Store

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private let d = UserDefaults.standard

    @Published var themeID: String { didSet { d.set(themeID, forKey: "theme.id") } }
    @Published var accentHex: String { didSet { d.set(accentHex, forKey: "theme.accent") } }
    @Published var mode: String { didSet { d.set(mode, forKey: "theme.mode") } }            // auto, light, dark
    @Published var density: String { didSet { d.set(density, forKey: "theme.density") } }   // compact, comfortable, touch
    @Published var textScale: Double { didSet { d.set(textScale, forKey: "theme.text") } }
    @Published var reduceMotion: Bool { didSet { d.set(reduceMotion, forKey: "theme.motion") } }
    @Published var chromeOn: Bool { didSet { d.set(chromeOn, forKey: "theme.chrome") } }
    @Published var glowOn: Bool { didSet { d.set(glowOn, forKey: "theme.glow") } }

    private init() {
        themeID = d.string(forKey: "theme.id") ?? "apple"
        accentHex = d.string(forKey: "theme.accent") ?? ""
        mode = d.string(forKey: "theme.mode") ?? "auto"
        density = d.string(forKey: "theme.density") ?? "comfortable"
        textScale = d.object(forKey: "theme.text") as? Double ?? 1
        reduceMotion = d.object(forKey: "theme.motion") as? Bool ?? false
        chromeOn = d.object(forKey: "theme.chrome") as? Bool ?? true
        glowOn = d.object(forKey: "theme.glow") as? Bool ?? true
        Fonts.registerBundled()
    }

    var current: AppTheme { AppTheme.all.first { $0.id == themeID } ?? AppTheme.all[0] }
    var accent: Color { Color(hexString: accentHex) ?? current.accent }
    var scheme: ColorScheme? {
        if let s = current.scheme { return s }
        return mode == "light" ? .light : mode == "dark" ? .dark : nil
    }
    /// Changing any of these rebuilds the view tree so every static Theme color is read again.
    var revision: String { "\(themeID)|\(accentHex)|\(mode)|\(density)|\(textScale)|\(chromeOn)|\(glowOn)" }
    var usesCustomChrome: Bool { chromeOn && ![.vitalos, .apple].contains(current.chrome) }
}

// MARK: - Fonts

enum Fonts {
    static func registerBundled() {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Fonts")) }
        // running unbundled from Xcode: use the project folder
        dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts"))
        for dir in dirs where fm.fileExists(atPath: dir.path) {
            let urls = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
            break
        }
    }
}

extension Font {
    /// Theme-aware replacement for `.system(size:weight:design:)`.
    static func ui(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let store = ThemeStore.shared, t = store.current
        let s = size * t.fontScale * CGFloat(store.textScale)
        if design == .monospaced, let m = t.mono { return .custom(m, size: s).weight(weight) }
        if let f = t.font {
            let heavy: [Font.Weight] = [.semibold, .bold, .heavy, .black]
            if heavy.contains(weight), let b = t.boldFont { return .custom(b, size: s) }
            return .custom(f, size: s).weight(weight)
        }
        return .system(size: s, weight: weight, design: design)
    }
}

// MARK: - Root modifier

struct Themed: ViewModifier {
    @ObservedObject var store = ThemeStore.shared

    func body(content: Content) -> some View {
        let t = store.current
        content
            .id(store.revision)
            .tint(store.accent)
            .preferredColorScheme(store.scheme)
            .controlSize(store.density == "compact" ? .small : store.density == "touch" ? .large : .regular)
            .modifier(ThemeButtons(chrome: t.chrome))
            .background(ThemeBackdrop(theme: t).ignoresSafeArea())
            .overlay(alignment: .top) { if store.usesCustomChrome { WindowChrome(theme: t).ignoresSafeArea(edges: .top) } }
            .overlay { if t.backdrop == .scanlines { Scanlines().ignoresSafeArea().allowsHitTesting(false) } }
            .modifier(Glow(color: store.glowOn ? t.glow : nil))
            .background(TrafficLights(hidden: store.usesCustomChrome))
    }
}

extension View {
    func themed() -> some View { modifier(Themed()) }
}

private struct Glow: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color { content.compositingGroup().shadow(color: color.opacity(0.55), radius: 2.5) } else { content }
    }
}

struct ThemeBackdrop: View {
    let theme: AppTheme
    var body: some View {
        switch theme.backdrop {
        case .pinstripe:
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.bg))
                var y: CGFloat = 0
                while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 2)), with: .color(.white.opacity(0.45))); y += 4 }
            }
        default:
            theme.bg
        }
    }
}

struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.28))); y += 3 }
        }
    }
}

/// Hides macOS's own traffic lights when the theme draws its own window frame.
private struct TrafficLights: NSViewRepresentable {
    let hidden: Bool
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { apply(v) }; return v }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { apply(v) } }
    private func apply(_ v: NSView) {
        guard let w = v.window else { return }
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = hidden }
    }
}

/// Lets an empty area drag the window, like a real title bar.
struct DragArea: NSViewRepresentable {
    final class V: NSView { override var mouseDownCanMoveWindow: Bool { true } }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - Window chrome per theme

struct WindowChrome: View {
    let theme: AppTheme
    private func act(_ f: @escaping (NSWindow) -> Void) { if let w = NSApp.keyWindow ?? NSApp.mainWindow { f(w) } }
    private var close: () -> Void { { act { $0.performClose(nil) } } }
    private var mini: () -> Void { { act { $0.miniaturize(nil) } } }
    private var zoom: () -> Void { { act { $0.zoom(nil) } } }

    var body: some View {
        ZStack {
            DragArea()
            bar
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }

    private var height: CGFloat { Self.height(theme.chrome) }
    static func height(_ c: ChromeStyle) -> CGFloat {
        switch c { case .win95: 24; case .xp: 30; case .win11: 32; case .mac1bit: 20; case .gnome: 40; default: 30 }
    }

    @ViewBuilder private var bar: some View {
        switch theme.chrome {
        case .win95:
            HStack(spacing: 2) {
                Text("VitalOS").font(.custom("Tahoma-Bold", size: 12)).foregroundStyle(.white).padding(.leading, 6)
                Spacer().allowsHitTesting(false)
                ForEach(["_", "□", "×"], id: \.self) { g in
                    Button(action: g == "×" ? close : g == "_" ? mini : zoom) {
                        Text(g).font(.custom("Tahoma-Bold", size: 10)).foregroundStyle(.black).frame(width: 16, height: 14)
                            .background(Color(hex6: 0xC0C0C0)).modifier(Bevel(raised: true))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 3).frame(maxHeight: .infinity)
            .background(LinearGradient(colors: [Color(hex6: 0x000080), Color(hex6: 0x1084D0)], startPoint: .leading, endPoint: .trailing).allowsHitTesting(false))
        case .xp:
            HStack(spacing: 2) {
                Text("VitalOS").font(.custom("Tahoma-Bold", size: 13)).foregroundStyle(.white).shadow(color: .black.opacity(0.4), radius: 0, x: 1, y: 1).padding(.leading, 8)
                Spacer().allowsHitTesting(false)
                ForEach(["_", "□", "×"], id: \.self) { g in
                    Button(action: g == "×" ? close : g == "_" ? mini : zoom) {
                        Text(g).font(.custom("Tahoma-Bold", size: 12)).foregroundStyle(.white).frame(width: 21, height: 21)
                            .background(LinearGradient(colors: g == "×" ? [Color(hex6: 0xE8836A), Color(hex6: 0xC83C14)] : [Color(hex6: 0x6A9CFF), Color(hex6: 0x1F57D9)], startPoint: .top, endPoint: .bottom),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 5).frame(maxHeight: .infinity)
            .background(LinearGradient(colors: [Color(hex6: 0x0A5FE8), Color(hex6: 0x3A93FF), Color(hex6: 0x0058E6), Color(hex6: 0x0047C9)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
        case .win11:
            HStack(spacing: 0) {
                Text("VitalOS").font(.system(size: 12)).foregroundStyle(Color(hex6: 0x1A1A1A)).padding(.leading, 12)
                Spacer().allowsHitTesting(false)
                ForEach(["minus", "square", "xmark"], id: \.self) { g in
                    Win11Button(symbol: g, isClose: g == "xmark", action: g == "xmark" ? close : g == "minus" ? mini : zoom)
                }
            }
        case .mac1bit:
            HStack(spacing: 6) {
                Button(action: close) { Rectangle().stroke(.black, lineWidth: 1).background(.white).frame(width: 11, height: 11) }.buttonStyle(.plain).padding(.leading, 8)
                Stripes()
                Text("VitalOS").font(.custom("Geneva", size: 12).weight(.bold)).foregroundStyle(.black).padding(.horizontal, 6).background(.white)
                Stripes()
                Button(action: zoom) { Rectangle().stroke(.black, lineWidth: 1).background(.white).frame(width: 11, height: 11) }.buttonStyle(.plain).padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity).background(Color.white.allowsHitTesting(false))
            .overlay(alignment: .bottom) { Rectangle().fill(.black).frame(height: 1) }
        case .gnome:
            HStack(spacing: 6) {
                Spacer().allowsHitTesting(false)
                Text("VitalOS").font(.custom("Ubuntu-Bold", size: 13)).foregroundStyle(Color(hex6: 0x2E3436))
                Spacer().allowsHitTesting(false)
                ForEach(["minus", "xmark"], id: \.self) { g in
                    Button(action: g == "xmark" ? close : mini) {
                        Image(systemName: g).font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex6: 0x2E3436))
                            .frame(width: 24, height: 24).background(Color.black.opacity(g == "xmark" ? 0.1 : 0.0001), in: Circle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(hex6: 0xD5D5D5)).frame(height: 1) }
        case .aqua:
            HStack(spacing: 8) {
                ForEach([(0xE0443E, close), (0xDEA123, mini), (0x1AAB29, zoom)].indices, id: \.self) { i in
                    let pair = [(0xE0443E, close), (0xDEA123, mini), (0x1AAB29, zoom)][i]
                    Button(action: pair.1) {
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.8), Color(hex6: UInt32(pair.0))], center: UnitPoint(x: 0.5, y: 0.25), startRadius: 0, endRadius: 7))
                            .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5)).frame(width: 13, height: 13)
                    }.buttonStyle(.plain)
                }
                Spacer().allowsHitTesting(false)
            }
            .padding(.leading, 10).frame(maxHeight: .infinity)
            .background(LinearGradient(colors: [Color(hex6: 0xE8E8E8), Color(hex6: 0xBDBDBD)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
        case .braun:
            HStack(spacing: 8) {
                Button(action: close) { Circle().fill(Color(hex6: 0xF25C05)).frame(width: 12, height: 12) }.buttonStyle(.plain)
                Button(action: mini) { Circle().fill(Color(hex6: 0x5A5A5A)).frame(width: 12, height: 12) }.buttonStyle(.plain)
                Spacer().allowsHitTesting(false)
                Text("vitalos").font(.custom("Space Grotesk", size: 12)).kerning(1.5).foregroundStyle(Color(hex6: 0xEDEAE3))
            }
            .padding(.horizontal, 12).frame(maxHeight: .infinity).background(Color(hex6: 0x2B2B2B).allowsHitTesting(false))
        case .terminal:
            HStack {
                Button(action: close) { Text("[x]").font(.custom("VT323", size: 18)).foregroundStyle(Color(hex6: 0x33FF66)) }.buttonStyle(.plain)
                Spacer().allowsHitTesting(false)
                Text("VITALOS v2.0 — READY").font(.custom("VT323", size: 18)).kerning(2).foregroundStyle(Color(hex6: 0x33FF66))
                Spacer().allowsHitTesting(false)
            }
            .padding(.horizontal, 10).frame(maxHeight: .infinity).background(Color(hex6: 0x062006).allowsHitTesting(false))
        default:
            EmptyView()
        }
    }
}

private struct Win11Button: View {
    let symbol: String, isClose: Bool, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(hover && isClose ? .white : Color(hex6: 0x1A1A1A))
                .frame(width: 46, height: 32).background(hover ? (isClose ? Color(hex6: 0xC42B1C) : Color.black.opacity(0.06)) : .clear)
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

private struct Stripes: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 3
            while y < size.height - 2 { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black)); y += 2 }
        }
        .frame(height: 14).allowsHitTesting(false)
    }
}

// MARK: - Bevels, cards and buttons

struct Bevel: ViewModifier {
    var raised = true
    func body(content: Content) -> some View {
        content.overlay(
            ZStack {
                Rectangle().stroke(raised ? Color.white : Color(hex6: 0x808080), lineWidth: 1).offset(x: -0.5, y: -0.5)
                Rectangle().stroke(raised ? Color(hex6: 0x404040) : Color.white, lineWidth: 1).offset(x: 0.5, y: 0.5)
            }
        )
    }
}

/// Every `.glass()` card in the app goes through this, so cards follow the theme.
struct ThemedCard: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        let t = ThemeStore.shared.current
        let r = min(radius, t.radius)
        switch t.cardStyle {
        case .glass:
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: r, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(t.stroke.opacity(0.7), lineWidth: 0.5))
        case .flat:
            content
                .background(t.card, in: RoundedRectangle(cornerRadius: r, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(t.stroke, lineWidth: 1))
        case .bevel:
            content.background(t.card).modifier(Bevel(raised: false))
        case .oneBit:
            content.background(Color.white).overlay(Rectangle().stroke(.black, lineWidth: 1))
                .background(Rectangle().fill(.black).offset(x: 2, y: 2))
        case .aqua:
            content
                .background(LinearGradient(colors: [.white, Color(hex6: 0xF2F2F2)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: r, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color(hex6: 0xA5A5A5), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        case .xp:
            content
                .background(Color.white, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex6: 0x7F9DB9), lineWidth: 1))
        case .dashed:
            content.background(t.card)
                .overlay(Rectangle().strokeBorder(t.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }
}

struct ThemeButtons: ViewModifier {
    let chrome: ChromeStyle
    func body(content: Content) -> some View {
        if chrome == .apple { content } else { content.buttonStyle(ThemeButtonStyle(chrome: chrome)) }
    }
}

struct ThemeButtonStyle: ButtonStyle {
    let chrome: ChromeStyle
    func makeBody(configuration c: Configuration) -> some View {
        let t = ThemeStore.shared.current
        let acc = ThemeStore.shared.accent
        let label = c.label.padding(.horizontal, 12).padding(.vertical, 5)
        switch chrome {
        case .win95:
            label.foregroundStyle(.black).background(Color(hex6: 0xC0C0C0)).modifier(Bevel(raised: !c.isPressed))
        case .xp:
            label.foregroundStyle(.black)
                .background(LinearGradient(colors: [.white, Color(hex6: 0xECEBE6), Color(hex6: 0xD6D0C5)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(hex6: 0x003C74), lineWidth: 1))
                .brightness(c.isPressed ? -0.08 : 0)
        case .aqua:
            label.foregroundStyle(.black)
                .background(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: Color(hex6: 0xE6E6E6), location: 0.5), .init(color: Color(hex6: 0xD6D6D6), location: 0.51), .init(color: Color(hex6: 0xF2F2F2), location: 1)], startPoint: .top, endPoint: .bottom), in: Capsule())
                .overlay(Capsule().stroke(Color(hex6: 0x8E8E8E), lineWidth: 1))
                .brightness(c.isPressed ? -0.1 : 0)
        case .mac1bit:
            label.foregroundStyle(c.isPressed ? .white : .black)
                .background(c.isPressed ? Color.black : .white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black, lineWidth: 1))
        case .terminal:
            label.foregroundStyle(c.isPressed ? t.bg : t.accent)
                .background(c.isPressed ? t.accent : .clear)
                .overlay(Rectangle().strokeBorder(t.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        case .braun:
            label.foregroundStyle(Color(hex6: 0xEDEAE3)).background(Color(hex6: 0x2B2B2B), in: Capsule()).opacity(c.isPressed ? 0.8 : 1)
        case .gnome:
            label.foregroundStyle(Color(hex6: 0x2E3436)).background(Color(hex6: 0xEBEBEB).opacity(c.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8))
        case .win11:
            label.foregroundStyle(Color(hex6: 0x1A1A1A)).background(Color(hex6: 0xFBFBFB), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex6: 0xE0E0E0), lineWidth: 1)).opacity(c.isPressed ? 0.75 : 1)
        case .vitalos, .apple:
            label.foregroundStyle(acc).background(acc.opacity(c.isPressed ? 0.25 : 0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// For the menu bar panel and the Settings window: theme colors, fonts and buttons, no window frame.
struct ThemedPanel: ViewModifier {
    @ObservedObject var store = ThemeStore.shared
    func body(content: Content) -> some View {
        let t = store.current
        content
            .id(store.revision)
            .tint(store.accent)
            .preferredColorScheme(store.scheme)
            .modifier(ThemeButtons(chrome: t.chrome))
            .background(ThemeBackdrop(theme: t))
            .overlay { if t.backdrop == .scanlines { Scanlines().allowsHitTesting(false) } }
    }
}

extension View {
    func themedPanel() -> some View { modifier(ThemedPanel()) }
}

struct HideSidebarToggle: ViewModifier {
    let hide: Bool
    func body(content: Content) -> some View {
        if hide { content.toolbar(removing: .sidebarToggle) } else { content }
    }
}

/// Sidebar color for themes that have their own; Apple Pro keeps the system material.
struct SidebarFill: View {
    var body: some View {
        if ThemeStore.shared.current.chrome == .apple { Color.clear } else {
            Theme.sidebar.ignoresSafeArea().background(FlattenSidebarGlass())
        }
    }
}

/// The sidebar column sits on frosted glass that washes out solid colors. Themes with their own sidebar turn it off.
private struct FlattenSidebarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { flatten(from: v) }; return v }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { flatten(from: v) } }
    private func flatten(from v: NSView) {
        var s = v.superview
        while let cur = s {
            // the glass may wrap the sidebar (keep it visible, just make it plain) or sit behind it as a sibling (hide it)
            if let ev = cur as? NSVisualEffectView { ev.state = .inactive; ev.material = .windowBackground; ev.blendingMode = .withinWindow; return }
            for sub in cur.subviews where !(sub === v) { if let ev = sub as? NSVisualEffectView, ev.subviews.isEmpty { ev.isHidden = true; return } }
            s = cur.superview
        }
    }
}
