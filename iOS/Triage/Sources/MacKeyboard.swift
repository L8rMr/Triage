import SwiftUI
import UIKit

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

    var body: some View {
        GeometryReader { g in
            let unit = g.size.width / 15.2
            let rowsCount = CGFloat(rows.count + 1)
            let h = min((g.size.height - 4 * rowsCount) / rowsCount, unit * 1.05)
            VStack(spacing: 4) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        ForEach(rows[i]) { k in keyView(k, unit: unit, h: i == 0 && showFRow ? h * 0.72 : h) }
                    }
                }
                bottomRow(unit: unit, h: h)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
    }

    private func bottomRow(unit: CGFloat, h: CGFloat) -> some View {
        HStack(spacing: 4) {
            modKey("fn", "fn", "globe", unit: unit, h: h)
            modKey("ctrl", "control", "control", unit: unit, h: h)
            modKey("opt", "option", "option", unit: unit, h: h)
            modKey("cmd", "command", "command", unit: unit * 1.3, h: h)
            keyView(K(label: "", key: "space", width: 5.2), unit: unit, h: h)
            modKey("cmd", "command", "command", unit: unit * 1.3, h: h)
            modKey("opt", "option", "option", unit: unit, h: h)
            // inverted T
            VStack(spacing: 2) {
                keyView(K(label: "▲", key: "up", small: true), unit: unit, h: h / 2 - 1)
                HStack(spacing: 2) {
                    keyView(K(label: "◀", key: "left", small: true), unit: unit, h: h / 2 - 1)
                    keyView(K(label: "▼", key: "down", small: true), unit: unit, h: h / 2 - 1)
                    keyView(K(label: "▶", key: "right", small: true), unit: unit, h: h / 2 - 1)
                }
            }
        }
    }

    private func modKey(_ mod: String, _ label: String, _ symbol: String, unit: CGFloat, h: CGFloat) -> some View {
        let on = mods.contains(mod), lock = locked.contains(mod)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if lock { locked.remove(mod); mods.remove(mod) }
            else if on { mods.remove(mod); locked.insert(mod) }       // second tap locks it
            else { mods.insert(mod) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Image(systemName: symbol).font(.system(size: max(9, h * 0.28)))
                Text(label).font(.system(size: max(7, h * 0.2)))
            }
            .frame(width: unit * 1.15, height: h, alignment: .bottomLeading)
            .padding(.leading, 4)
        }
        .buttonStyle(KeyStyle(active: on || lock, locked: lock))
    }

    @ViewBuilder private func keyView(_ k: K, unit: CGFloat, h: CGFloat) -> some View {
        if let mod = k.mod {
            let on = mods.contains(mod), lock = locked.contains(mod)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if lock { locked.remove(mod); mods.remove(mod) } else if on { mods.remove(mod); locked.insert(mod) } else { mods.insert(mod) }
            } label: {
                Text("⇧ " + k.label).font(.system(size: max(8, h * 0.24))).frame(width: unit * k.width + 4 * (k.width - 1), height: h)
            }
            .buttonStyle(KeyStyle(active: on || lock, locked: lock))
        } else if k.key == "caps" {
            let lock = locked.contains("shift")
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if lock { locked.remove("shift") } else { locked.insert("shift") }
            } label: {
                HStack {
                    Circle().fill(lock ? Color.phosphor : Color.white.opacity(0.25)).frame(width: 5, height: 5)
                    Text(k.label).font(.system(size: max(8, h * 0.22)))
                }
                .frame(width: unit * k.width + 4 * (k.width - 1), height: h)
            }
            .buttonStyle(KeyStyle(active: false, locked: false))
        } else {
            RepeatKey(repeats: ["delete", "left", "right", "up", "down", "space"].contains(k.key)) {
                let m = Array(mods.union(locked))
                press(k.key, m)
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
                .frame(width: unit * k.width + 4 * (k.width - 1), height: h)
            }
        }
    }
}

/// Fires on touch-down (feels instant) and repeats while held for delete, arrows and space.
private struct RepeatKey<Label: View>: View {
    let repeats: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var down = false
    @State private var timer: Timer?

    var body: some View {
        label
            .foregroundStyle(.white)
            .background(down ? Color.white.opacity(0.32) : Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .top) {
                if down && !repeats {      // the little pop-up like iOS, so you see what you hit
                    label.foregroundStyle(.white).scaleEffect(1.25)
                        .background(Color(white: 0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .offset(y: -40).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
                        action()
                        if repeats {
                            timer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { _ in
                                timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in action() }
                            }
                        }
                    }
                    .onEnded { _ in down = false; timer?.invalidate(); timer = nil }
            )
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
