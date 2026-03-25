import Foundation
import Metal
import os

private let logger = Logger(subsystem: "com.locus.app", category: "metrics")

/// Tracks app memory, GPU memory, CPU usage, and thermal state in real time.
@MainActor
final class SystemMetrics: ObservableObject {
    @Published var memoryMB: Double = 0
    @Published var gpuMemoryMB: Double = 0
    @Published var cpuPercent: Double = 0
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var componentMemory: [String: Double] = [:]

    private var timer: Timer?
    private let metalDevice = MTLCreateSystemDefaultDevice()

    private var appBaselineMemory: Double = 0
    private var lastSnapshotMemory: Double = 0

    init() {}

    func startMonitoring(interval: TimeInterval = 1.0) {
        update()
        appBaselineMemory = Self.appMemoryMB()
        lastSnapshotMemory = appBaselineMemory
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

    func beginTracking(_ component: String) {
        lastSnapshotMemory = Self.appMemoryMB()
        componentMemory[component] = -1
        let snap = lastSnapshotMemory
        logger.info("[\(component)] loading... snapshot: \(snap, format: .fixed(precision: 1)) MB")
    }

    func endTracking(_ component: String) {
        let mem = Self.appMemoryMB()
        let delta = mem - lastSnapshotMemory
        componentMemory[component] = max(0, delta)
        lastSnapshotMemory = mem
        logger.info("[\(component)] loaded. delta: \(delta, format: .fixed(precision: 1)) MB, total app: \(mem, format: .fixed(precision: 1)) MB")
    }

    func clearTracking(_ component: String) {
        componentMemory.removeValue(forKey: component)
    }

    var trackedMemoryMB: Double {
        componentMemory.values.filter { $0 > 0 }.reduce(0, +)
    }

    var otherMemoryMB: Double {
        max(0, memoryMB - appBaselineMemory - trackedMemoryMB)
    }

    var baselineMemoryMB: Double { appBaselineMemory }

    var thermalStateLabel: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var thermalStateColor: String {
        switch thermalState {
        case .nominal: return "green"
        case .fair: return "yellow"
        case .serious: return "orange"
        case .critical: return "red"
        @unknown default: return "gray"
        }
    }

    // MARK: - Private

    private func update() {
        memoryMB = Self.appMemoryMB()
        gpuMemoryMB = Double(metalDevice?.currentAllocatedSize ?? 0) / (1024 * 1024)
        cpuPercent = Self.appCPUPercent()
        thermalState = ProcessInfo.processInfo.thermalState
    }

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
