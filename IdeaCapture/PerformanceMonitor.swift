import Foundation
import os.log

struct PerformanceMetrics {
    let timestamp: Date
    let appLaunchTime: TimeInterval
    let memoryUsageMB: Double
    let cpuUsagePercent: Double
}

@MainActor
class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()

    @Published var metrics: [PerformanceMetrics] = []
    @Published var currentMemoryUsage: Double = 0.0
    @Published var currentCPUUsage: Double = 0.0

    private var launchStartTime: Date?
    private var launchEndTime: Date?
    private var monitoringTimer: Timer?

    private init() {}

    // MARK: - App Launch Time Measurement

    func startLaunchMeasurement() {
        launchStartTime = Date()
    }

    func endLaunchMeasurement() {
        launchEndTime = Date()
    }

    var appLaunchTime: TimeInterval {
        guard let start = launchStartTime, let end = launchEndTime else {
            return 0
        }
        return end.timeIntervalSince(start)
    }

    // MARK: - Memory Usage

    func measureMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }

        if kerr == KERN_SUCCESS {
            let memoryUsageBytes = Double(info.resident_size)
            let memoryUsageMB = memoryUsageBytes / (1024 * 1024)
            return memoryUsageMB
        } else {
            os_log("メモリ使用量の取得に失敗しました: %{public}d", log: .default, type: .error, kerr)
            return 0
        }
    }

    // MARK: - CPU Usage

    func measureCPUUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        let kerr = task_threads(mach_task_self_, &threadList, &threadCount)

        guard kerr == KERN_SUCCESS, let threads = threadList else {
            return 0
        }

        var totalCPU: Double = 0

        for i in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

            let infoKerr = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    thread_info(threads[i],
                               thread_flavor_t(THREAD_BASIC_INFO),
                               $0,
                               &threadInfoCount)
                }
            }

            if infoKerr == KERN_SUCCESS {
                if threadInfo.flags & TH_FLAGS_IDLE == 0 {
                    totalCPU += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                }
            }
        }

        // スレッドリストを解放
        vm_deallocate(mach_task_self_,
                     vm_address_t(bitPattern: threads),
                     vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))

        return totalCPU
    }

    // MARK: - Continuous Monitoring

    func startMonitoring(interval: TimeInterval = 1.0) {
        stopMonitoring()

        monitoringTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentMemoryUsage = self.measureMemoryUsage()
                self.currentCPUUsage = self.measureCPUUsage()
            }
        }
    }

    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }

    // MARK: - Snapshot

    func captureSnapshot() {
        let metric = PerformanceMetrics(
            timestamp: Date(),
            appLaunchTime: appLaunchTime,
            memoryUsageMB: measureMemoryUsage(),
            cpuUsagePercent: measureCPUUsage()
        )
        metrics.append(metric)
    }

    // MARK: - Report Generation

    func generateReport() -> String {
        var report = "=== IdeaCapture パフォーマンスレポート ===\n\n"
        report += "生成日時: \(Date().formatted())\n\n"

        // アプリ起動時間
        report += "## アプリ起動時間\n"
        report += String(format: "%.3f 秒\n\n", appLaunchTime)

        // メモリ使用量統計
        if !metrics.isEmpty {
            let memoryUsages = metrics.map { $0.memoryUsageMB }
            let avgMemory = memoryUsages.reduce(0, +) / Double(memoryUsages.count)
            let maxMemory = memoryUsages.max() ?? 0
            let minMemory = memoryUsages.min() ?? 0

            report += "## メモリ使用量\n"
            report += String(format: "現在: %.2f MB\n", currentMemoryUsage)
            report += String(format: "平均: %.2f MB\n", avgMemory)
            report += String(format: "最大: %.2f MB\n", maxMemory)
            report += String(format: "最小: %.2f MB\n\n", minMemory)
        } else {
            report += "## メモリ使用量\n"
            report += String(format: "現在: %.2f MB\n\n", currentMemoryUsage)
        }

        // CPU使用率統計
        if !metrics.isEmpty {
            let cpuUsages = metrics.map { $0.cpuUsagePercent }
            let avgCPU = cpuUsages.reduce(0, +) / Double(cpuUsages.count)
            let maxCPU = cpuUsages.max() ?? 0
            let minCPU = cpuUsages.min() ?? 0

            report += "## CPU使用率\n"
            report += String(format: "現在: %.2f%%\n", currentCPUUsage)
            report += String(format: "平均: %.2f%%\n", avgCPU)
            report += String(format: "最大: %.2f%%\n", maxCPU)
            report += String(format: "最小: %.2f%%\n\n", minCPU)
        } else {
            report += "## CPU使用率\n"
            report += String(format: "現在: %.2f%%\n\n", currentCPUUsage)
        }

        // 詳細履歴
        if !metrics.isEmpty {
            report += "## 測定履歴 (直近\(min(10, metrics.count))件)\n"
            for metric in metrics.suffix(10) {
                report += "\n[\(metric.timestamp.formatted())]\n"
                report += String(format: "  メモリ: %.2f MB\n", metric.memoryUsageMB)
                report += String(format: "  CPU: %.2f%%\n", metric.cpuUsagePercent)
            }
        }

        return report
    }

    func clearMetrics() {
        metrics.removeAll()
    }
}
