import Foundation
import Darwin

/// Writes VitalOS's own CPU and memory use once a minute to TestFiles/perf.log (only when that folder exists).
final class PerfLog {
    static let shared = PerfLog()
    private let url: URL?
    private var lastCPU: Double = PerfLog.cpuSeconds()
    private var lastTime = Date()
    private var lastWrite = Date.distantPast

    private init() {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects/VitalOS/TestFiles")
        var isDir: ObjCBool = false
        url = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue ? dir.appendingPathComponent("perf.log") : nil
    }

    func tick() {
        guard let url, UserDefaults.standard.object(forKey: "perf.log") as? Bool ?? true, Date().timeIntervalSince(lastWrite) >= 60 else { return }
        let now = Date(), cpu = PerfLog.cpuSeconds()
        let pct = (cpu - lastCPU) / max(now.timeIntervalSince(lastTime), 0.001) * 100
        lastCPU = cpu; lastTime = now; lastWrite = now
        let line = String(format: "%@ cpu=%.1f%% mem=%.0fMB showing=%@\n",
                          ISO8601DateFormatter().string(from: now), pct, PerfLog.footprintMB(), AppVisibility.anythingShowing ? "yes" : "no")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Same "Memory" number Activity Monitor shows.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
