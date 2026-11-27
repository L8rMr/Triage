import Foundation
import AppKit
import Network
import CoreAudio

// MARK: - Every Mac tool, reachable from the phone
//
// Each tool keeps one model alive here (on the main thread, like the Mac's own views), so the phone sees the same
// scans and results the Mac would. Long jobs (duplicate scans, conversions) start and then get polled.

extension RemoteAPI {
    static let toolReadOps = ["toolDiskMap", "toolScan", "toolApps", "toolStartup", "toolNetwork", "toolPorts", "toolHistory",
                              "toolDrives", "toolWifi", "toolSound", "toolTidy", "toolRules", "convertTargets", "renamePreview", "jobState"]
    static let toolWriteOps: Set<String> = ["uninstallApp", "startupSet", "loginItemRemove", "portKill", "docker", "wifiPower",
                                            "wifiJoin", "soundSet", "tidyApply", "ruleSet", "ruleRun", "convert", "batchRename"]

    /// Handled here: returns false when the op isn't a tool op.
    static func tools(_ op: String, _ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) -> Bool {
        let hub = ToolHub.shared
        switch op {
        case "toolDiskMap": hub.diskMap(a, done)
        case "toolScan": hub.scan(a, done)
        case "toolApps": hub.apps(a, done)
        case "uninstallApp": hub.uninstall(a, s, done)
        case "toolStartup": hub.startup(done)
        case "startupSet": hub.startupSet(a, s, done)
        case "loginItemRemove": hub.loginItemRemove(a, s, done)
        case "toolNetwork": hub.network(done)
        case "toolPorts": hub.ports(done)
        case "portKill": hub.portKill(a, s, done)
        case "docker": hub.docker(a, s, done)
        case "toolHistory": hub.history(a, done)
        case "toolDrives": hub.drives(a, done)
        case "toolWifi": hub.wifi(a, done)
        case "wifiPower": hub.wifiPower(a, s, done)
        case "wifiJoin": hub.wifiJoin(a, s, done)
        case "toolSound": hub.sound(done)
        case "soundSet": hub.soundSet(a, done)
        case "toolTidy": hub.tidy(done)
        case "tidyApply": hub.tidyApply(a, s, done)
        case "toolRules": hub.rules(done)
        case "ruleSet": hub.ruleSet(a, done)
        case "ruleRun": hub.ruleRun(a, s, done)
        case "convertTargets": hub.convertTargets(a, done)
        case "convert": hub.convert(a, s, done)
        case "renamePreview": hub.rename(a, s, apply: false, done)
        case "batchRename": hub.rename(a, s, apply: true, done)
        case "jobState": hub.jobState(a, done)
        default: return false
        }
        return true
    }
}

final class ToolHub {
    static let shared = ToolHub()
    typealias Done = RemoteAPI.Done

    private lazy var dup = DupModel()
    private lazy var forgotten = ForgottenModel()
    private lazy var uninstaller = UninstallModel()
    private lazy var startupM = StartupModel()
    private lazy var net = NetworkModel()
    private lazy var portsM = PortsModel()
    private lazy var diskHealth = DiskHealthModel()
    private lazy var disk = DiskMapModel()
    private var liveUntil: [String: Date] = [:]      // network and ports sample only while a phone is looking
    private var idleTimer: Timer?

    private static func t(_ d: Date?) -> Double? { d.map { $0.timeIntervalSince1970 } }
    private static func fail(_ done: Done, _ m: String) { done(.failure(RemoteError(message: m))) }
    private static func home(_ p: String?) -> URL {
        guard let p, !p.isEmpty else { return Places.home }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    /// Network/ports models run a timer; stop them once no phone has asked for a while.
    private func keepLive(_ key: String) {
        liveUntil[key] = Date().addingTimeInterval(20)
        if idleTimer == nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reap() }
        }
    }
    private func reap() {
        let now = Date()
        for (k, until) in liveUntil where until < now {
            if k == "net" { net.stop() }
            if k == "ports" { portsM.stop() }
            if k == "sound" { MixerModel.shared.stop() }
            liveUntil[k] = nil
        }
        if liveUntil.isEmpty { idleTimer?.invalidate(); idleTimer = nil }
    }

    // MARK: Disk Map

    func diskMap(_ a: [String: Any], _ done: Done) {
        let u = Self.home(a["path"] as? String)
        if (a["refresh"] as? Bool) == true { disk.load(u, force: true) }
        else if disk.root.standardizedFileURL.path != u.standardizedFileURL.path || (!disk.loading && disk.nodes.isEmpty) { disk.load(u) }
        let nodes = disk.nodes.prefix(250).map { ["path": $0.url.path, "name": $0.name, "size": Double($0.size), "dir": $0.isDir] as [String: Any] }
        done(.success(["path": disk.root.path, "loading": disk.loading, "scanned": disk.scanned, "nodes": Array(nodes)]))
    }

    // MARK: Duplicates and Forgotten Files (long scans: start, then poll)

    func scan(_ a: [String: Any], _ done: Done) {
        let kind = a["kind"] as? String ?? "dupes"
        let action = a["action"] as? String ?? "state"
        if kind == "dupes" {
            if action == "start" {
                dup.root = Self.home(a["root"] as? String)
                dup.minSizeMB = a["minMB"] as? Double ?? 1
                dup.scan()
            } else if action == "stop" { dup.stop() }
            let groups = dup.groups.prefix(300).map { g in
                g.map { ["path": $0.url.path, "size": Double($0.size), "modified": $0.modified.timeIntervalSince1970] as [String: Any] }
            }
            done(.success(["running": dup.scanning, "status": dup.status, "root": dup.root.path,
                           "wasted": Double(dup.wasted), "groups": Array(groups)]))
        } else {
            if action == "start" {
                forgotten.months = a["months"] as? Int ?? 12
                forgotten.minMB = a["minMB"] as? Int ?? 50
                forgotten.run()
            }
            let items = forgotten.items.sorted { $0.size > $1.size }.prefix(500).map {
                ["path": $0.url.path, "size": Double($0.size), "used": Self.t($0.touched) ?? 0] as [String: Any]
            }
            done(.success(["running": forgotten.searching, "items": Array(items)]))
        }
    }

    // MARK: App Uninstaller

    func apps(_ a: [String: Any], _ done: Done) {
        if (a["refresh"] as? Bool) == true || (uninstaller.apps.isEmpty && !uninstaller.loading) { uninstaller.load() }
        let list = uninstaller.apps.map { x -> [String: Any] in
            var d: [String: Any] = ["path": x.url.path, "name": x.name, "size": Double(x.size),
                                    "leftovers": x.leftovers.count, "leftoverBytes": Double(x.leftoverBytes)]
            if let v = x.version { d["version"] = v }
            if let id = x.bundleID { d["bundleID"] = id }
            if let u = Self.t(x.lastUsed) { d["used"] = u }
            return d
        }
        done(.success(["loading": uninstaller.loading, "apps": list]))
    }

    func uninstall(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        guard (a["confirm"] as? String) == "REMOVE" else { Self.fail(done, "Confirm on the phone first"); return }
        guard let p = a["path"] as? String, let app = uninstaller.apps.first(where: { $0.url.path == p }) else {
            Self.fail(done, "That app isn't in the list any more"); return
        }
        guard !p.hasPrefix("/System/"), app.bundleID != Bundle.main.bundleIdentifier else { Self.fail(done, "That one stays"); return }
        uninstaller.uninstall(app) {
            RemoteServer.shared.record(s.deviceName, "Uninstalled \(app.name) (to the Trash)")
            done(.success(["removed": app.name]))
        }
    }

    // MARK: Startup Items

    func startup(_ done: @escaping Done) {
        startupM.load()
        startupM.loadLoginItems()
        // both loads are quick; give them a moment, then answer with what's there
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            let items = startupM.items.map { i -> [String: Any] in
                ["id": i.plist.path, "label": i.label, "program": i.program, "scope": i.scope, "kind": i.kind,
                 "enabled": i.enabled, "running": i.running, "canToggle": i.canToggle, "vendor": i.vendor]
            }
            done(.success(["items": items, "login": startupM.loginItems]))
        }
    }

    func startupSet(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        guard let id = a["id"] as? String, let item = startupM.items.first(where: { $0.plist.path == id }), item.canToggle else {
            Self.fail(done, "Only your own background items can be switched"); return
        }
        let on = (a["on"] as? Bool) ?? true
        startupM.setEnabled(item, on)
        RemoteServer.shared.record(s.deviceName, "\(on ? "Turned on" : "Turned off") startup item \(item.label)")
        done(.success([:]))
    }

    func loginItemRemove(_ a: [String: Any], _ s: RemoteSession, _ done: Done) {
        guard let name = a["name"] as? String, startupM.loginItems.contains(name) else { Self.fail(done, "That login item is gone"); return }
        startupM.removeLoginItem(name)
        RemoteServer.shared.record(s.deviceName, "Removed login item \(name)")
        done(.success([:]))
    }

    // MARK: Network by App and Dev Servers & Ports

    func network(_ done: Done) {
        if liveUntil["net"] == nil { net.start() }
        keepLive("net")
        let apps = net.apps.prefix(60).map { ["name": $0.name, "down": $0.down, "up": $0.up,
                                              "received": Double($0.received), "sent": Double($0.sent)] as [String: Any] }
        done(.success(["available": net.available, "apps": Array(apps)]))
    }

    func ports(_ done: Done) {
        if liveUntil["ports"] == nil { portsM.start() }
        keepLive("ports")
        let l = portsM.listeners.map { ["pid": Int($0.pid), "command": $0.command, "app": $0.app, "host": $0.host,
                                        "port": $0.port, "local": $0.isLocalOnly] as [String: Any] }
        let c = portsM.containers.map { ["id": $0.id, "name": $0.name, "image": $0.image, "status": $0.status,
                                         "ports": $0.ports, "running": $0.running] as [String: Any] }
        done(.success(["listeners": l, "containers": c, "docker": portsM.docker != nil]))
    }

    func portKill(_ a: [String: Any], _ s: RemoteSession, _ done: Done) {
        guard let pid = a["pid"] as? Int, let l = portsM.listeners.first(where: { Int($0.pid) == pid }) else {
            Self.fail(done, "That server already stopped"); return
        }
        guard l.pid > 1, l.pid != getpid() else { Self.fail(done, "That one stays"); return }
        portsM.kill(l)
        RemoteServer.shared.record(s.deviceName, "Stopped \(l.app) on port \(l.port)")
        done(.success([:]))
    }

    func docker(_ a: [String: Any], _ s: RemoteSession, _ done: Done) {
        guard let id = a["id"] as? String, let c = portsM.containers.first(where: { $0.id == id }),
              let verb = a["verb"] as? String, ["start", "stop", "restart"].contains(verb) else {
            Self.fail(done, "That container is gone"); return
        }
        portsM.dockerRun(verb, c)
        RemoteServer.shared.record(s.deviceName, "Docker \(verb): \(c.name)")
        done(.success([:]))
    }

    // MARK: Health History and Drive Health

    func history(_ a: [String: Any], _ done: Done) {
        let hours = min(max(a["hours"] as? Double ?? 24, 1), 24 * 14)
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        let all = HealthLog.shared.samples.filter { $0.t >= cutoff }
        let step = max(1, all.count / 300)
        let pts = stride(from: 0, to: all.count, by: step).map { i -> [String: Any] in
            let x = all[i]
            var d: [String: Any] = ["t": x.t.timeIntervalSince1970, "bpm": x.bpm, "cpu": x.cpu, "mem": x.mem, "health": x.health]
            if let top = x.top { d["top"] = top }
            return d
        }
        done(.success(["samples": pts, "hours": hours]))
    }

    func drives(_ a: [String: Any], _ done: @escaping Done) {
        if (a["refresh"] as? Bool) == true || (diskHealth.drives.isEmpty && !diskHealth.loading) { diskHealth.load() }
        // smartctl and diskutil take a few seconds: wait for them (the phone's request allows 25)
        waitUntil(timeout: 15, { [self] in !diskHealth.loading }) { [self] in
            let drives = diskHealth.drives.map { d -> [String: Any] in
                let h = d.health
                var o: [String: Any] = ["id": d.id, "name": d.name, "bus": d.bus, "internal": d.isInternal, "ssd": d.isSSD,
                                        "size": Double(d.size), "smart": d.smart, "level": "\(h.0)", "summary": h.1, "notes": h.2]
                if let t = d.trim { o["trim"] = t }
                if let x = d.detail {
                    if let v = x.percentUsed { o["percentUsed"] = v }
                    if let v = x.powerOnHours { o["hours"] = v }
                    if let v = x.bytesWritten { o["written"] = Double(v) }
                    if let v = x.temperature { o["temp"] = v }
                    if let v = x.spare { o["spare"] = v }
                    if let v = x.mediaErrors { o["mediaErrors"] = v }
                    if let v = x.unsafeShutdowns { o["unsafeShutdowns"] = v }
                }
                return o
            }
            let vols = diskHealth.volumes.map { ["name": $0.name, "path": $0.url.path, "format": $0.format, "total": Double($0.total),
                                                 "free": Double($0.free), "importantFree": Double($0.importantFree)] as [String: Any] }
            done(.success(["drives": drives, "volumes": vols, "snapshots": diskHealth.snapshots.count,
                           "smartctl": diskHealth.smartctl != nil, "loading": diskHealth.loading]))
        }
    }

    /// The phone reached us on the local network (so Wi-Fi off would cut it off).
    static func overLAN(_ s: RemoteSession) -> Bool {
        guard !s.framed, case .hostPort(let host, _)? = s.conn.currentPath?.remoteEndpoint else { return false }
        let h = "\(host)".split(separator: "%").first.map(String.init) ?? ""
        if h.hasPrefix("100.") { return false }          // Tailscale
        return h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("fe80") || h.hasPrefix("fd") || h.hasPrefix("169.254.")
            || (h.hasPrefix("172.") && (Int(h.split(separator: ".")[1]) ?? 0) >= 16 && (Int(h.split(separator: ".")[1]) ?? 0) <= 31)
    }

    private func waitUntil(timeout: TimeInterval, _ ok: @escaping () -> Bool, then: @escaping () -> Void) {
        let end = Date().addingTimeInterval(timeout)
        func tick() {
            if ok() || Date() > end { then(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: tick)
        }
        tick()
    }

    // MARK: Wi-Fi

    func wifi(_ a: [String: Any], _ done: @escaping Done) {
        let w = WiFiModel.shared
        w.refresh()
        if (a["scan"] as? Bool) == true && !w.scanning { w.scan() }
        let answer = {
            let nets = w.networks.map { ["ssid": $0.ssid, "rssi": $0.rssi, "secure": $0.secure, "known": $0.known,
                                         "channel": $0.channel, "bars": $0.bars] as [String: Any] }
            var d: [String: Any] = ["power": w.powerOn, "rssi": w.rssi, "txRate": w.txRate, "networks": nets,
                                    "scanning": w.scanning, "locationAllowed": w.locationAllowed]
            if let v = w.ssid { d["ssid"] = v }
            if let v = w.ip { d["ip"] = v }
            if let v = w.joining { d["joining"] = v }
            if let v = w.message { d["message"] = v }
            done(.success(d))
        }
        if (a["scan"] as? Bool) == true { waitUntil(timeout: 12, { !w.scanning }, then: answer) } else { answer() }
    }

    func wifiPower(_ a: [String: Any], _ s: RemoteSession, _ done: Done) {
        let on = (a["on"] as? Bool) ?? true
        if !on && Self.overLAN(s) {
            Self.fail(done, "Your phone is reaching the Mac over Wi-Fi: turning it off would cut you off"); return
        }
        WiFiModel.shared.setPower(on)
        RemoteServer.shared.record(s.deviceName, on ? "Turned Wi-Fi on" : "Turned Wi-Fi off")
        done(.success([:]))
    }

    func wifiJoin(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        let w = WiFiModel.shared
        guard let ssid = a["ssid"] as? String, let net = w.networks.first(where: { $0.ssid == ssid }) else {
            Self.fail(done, "Scan again: that network isn't in range"); return
        }
        let pw = (a["password"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        w.join(net, password: pw)
        RemoteServer.shared.record(s.deviceName, "Joined Wi-Fi \(ssid)")
        waitUntil(timeout: 20, { w.joining == nil }) { done(.success(["message": w.message ?? "", "ssid": w.ssid ?? ""])) }
    }

    // MARK: Sound Mixer

    func sound(_ done: Done) {
        let m = MixerModel.shared
        if liveUntil["sound"] == nil { m.start() } else { m.refresh() }
        keepLive("sound")
        let apps = m.apps.map { ["id": $0.id, "name": $0.name, "playing": $0.playing, "level": Double(m.level($0))] as [String: Any] }
        let devs = m.devices.map { ["id": Int($0.id), "name": $0.name] as [String: Any] }
        var d: [String: Any] = ["master": Double(m.master), "muted": m.masterMuted, "output": Int(m.output),
                                "devices": devs, "apps": apps, "supported": m.supported]
        if let p = m.problem { d["problem"] = p }
        done(.success(d))
    }

    func soundSet(_ a: [String: Any], _ done: Done) {
        let m = MixerModel.shared
        if let v = a["master"] as? Double { m.setMaster(Float(min(max(v, 0), 1))) }
        if let mute = a["muted"] as? Bool, mute != m.masterMuted { m.toggleMasterMute() }
        if let o = a["output"] as? Int { m.setOutput(AudioDeviceID(o)) }
        if let id = a["app"] as? String, let v = a["level"] as? Double, let app = m.apps.first(where: { $0.id == id }) {
            m.setLevel(app, Float(min(max(v, 0), 1)))
        }
        if (a["reset"] as? Bool) == true { m.resetAll() }
        sound(done)
    }

    // MARK: Tidy Downloads and Folder Autopilot

    private var lastPlan: [TidyItem] = []

    func tidy(_ done: @escaping Done) {
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = Tidier.plan()
            DispatchQueue.main.async { [self] in
                lastPlan = plan
                let items = plan.prefix(600).map { i -> [String: Any] in
                    var d: [String: Any] = ["path": i.url.path, "name": i.name, "size": Double(i.size), "kind": i.kind.rawValue,
                                            "added": i.added.timeIntervalSince1970, "flags": i.flags]
                    if let s = i.source { d["source"] = s }
                    return d
                }
                done(.success(["items": Array(items)]))
            }
        }
    }

    func tidyApply(_ a: [String: Any], _ s: RemoteSession, _ done: @escaping Done) {
        let want = Set((a["paths"] as? [String]) ?? [])
        let list = lastPlan.filter { want.contains($0.url.path) }
        guard !list.isEmpty else { Self.fail(done, "Nothing picked (or Downloads changed: refresh)"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let moved = Tidier.apply(list)
            DispatchQueue.main.async {
                RemoteServer.shared.record(s.deviceName, "Tidied \(moved.count) downloads into folders")
                UndoCenter.shared.show("Tidied \(moved.count) file\(moved.count == 1 ? "" : "s") from your iPhone") { FileOps.moveBack(moved) }
                done(.success(["moved": moved.count]))
            }
        }
    }

    func rules(_ done: Done) {
        let store = RuleStore.shared
        let list = store.rules.map { r -> [String: Any] in
            var d: [String: Any] = ["id": r.id.uuidString, "name": r.name, "enabled": r.enabled, "sentence": r.sentence,
                                    "action": r.action, "lastCount": r.lastCount, "waiting": store.matches(r).count]
            if let t = Self.t(r.lastRun) { d["lastRun"] = t }
            return d
        }
        done(.success(["rules": list]))
    }

    func ruleSet(_ a: [String: Any], _ done: Done) {
        let store = RuleStore.shared
        guard let id = a["id"] as? String, let i = store.rules.firstIndex(where: { $0.id.uuidString == id }) else {
            Self.fail(done, "That rule is gone"); return
        }
        if let on = a["enabled"] as? Bool { store.rules[i].enabled = on }
        rules(done)
    }

    func ruleRun(_ a: [String: Any], _ s: RemoteSession, _ done: Done) {
        let store = RuleStore.shared
        guard let id = a["id"] as? String, let r = store.rules.first(where: { $0.id.uuidString == id }) else {
            Self.fail(done, "That rule is gone"); return
        }
        guard r.action == "trash" || !r.destination.isEmpty else { Self.fail(done, "This rule has no destination yet. Set it on the Mac."); return }
        let moved = store.run(r)
        if !moved.isEmpty { UndoCenter.shared.show("Autopilot “\(r.name)”: \(moved.count) file\(moved.count == 1 ? "" : "s")") { FileOps.moveBack(moved) } }
        RemoteServer.shared.record(s.deviceName, "Ran Autopilot rule “\(r.name)” (\(moved.count) files)")
        done(.success(["moved": moved.count]))
    }

    // MARK: Converter (a job: start, then poll)

    func convertTargets(_ a: [String: Any], _ done: Done) {
        let urls = ((a["paths"] as? [String]) ?? []).map { URL(fileURLWithPath: $0) }
        let fams = Set(urls.map { ConvFamily.of($0) })
        guard !urls.isEmpty, !fams.contains(.unknown) else { Self.fail(done, "Triage can't convert one of these files"); return }
        var common: [String]?
        for f in fams { common = common.map { c in c.filter { f.outputs.contains($0) } } ?? f.outputs }
        let outs = (common ?? []).map { ["ext": $0, "label": Converter.describe($0)] }
        done(.success(["targets": outs, "families": fams.map(\.rawValue)]))
    }

    private struct Job { var total: Int; var finished = 0; var failed: [String] = []; var outputs: [String] = []; var running = true }
    private var jobs: [String: Job] = [:]

    func convert(_ a: [String: Any], _ s: RemoteSession, _ done: Done) {
        let paths = ((a["paths"] as? [String]) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty, paths.count <= 200, let ext = a["to"] as? String else { Self.fail(done, "Pick 1 to 200 files and a format"); return }
        let quality = a["quality"] as? Double ?? 0.85
        let id = UUID().uuidString
        jobs[id] = Job(total: paths.count)
        RemoteServer.shared.record(s.deviceName, "Converting \(paths.count) file\(paths.count == 1 ? "" : "s") to \(ext.uppercased())")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for p in paths {
                let u = URL(fileURLWithPath: p)
                do {
                    let outs = try Converter.convert(u, to: ext, outDir: u.deletingLastPathComponent(), quality: quality)
                    DispatchQueue.main.async { self.jobs[id]?.outputs += outs.map(\.path) }
                } catch {
                    DispatchQueue.main.async { self.jobs[id]?.failed.append("\(u.lastPathComponent): \(error.localizedDescription)") }
                }
                DispatchQueue.main.async { self.jobs[id]?.finished += 1 }
            }
            DispatchQueue.main.async { self.jobs[id]?.running = false }
        }
        done(.success(["job": id]))
    }

    func jobState(_ a: [String: Any], _ done: Done) {
        guard let id = a["job"] as? String, let j = jobs[id] else { Self.fail(done, "That job is gone"); return }
        done(.success(["total": j.total, "finished": j.finished, "failed": j.failed, "outputs": j.outputs, "running": j.running]))
        if !j.running { jobs[id] = nil }
    }

    // MARK: Batch Rename (same patterns as the Mac's tool)

    func rename(_ a: [String: Any], _ s: RemoteSession, apply: Bool, _ done: @escaping Done) {
        let paths = (a["paths"] as? [String]) ?? []
        guard !paths.isEmpty, paths.count <= 1000 else { Self.fail(done, "Pick 1 to 1000 files"); return }
        let pattern = (a["pattern"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "{name}"
        let find = a["find"] as? String ?? "", replace = a["replace"] as? String ?? ""
        let regex = (a["regex"] as? Bool) ?? false, caseMode = a["case"] as? String ?? "keep"
        let start = a["start"] as? Int ?? 1, pad = min(max(a["pad"] as? Int ?? 2, 1), 6)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        func newName(_ u: URL, _ i: Int) -> String {
            let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            var n = pattern
                .replacingOccurrences(of: "{name}", with: base)
                .replacingOccurrences(of: "{n}", with: String(format: "%0\(pad)d", start + i))
                .replacingOccurrences(of: "{date}", with: df.string(from: v?.contentModificationDate ?? Date()))
                .replacingOccurrences(of: "{created}", with: df.string(from: v?.creationDate ?? Date()))
                .replacingOccurrences(of: "{folder}", with: u.deletingLastPathComponent().lastPathComponent)
            if !find.isEmpty {
                n = regex ? n.replacingOccurrences(of: find, with: replace, options: .regularExpression) : n.replacingOccurrences(of: find, with: replace)
            }
            switch caseMode {
            case "lower": n = n.lowercased()
            case "upper": n = n.uppercased()
            case "title": n = n.capitalized
            case "kebab": n = n.lowercased().replacingOccurrences(of: " ", with: "-")
            default: break
            }
            n = n.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            return ext.isEmpty ? n : "\(n).\(ext)"
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        var plan: [(URL, String, Bool)] = []
        for (i, u) in urls.enumerated() {
            let n = newName(u, i)
            let dest = u.deletingLastPathComponent().appendingPathComponent(n).path
            let clash = n.isEmpty || seen.contains(dest) || (dest != u.path && FileManager.default.fileExists(atPath: dest))
            seen.insert(dest)
            plan.append((u, n, clash))
        }
        let preview = plan.map { ["path": $0.0.path, "name": $0.1, "clash": $0.2] as [String: Any] }
        guard apply else { done(.success(["preview": preview])); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var renamed = 0, skipped: [String] = []
            for (u, n, clash) in plan {
                guard !clash, RemoteAPI.trashable(u.path) else { skipped.append(u.lastPathComponent); continue }
                if n == u.lastPathComponent { continue }
                do { try FileManager.default.moveItem(at: u, to: u.deletingLastPathComponent().appendingPathComponent(n)); renamed += 1 }
                catch { skipped.append(u.lastPathComponent) }
            }
            DispatchQueue.main.async {
                RemoteServer.shared.record(s.deviceName, "Batch renamed \(renamed) file\(renamed == 1 ? "" : "s")")
                done(.success(["renamed": renamed, "skipped": skipped]))
            }
        }
    }
}
