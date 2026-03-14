import Foundation
import os

private let logger = Logger(subsystem: "com.locus.app", category: "metrics")

/// Tracks app memory and CPU usage in real time, with per-component memory snapshots.
@MainActor
final class SystemMetrics: ObservableObject {
    @Published var memoryMB: Double = 0
    @Published var cpuPercent: Double = 0
    @Published var componentMemory: [String: Double] = [:]  // component name → MB used
    @Published var isVisible: Bool = true

    private var timer: Timer?

    init() {}

    func startMonitoring(interval: TimeInterval = 1.0) {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.update()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Call before loading a component to snapshot baseline memory.
    func beginTracking(_ component: String) {
        let mem = Self.appMemoryMB()
        componentMemory[component] = -mem  // store negative baseline, will add final later
        logger.info("[\(component)] loading... baseline: \(mem, format: .fixed(precision: 1)) MB")
    }

    /// Call after loading a component to record its memory delta.
    func endTracking(_ component: String) {
        let mem = Self.appMemoryMB()
        let baseline = -(componentMemory[component] ?? 0)
        let delta = mem - baseline
        componentMemory[component] = max(0, delta)
        logger.info("[\(component)] loaded. delta: \(delta, format: .fixed(precision: 1)) MB, total app: \(mem, format: .fixed(precision: 1)) MB")
    }

    /// Remove tracking for a component (e.g. when unloaded).
    func clearTracking(_ component: String) {
        componentMemory.removeValue(forKey: component)
        logger.info("[\(component)] unloaded")
    }

    // MARK: - Private

    private func update() {
        memoryMB = Self.appMemoryMB()
        cpuPercent = Self.appCPUPercent()
    }

    /// App physical footprint in MB via task_vm_info (matches Xcode's memory gauge).
    static func appMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    /// App CPU usage as a percentage via thread_info.
    static func appCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return 0 }

        var totalCPU: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if result == KERN_SUCCESS && info.flags & TH_FLAGS_IDLE == 0 {
                totalCPU += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }

        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size))

        return totalCPU
    }
}
