import Foundation
import Combine
import WidgetKit
import BackgroundTasks

/// Keeps the Home Screen widgets fed.
/// • While Triage is open: every vitals update is saved and the widgets redraw every few seconds (iOS doesn't count
///   these against the widget budget while the app is in front).
/// • While it's closed: a background refresh wakes the app on the schedule the widgets asked for, reconnects,
///   takes one fresh reading and redraws them.
final class WidgetFeed {
    static let shared = WidgetFeed()
    static let taskID = "com.alenlvovich.triage.ios.refresh"

    private var bag: AnyCancellable?
    private var lastReload = Date.distantPast
    private var pending: DispatchWorkItem?

    func start() {
        let link = MacLink.shared
        bag = link.$vitals
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.store(v, mac: link.macName) }
    }

    private func store(_ v: Vitals, mac: String) {
        let snap = WidgetSnap(
            t: Date(), mac: mac, connected: true, bpm: v.bpm, bpmHistory: Array((v.bpmHistory ?? []).suffix(60)),
            cpu: v.cpu, cpuHistory: Array((v.cpuHistory ?? []).suffix(60)), memUsed: v.memUsed, memTotal: v.memTotal,
            pressure: v.pressure, diskFree: v.diskFree, diskTotal: v.diskTotal, netIn: v.netIn ?? 0, netOut: v.netOut ?? 0,
            battery: v.battery?.percent, charging: v.battery?.charging, health: v.health, status: v.status,
            uptime: v.uptime, thermal: v.thermal,
            top: (v.top ?? []).filter { $0.system != true }.prefix(5).map { .init(name: $0.name, cpu: $0.cpu, memory: $0.memory) },
            themeID: ThemeModel.shared.activeID)
        SnapStore.save(snap)
        reloadSoon()
    }

    /// At most one redraw every 3 seconds: smooth enough to feel live, light enough to be free.
    private func reloadSoon() {
        guard pending == nil else { return }
        let wait = max(0, 3 - Date().timeIntervalSince(lastReload))
        let w = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.lastReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: SnapStore.kind)
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }

    /// The theme changed: widgets follow right away.
    func themeChanged() {
        guard var s = SnapStore.load() else { return }
        s.themeID = ThemeModel.shared.activeID
        SnapStore.save(s)
        WidgetCenter.shared.reloadTimelines(ofKind: SnapStore.kind)
    }

    // MARK: Background refresh

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            self.schedule()
            let work = Task { @MainActor in
                let ok = await self.freshReading()
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: Self.taskID)
        r.earliestBeginDate = Date().addingTimeInterval(Double(SnapStore.refreshMinutes) * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Reconnect, wait for one vitals reading (up to 20 s), save it, done.
    @MainActor private func freshReading() async -> Bool {
        let link = MacLink.shared
        let before = link.vitals?.t ?? 0
        if link.phase == .ready { link.resume() }
        else {
            // launched in the background: find the Mac through iCloud and connect the best way available
            await CloudDirectory.shared.refresh()
            let want = link.rememberedMac
            if let m = CloudDirectory.shared.macs.first(where: { $0.name == want }) ?? CloudDirectory.shared.macs.first {
                link.connect(anywhere: m, lan: [])
            } else { link.resume() }
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if let t = link.vitals?.t, t > before { break }
        }
        let got = (link.vitals?.t ?? 0) > before
        if !got, var s = SnapStore.load() { s.connected = false; SnapStore.save(s) }
        WidgetCenter.shared.reloadTimelines(ofKind: SnapStore.kind)
        link.suspend()
        return got
    }
}
