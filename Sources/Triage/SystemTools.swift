import SwiftUI
import AppKit
import Charts
import UserNotifications

/// Name of the app that owns a process (Chrome's helpers → "Google Chrome").
func appName(forPID pid: pid_t, fallback: String) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let cap = UInt32(4096)
    guard proc_pidpath(pid, &buf, cap) > 0 else { return fallback }
    let path = String(cString: buf)
    if let r = path.range(of: ".app/") {
        return ((String(path[..<r.lowerBound]) + ".app") as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }
    return (path as NSString).lastPathComponent
}

// MARK: - Startup Items

struct StartupItem: Identifiable {
    let plist: URL
    let label: String
    let program: String
    let scope: String
    let kind: String
    var enabled: Bool
    var running: Bool
    var id: String { plist.path }

    var vendor: String {
        if let r = program.range(of: ".app/") {
            return ((String(program[..<r.lowerBound])) as NSString).lastPathComponent
        }
        let parts = label.split(separator: ".")
        return parts.count > 1 ? String(parts[1]).capitalized : label
    }
    var canToggle: Bool { scope == "You" }
}

final class StartupModel: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var loginItems: [String] = []
    @Published var loadedLogin = false

    static let userAgents = Places.home.appendingPathComponent("Library/LaunchAgents")
    static let disabledDir = Places.home.appendingPathComponent("Library/LaunchAgents (Disabled by Triage)")

    func load() {
        Work.quick.async {
            let running = Set(Shell.run("/bin/launchctl", ["list"]).split(separator: "\n").compactMap { line -> String? in
                let cols = line.split(separator: "\t")
                guard cols.count == 3, cols[0] != "-", cols[0] != "PID" else { return nil }
                return String(cols[2])
            })
            var out: [StartupItem] = []
            let sources: [(URL, String, String, Bool)] = [
                (Self.userAgents, "You", "Background agent", true),
                (Self.disabledDir, "You", "Background agent", false),
                (URL(fileURLWithPath: "/Library/LaunchAgents"), "All users", "Background agent", true),
                (URL(fileURLWithPath: "/Library/LaunchDaemons"), "System", "System service", true),
            ]
            for (dir, scope, kind, enabled) in sources {
                for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "plist" {
                    guard let d = NSDictionary(contentsOf: f) as? [String: Any] else { continue }
                    let label = d["Label"] as? String ?? f.deletingPathExtension().lastPathComponent
                    let program = d["Program"] as? String ?? (d["ProgramArguments"] as? [String])?.first ?? ""
                    out.append(StartupItem(plist: f, label: label, program: program, scope: scope, kind: kind,
                                           enabled: enabled, running: running.contains(label)))
                }
            }
            DispatchQueue.main.async { self.items = out }
        }
    }

    func loadLoginItems() {
        DispatchQueue.global().async {
            let r = Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get the name of every login item"])
            let names = r.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            DispatchQueue.main.async { self.loginItems = names; self.loadedLogin = true }
        }
    }

    func removeLoginItem(_ name: String) {
        let safe = name.replacingOccurrences(of: "\"", with: "")
        DispatchQueue.global().async {
            Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete login item \"\(safe)\""])
            self.loadLoginItems()
        }
    }

    func setEnabled(_ item: StartupItem, _ on: Bool) {
        guard item.canToggle else { return }
        let fm = FileManager.default
        let domain = "gui/\(getuid())"
        try? fm.createDirectory(at: Self.disabledDir, withIntermediateDirectories: true)
        let dest = (on ? Self.userAgents : Self.disabledDir).appendingPathComponent(item.plist.lastPathComponent)
        DispatchQueue.global().async {
            if !on { Shell.run("/bin/launchctl", ["bootout", domain, item.plist.path]) }
            try? fm.moveItem(at: item.plist, to: dest)
            if on { Shell.run("/bin/launchctl", ["bootstrap", domain, dest.path]) }
            self.load()
        }
    }
}

struct StartupView: View {
    @StateObject private var m = StartupModel()
    @State private var sort = ColumnSort(key: "name", ascending: true)
    @State private var fName = ""
    @State private var fScope: Set<String> = []
    @State private var fState: Set<String> = []

    private func state(_ i: StartupItem) -> String { !i.enabled ? "Turned off" : i.running ? "Running" : "Waiting" }

    private var visible: [StartupItem] {
        let l = m.items.filter {
            TextFilter.matches($0.vendor + " " + $0.label, fName)
                && (fScope.isEmpty || fScope.contains($0.scope))
                && (fState.isEmpty || fState.contains(state($0)))
        }
        let s = sort.key == "vendor" ? l.sorted { $0.vendor < $1.vendor } : l.sorted { $0.label < $1.label }
        return sort.ascending ? s : s.reversed()
    }

    private func opts(_ vals: [String]) -> [FilterOption] {
        var c: [String: Int] = [:]; vals.forEach { c[$0, default: 0] += 1 }
        return c.sorted { $0.key < $1.key }.map { FilterOption(id: $0.key, label: $0.key, count: $0.value) }
    }

    var body: some View {
        ToolPage(tool: .startup, subtitle: "Things that start on their own. Your own agents can be turned off here; system ones need an admin.", trailing: {
            HStack {
                Button("Login Items Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                Button { m.load() } label: { Image(systemName: "arrow.clockwise") }
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("OPEN AT LOGIN").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                    Spacer()
                    if !m.loadedLogin { Button("Show login items") { m.loadLoginItems() }.controlSize(.small) }
                }
                if m.loadedLogin {
                    if m.loginItems.isEmpty { Text("None.").font(.ui(size: 12)).foregroundStyle(.secondary) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(m.loginItems, id: \.self) { n in
                                HStack(spacing: 6) {
                                    Text(n).font(.ui(size: 12))
                                    Button { m.removeLoginItem(n) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop opening at login")
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(14).glass(12)

            TableBox(footer: "\(m.items.filter(\.running).count) running · \(m.items.filter { !$0.enabled }.count) turned off by you") {
                HStack(spacing: 0) {
                    ColumnHeader("Item", sortKey: "name", sort: $sort, text: $fName)
                    ColumnHeader("From", width: 130, sortKey: "vendor", sort: $sort)
                    ColumnHeader("For", width: 90, sort: $sort, options: opts(m.items.map(\.scope)), selection: $fScope)
                    ColumnHeader("Status", width: 100, sort: $sort, options: opts(m.items.map(state)), selection: $fState)
                    ColumnHeader("On", width: 50, sort: $sort)
                }
            } rows: {
                ForEach(visible) { i in
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.label).font(.ui(size: 12, weight: .medium)).lineLimit(1)
                            Text(i.program).font(.ui(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                        Text(i.vendor).frame(width: 130, alignment: .leading).lineLimit(1)
                        Text(i.scope).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        HStack(spacing: 4) {
                            Circle().fill(i.running ? Theme.good : (i.enabled ? Color.secondary : Theme.net)).frame(width: 6, height: 6)
                            Text(state(i))
                        }
                        .foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                        Toggle("", isOn: Binding(get: { i.enabled }, set: { m.setEnabled(i, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .disabled(!i.canToggle)
                            .help(i.canToggle ? "Turn on or off" : "Needs an administrator. Use Login Items Settings.")
                            .frame(width: 50, alignment: .leading)
                    }
                    .font(.ui(size: 12))
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .contextMenu {
                        Button("Show plist in Finder") { NSWorkspace.shared.activateFileViewerSelecting([i.plist]) }
                        if !i.program.isEmpty { Button("Show program in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.program)]) } }
                    }
                }
            }
        }
        .onAppear { m.load() }
    }
}

// MARK: - Network by App

struct NetUsage: Identifiable {
    let name: String
    var down: Double
    var up: Double
    var received: Int64
    var sent: Int64
    var id: String { name }
}

final class NetworkModel: ObservableObject {
    @Published var apps: [NetUsage] = []
    @Published var available = FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop")
    private var last: [pid_t: (Int64, Int64)] = [:]
    private var lastTime = Date()
    private var timer: Timer?

    func start() {
        sample()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        DispatchQueue.global(qos: .utility).async {
            let out = Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-J", "bytes_in,bytes_out", "-x"], timeout: 6)
            let now = Date()
            let dt = max(now.timeIntervalSince(self.lastTime), 0.5)
            var current: [pid_t: (Int64, Int64)] = [:]
            var byApp: [String: NetUsage] = [:]
            for line in out.split(separator: "\n") {
                let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 3 else { continue }
                let nums = f.compactMap { Int64($0) }
                guard nums.count >= 2 else { continue }
                let label = f.first(where: { $0.contains(".") && Int64($0) == nil && $0.range(of: #"\.\d+$"#, options: .regularExpression) != nil }) ?? ""
                guard let dot = label.lastIndex(of: "."), let pid = pid_t(label[label.index(after: dot)...]) else { continue }
                let name = appName(forPID: pid, fallback: String(label[..<dot]))
                let bin = nums[nums.count - 2], bout = nums[nums.count - 1]
                current[pid] = (bin, bout)
                var u = byApp[name] ?? NetUsage(name: name, down: 0, up: 0, received: 0, sent: 0)
                u.received += bin; u.sent += bout
                if let p = self.last[pid] {
                    u.down += Double(max(bin - p.0, 0)) / dt
                    u.up += Double(max(bout - p.1, 0)) / dt
                }
                byApp[name] = u
            }
            DispatchQueue.main.async {
                self.last = current
                self.lastTime = now
                self.apps = Array(byApp.values).filter { $0.received + $0.sent > 0 }
            }
        }
    }
}

struct NetworkView: View {
    @StateObject private var m = NetworkModel()
    @EnvironmentObject var monitor: SystemMonitor
    @State private var sort = ColumnSort(key: "down", ascending: false)
    @State private var fName = ""
    @State private var fActive: Set<String> = []

    private func activity(_ u: NetUsage) -> String { u.down + u.up > 10_000 ? "Active now" : "Quiet" }

    private var visible: [NetUsage] {
        let l = m.apps.filter { TextFilter.matches($0.name, fName) && (fActive.isEmpty || fActive.contains(activity($0))) }
        let s: [NetUsage]
        switch sort.key {
        case "name": s = l.sorted { $0.name < $1.name }
        case "up": s = l.sorted { $0.up < $1.up }
        case "received": s = l.sorted { $0.received < $1.received }
        case "sent": s = l.sorted { $0.sent < $1.sent }
        default: s = l.sorted { $0.down < $1.down }
        }
        return sort.ascending ? s : s.reversed()
    }

    var body: some View {
        ToolPage(tool: .network) {
            HStack(spacing: 14) {
                StatCard(title: "Download", value: Fmt.rate(monitor.snap.netIn), detail: "whole Mac", history: monitor.netInHistory, maxValue: nil, color: Theme.cpu)
                StatCard(title: "Upload", value: Fmt.rate(monitor.snap.netOut), detail: "whole Mac", history: monitor.netOutHistory, maxValue: nil, color: Theme.net)
            }
            if !m.available {
                empty("nettop isn't available on this Mac.")
            } else {
                TableBox(footer: "Totals count since each app opened. Speeds refresh every 2 seconds.") {
                    HStack(spacing: 0) {
                        ColumnHeader("App", sortKey: "name", sort: $sort,
                                     options: ["Active now", "Quiet"].map { a in FilterOption(id: a, label: a, count: m.apps.filter { activity($0) == a }.count) },
                                     selection: $fActive, text: $fName)
                        ColumnHeader("Down", width: 100, sortKey: "down", sort: $sort, defaultAscending: false)
                        ColumnHeader("Up", width: 100, sortKey: "up", sort: $sort, defaultAscending: false)
                        ColumnHeader("Received", width: 100, sortKey: "received", sort: $sort, defaultAscending: false)
                        ColumnHeader("Sent", width: 100, sortKey: "sent", sort: $sort, defaultAscending: false)
                    }
                } rows: {
                    ForEach(visible) { u in
                        HStack(spacing: 0) {
                            Text(u.name).lineLimit(1).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                            Text(Fmt.rate(u.down)).foregroundStyle(u.down > 100_000 ? Theme.cpu : .secondary).frame(width: 100, alignment: .leading)
                            Text(Fmt.rate(u.up)).foregroundStyle(u.up > 100_000 ? Theme.net : .secondary).frame(width: 100, alignment: .leading)
                            Text(Fmt.bytes(u.received)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                            Text(Fmt.bytes(u.sent)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                        }
                        .font(.ui(size: 12)).monospacedDigit()
                        .padding(.horizontal, 16).padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Copy App Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.name, forType: .string) }
                            Button("Only Show \(u.name)") { fName = u.name }
                            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == u.name }) {
                                Button("Bring \(u.name) to Front") { app.activate() }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { m.start() }
        .onDisappear { m.stop() }
    }
}

// MARK: - Dev Servers & Ports

struct Listener: Identifiable, Hashable {
    let pid: pid_t
    let command: String
    let app: String
    let host: String
    let port: Int
    var id: String { "\(pid):\(host):\(port)" }
    var isLocalOnly: Bool { host.hasPrefix("127.") || host == "[::1]" || host == "localhost" }
}

struct Container: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: String
    var running: Bool { status.hasPrefix("Up") }
}

final class PortsModel: ObservableObject {
    @Published var listeners: [Listener] = []
    @Published var containers: [Container] = []
    @Published var docker: String? = Shell.which(["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                                   "/Applications/Docker.app/Contents/Resources/bin/docker"])
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let dockerPath = docker
        DispatchQueue.global(qos: .utility).async {
            let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 8)
            var pid: pid_t = 0, cmd = ""
            var found = Set<Listener>()
            for line in out.split(separator: "\n") {
                guard let tag = line.first else { continue }
                let v = String(line.dropFirst())
                switch tag {
                case "p": pid = pid_t(v) ?? 0
                case "c": cmd = v
                case "n":
                    guard let colon = v.lastIndex(of: ":"), let port = Int(v[v.index(after: colon)...]) else { continue }
                    let host = String(v[..<colon])
                    found.insert(Listener(pid: pid, command: cmd, app: appName(forPID: pid, fallback: cmd),
                                          host: host == "*" ? "All networks" : host, port: port))
                default: break
                }
            }
            // collapse IPv4 + IPv6 duplicates of the same port
            var seen = Set<String>()
            let list = found.sorted { $0.port < $1.port }.filter { seen.insert("\($0.pid):\($0.port)").inserted }
            var cs: [Container] = []
            if let d = dockerPath {
                let r = Shell.run(d, ["ps", "-a", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"], timeout: 6)
                for line in r.split(separator: "\n") {
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    if f.count >= 4 { cs.append(Container(id: f[0], name: f[1], image: f[2], status: f[3], ports: f.count > 4 ? f[4] : "")) }
                }
            }
            DispatchQueue.main.async { self.listeners = list; self.containers = cs }
        }
    }

    func kill(_ l: Listener) {
        Darwin.kill(l.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func dockerRun(_ verb: String, _ c: Container) {
        guard let d = docker else { return }
        DispatchQueue.global().async { Shell.run(d, [verb, c.id], timeout: 30); self.refresh() }
    }
}

struct PortsView: View {
    @StateObject private var m = PortsModel()
    @State private var sort = ColumnSort(key: "port", ascending: true)
    @State private var fName = ""
    @State private var fReach: Set<String> = []
    @State private var confirm: Listener?

    private func reach(_ l: Listener) -> String { l.isLocalOnly ? "This Mac only" : "Open to network" }

    private var visible: [Listener] {
        let l = m.listeners.filter { TextFilter.matches("\($0.app) \($0.command) \($0.port)", fName) && (fReach.isEmpty || fReach.contains(reach($0))) }
        let s = sort.key == "name" ? l.sorted { $0.app < $1.app } : l.sorted { $0.port < $1.port }
        return sort.ascending ? s : s.reversed()
    }

    var body: some View {
        ToolPage(tool: .ports, subtitle: "Every program listening for connections, so “port 3000 is already in use” takes one click to fix.", trailing: {
            Button { m.refresh() } label: { Image(systemName: "arrow.clockwise") }
        }) {
            TableBox(footer: "\(m.listeners.count) listening · \(m.listeners.filter { !$0.isLocalOnly }.count) reachable from your network") {
                HStack(spacing: 0) {
                    ColumnHeader("Port", width: 80, sortKey: "port", sort: $sort)
                    ColumnHeader("Program", sortKey: "name", sort: $sort, text: $fName)
                    ColumnHeader("Reachable from", width: 150, sort: $sort,
                                 options: ["This Mac only", "Open to network"].map { r in FilterOption(id: r, label: r, count: m.listeners.filter { reach($0) == r }.count) },
                                 selection: $fReach)
                    ColumnHeader("PID", width: 70, sort: $sort)
                    Color.clear.frame(width: 150, height: 1)
                }
            } rows: {
                ForEach(visible) { l in
                    HStack(spacing: 0) {
                        Text(":\(l.port)").font(.ui(size: 13, weight: .semibold, design: .monospaced)).frame(width: 80, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(l.app).font(.ui(size: 12, weight: .medium))
                            Text(l.command).font(.ui(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            Image(systemName: l.isLocalOnly ? "lock.fill" : "wifi").foregroundStyle(l.isLocalOnly ? Theme.good : Theme.net)
                            Text(reach(l))
                        }
                        .font(.ui(size: 11)).frame(width: 150, alignment: .leading)
                        Text("\(l.pid)").font(.ui(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        HStack(spacing: 6) {
                            Button("Open") { NSWorkspace.shared.open(URL(string: "http://localhost:\(l.port)")!) }
                            Button("Stop") { confirm = l }
                        }
                        .controlSize(.small).frame(width: 150, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Open in Browser") { NSWorkspace.shared.open(URL(string: "http://localhost:\(l.port)")!) }
                        Button("Copy Process ID \(l.pid)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(l.pid)", forType: .string) }
                        Button("Stop Process…") { confirm = l }
                        Button("Copy http://localhost:\(l.port)") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("http://localhost:\(l.port)", forType: .string)
                        }
                    }
                }
            }
            if m.docker != nil {
                Text("DOCKER CONTAINERS").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    if m.containers.isEmpty { Text("No containers, or Docker isn't running.").font(.ui(size: 12)).foregroundStyle(.secondary) }
                    ForEach(m.containers) { c in
                        HStack {
                            Circle().fill(c.running ? Theme.good : Color.secondary).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(.ui(size: 12, weight: .medium))
                                Text("\(c.image) · \(c.status)").font(.ui(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(c.ports).font(.ui(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            if c.running {
                                Button("Restart") { m.dockerRun("restart", c) }
                                Button("Stop") { m.dockerRun("stop", c) }
                            } else {
                                Button("Start") { m.dockerRun("start", c) }
                            }
                        }
                        .controlSize(.small)
                        .contentShape(Rectangle())
                        .contextMenu {
                            if c.running {
                                Button("Restart") { m.dockerRun("restart", c) }
                                Button("Stop") { m.dockerRun("stop", c) }
                            } else {
                                Button("Start") { m.dockerRun("start", c) }
                            }
                            Divider()
                            Button("Copy Container ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.id, forType: .string) }
                            Button("Copy Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.name, forType: .string) }
                        }
                    }
                }
                .padding(14).glass(12)
            }
        }
        .onAppear { m.start() }
        .onDisappear { m.stop() }
        .confirmationDialog("Stop \(confirm?.app ?? "") on port \(confirm?.port ?? 0)?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Stop Process", role: .destructive) { if let c = confirm { m.kill(c) }; confirm = nil }
        } message: { Text("Sends a normal quit signal to process \(confirm?.pid ?? 0). Unsaved work in it may be lost.") }
    }
}

// MARK: - Health History

struct HealthSample: Codable, Identifiable {
    let t: Date
    let bpm: Double
    let cpu: Double
    let mem: Double
    let health: Int
    let top: String?
    var id: Date { t }
}

final class HealthLog: ObservableObject {
    static let shared = HealthLog()
    @Published private(set) var samples: [HealthSample] = []
    private let file = Shell.supportDir.appendingPathComponent("health.json")
    private var unsaved = 0
    private var strainedSince: Date?
    private var lastAlert: Date?

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([HealthSample].self, from: d) { samples = s }
    }

    func add(_ s: HealthSample) {
        samples.append(s)
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        if let first = samples.first, first.t < cutoff { samples.removeAll { $0.t < cutoff } }
        unsaved += 1
        if unsaved >= 5 { save() }
        checkAlert(s)
    }

    func save() {
        unsaved = 0
        if let d = try? JSONEncoder().encode(samples) { try? d.write(to: file, options: .atomic) }
    }

    private func checkAlert(_ s: HealthSample) {
        let d = UserDefaults.standard
        guard d.object(forKey: "alert.enabled") == nil || d.bool(forKey: "alert.enabled") else { return }
        let threshold = d.object(forKey: "alert.bpm") == nil ? 140.0 : d.double(forKey: "alert.bpm")
        let minutes = d.object(forKey: "alert.minutes") == nil ? 5.0 : d.double(forKey: "alert.minutes")
        guard s.bpm >= threshold else { strainedSince = nil; return }
        let since = strainedSince ?? s.t
        strainedSince = since
        guard s.t.timeIntervalSince(since) >= minutes * 60,
              lastAlert.map({ s.t.timeIntervalSince($0) > 1800 }) ?? true else { return }
        lastAlert = s.t
        notify(title: "Your Mac's heart rate is \(Int(s.bpm)) bpm",
               body: "It's been strained for \(Int(minutes)) minutes\(s.top.map { ". \($0) is working hardest" } ?? "").")
    }

    func notify(title: String, body: String) {
        NSSound(named: "Funk")?.play()
        UndoCenter.shared.show(title)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

struct HealthHistoryView: View {
    @ObservedObject private var log = HealthLog.shared
    @State private var range: Double = 86_400
    @AppStorage("alert.enabled") private var alertOn = true
    @AppStorage("alert.bpm") private var alertBPM = 140.0
    @AppStorage("alert.minutes") private var alertMinutes = 5.0

    private var shown: [HealthSample] {
        let cutoff = Date().addingTimeInterval(-range)
        return log.samples.filter { $0.t >= cutoff }
    }

    private struct Spike: Identifiable {
        let start: Date
        let end: Date
        let peak: Double
        let top: String?
        var id: Date { start }
    }

    private var spikes: [Spike] {
        var out: [Spike] = []
        var cur: [HealthSample] = []
        func close() {
            guard cur.count >= 2, let a = cur.first, let b = cur.last else { cur = []; return }
            let tops = Dictionary(grouping: cur.compactMap(\.top), by: { $0 }).max { $0.value.count < $1.value.count }?.key
            out.append(Spike(start: a.t, end: b.t, peak: cur.map(\.bpm).max() ?? 0, top: tops))
            cur = []
        }
        for s in shown { if s.bpm >= 120 { cur.append(s) } else { close() } }
        close()
        return out.reversed()
    }

    private var grade: (String, Color, String) {
        guard !shown.isEmpty else { return ("–", .secondary, "Not enough data yet") }
        let avg = Double(shown.map(\.health).reduce(0, +)) / Double(shown.count)
        let strained = Double(shown.filter { $0.bpm >= 130 }.count) / Double(shown.count)
        let note = "Average health \(Int(avg)) · strained \(Int(strained * 100))% of the time"
        switch avg - strained * 30 {
        case 85...: return ("A", Theme.good, note)
        case 70..<85: return ("B", Theme.good, note)
        case 55..<70: return ("C", Theme.net, note)
        case 40..<55: return ("D", Theme.net, note)
        default: return ("F", Theme.warn, note)
        }
    }

    var body: some View {
        ToolPage(tool: .history, trailing: {
            Picker("", selection: $range) {
                Text("1 hour").tag(3600.0); Text("24 hours").tag(86_400.0); Text("7 days").tag(604_800.0); Text("14 days").tag(1_209_600.0)
            }
            .pickerStyle(.segmented).frame(width: 300)
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("REPORT CARD").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                            Text(grade.0).font(.ui(size: 54, weight: .bold, design: .rounded)).foregroundStyle(grade.1)
                            Text(grade.2).font(.ui(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(14).frame(width: 220, alignment: .leading).glass()
                        stat("Average", shown.isEmpty ? "–" : "\(Int(shown.map(\.bpm).reduce(0, +) / Double(shown.count))) bpm")
                        stat("Resting", shown.isEmpty ? "–" : "\(Int(shown.map(\.bpm).sorted()[shown.count / 10])) bpm")
                        stat("Peak", shown.isEmpty ? "–" : "\(Int(shown.map(\.bpm).max() ?? 0)) bpm")
                    }
                    VStack(alignment: .leading) {
                        if shown.count < 2 {
                            empty("Recording started. Triage logs your Mac's heart rate every minute while it's open, and keeps 14 days.")
                        } else {
                            Chart {
                                ForEach(shown) { s in
                                    AreaMark(x: .value("Time", s.t), y: .value("bpm", s.bpm))
                                        .foregroundStyle(LinearGradient(colors: [Theme.heart.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                                    LineMark(x: .value("Time", s.t), y: .value("bpm", s.bpm))
                                        .foregroundStyle(Theme.heart)
                                }
                                RuleMark(y: .value("Alert", alertBPM))
                                    .foregroundStyle(Theme.warn.opacity(0.6))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            }
                            .chartYScale(domain: 50.0...185.0)
                            .frame(height: 220)
                        }
                    }
                    .padding(14).glass()

                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SPIKES (120+ BPM)").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                            if spikes.isEmpty { Text("None in this period.").font(.ui(size: 12)).foregroundStyle(.secondary) }
                            ForEach(spikes.prefix(12)) { sp in
                                HStack {
                                    Text(sp.start, format: .dateTime.weekday().hour().minute()).frame(width: 110, alignment: .leading)
                                    Text("\(max(1, Int(sp.end.timeIntervalSince(sp.start) / 60))) min").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                                    Text("peak \(Int(sp.peak))").foregroundStyle(Theme.warn).frame(width: 70, alignment: .leading)
                                    Text(sp.top ?? "").foregroundStyle(.secondary).lineLimit(1)
                                }
                                .font(.ui(size: 12))
                                .contentShape(Rectangle())
                                .contextMenu {
                                    Button("Copy Details") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString("\(sp.start.formatted()) · \(Int(sp.peak)) bpm peak · \(sp.top ?? "")", forType: .string)
                                    }
                                }
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("ALERTS").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                            Toggle("Tell me when my Mac is strained", isOn: $alertOn)
                            Stepper("Heart rate at or above \(Int(alertBPM)) bpm", value: $alertBPM, in: 100...175, step: 5)
                            Stepper("For \(Int(alertMinutes)) minutes", value: $alertMinutes, in: 1...30)
                            Button("Send a test alert") { HealthLog.shared.notify(title: "Test alert", body: "This is how Triage will let you know.") }
                                .controlSize(.small)
                        }
                        .font(.ui(size: 12))
                        .padding(14).frame(width: 320, alignment: .leading).glass()
                    }
                }
            }
        }
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.uppercased()).font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            Text(v).font(.ui(size: 24, weight: .semibold, design: .rounded))
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass()
    }
}
