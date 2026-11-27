import SwiftUI
import UIKit
import AudioToolbox

/// A MacBook keyboard, drawn key for key: esc + F-row, number row, ⇥ QWERTY, ⇪ ASDF, ⇧ ZXCV, fn ⌃ ⌥ ⌘ space ⌘ ⌥ and the inverted-T arrows.
/// Modifiers work like the Mac's Sticky Keys: tap once for the next key, tap twice to lock.
struct MacKeyboard: View {
    @Binding var mods: Set<String>
    @Binding var locked: Set<String>
    var showFRow = true
    let press: (_ key: String, _ mods: [String]) -> Void

    private struct K: Identifiable {
        let id = UUID()
        let label: String
        var shifted: String? = nil
        let key: String          // name the Mac understands
        var width: CGFloat = 1
        var mod: String? = nil
        var small = false
        var symbol: String? = nil
    }

    /// The MacBook top row: what each F-key does by default (hold fn for plain F1–F12).
    static let fSymbols = ["sun.min", "sun.max", "rectangle.3.group", "magnifyingglass", "mic", "moon",
                           "backward.fill", "playpause.fill", "forward.fill", "speaker.slash", "speaker.wave.1", "speaker.wave.3"]

    private var rows: [[K]] {
        var r: [[K]] = []
        if showFRow {
            r.append([K(label: "esc", key: "escape", width: 1.4, small: true)] +
                     (1...12).map { K(label: "F\($0)", key: "f\($0)", small: true, symbol: Self.fSymbols[$0 - 1]) })
        }
        let num: [(String, String)] = [("`", "~"), ("1", "!"), ("2", "@"), ("3", "#"), ("4", "$"), ("5", "%"), ("6", "^"), ("7", "&"), ("8", "*"), ("9", "("), ("0", ")"), ("-", "_"), ("=", "+")]
        r.append(num.map { K(label: $0.0, shifted: $0.1, key: $0.0) } + [K(label: "delete", key: "delete", width: 1.5, small: true)])
        r.append([K(label: "tab", key: "tab", width: 1.5, small: true)] + "qwertyuiop".map { K(label: String($0), key: String($0)) } +
                 [K(label: "[", shifted: "{", key: "["), K(label: "]", shifted: "}", key: "]"), K(label: "\\", shifted: "|", key: "\\")])
        r.append([K(label: "caps lock", key: "caps", width: 1.8, small: true)] + "asdfghjkl".map { K(label: String($0), key: String($0)) } +
                 [K(label: ";", shifted: ":", key: ";"), K(label: "'", shifted: "\"", key: "'"), K(label: "return", key: "return", width: 1.8, small: true)])
        r.append([K(label: "shift", key: "", width: 2.3, mod: "shift", small: true)] + "zxcvbnm".map { K(label: String($0), key: String($0)) } +
                 [K(label: ",", shifted: "<", key: ","), K(label: ".", shifted: ">", key: "."), K(label: "/", shifted: "?", key: "/"),
                  K(label: "shift", key: "", width: 2.3, mod: "shift", small: true)])
        return r
    }

    private var shifted: Bool { mods.contains("shift") || locked.contains("shift") }
    @State private var echo: [String] = []          // the last keys that went to the Mac, so every press is confirmed
    @State private var echoAt = Date.distantPast

    private func sent(_ key: String, _ m: [String]) {
        let marks = [("ctrl", "⌃"), ("opt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")].filter { m.contains($0.0) }.map(\.1).joined()
        let names = ["delete": "⌫", "return": "↩", "tab": "⇥", "space": "␣", "escape": "esc", "left": "←", "right": "→", "up": "↑", "down": "↓"]
        var face = names[key] ?? key
        if face.count == 1, m.contains("shift") { face = face.uppercased() }
        let tag = marks + face
        // a held key reads "⌫×14", not fourteen ⌫s
        if let last = echo.last, last == tag || last.hasPrefix(tag + "×") {
            let n = (Int(last.split(separator: "×").last.map(String.init) ?? "") ?? 1) + 1
            echo[echo.count - 1] = "\(tag)×\(n)"
        } else {
            echo = Array((echo + [tag]).suffix(14))
        }
        echoAt = Date()
        let at = echoAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if echoAt == at { withAnimation(.easeOut(duration: 0.3)) { echo = [] } } }
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let rowsCount = CGFloat(rows.count + 1)
            let h = min((g.size.height - 4 * rowsCount) / rowsCount, w / 15 * 1.05)
            VStack(spacing: 4) {
                ForEach(rows.indices, id: \.self) { i in
                    // every row fills exactly the width there is: no key ever hangs off an edge
                    let units = rows[i].reduce(0) { $0 + $1.width }
                    let unit = (w - 4 * CGFloat(rows[i].count - 1)) / units
                    HStack(spacing: 4) {
                        ForEach(rows[i]) { k in keyView(k, unit: unit, h: i == 0 && showFRow ? h * 0.72 : h) }
                    }
                }
                bottomRow(width: w, h: h)
            }
            .frame(width: w, height: g.size.height, alignment: .bottom)
        }
        .overlay(alignment: .topTrailing) {
            if !echo.isEmpty {
                Text(echo.joined(separator: " "))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.phosphor)
                    .lineLimit(1).truncationMode(.head)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.65), in: Capsule())
                    .offset(y: -30)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    /// fn ⌃ ⌥ ⌘ [space] ⌘ ⌥ ◀▲▼▶, in MacBook proportions, summing to the full width.
    private func bottomRow(width: CGFloat, h: CGFloat) -> some View {
        // 1 + 1 + 1 + 1.25 + space 5 + 1.25 + 1 + arrows 3 = 14.5 units, 8 gaps of 4 pt
        let unit = (width - 4 * 8) / 14.5
        let arrow = (unit * 3 - 4) / 3
        return HStack(spacing: 4) {
            modKey("fn", "fn", "globe", width: unit, h: h)
            modKey("ctrl", "control", "control", width: unit, h: h)
            modKey("opt", "option", "option", width: unit, h: h)
            modKey("cmd", "command", "command", width: unit * 1.25, h: h)
            keyView(K(label: "", key: "space", width: 5), unit: unit, h: h)
            modKey("cmd", "command", "command", width: unit * 1.25, h: h)
            modKey("opt", "option", "option", width: unit, h: h)
            // inverted T
            VStack(spacing: 2) {
                keyView(K(label: "▲", key: "up", small: true), unit: arrow, h: h / 2 - 1)
                HStack(spacing: 2) {
                    keyView(K(label: "◀", key: "left", small: true), unit: arrow, h: h / 2 - 1)
                    keyView(K(label: "▼", key: "down", small: true), unit: arrow, h: h / 2 - 1)
                    keyView(K(label: "▶", key: "right", small: true), unit: arrow, h: h / 2 - 1)
                }
            }
            .frame(width: unit * 3)
        }
        .frame(width: width)
    }

    private func modKey(_ mod: String, _ label: String, _ symbol: String, width: CGFloat, h: CGFloat) -> some View {
        let on = mods.contains(mod), lock = locked.contains(mod)
        return Button {
            KeyFeel.modifier()
            if lock { locked.remove(mod); mods.remove(mod) }
            else if on { mods.remove(mod); locked.insert(mod) }       // second tap locks it
            else { mods.insert(mod) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Image(systemName: symbol).font(.system(size: max(9, h * 0.28)))
                Text(label).font(.system(size: max(7, h * 0.2)))
            }
            .padding(.leading, 4).padding(.bottom, 3)
            .frame(width: width, height: h, alignment: .bottomLeading)
        }
        .buttonStyle(KeyStyle(active: on || lock, locked: lock))
    }

    @ViewBuilder private func keyView(_ k: K, unit: CGFloat, h: CGFloat) -> some View {
        if let mod = k.mod {
            let on = mods.contains(mod), lock = locked.contains(mod)
            Button {
                KeyFeel.modifier()
                if lock { locked.remove(mod); mods.remove(mod) } else if on { mods.remove(mod); locked.insert(mod) } else { mods.insert(mod) }
            } label: {
                Text("⇧ " + k.label).font(.system(size: max(8, h * 0.24))).lineLimit(1).minimumScaleFactor(0.6).frame(width: unit * k.width, height: h)
            }
            .buttonStyle(KeyStyle(active: on || lock, locked: lock))
        } else if k.key == "caps" {
            let lock = locked.contains("shift")
            Button {
                KeyFeel.modifier()
                if lock { locked.remove("shift") } else { locked.insert("shift") }
            } label: {
                HStack {
                    Circle().fill(lock ? Color.phosphor : Color.white.opacity(0.25)).frame(width: 5, height: 5)
                    Text(k.label).font(.system(size: max(8, h * 0.22))).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(width: unit * k.width, height: h)
            }
            .buttonStyle(KeyStyle(active: false, locked: false))
        } else {
            RepeatKey(repeats: ["delete", "left", "right", "up", "down", "space"].contains(k.key), sound: k.key == "delete" ? 1155 : (k.small ? 1156 : 1104)) {
                let m = Array(mods.union(locked))
                press(k.key, m)
                sent(k.key, m)
                if !mods.isEmpty { mods = [] }
            } label: {
                Group {
                    if let sym = k.symbol {
                        VStack(spacing: 1) {
                            if !(mods.contains("fn") || locked.contains("fn")) {
                                Image(systemName: sym).font(.system(size: max(9, h * 0.36), weight: .medium))
                            }
                            Text(k.label).font(.system(size: max(6, h * 0.2))).opacity(mods.contains("fn") || locked.contains("fn") ? 1 : 0.5)
                        }
                    } else if let s = k.shifted {
                        VStack(spacing: 0) {
                            Text(s).font(.system(size: max(8, h * 0.26))).opacity(shifted ? 1 : 0.55)
                            Text(k.label).font(.system(size: max(10, h * 0.32))).opacity(shifted ? 0.55 : 1)
                        }
                    } else {
                        Text(k.label.count == 1 && shifted ? k.label.uppercased() : k.label)
                            .font(.system(size: k.small ? max(8, h * 0.24) : max(12, h * 0.42), weight: k.small ? .regular : .medium))
                    }
                }
                .frame(width: unit * k.width, height: h)
                .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }
}

/// What a key press feels like: a firm tap going down, a softer one coming up, and the iPhone keyboard's own click
/// (it follows the ring/silent switch; Settings › Remote › Key clicks turns it off).
enum KeyFeel {
    private static let downGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let upGen = UIImpactFeedbackGenerator(style: .soft)
    private static let tickGen = UISelectionFeedbackGenerator()
    static var clicks: Bool { UserDefaults.standard.object(forKey: "remote.keyClicks") as? Bool ?? true }

    static func prepare() { downGen.prepare(); upGen.prepare(); tickGen.prepare() }
    static func down(sound: SystemSoundID = 1104) {
        downGen.impactOccurred(intensity: 0.9); downGen.prepare()
        if clicks { AudioServicesPlaySystemSound(sound) }
    }
    static func up() { upGen.impactOccurred(intensity: 0.45); upGen.prepare() }
    static func repeatTick() { tickGen.selectionChanged(); tickGen.prepare() }
    static func modifier() {
        downGen.impactOccurred(intensity: 0.7); downGen.prepare()
        if clicks { AudioServicesPlaySystemSound(1156) }
    }
}

/// Fires on touch-down (feels instant) and repeats while held for delete, arrows and space.
/// Even the quickest tap lights the key and pops it up for a moment, so you always see what you hit.
private struct RepeatKey<Label: View>: View {
    let repeats: Bool
    var sound: SystemSoundID = 1104
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var down = false
    @State private var lit = false
    @State private var timer: Timer?

    var body: some View {
        label
            .foregroundStyle(lit ? Color.black : .white)
            .background(lit ? Color.phosphor : Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(lit ? 0.93 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: lit)
            .overlay(alignment: .top) {
                if lit && !repeats {      // the pop-up like iOS, so you see what you hit
                    label.foregroundStyle(.black).scaleEffect(1.35)
                        .background(Color.phosphor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                        .offset(y: -44).allowsHitTesting(false)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onAppear { KeyFeel.prepare() }
            .onDisappear { stop() }
            // @GestureState resets itself when the touch ends *or* is interrupted (a redraw, a scroll, a system
            // gesture), so a held key can never get stuck repeating.
            .onChange(of: pressing) { _, now in if !now { release() } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        lit = true
                        KeyFeel.down(sound: sound)
                        action()
                        if repeats {
                            let started = Date()
                            timer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { _ in
                                timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { t in
                                    // belt and braces: stop if the finger is gone, or after 8 seconds of holding
                                    guard down, Date().timeIntervalSince(started) < 8 else { t.invalidate(); return }
                                    action(); KeyFeel.repeatTick()
                                }
                            }
                        }
                    }
                    .onEnded { _ in release() }
            )
    }

    @GestureState private var pressing = false

    private func stop() { timer?.invalidate(); timer = nil; down = false; lit = false }

    private func release() {
        guard down else { return }
        down = false; timer?.invalidate(); timer = nil
        KeyFeel.up()
        // keep the light on long enough to be seen, even after a lightning-fast tap
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { if !down { lit = false } }
    }
}

private struct KeyStyle: ButtonStyle {
    var active: Bool
    var locked: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? .black : .white)
            .background(
                active ? Color.phosphor.opacity(locked ? 1 : 0.75) : Color.white.opacity(configuration.isPressed ? 0.3 : 0.11),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}
