import Foundation
import IOKit

/// Samples system load — CPU, GPU, and RAM — without root.
/// - CPU: Mach `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas between samples.
/// - GPU: IOKit `IOAccelerator` → `PerformanceStatistics` → "Device Utilization %".
/// - RAM: Mach `host_statistics64(HOST_VM_INFO64)` (active + wired + compressed) / physical.
///
/// All three are read in-process (no subprocess) and only while the Load tab is
/// open, so this adds no steady-state cost.
@MainActor
@Observable
final class SystemLoadMonitor {
    static let shared = SystemLoadMonitor()

    var cpu: Double = 0   // 0–100, busy % across all cores
    var gpu: Double = 0   // 0–100, device utilization
    var ram: Double = 0   // 0–100, used (active+wired+compressed) / physical

    @ObservationIgnored private var prevBusy: UInt64 = 0
    @ObservationIgnored private var prevTotal: UInt64 = 0

    private init() {}

    func sample() {
        if let c = sampleCPU() { cpu = c }
        if let g = Self.sampleGPU() { gpu = g }
        if let r = Self.sampleRAM() { ram = r }
    }

    // MARK: - CPU (tick deltas)

    private func sampleCPU() -> Double? {
        guard let (busy, total) = Self.cpuTicks() else { return nil }
        let dBusy = busy &- prevBusy
        let dTotal = total &- prevTotal
        let hadPrev = prevTotal != 0
        prevBusy = busy
        prevTotal = total
        guard hadPrev, dTotal > 0 else { return nil }  // first call just seeds
        return min(100, max(0, Double(dBusy) / Double(dTotal) * 100))
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)   // CPU_STATE_USER
        let sys  = UInt64(info.cpu_ticks.1)   // CPU_STATE_SYSTEM
        let idle = UInt64(info.cpu_ticks.2)   // CPU_STATE_IDLE
        let nice = UInt64(info.cpu_ticks.3)   // CPU_STATE_NICE
        let busy = user + sys + nice
        return (busy, busy + idle)
    }

    // MARK: - GPU (IOAccelerator)

    private static func sampleGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var result: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any],
               let util = perf["Device Utilization %"] as? Int {
                result = max(result ?? 0, Double(util))  // pick the busiest accelerator (the real GPU)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result.map { min(100, max(0, $0)) }
    }

    // MARK: - RAM

    private static func sampleRAM() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pageSize = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return min(100, max(0, used / total * 100))
    }
}
