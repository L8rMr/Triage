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

/// The sweeping heart trace. Each 3-second pass is drawn once; Core Animation moves the write head
/// on the graphics chip, so the CPU does almost nothing between passes.
struct PulseLine: View {
    var bpm: Double
    var color: Color
    var window: Double = 3.0          // seconds of trace shown across the width

    var body: some View {
        PulseLayerView(bpm: bpm, color: NSColor(color), window: window, still: ThemeStore.shared.reduceMotion)
    }
}

private struct PulseLayerView: NSViewRepresentable {
    let bpm: Double, color: NSColor, window: Double, still: Bool
    func makeNSView(context: Context) -> PulseNSView { PulseNSView() }
    func updateNSView(_ v: PulseNSView, context: Context) { v.update(bpm: bpm, color: color, window: window, still: still) }
}

final class PulseNSView: NSView {
    // decoration only: let clicks fall through to the button or card it sits in (the header pill ignored clicks)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var bpm = 60.0, span = 3.0, still = false
    private var color: NSColor = .systemGreen
    private let fresh = CAShapeLayer(), old = CAShapeLayer(), dot = CAShapeLayer(), halo = CAShapeLayer()
    private let freshMask = CALayer(), oldMask = CALayer()
    private var timer: Timer?
    private var beatCarry: Double = 0.2        // seconds into the next pass when the next beat lands
    private var lastBeatOffset: Double = -10   // last beat of the previous pass, in this pass's time
    private var lastFresh: CGPath?
    private var visible = true
    private var token: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        for l in [old, fresh] {
            l.fillColor = nil; l.lineWidth = 1.6; l.lineCap = .round; l.lineJoin = .round
            layer?.addSublayer(l)
        }
        fresh.mask = freshMask; old.mask = oldMask
        freshMask.backgroundColor = NSColor.black.cgColor; oldMask.backgroundColor = NSColor.black.cgColor
        freshMask.anchorPoint = CGPoint(x: 0, y: 0); oldMask.anchorPoint = CGPoint(x: 1, y: 0)
        halo.path = CGPath(ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8), transform: nil)
        dot.path = CGPath(ellipseIn: CGRect(x: -2, y: -2, width: 4, height: 4), transform: nil)
        layer?.addSublayer(halo); layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func update(bpm: Double, color: NSColor, window: Double, still: Bool) {
        let restartNeeded = still != self.still || window != self.span
        self.bpm = bpm; self.span = window; self.still = still
        if color != self.color { self.color = color; applyColor() }
        if restartNeeded { restart() }
    }

    private func applyColor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fresh.strokeColor = color.cgColor
        old.strokeColor = color.withAlphaComponent(0.35).cgColor
        dot.fillColor = color.cgColor
        halo.fillColor = color.withAlphaComponent(0.25).cgColor
        CATransaction.commit()
    }

    override func layout() { super.layout(); restart() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        guard let w = window else { stop(); return }
        token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
            guard let self else { return }
            let v = w.isVisible && w.occlusionState.contains(.visible)
            if v != self.visible { self.visible = v; self.restart() }
        }
        visible = w.isVisible && w.occlusionState.contains(.visible)
        applyColor()
        restart()
    }

    deinit { timer?.invalidate(); if let token { NotificationCenter.default.removeObserver(token) } }

    private func stop() {
        timer?.invalidate(); timer = nil
        [freshMask, oldMask, dot, halo].forEach { $0.removeAllAnimations() }
    }

    private func restart() {
        stop()
        guard bounds.width > 4, bounds.height > 4, window != nil else { return }
        applyColor()
        pass()
        guard visible, !still else { return }
        let t = Timer(timeInterval: span, repeats: true) { [weak self] _ in self?.pass() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Lays down one pass of the trace and starts the sweep across it.
    private func pass() {
        let w = bounds.width, h = bounds.height
        let rate = min(max(bpm, 35), 200)
        let interval = 60 / rate
        let amp = min(1.0, max(0.5, 0.55 + (rate - 70) / 130))   // taller spikes when strained
        var beats: [Double] = [lastBeatOffset]
        var t = beatCarry
        while t < span { beats.append(t); t += interval }
        beatCarry = t - span
        lastBeatOffset = (beats.last ?? 0) - span

        let mid = h * 0.62, scale = h * 0.58
        func signal(_ time: Double) -> Double {
            guard let b = beats.last(where: { $0 <= time }) else { return 0 }
            let p = (time - b) / 0.6
            guard p >= 0, p < 1 else { return 0 }
            let keys: [(Double, Double)] = [(0, 0), (0.12, 0.10), (0.2, 0), (0.30, 0), (0.34, -0.12), (0.40, 1),
                                            (0.46, -0.30), (0.52, 0), (0.70, 0.20), (0.85, 0), (1, 0)]
            for i in 1..<keys.count where p <= keys[i].0 {
                let a = keys[i - 1], c = keys[i]
                return (a.1 + (c.1 - a.1) * (p - a.0) / (c.0 - a.0)) * amp
            }
            return 0
        }
        let path = CGMutablePath()
        var points: [CGPoint] = []
        var x: CGFloat = 0
        while x <= w {
            let y = mid - CGFloat(signal(Double(x / w) * span)) * scale
            let pt = CGPoint(x: x, y: y)
            if x == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            points.append(pt)
            x += 1.5
        }

        CATransaction.begin(); CATransaction.setDisableActions(true)
        old.path = lastFresh ?? path
        fresh.path = path
        lastFresh = path
        let gap = w * 0.06
        freshMask.bounds = CGRect(x: 0, y: 0, width: still ? w : 0, height: h); freshMask.position = .zero
        oldMask.bounds = CGRect(x: 0, y: 0, width: still ? 0 : max(w - gap, 0), height: h); oldMask.position = CGPoint(x: w, y: 0)
        dot.isHidden = still; halo.isHidden = still
        CATransaction.commit()
        guard !still, visible else { return }

        let reveal = CABasicAnimation(keyPath: "bounds.size.width")
        reveal.fromValue = 0; reveal.toValue = w; reveal.duration = span
        reveal.fillMode = .forwards; reveal.isRemovedOnCompletion = false
        freshMask.add(reveal, forKey: "sweep")

        let erase = CABasicAnimation(keyPath: "bounds.size.width")
        erase.fromValue = max(w - gap, 0); erase.toValue = 0; erase.duration = span * Double(max(w - gap, 0) / w)
        erase.fillMode = .forwards; erase.isRemovedOnCompletion = false
        oldMask.add(erase, forKey: "sweep")

        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = points.map { NSValue(point: $0) }
        move.duration = span
        move.calculationMode = .linear
        move.fillMode = .forwards; move.isRemovedOnCompletion = false
        dot.add(move, forKey: "sweep"); halo.add(move, forKey: "sweep")
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
