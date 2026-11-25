import Foundation
import AppKit
import UniformTypeIdentifiers

final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    static let historyLength = 60

    @Published private(set) var snap = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []
    @Published private(set) var netInHistory: [Double] = []
    @Published private(set) var netOutHistory: [Double] = []
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var heart: HeartReading?
    @Published private(set) var bpm: Double = 60
    @Published private(set) var bpmHistory: [Double] = []
    @Published private(set) var factorHistory: [String: [Double]] = [:]

    private var appHistory: [String: [Double]] = [:]
    private var logTicks = 39
    private let sampler = ProcessSampler()
    private let stats = SystemStats()
    private let queue = DispatchQueue(label: "vitalos.sampler", qos: .utility)
    private var timer: Timer?

    private init() {
        tick()
        schedule(1.5)
    }

    /// 1.5 s while a window or the menu panel is showing, 5 s in the background.
    private var interval: TimeInterval = 0
    private func schedule(_ s: TimeInterval) {
        guard s != interval else { return }
        interval = s
        timer?.invalidate()
        let t = Timer(timeInterval: s, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = s * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var processCount: Int { apps.reduce(0) { $0 + $1.processes.count } }

    var topByCPU: [AppUsage] {
        apps.sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
    }

    private var tickCount2 = 0
    private func tick() {
        tickCount2 &+= 1
        let showing = AppVisibility.anythingShowing
        let d = UserDefaults.standard
        schedule(showing ? (d.object(forKey: "heart.rate") as? Double ?? 1.5) : (d.object(forKey: "heart.bgrate") as? Double ?? 5))
        PerfLog.shared.tick()
        if tickCount2 % 5 == 1, (UserDefaults.standard.string(forKey: "bar.items") ?? "").contains("wifi") { WiFiModel.shared.refresh() }
        if tickCount2 % 12 == 2, let bar = UserDefaults.standard.string(forKey: "bar.items"), bar.contains("headphones") || bar.contains("mouse") { BluetoothModel.shared.refresh() }
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.stats.snapshot()
            let a = self.sampler.sample()
            DispatchQueue.main.async { self.apply(s, a) }
        }
    }

    private func apply(_ s: SystemSnapshot, _ a: [AppUsage]) {
        snap = s
        push(&cpuHistory, s.cpu)
        push(&memHistory, s.memFraction * 100)
        push(&netInHistory, s.netIn)
        push(&netOutHistory, s.netOut)
        var seen = Set<String>()
        var next: [AppUsage] = []
        next.reserveCapacity(a.count)
        for var app in a {
            var h = appHistory[app.id] ?? []
            push(&h, app.cpu)
            appHistory[app.id] = h
            app.history = h
            seen.insert(app.id)
            next.append(app)
        }
        apps = next

        let reading = Cardiologist.read(s, apps: next)
        heart = reading
        bpm = bpmHistory.isEmpty ? reading.bpm : bpm * 0.6 + reading.bpm * 0.4   // ease, don't jump
        push(&bpmHistory, bpm)
        var fh = factorHistory
        for f in reading.factors {
            var h = fh[f.id] ?? []
            push(&h, f.stress)
            fh[f.id] = h
        }
        factorHistory = fh

        logTicks += 1
        if logTicks % 40 == 0 {   // ~ once a minute
            HealthLog.shared.add(HealthSample(t: Date(), bpm: bpm, cpu: s.cpu, mem: s.memFraction * 100,
                                              health: reading.health, top: topByCPU.first?.name))
        }
        appHistory = appHistory.filter { seen.contains($0.key) }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > Self.historyLength { arr.removeFirst(arr.count - Self.historyLength) }
    }

    func quit(_ app: AppUsage) {
        guard !app.isSystem else { return }
        if let path = app.bundlePath,
           let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
            running.terminate()
        } else {
            app.processes.forEach { kill($0.pid, SIGTERM) }
        }
    }
}

enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: AppUsage) -> NSImage {
        let key = app.bundlePath ?? app.id
        if let i = cache[key] { return i }
        let img: NSImage
        if let p = app.bundlePath {
            img = NSWorkspace.shared.icon(forFile: p)
        } else if app.isSystem {
            img = NSImage(named: NSImage.computerName) ?? NSWorkspace.shared.icon(for: .unixExecutable)
        } else {
            img = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        cache[key] = img
        return img
    }
}
