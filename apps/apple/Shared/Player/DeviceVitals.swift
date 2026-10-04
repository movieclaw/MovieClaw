import Foundation
import Darwin
#if canImport(UIKit)
import UIKit
#endif

/// 设备体征读数：开发期的引擎能耗对比（docs/design/player-engine.md 第 6 节），以及播放记录的资源读数
/// （docs/design/playback-qoe.md §3.4，Release 包也用，10 秒采一次，开销可以忽略）。
///
/// 开发期每 10 秒随播放打一行 `[Vitals]`：温度状态、电量与充电状态、本进程 CPU、内存占用、低电量模式。
/// 注意口径：AVPlayer 的解码与合成在系统进程（mediaserverd / 硬件解码器）里做，**不计入本进程 CPU**；
/// 自研引擎软件通路的解码在本进程里。所以不同通路的「本进程 CPU」不能直接比较谁更省电，
/// 同一部片连播 30 分钟后的温度状态与掉电才是可比的结果。
enum DeviceVitals {
    static func line() -> String {
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "正常"
        case .fair: "偏热"
        case .serious: "严重"
        case .critical: "临界"
        @unknown default: "未知"
        }
        let resources = "本进程CPU=\(String(format: "%.0f", processCPU()))% 内存=\(Int(footprintMB()))MB"
        #if os(iOS)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let battery = device.batteryLevel < 0 ? "?" : "\(Int((device.batteryLevel * 100).rounded()))%"
        let charging = switch device.batteryState {
        case .charging: "充电中"
        case .full: "已充满"
        case .unplugged: "未插电"
        default: "未知"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? " 低电量模式" : ""
        return "温度=\(thermal) 电量=\(battery)(\(charging)) \(resources)\(lowPower)"
        #else
        // Apple TV 插电运行、没有电池；Mac 的电量不影响播放策略，不读
        return "温度=\(thermal) \(resources)"
        #endif
    }

    /// 本进程所有线程的 CPU 占用之和（100 = 占满一个核）
    static func processCPU() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let task = mach_task_self_
        guard task_threads(task, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
        defer {
            vm_deallocate(task, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0 ..< Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    /// 本进程的内存占用（phys_footprint，系统按它判定内存超限）
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
