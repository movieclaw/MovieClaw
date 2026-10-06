import Foundation
import Darwin

/// 内核也能使用的轻量采样；不读写文件，不启动外部工具。
final class WorkerTelemetry: @unchecked Sendable {
    private let pressureSource = DispatchSource.makeMemoryPressureSource(
        eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility)
    )
    private let lock = NSLock()
    private var pressure = 0
    private var previous: (busy: UInt64, total: UInt64)?

    init() {
        previous = Self.cpuTicks()
        pressureSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.pressureSource.data
            self.lock.lock()
            self.pressure = event.contains(.critical) ? 2 : event.contains(.warning) ? 1 : 0
            self.lock.unlock()
        }
        pressureSource.resume()
    }

    deinit { pressureSource.cancel() }

    static func hardware() -> [String: Any] {
        var size = 0
        var chip = "Apple Silicon"
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
                chip = String(cString: buffer)
            }
        }
        return ["chip": chip, "cpu_cores": ProcessInfo.processInfo.processorCount,
                "memory_bytes": ProcessInfo.processInfo.physicalMemory]
    }

    func sample() -> [String: Any] {
        let ticks = Self.cpuTicks()
        var cpu = 0.0
        if let old = previous, let ticks, ticks.total > old.total, ticks.busy >= old.busy {
            cpu = Double(ticks.busy - old.busy) / Double(ticks.total - old.total)
        }
        previous = ticks
        lock.lock()
        let memoryPressure = pressure
        lock.unlock()
        return ["cpu": min(1, max(0, cpu)), "memory_pressure": memoryPressure,
                "memory_used_bytes": Self.memoryUsed(),
                "thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        return (busy, busy + UInt64(info.cpu_ticks.2))
    }

    private static func memoryUsed() -> UInt64 {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let app = UInt64(info.internal_page_count) - min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))
        return (app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * UInt64(vm_kernel_page_size)
    }
}
