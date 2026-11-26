import SwiftUI
import UIKit

// MARK: - The monitor

/// A bedside-monitor trace: the beat timeline integrates bpm over time (so speeding up never
/// jumps), each beat is a Gaussian PQRST complex with Bazett-scaled QT, and a sweep bar erases
/// ahead of the pen like a real phosphor screen.
final class ECGEngine {
    var phase = 0.0                   // position inside the current beat, 0..1
    var shownBPM = 60.0               // eased toward the Mac's reading
    var samples: [Double]             // one per column, written by the sweep
    var cursor = 0.0                  // sweep position in columns
    var last: Date?
    var haptics = false

    init(columns: Int = 600) { samples = Array(repeating: 0, count: columns) }

    func advance(to now: Date, bpm target: Double, columns: Int, flat: Bool) {
        if samples.count != columns { samples = Array(repeating: 0, count: max(columns, 2)); cursor = 0 }
        let dt = min(max(now.timeIntervalSince(last ?? now), 0), 0.1)
        last = now
        // ~4 s for 60→160 bpm: the heart climbs gradually, the way the brand doc says
        shownBPM += (max(target, 30) - shownBPM) * min(1, dt * 0.9)
        let secondsAcross = 4.0
        let colsPerSec = Double(columns) / secondsAcross
        var steps = dt * colsPerSec
        let perStep = 1 / colsPerSec
        while steps > 0 {
            let s = min(steps, 1)
            let beatLen = 60 / shownBPM
            phase += s * perStep / beatLen
            if phase >= 1 {
                phase -= 1
                // the Mac's pulse in your hand: soft at rest, firmer when it's working hard
                if !flat && haptics { Pulse.beat(bpm: shownBPM) }
            }
            let i = Int(cursor) % columns
            samples[i] = flat ? jitter() : Self.pqrst(phase, bpm: shownBPM) + jitter()
            cursor += s
            if cursor >= Double(columns) { cursor -= Double(columns) }
            steps -= s
        }
    }

    private func jitter() -> Double { Double.random(in: -0.012...0.012) }

    static func g(_ x: Double, _ mu: Double, _ sigma: Double, _ a: Double) -> Double {
        a * exp(-pow(x - mu, 2) / (2 * sigma * sigma))
    }

    /// One heartbeat. Faster hearts shorten the QT interval (Bazett), so T creeps toward QRS.
    static func pqrst(_ p: Double, bpm: Double) -> Double {
        let rr = 60 / bpm
        let qtScale = sqrt(rr)              // QT ∝ √RR
        let tPos = 0.30 + 0.24 * qtScale
        return g(p, 0.14, 0.022, 0.10)
            + g(p, 0.265, 0.007, -0.12)
            + g(p, 0.29, 0.008, 1.0)
            + g(p, 0.315, 0.009, -0.24)
            + g(p, tPos, 0.045 * qtScale, 0.28)
    }
}

struct ECGView: View {
    var bpm: Double
    var color: Color
    var flat = false
    var haptics = false
    @State private var engine = ECGEngine()

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let cols = max(Int(size.width / 2), 60)
                engine.haptics = haptics
                engine.advance(to: ctx.date, bpm: flat ? 60 : bpm, columns: cols, flat: flat)
                let step = size.width / CGFloat(cols - 1)
                let mid = size.height * 0.62
                let amp = size.height * 0.5
                let gap = 10                     // erased columns ahead of the pen
                let cur = Int(engine.cursor)

                // faint grid, like monitor paper
                var grid = Path()
                stride(from: 0, through: size.width, by: 24).forEach { x in grid.move(to: .init(x: x, y: 0)); grid.addLine(to: .init(x: x, y: size.height)) }
                stride(from: 0, through: size.height, by: 24).forEach { y in grid.move(to: .init(x: 0, y: y)); grid.addLine(to: .init(x: size.width, y: y)) }
                g.stroke(grid, with: .color(color.opacity(0.06)), lineWidth: 0.5)

                var path = Path()
                var pen = false
                for i in 0..<cols {
                    let ahead = (i - cur + cols) % cols
                    if ahead > 0 && ahead <= gap { pen = false; continue }
                    let pt = CGPoint(x: CGFloat(i) * step, y: mid - CGFloat(engine.samples[i]) * amp)
                    if pen { path.addLine(to: pt) } else { path.move(to: pt); pen = true }
                }
                // glow, then the bright line
                g.drawLayer { l in
                    l.addFilter(.blur(radius: 6))
                    l.stroke(path, with: .color(color.opacity(0.7)), style: .init(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                g.stroke(path, with: .color(color), style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // the pen head
                let head = CGPoint(x: CGFloat(cur % cols) * step, y: mid - CGFloat(engine.samples[max(cur - 1, 0) % cols]) * amp)
                g.fill(Path(ellipseIn: CGRect(x: head.x - 3, y: head.y - 3, width: 6, height: 6)), with: .color(.white))
            }
        }
        .accessibilityLabel(flat ? "Flat line" : "Heart rate \(Int(bpm)) beats per minute")
    }
}

/// A real heartbeat is two sounds: lub (valves closing, strong) then dub (softer), closer together as it races.
enum Pulse {
    private static let gen = UIImpactFeedbackGenerator(style: .heavy)
    static func beat(bpm: Double) {
        let strength = UserDefaults.standard.object(forKey: "pulse.strength") as? Int ?? 2
        let base = [0.45, 0.7, 1.0][max(0, min(strength, 2))]
        let lub = min(1, base + max(0, bpm - 60) / 400)
        gen.prepare()
        gen.impactOccurred(intensity: lub)
        let gap = 0.3 * sqrt(60 / max(bpm, 40))
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { gen.impactOccurred(intensity: lub * 0.6) }
    }
}

// MARK: - Heart screen

struct HeartScreen: View {
    @EnvironmentObject var link: MacLink
    @AppStorage("heart.haptics") private var haptics = false
    @State private var awakeBusy = false
    @State private var width: CGFloat = 0
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let v = link.vitals {
                // Open iPhone Duo / iPad: monitor and vitals side by side. Closed: stacked.
                Group {
                    if width > 720 {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) { monitor(v); battery(v) }
                            VStack(spacing: 16) { factors(v); topApps(v) }
                        }
                    } else {
                        VStack(spacing: 16) { monitor(v); factors(v); battery(v); topApps(v) }
                    }
                }
                .padding(16)
            } else {
                ProgressView("Listening for a heartbeat…").padding(.top, 80)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.glass900)
        .navigationTitle(link.macName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { haptics.toggle() } label: {
                    Label(haptics ? "Pulse on" : "Feel pulse", systemImage: haptics ? "hand.tap.fill" : "hand.tap")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func monitor(_ v: Vitals) -> some View {
        let c = Color.pulse(v.bpm)
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HR").font(.caption2.weight(.bold).monospaced()).foregroundStyle(c.opacity(0.8))
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(Int(v.bpm.rounded()))")
                                .font(.system(size: 64, weight: .bold, design: .monospaced))
                                .contentTransition(.numericText(value: v.bpm))
                                .foregroundStyle(c)
                                .shadow(color: c.opacity(0.5), radius: 12)
                            Text("bpm").font(.subheadline.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(v.status ?? "").font(.headline).foregroundStyle(c)
                        if let h = v.health { Text("Health \(h)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        if let u = v.uptime { Text("Up \(Fmt.span(u))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
                .padding(16)
                ECGView(bpm: v.bpm, color: c, haptics: haptics)
                    .frame(height: 150)
                    .padding(.bottom, 12)
                Text(diagnosis(v) ?? " ").font(.callout).foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 14)
                Divider().overlay(Color.white.opacity(0.06))
                Toggle(isOn: Binding(get: { v.keepAwake ?? false }, set: { on in
                    awakeBusy = true
                    Task {
                        do { try await link.setKeepAwake(on) } catch { self.error = error.localizedDescription }
                        awakeBusy = false
                    }
                })) {
                    Label("Keep \(link.macName) awake", systemImage: "cup.and.saucer.fill")
                }
                .disabled(awakeBusy)
                .padding(16)
            }
        }
    }

    /// Bedside manner: the reading, the cause in plain words, what to do.
    private func diagnosis(_ v: Vitals) -> String? {
        guard let worst = v.factors?.max(by: { $0.stress < $1.stress }) else { return nil }
        if worst.stress < 0.3 { return "Resting heart rate. Nothing needs you right now." }
        switch worst.id {
        case "cpu": return worst.cause.map { "Pulse is up to \(Int(v.bpm)). \($0) is doing most of the lifting." } ?? "The processor is working hard."
        case "mem": return worst.cause.map { "Memory's tight. \($0) is holding the most." } ?? "Memory's tight."
        case "disk": return "Your disk is \(100 - Int(v.diskFreeFraction * 100))% full. Files can help you find what's hogging it."
        case "thermal": return "Running warm. Give it some air, or close something heavy."
        case "battery": return "Battery's getting low. Time for the charger."
        default: return nil
        }
    }

    private func factors(_ v: Vitals) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("VITALS").font(.caption.weight(.bold)).kerning(1).foregroundStyle(.secondary)
                ForEach(v.factors ?? []) { f in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(f.channel).font(.caption2.weight(.bold).monospaced()).foregroundStyle(Color.vital(f.stress))
                                .frame(width: 42, alignment: .leading)
                            Text(f.label).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(f.reading).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule().fill(Color.vital(f.stress)).frame(width: max(4, geo.size.width * f.stress))
                            }
                        }
                        .frame(height: 5)
                        Text(f.cause.flatMap { $0.isEmpty ? nil : "Mostly \($0)" } ?? " ")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .opacity((f.cause ?? "").isEmpty || f.stress <= 0.3 ? 0 : 1)
                    }
                    .animation(.easeInOut(duration: 0.6), value: f.stress)
                }
            }
        }
    }

    @ViewBuilder private func battery(_ v: Vitals) -> some View {
        if let b = v.battery {
            Card {
                HStack(spacing: 14) {
                    Image(systemName: b.charging ? "battery.100percent.bolt" : b.percent < 20 ? "battery.25percent" : "battery.75percent")
                        .font(.title2).foregroundStyle(b.percent < 20 && !b.onAC ? Color.coral : Color.phosphor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(b.percent))% · \(b.charging ? "Charging" : b.onAC ? "Plugged in" : "On battery")").font(.subheadline.weight(.semibold))
                        Text([b.health.flatMap { $0 > 0 ? "Health \(Int($0))%" : nil },
                              b.cycles.flatMap { $0 > 0 ? "\($0) cycles" : nil },
                              b.minutesLeft.flatMap { $0 > 0 ? "\($0 / 60)h \($0 % 60)m left" : nil }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func topApps(_ v: Vitals) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("WORKING HARDEST").font(.caption.weight(.bold)).kerning(1).foregroundStyle(.secondary)
                ForEach(Array((v.top ?? []).prefix(5))) { a in
                    HStack {
                        Text(a.name).font(.subheadline).lineLimit(1)
                        Spacer()
                        Text(Fmt.pct(a.cpu)).font(.subheadline.monospacedDigit()).foregroundStyle(Color.vital(min(a.cpu / 100, 1)))
                        Text(Fmt.bytes(a.memory)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                    }
                }
            }
        }
    }
}
