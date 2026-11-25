import SwiftUI
import AppKit

// MARK: - Data

struct SmartDetail {
    var percentUsed: Int?
    var powerOnHours: Int?
    var bytesWritten: Int64?
    var bytesRead: Int64?
    var temperature: Int?
    var spare: Int?
    var spareThreshold: Int?
    var mediaErrors: Int?
    var unsafeShutdowns: Int?
    var powerCycles: Int?
}

struct DriveInfo: Identifiable {
    let id: String            // disk0, disk4…
    var name: String
    var bus: String
    var isInternal: Bool
    var isSSD: Bool
    var size: Int64
    var smart: String         // Verified, Failing, Not Supported…
    var trim: String?
    var detail: SmartDetail?

    enum Health { case good, watch, critical, unknown }

    var health: (Health, String, [String]) {
        var notes: [String] = []
        var level = Health.good
        func raise(_ l: Health) {
            let rank: [Health: Int] = [.good: 0, .unknown: 1, .watch: 2, .critical: 3]
            if rank[l]! > rank[level]! { level = l }
        }
        switch smart.lowercased() {
        case "verified": notes.append("SMART self-check passed.")
        case let s where s.contains("fail"): raise(.critical); notes.append("The drive reports it is failing. Back up now and replace it.")
        default: raise(.unknown); notes.append("This drive doesn't report SMART status (common for USB enclosures).")
        }
        if let d = detail {
            if let p = d.percentUsed {
                if p >= 100 { raise(.critical); notes.append("Rated write life is used up (\(p)%). It can keep working, but plan a replacement.") }
                else if p >= 80 { raise(.watch); notes.append("\(p)% of its rated write life is used.") }
                else { notes.append("Only \(p)% of its rated write life is used.") }
            }
            if let s = d.spare, let t = d.spareThreshold, s <= t {
                raise(.critical); notes.append("Spare blocks are down to \(s)%, at or below the \(t)% warning line.")
            }
            if let e = d.mediaErrors, e > 0 { raise(.watch); notes.append("\(e) media error\(e == 1 ? "" : "s") recorded.") }
            if let t = d.temperature, t >= 70 { raise(.watch); notes.append("Running hot at \(t)°C.") }
        }
        let label: String
        switch level {
        case .good: label = "Healthy"
        case .watch: label = "Keep an eye on it"
        case .critical: label = "Back up now"
        case .unknown: label = "Limited info"
        }
        return (level, label, notes)
    }
}

struct VolumeInfo: Identifiable {
    let url: URL
    let name: String
    let format: String
    let total: Int64
    let free: Int64
    let importantFree: Int64
    var id: URL { url }
    var purgeable: Int64 { max(importantFree - free, 0) }
    var usedFraction: Double { total > 0 ? Double(total - importantFree) / Double(total) : 0 }
}

final class DiskHealthModel: ObservableObject {
    @Published var drives: [DriveInfo] = []
    @Published var volumes: [VolumeInfo] = []
    @Published var snapshots: [String] = []
    @Published var loading = false
    @Published var smartctl = Shell.which(["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl", "/opt/homebrew/sbin/smartctl", "/usr/local/sbin/smartctl"])
    @Published var brew = Shell.which(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
    @Published var installing = false
    @Published var verifyLog = ""
    @Published var verifying = false
    @Published var verifyResult: Bool?

    private func plist(_ out: String) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil)) as? [String: Any]
    }

    func load() {
        loading = true
        let sc = smartctl
        DispatchQueue.global(qos: .userInitiated).async {
            var drives: [DriveInfo] = []
            let list = self.plist(Shell.run("/usr/sbin/diskutil", ["list", "-plist", "physical"]))
            let whole = (list?["WholeDisks"] as? [String]) ?? []
            // Model names and TRIM from System Information
            var nvme: [String: (String, String)] = [:]
            if let data = Shell.run("/usr/sbin/system_profiler", ["SPNVMeDataType", "SPSerialATADataType", "-json"], timeout: 30).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for key in ["SPNVMeDataType", "SPSerialATADataType"] {
                    for ctrl in (json[key] as? [[String: Any]]) ?? [] {
                        for item in (ctrl["_items"] as? [[String: Any]]) ?? [] {
                            if let bsd = item["bsd_name"] as? String {
                                let model = (item["device_model"] as? String) ?? (item["_name"] as? String) ?? ""
                                let trim = (item["spnvme_trim_support"] as? String) ?? (item["spsata_trim_support"] as? String) ?? ""
                                nvme[bsd] = (model, trim)
                            }
                        }
                    }
                }
            }
            for d in whole {
                guard let info = self.plist(Shell.run("/usr/sbin/diskutil", ["info", "-plist", d])) else { continue }
                var drive = DriveInfo(
                    id: d,
                    name: nvme[d]?.0.isEmpty == false ? nvme[d]!.0 : ((info["MediaName"] as? String) ?? d),
                    bus: (info["BusProtocol"] as? String) ?? "",
                    isInternal: (info["Internal"] as? Bool) ?? false,
                    isSSD: (info["SolidState"] as? Bool) ?? false,
                    size: ((info["TotalSize"] ?? info["Size"]) as? NSNumber)?.int64Value ?? 0,
                    smart: (info["SMARTStatus"] as? String) ?? "Not Supported",
                    trim: nvme[d]?.1)
                if let sc, let data = Shell.run(sc, ["-a", "-j", "/dev/\(d)"], timeout: 20).data(using: .utf8),
                   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    var s = SmartDetail()
                    let n = j["nvme_smart_health_information_log"] as? [String: Any]
                    func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
                    s.percentUsed = int(n?["percentage_used"])
                    s.powerOnHours = int(n?["power_on_hours"]) ?? int((j["power_on_time"] as? [String: Any])?["hours"])
                    s.bytesWritten = (n?["data_units_written"] as? NSNumber).map { $0.int64Value * 512_000 }
                    s.bytesRead = (n?["data_units_read"] as? NSNumber).map { $0.int64Value * 512_000 }
                    s.temperature = int((j["temperature"] as? [String: Any])?["current"]) ?? int(n?["temperature"])
                    s.spare = int(n?["available_spare"])
                    s.spareThreshold = int(n?["available_spare_threshold"])
                    s.mediaErrors = int(n?["media_errors"])
                    s.unsafeShutdowns = int(n?["unsafe_shutdowns"])
                    s.powerCycles = int(n?["power_cycles"]) ?? int(j["power_cycle_count"])
                    if s.powerOnHours != nil || s.percentUsed != nil || s.temperature != nil { drive.detail = s }
                }
                drives.append(drive)
            }
            // Volumes, including space macOS can free on its own (purgeable)
            let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                          .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey]
            let vols = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).compactMap { u -> VolumeInfo? in
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
                return VolumeInfo(url: u, name: v.volumeName ?? u.lastPathComponent, format: v.volumeLocalizedFormatDescription ?? "",
                                  total: Int64(v.volumeTotalCapacity ?? 0), free: Int64(v.volumeAvailableCapacity ?? 0),
                                  importantFree: v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0))
            }
            let snaps = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).split(separator: "\n")
                .map(String.init).filter { $0.contains("com.apple") }
            DispatchQueue.main.async {
                self.drives = drives
                self.volumes = vols
                self.snapshots = snaps
                self.loading = false
            }
        }
    }

    func installSmartctl() {
        guard let brew else { return }
        installing = true
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.run(brew, ["install", "smartmontools"], timeout: 600)
            let found = Shell.which(["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl", "/opt/homebrew/sbin/smartctl", "/usr/local/sbin/smartctl"])
            DispatchQueue.main.async {
                self.installing = false
                self.smartctl = found
                UndoCenter.shared.show(found == nil ? "Couldn't install smartmontools" : "Installed. Reading drive sensors…")
                if found != nil { self.load() }
            }
        }
    }

    /// Read-only First Aid check of the startup volume. Changes nothing.
    func verify() {
        verifying = true; verifyLog = ""; verifyResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Shell.run("/usr/sbin/diskutil", ["verifyVolume", "/"], timeout: 900)
            let ok = out.lowercased().contains("appears to be ok") || out.lowercased().contains("appear to be ok")
            DispatchQueue.main.async {
                self.verifyLog = out.isEmpty ? "macOS didn't allow a check of the running startup volume from here. Disk Utility → First Aid can run it." : out
                self.verifyResult = out.isEmpty ? nil : ok
                self.verifying = false
            }
        }
    }
}

// MARK: - Page

struct DiskHealthView: View {
    @StateObject private var m = DiskHealthModel()
    @State private var sort = ColumnSort(key: "used", ascending: false)
    @State private var fName = ""
    @State private var fFormat: Set<String> = []
    @State private var showLog = false

    private var vols: [VolumeInfo] {
        let l = m.volumes.filter { TextFilter.matches($0.name, fName) && (fFormat.isEmpty || fFormat.contains($0.format)) }
        let s: [VolumeInfo]
        switch sort.key {
        case "name": s = l.sorted { $0.name < $1.name }
        case "size": s = l.sorted { $0.total < $1.total }
        case "free": s = l.sorted { $0.importantFree < $1.importantFree }
        default: s = l.sorted { $0.usedFraction < $1.usedFraction }
        }
        return sort.ascending ? s : s.reversed()
    }

    var body: some View {
        ToolPage(tool: .diskhealth, trailing: {
            HStack {
                Button("Open Disk Utility") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")) }
                Button { m.load() } label: { Image(systemName: "arrow.clockwise") }
            }
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if m.loading && m.drives.isEmpty { ProgressView("Reading drives…").frame(maxWidth: .infinity).padding(30) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14)], spacing: 14) {
                        ForEach(m.drives) { d in driveCard(d) }
                    }
                    if m.smartctl == nil { sensorCard }

                    Text("VOLUMES").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ColumnHeader("Volume", sortKey: "name", sort: $sort, text: $fName)
                            ColumnHeader("Format", width: 140, sort: $sort,
                                         options: Array(Set(m.volumes.map(\.format))).sorted().map { f in FilterOption(id: f, label: f, count: m.volumes.filter { $0.format == f }.count) },
                                         selection: $fFormat)
                            ColumnHeader("Size", width: 90, sortKey: "size", sort: $sort, defaultAscending: false)
                            ColumnHeader("Available", width: 100, sortKey: "free", sort: $sort, defaultAscending: false)
                            ColumnHeader("Purgeable", width: 90, sort: $sort)
                            ColumnHeader("Used", width: 140, sortKey: "used", sort: $sort, defaultAscending: false)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        Rectangle().fill(Theme.stroke).frame(height: 0.5)
                        ForEach(vols) { v in
                            HStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: v.url.path)).resizable().frame(width: 18, height: 18)
                                    Text(v.name).lineLimit(1)
                                }
                                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                                Text(v.format).foregroundStyle(.secondary).lineLimit(1).frame(width: 140, alignment: .leading)
                                Text(Fmt.bytes(v.total)).frame(width: 90, alignment: .leading)
                                Text(Fmt.bytes(v.importantFree)).frame(width: 100, alignment: .leading)
                                Text(v.purgeable > 0 ? Fmt.bytes(v.purgeable) : "—").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                HStack(spacing: 6) {
                                    ProgressView(value: v.usedFraction).tint(Theme.load(v.usedFraction * 100)).frame(width: 80)
                                    Text(Fmt.pct(v.usedFraction * 100)).foregroundStyle(.secondary)
                                }
                                .frame(width: 140, alignment: .leading)
                            }
                            .font(.ui(size: 12)).monospacedDigit()
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(v.url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([v.url]) }
                                if v.url.path.hasPrefix("/Volumes/") {
                                    Divider()
                                    Button("Eject") {
                                        try? NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
                                        m.load()
                                    }
                                }
                            }
                        }
                    }
                    .glass(12)
                    Text("Purgeable space is held by caches and iCloud copies that macOS frees on its own when it needs room.")
                        .font(.ui(size: 11)).foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TIME MACHINE SNAPSHOTS ON THIS MAC").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                            Text(m.snapshots.isEmpty ? "None stored locally." : "\(m.snapshots.count) local snapshot\(m.snapshots.count == 1 ? "" : "s").")
                                .font(.ui(size: 13, weight: .semibold))
                            Text("macOS keeps these for up to 24 hours and deletes them automatically when space runs low. They count toward purgeable space.")
                                .font(.ui(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass(12)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("FIRST AID CHECK").font(.ui(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                            HStack {
                                if m.verifying { ProgressView().controlSize(.small); Text("Checking the startup volume…").font(.ui(size: 12)) }
                                else if let ok = m.verifyResult {
                                    Label(ok ? "No problems found" : "Problems found. Run First Aid in Disk Utility.",
                                          systemImage: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(ok ? Theme.good : Theme.warn).font(.ui(size: 13, weight: .semibold))
                                } else {
                                    Text("Read-only: looks for file system damage without changing anything.").font(.ui(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Button("Check Startup Volume") { m.verify() }.disabled(m.verifying)
                                if !m.verifyLog.isEmpty { Button(showLog ? "Hide details" : "Details") { showLog.toggle() } }
                            }
                            .controlSize(.small)
                            if showLog {
                                ScrollView { Text(m.verifyLog).font(.ui(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(height: 140)
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass(12)
                    }
                }
            }
        }
        .onAppear { if m.drives.isEmpty { m.load() } }
    }

    private func color(_ h: DriveInfo.Health) -> Color {
        switch h {
        case .good: return Theme.good
        case .watch: return Theme.net
        case .critical: return Theme.warn
        case .unknown: return Color.secondary
        }
    }

    private func driveCard(_ d: DriveInfo) -> some View {
        let h = d.health
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: d.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                    .font(.ui(size: 24)).foregroundStyle(color(h.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.ui(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(d.isInternal ? "Internal" : "External") \(d.isSSD ? "SSD" : "drive") · \(d.bus) · \(Fmt.bytes(d.size)) · \(d.id)")
                        .font(.ui(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(h.1).font(.ui(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(color(h.0).opacity(0.15), in: Capsule())
                    .foregroundStyle(color(h.0))
            }
            if let s = d.detail, let p = s.percentUsed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Wear").font(.ui(size: 12))
                        Spacer()
                        Text("\(p)% of rated life used").font(.ui(size: 12, weight: .medium))
                    }
                    ProgressView(value: Double(min(p, 100)), total: 100).tint(p >= 80 ? Theme.warn : p >= 50 ? Theme.net : Theme.good)
                }
            }
            VStack(spacing: 5) {
                row("SMART status", d.smart)
                if let t = d.trim, !t.isEmpty { row("TRIM", t) }
                if let s = d.detail {
                    if let hrs = s.powerOnHours { row("In use for", "\(hrs.formatted()) hours (\(hrs / 24) days)") }
                    if let w = s.bytesWritten { row("Data written", Fmt.bytes(w)) }
                    if let r = s.bytesRead { row("Data read", Fmt.bytes(r)) }
                    if let t = s.temperature { row("Temperature", "\(t) °C") }
                    if let sp = s.spare { row("Spare blocks", "\(sp)%" + (s.spareThreshold.map { " (warns at \($0)%)" } ?? "")) }
                    if let e = s.mediaErrors { row("Media errors", "\(e)") }
                    if let u = s.unsafeShutdowns { row("Unexpected power losses", "\(u)") }
                    if let c = s.powerCycles { row("Power cycles", c.formatted()) }
                }
            }
            ForEach(h.2, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.ui(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .glass(12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open Disk Utility") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")) }
            Button("Copy Health Report") {
                var lines = ["\(d.name) (\(d.id))", "Health: \(h.1)", "SMART: \(d.smart)"]
                if let s = d.detail {
                    if let p = s.percentUsed { lines.append("Wear: \(p)%") }
                    if let hrs = s.powerOnHours { lines.append("Hours: \(hrs)") }
                    if let t = s.temperature { lines.append("Temperature: \(t) °C") }
                }
                lines += h.2
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            }
            Button("Check Again") { m.load() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).monospacedDigit()
        }
        .font(.ui(size: 12))
    }

    private var sensorCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sensor.tag.radiowaves.forward").font(.ui(size: 22)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Want wear, hours and temperature?").font(.ui(size: 13, weight: .semibold))
                Text("macOS only reports pass or fail. The free smartmontools package reads the drive's full health log (it's what most disk tools use).")
                    .font(.ui(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if m.brew != nil {
                        Button(m.installing ? "Installing…" : "Install with Homebrew") { m.installSmartctl() }
                            .buttonStyle(.borderedProminent).disabled(m.installing)
                    }
                    Button("Copy install command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install smartmontools", forType: .string)
                        UndoCenter.shared.show("Copied: brew install smartmontools")
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(12)
    }
}
