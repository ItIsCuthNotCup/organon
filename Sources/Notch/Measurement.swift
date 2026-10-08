import Foundation
import Darwin
import NotchCore

enum NotchMeasurement {
    @MainActor
    static func run() async {
        let store = CoActivityStore()
        let pipeline = ClassificationPipeline.defaults(corrections: [], rules: DefaultRules.rules, store: store)
        var durations: [Double] = []
        var windowCount = 0
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let windows = await Task.detached(priority: .userInitiated) {
                WindowEnumerator.enumerate()
            }.value
            windowCount = windows.count
            _ = await pipeline.groups(windows.map(\.features))
            durations.append(Double(start.duration(to: .now).components.attoseconds) / 1_000_000_000_000_000 +
                              Double(start.duration(to: .now).components.seconds) * 1_000)
        }
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        print(String(format: "Enumeration + classification: median %.2f ms, p95 %.2f ms, windows %d",
                     median, p95, windowCount))
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            var vmInfo = task_vm_info_data_t()
            var vmCount = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let vmResult = withUnsafeMutablePointer(to: &vmInfo) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
                }
            }
            if vmResult == KERN_SUCCESS {
                print(String(format: "Memory: rss MB %.2f, footprint MB %.2f",
                             Double(info.resident_size) / 1_048_576,
                             Double(vmInfo.phys_footprint) / 1_048_576))
            } else {
                print(String(format: "Memory: rss MB %.2f, footprint MB unavailable",
                             Double(info.resident_size) / 1_048_576))
            }
        }
    }
}
