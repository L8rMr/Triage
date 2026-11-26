import Foundation
import Darwin
import IOKit
import IOKit.ps

struct BatteryInfo {
    var percent: Double
    var charging: Bool
    var onAC: Bool
    var minutesLeft: Int?
    var cycles: Int?
    var health: Double?
}

struct SystemSnapshot {
    var cpu: Double = 0
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressureLevel: Int = 1
    var netIn: Double = 0
    var netOut: Double = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var battery: BatteryInfo?
    var thermal: ProcessInfo.ThermalState = .nominal

    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }
}

/// Whole-machine numbers: CPU ticks, VM stats, interfaces, power, disk.
final class SystemStats {
    private var lastTicks: [UInt64]?
    private var lastNet: (inB: UInt64, outB: UInt64, time: UInt64)?
    private var tickCount = 0
    private var cachedBattery: BatteryInfo?
    private var cachedDisk: (free: Int64, total: Int64) = (0, 0)

    func snapshot() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.cpu = cpuLoad()
        memory(&s)
        network(&s)
        if tickCount % 10 == 0 {
            cachedBattery = Self.battery()
            cachedDisk = Self.disk()
        }
        tickCount += 1
        s.battery = cachedBattery
        s.diskFree = cachedDisk.free
        s.diskTotal = cachedDisk.total
        s.thermal = ProcessInfo.processInfo.thermalState
        return s
    }

    private func cpuLoad() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reb, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t: [UInt64] = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1),
                           UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { lastTicks = t }
        guard let l = lastTicks else { return 0 }
        let d = zip(t, l).map { $0 >= $1 ? $0 - $1 : 0 }
        let total = d.reduce(0, +)
        guard total > 0 else { return 0 }
        // user + system + nice over everything
        return Double(d[0] + d[1] + d[3]) / Double(total) * 100
    }

    private func memory(_ s: inout SystemSnapshot) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reb, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(getpagesize())
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            s.memApp = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            s.memWired = UInt64(vm.wire_count) * page
            s.memCompressed = UInt64(vm.compressor_page_count) * page
            s.memUsed = s.memApp + s.memWired + s.memCompressed
        }
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            s.pressureLevel = Int(level)
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
        }
    }

    private func network(_ s: inout SystemSnapshot) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        var inB: UInt64 = 0
        var outB: UInt64 = 0
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                if !name.hasPrefix("lo") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    inB += UInt64(d.ifi_ibytes)
                    outB += UInt64(d.ifi_obytes)
                }
            }
            cur = ifa.ifa_next
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if let l = lastNet, now > l.time {
            let dt = Double(now - l.time) / 1e9
            s.netIn = inB >= l.inB ? Double(inB - l.inB) / dt : 0
            s.netOut = outB >= l.outB ? Double(outB - l.outB) / dt : 0
        }
        lastNet = (inB, outB, now)
    }

    static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = max(d[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            var info = BatteryInfo(
                percent: Double(cur) / Double(mx) * 100,
                charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                minutesLeft: (d[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            )
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                func prop(_ k: String) -> Int? {
                    IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Int
                }
                info.cycles = prop("CycleCount")
                if let design = prop("DesignCapacity"), design > 0, let raw = prop("AppleRawMaxCapacity") {
                    info.health = min(Double(raw) / Double(design) * 100, 100)
                }
                IOObjectRelease(service)
            }
            return info
        }
        return nil
    }

    static func disk() -> (free: Int64, total: Int64) {
        let url = URL(fileURLWithPath: "/")
        let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
