import SwiftUI
import AppKit

/// Beat times laid down as they happen. Faster heart: beats arrive closer together and spike taller.
/// The trace itself always sweeps at the same speed, like a bedside monitor.
final class BeatClock {
    private(set) var beats: [(t: Double, amp: Double)] = []
    private var next: Double?

    func update(_ now: Double, bpm: Double) {
        let rate = min(max(bpm, 35), 200)
        if next == nil { next = now - 0.2 }
        while let n = next, n <= now {
            // spike height grows with strain: calm ~0.55, racing ~1.0
            let amp = min(1.0, max(0.5, 0.55 + (rate - 70) / 130))
            beats.append((n, amp))
            next = n + 60 / rate
        }
        beats.removeAll { $0.t < now - 12 }
    }

    /// Heart signal at time t (PQRST shape, about 0.6 s long, fixed width at any rate).
    func signal(at t: Double) -> Double {
        guard let b = beats.last(where: { $0.t <= t }) else { return 0 }
        let p = (t - b.t) / 0.6
        guard p >= 0, p < 1 else { return 0 }
        let keys: [(Double, Double)] = [
            (0, 0), (0.12, 0.10), (0.2, 0), (0.30, 0), (0.34, -0.12), (0.40, 1),
            (0.46, -0.30), (0.52, 0), (0.70, 0.20), (0.85, 0), (1, 0),
        ]
        for i in 1..<keys.count where p <= keys[i].0 {
            let a = keys[i - 1], c = keys[i]
            let v = a.1 + (c.1 - a.1) * (p - a.0) / (c.0 - a.0)
            return v * b.amp
        }
        return 0
    }
}

struct PulseLine: View {
    var bpm: Double
    var color: Color
    var window: Double = 3.0          // seconds of trace shown across the width
    @State private var clock = BeatClock()
    @State private var onScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !onScreen || ThemeStore.shared.reduceMotion)) { tl in
            Canvas { ctx, size in
                let now = tl.date.timeIntervalSinceReferenceDate
                clock.update(now, bpm: bpm)
                let w = max(size.width, 1)
                let mid = size.height * 0.62
                let amp = size.height * 0.58
                // sweeping write head: left of it is this pass, right of it is the previous pass
                let sweepStart = floor(now / window) * window
                let head = (now - sweepStart) / window
                let gap = 0.06
                var fresh = Path(), old = Path()
                var x: CGFloat = 0
                var startedFresh = false, startedOld = false
                while x <= w {
                    let f = Double(x / w)
                    if f <= head {
                        let y = mid - CGFloat(clock.signal(at: sweepStart + f * window)) * amp
                        if startedFresh { fresh.addLine(to: CGPoint(x: x, y: y)) } else { fresh.move(to: CGPoint(x: x, y: y)); startedFresh = true }
                    } else if f > head + gap {
                        let y = mid - CGFloat(clock.signal(at: sweepStart - window + f * window)) * amp
                        if startedOld { old.addLine(to: CGPoint(x: x, y: y)) } else { old.move(to: CGPoint(x: x, y: y)); startedOld = true }
                    }
                    x += 1
                }
                let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                ctx.stroke(old, with: .color(color.opacity(0.35)), style: style)
                ctx.stroke(fresh, with: .color(color), style: style)
                // glowing dot at the write head
                let hx = CGFloat(head) * w
                let hy = mid - CGFloat(clock.signal(at: now)) * amp
                ctx.fill(Path(ellipseIn: CGRect(x: hx - 4, y: hy - 4, width: 8, height: 8)), with: .color(color.opacity(0.25)))
                ctx.fill(Path(ellipseIn: CGRect(x: hx - 2, y: hy - 2, width: 4, height: 4)), with: .color(color))
            }
        }
        .background(OnScreenReader(visible: $onScreen))
    }
}


/// Reports whether the hosting window is actually visible (not closed, minimized, hidden or fully covered).
struct OnScreenReader: NSViewRepresentable {
    @Binding var visible: Bool
    func makeNSView(context: Context) -> ReaderView { let v = ReaderView(); v.onChange = { visible = $0 }; return v }
    func updateNSView(_ v: ReaderView, context: Context) { v.onChange = { new in if visible != new { visible = new } } }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let w = window else { report(false); return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in self?.check() }
            check()
        }
        private func check() { report(window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false) }
        private func report(_ v: Bool) { DispatchQueue.main.async { self.onChange?(v) } }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

enum AppVisibility {
    /// True when any VitalOS window or the menu bar panel is showing.
    static var anythingShowing: Bool {
        guard let app = NSApp as NSApplication? else { return true }
        return app.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.height > 60 }
    }
}
