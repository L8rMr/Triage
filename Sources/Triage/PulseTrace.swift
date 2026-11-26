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
        else if abs(bpm - drawnBPM) >= 2 { replan() }   // the next beat follows the new rate, not the next sweep
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

    // MARK: the heart itself
    // Beats live on one continuous timeline (seconds since the view started), each with the R-R interval
    // that led into it. Every pass draws [passStart, passStart + span]; a rate change rewrites only beats
    // that haven't started yet, so the part already on screen never jumps.
    private var t0: CFTimeInterval = CACurrentMediaTime()
    private var passStart: Double = 0
    private var beats: [(t: Double, rr: Double)] = []
    private var breath: Double = 0
    private var drawnBPM: Double = 0
    private func now() -> Double { CACurrentMediaTime() - t0 }

    /// Next R-R interval: the set rate, swaying with breathing (sinus arrhythmia) plus a little natural jitter.
    private func nextRR() -> Double {
        let rr = 60 / min(max(bpm, 35), 200)
        breath += rr
        let sway = sin(breath * 2 * .pi / 4.5) * 0.035
        return rr * (1 + sway + Double.random(in: -0.015...0.015))
    }

    private func fill(until end: Double) {
        if let last = beats.last, last.t < passStart - 2 { beats = [] }   // coming back after being hidden: start fresh
        if beats.isEmpty { beats.append((passStart + 0.3, 60 / min(max(bpm, 35), 200))) }
        while let last = beats.last, last.t < end { let rr = nextRR(); beats.append((last.t + rr, rr)) }
        beats.removeAll { $0.t < passStart - span - 1 }
    }

    /// Lead II, built from smooth bumps around each R peak. The QT interval follows Bazett (QT ≈ 0.40·√RR),
    /// so at a fast rate the T wave tucks in close instead of being cut off by the next beat.
    private func signal(_ t: Double) -> Double {
        func g(_ x: Double, _ mu: Double, _ s: Double, _ a: Double) -> Double { let z = (x - mu) / s; return a * exp(-0.5 * z * z) }
        var v = 0.015 * sin(t * 2 * .pi / 6.5)                       // slow baseline wander
        for b in beats where b.t > t - 0.75 && b.t < t + 0.3 {
            let d = t - b.t
            let qt = 0.40 * sqrt(b.rr)
            let pr = 0.12 + 0.05 * min(b.rr, 1.2) / 1.2                // PR shortens a little when fast
            v += g(d, -pr, 0.024, 0.12)                                  // P
            v += g(d, -0.030, 0.008, -0.12)                              // Q
            v += g(d, 0, 0.010, 1.0)                                     // R
            v += g(d, 0.030, 0.010, -0.26)                               // S
            v += g(d, qt * 0.66, qt * 0.12, 0.30)                        // T
        }
        return v
    }

    /// Builds the trace for the current pass, sampled every 4 ms so the narrow QRS is never skipped.
    private func tracePath() -> (CGPath, [CGPoint]) {
        let w = bounds.width, h = bounds.height
        let mid = h * 0.62, scale = h * 0.55
        let path = CGMutablePath()
        var points: [CGPoint] = []
        var lastX: CGFloat = -10
        var t = 0.0
        while t <= span {
            let x = CGFloat(t / span) * w
            let pt = CGPoint(x: x, y: mid - CGFloat(signal(passStart + t)) * scale)
            if t == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            if x - lastX >= 1.5 { points.append(pt); lastX = x }      // the write head only needs a point per 1.5 px
            t += 0.004
        }
        return (path, points)
    }

    /// The rate changed: re-plan beats that haven't begun, and swap in the new trace without restarting the sweep.
    private func replan() {
        guard timer != nil, !beats.isEmpty else { return }
        let n = now()
        beats.removeAll { $0.t > n + 0.3 }          // keep anything whose P wave may already be on screen
        fill(until: passStart + span + 0.5)
        let (path, _) = tracePath()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fresh.path = path; lastFresh = path
        CATransaction.commit()
        drawnBPM = bpm
    }

    /// Lays down one pass of the trace and starts the sweep across it.
    private func pass() {
        let w = bounds.width, h = bounds.height
        passStart = now()
        fill(until: passStart + span + 0.5)
        drawnBPM = bpm
        let (path, points) = tracePath()

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
    /// True when any Triage window or the menu bar panel is showing.
    static var anythingShowing: Bool {
        guard let app = NSApp as NSApplication? else { return true }
        return app.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.height > 60 }
    }
}
