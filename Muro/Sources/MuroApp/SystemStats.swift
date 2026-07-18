import Foundation
import Darwin

/// Live CPU% / RAM of this process (app + embedded engine) for the
/// menu-bar stats block. CPU is the delta of task time between samples.
final class StatsSampler {
    private var lastCPUTime: Double = 0
    private var lastSampleAt = Date.distantPast

    func sample() -> (cpuPercent: Double, ramMB: Double) {
        let now = Date()
        let cpuTime = Self.taskCPUSeconds()
        let wall = now.timeIntervalSince(lastSampleAt)
        var percent = 0.0
        if wall > 0.1, wall < 60, lastCPUTime > 0 {
            percent = max(0, (cpuTime - lastCPUTime) / wall * 100)
        }
        lastCPUTime = cpuTime
        lastSampleAt = now
        return (percent, Self.residentMB())
    }

    private static func taskCPUSeconds() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return user + system
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }
}
