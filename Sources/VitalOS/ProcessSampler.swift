import Foundation
import Darwin

struct ProcUsage: Identifiable {
    let pid: pid_t
    let name: String
    let cpu: Double
    let memory: UInt64
    var id: pid_t { pid }
}

/// Every helper rolled up under the app that owns it.
struct AppUsage: Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    var cpu: Double
    var memory: UInt64
    var processes: [ProcUsage]
    var history: [Double] = []
    var isSystem: Bool { id == "macos" }
}

final class ProcessSampler {
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastWall: UInt64 = 0
    private var names: [String: String] = [:]
    private let numer: Double
    private let denom: Double
    private let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = Double(tb.numer)
        denom = Double(max(tb.denom, 1))
    }

    func sample() -> [AppUsage] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let got = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard got > 0 else { return [] }

        let now = DispatchTime.now().uptimeNanoseconds
        let wall = lastWall > 0 && now > lastWall ? Double(now - lastWall) : 0
        var newCPU: [pid_t: UInt64] = [:]
        var groups: [String: AppUsage] = [:]
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let pathCap: UInt32 = 4096
        let nameCap: UInt32 = 256
        var pathBuf = [CChar](repeating: 0, count: Int(pathCap))
        var nameBuf = [CChar](repeating: 0, count: Int(nameCap))

        for pid in pids.prefix(Int(got)) where pid > 0 {
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, taskSize) == taskSize else { continue }
            let ticks = Double(info.pti_total_user) + Double(info.pti_total_system)
            let cpuNs = UInt64(ticks * numer / denom)
            newCPU[pid] = cpuNs
            var cpu = 0.0
            if wall > 0, let prev = lastCPU[pid], cpuNs >= prev {
                // Share of the whole Mac: 100% means every core is busy, matching the overall CPU number.
                cpu = Double(cpuNs - prev) / wall * 100 / cores
            }

            let plen = proc_pidpath(pid, &pathBuf, pathCap)
            let path = plen > 0 ? String(cString: pathBuf) : ""
            var pname = path.isEmpty ? "" : (path as NSString).lastPathComponent
            if pname.isEmpty {
                pname = proc_name(pid, &nameBuf, nameCap) > 0 ? String(cString: nameBuf) : "pid \(pid)"
            }

            let g = group(for: path, name: pname)
            let proc = ProcUsage(pid: pid, name: pname, cpu: cpu, memory: info.pti_resident_size)
            var app = groups[g.key] ?? AppUsage(id: g.key, name: g.display, bundlePath: g.bundle, cpu: 0, memory: 0, processes: [])
            app.cpu += cpu
            app.memory += info.pti_resident_size
            app.processes.append(proc)
            groups[g.key] = app
        }
        lastCPU = newCPU
        lastWall = now

        return groups.values.map { a in
            var a = a
            a.processes.sort { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
            return a
        }
    }

    private func group(for path: String, name: String) -> (key: String, display: String, bundle: String?) {
        // The first ".app/" in the path is the outermost bundle: Chrome's helpers live inside Google Chrome.app.
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]) + ".app"
            if let n = names[bundle] { return (bundle, n, bundle) }
            var n = FileManager.default.displayName(atPath: bundle)
            if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
            names[bundle] = n
            return (bundle, n, bundle)
        }
        let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/"]
        if path.isEmpty || systemPrefixes.contains(where: { path.hasPrefix($0) }) {
            return ("macos", "macOS", nil)
        }
        return ("proc:" + name, name, nil)
    }
}
