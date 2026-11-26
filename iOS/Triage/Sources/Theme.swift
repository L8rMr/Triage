import SwiftUI
import UIKit

/// The Mac's ten themes, translated for the phone. Same ids as ThemeKit.swift on the Mac so they can sync.
struct Palette: Identifiable {
    let id: String
    let name: String
    let era: String
    let scheme: ColorScheme?          // nil: follow the phone
    let bg: Color, card: Color, stroke: Color
    let accent: Color, good: Color, warn: Color, heat: Color
    var radius: CGFloat = 16
    var mono = false
    var glow = false

    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static let all: [Palette] = [
        Palette(id: "vitalos", name: "Triage", era: "Clinical dark", scheme: .dark,
                bg: hex(0x0B0D10), card: hex(0x14191E), stroke: hex(0x1E242C),
                accent: hex(0x3DDC97), good: hex(0x3DDC97), warn: hex(0xFF7A6B), heat: hex(0xF5B451), glow: true),
        Palette(id: "apple", name: "Apple Pro", era: "First-party, today", scheme: nil,
                bg: Color(.systemGroupedBackground), card: Color(.secondarySystemGroupedBackground), stroke: Color(.separator),
                accent: .blue, good: .green, warn: .red, heat: .orange, radius: 14),
        Palette(id: "aqua", name: "Aqua", era: "Mac OS X · 2001–2007", scheme: .light,
                bg: hex(0xECECEC), card: .white, stroke: hex(0xA5A5A5),
                accent: hex(0x2F7FE0), good: hex(0x2E9E3A), warn: hex(0xD8382E), heat: hex(0xD9A400), radius: 8),
        Palette(id: "win95", name: "Windows 95", era: "1995 · beveled gray", scheme: .light,
                bg: hex(0xC0C0C0), card: hex(0xD4D0C8), stroke: hex(0x808080),
                accent: hex(0x000080), good: hex(0x008000), warn: hex(0x800000), heat: hex(0x808000), radius: 0),
        Palette(id: "xp", name: "Windows XP", era: "2001 · Luna", scheme: .light,
                bg: hex(0xECE9D8), card: .white, stroke: hex(0xACA899),
                accent: hex(0x316AC5), good: hex(0x3C9A3C), warn: hex(0xC83C14), heat: hex(0xD9A400), radius: 3),
        Palette(id: "win11", name: "Windows 11", era: "2021 · Fluent", scheme: .light,
                bg: hex(0xF3F3F3), card: hex(0xFBFBFB), stroke: hex(0xE0E0E0),
                accent: hex(0x0067C0), good: hex(0x0F7B0F), warn: hex(0xC42B1C), heat: hex(0xC19C00), radius: 8),
        Palette(id: "mac1bit", name: "Macintosh", era: "1984–1991 · System 7", scheme: .light,
                bg: .white, card: .white, stroke: .black,
                accent: .black, good: .black, warn: .black, heat: .black, radius: 0),
        Palette(id: "gnome", name: "Linux", era: "Ubuntu · GNOME", scheme: .light,
                bg: hex(0xFAFAFA), card: .white, stroke: hex(0xD5D5D5),
                accent: hex(0xE95420), good: hex(0x26A269), warn: hex(0xC01C28), heat: hex(0xE5A50A), radius: 12),
        Palette(id: "braun", name: "Braun", era: "Dieter Rams", scheme: .light,
                bg: hex(0xEDEAE3), card: hex(0xF6F4EF), stroke: hex(0xCFC9BC),
                accent: hex(0xF25C05), good: hex(0x3B7D3A), warn: hex(0xC8401A), heat: hex(0xC98A1A), radius: 6),
        Palette(id: "phosphor", name: "Phosphor", era: "CRT terminal", scheme: .dark,
                bg: hex(0x030703), card: hex(0x061206), stroke: hex(0x1E9A3E),
                accent: hex(0x33FF66), good: hex(0x33FF66), warn: hex(0xFF6B4A), heat: hex(0xFFD166), radius: 0, mono: true, glow: true),
    ]
}

/// "Match Mac" follows whatever the Mac is wearing; picking a theme here keeps the phone on its own.
final class ThemeModel: ObservableObject {
    static let shared = ThemeModel()
    private let d = UserDefaults.standard

    @Published var macThemeID: String { didSet { d.set(macThemeID, forKey: "theme.mac") } }
    @Published var choice: String { didSet { d.set(choice, forKey: "theme.choice") } }

    private init() {
        macThemeID = d.string(forKey: "theme.mac") ?? "vitalos"
        choice = d.string(forKey: "theme.choice") ?? "mac"
    }

    var followsMac: Bool { choice == "mac" }
    var activeID: String { followsMac ? macThemeID : choice }
    var palette: Palette { Palette.all.first { $0.id == activeID } ?? Palette.all[0] }
    var macPalette: Palette { Palette.all.first { $0.id == macThemeID } ?? Palette.all[0] }

    static var current: Palette { shared.palette }
}
