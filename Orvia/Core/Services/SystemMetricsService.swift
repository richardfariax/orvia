import Combine
import Foundation

@MainActor
final class SystemMetricsService: ObservableObject {
    @Published private(set) var snapshot = SystemMetricsSnapshot.empty
    @Published private(set) var cpuHistory: [MetricHistoryPoint] = []
    @Published private(set) var memoryHistory: [MetricHistoryPoint] = []
    @Published private(set) var gpuHistory: [MetricHistoryPoint] = []
    @Published private(set) var temperatureHistory: [MetricHistoryPoint] = []
    @Published private(set) var fanHistory: [MetricHistoryPoint] = []
    @Published private(set) var storageHistory: [MetricHistoryPoint] = []
    @Published private(set) var diskHistory: [MetricHistoryPoint] = []
    @Published private(set) var networkHistory: [MetricHistoryPoint] = []
    @Published private(set) var powerHistory: [MetricHistoryPoint] = []
    @Published private(set) var thermalSensorHistories: [String: [MetricHistoryPoint]] = [:]
    @Published private(set) var fanHistories: [Int: [MetricHistoryPoint]] = [:]

    let hardware: SystemHardwareInfo
    private(set) var isRunning = false

    private let cpuSampler = CPUMetricsSampler()
    private let memorySampler = MemoryMetricsSampler()
    private let gpuSampler: GPUMetricsSampler
    private let thermalSampler = ThermalMetricsSampler()
    private let fanSampler = FanMetricsSampler()
    private let storageSampler = StorageMetricsSampler()
    private let networkSampler = NetworkMetricsSampler()
    private let powerSampler = PowerMetricsSampler()
    private let sampleInterval: TimeInterval
    private let historyLimit: Int
    private var timer: Timer?
    private var isSampling = false

    init(sampleInterval: TimeInterval = 2, historyLimit: Int = 90) {
        let gpuSampler = GPUMetricsSampler()
        self.gpuSampler = gpuSampler
        self.sampleInterval = max(sampleInterval, 0.5)
        self.historyLimit = max(historyLimit, 10)
        hardware = SystemHardwareInfo.current(
            gpuName: gpuSampler.deviceName,
            gpuCoreCount: gpuSampler.coreCount
        )
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()

        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func refresh() {
        guard !isSampling else { return }
        isSampling = true
        let previousSnapshot = snapshot

        let samplingTask = Task.detached(priority: .utility) { [cpuSampler, memorySampler, gpuSampler, thermalSampler, fanSampler, storageSampler, networkSampler, powerSampler] in
            let now = Date()
            return SystemMetricsSnapshot(
                timestamp: now,
                cpu: cpuSampler.sample() ?? previousSnapshot.cpu,
                memory: memorySampler.sample() ?? previousSnapshot.memory,
                gpu: gpuSampler.sample(),
                thermal: thermalSampler.sample(),
                fans: fanSampler.sample(),
                storage: storageSampler.sample(at: now),
                network: networkSampler.sample(at: now),
                power: powerSampler.sample()
            )
        }

        Task { [weak self] in
            let updatedSnapshot = await samplingTask.value
            guard let self else { return }
            self.apply(updatedSnapshot)
        }
    }

    private func apply(_ updatedSnapshot: SystemMetricsSnapshot) {
        snapshot = updatedSnapshot
        isSampling = false

        append(updatedSnapshot.cpu.total, at: updatedSnapshot.timestamp, to: &cpuHistory)
        append(updatedSnapshot.memory.usedFraction, at: updatedSnapshot.timestamp, to: &memoryHistory)
        if let gpu = updatedSnapshot.gpu {
            append(gpu.device, at: updatedSnapshot.timestamp, to: &gpuHistory)
        }
        if let temperature = updatedSnapshot.thermal.peakTemperature {
            append(temperature, at: updatedSnapshot.timestamp, to: &temperatureHistory)
        }
        for sensor in updatedSnapshot.thermal.sensors {
            var history = thermalSensorHistories[sensor.id] ?? []
            append(sensor.temperature, at: updatedSnapshot.timestamp, to: &history)
            thermalSensorHistories[sensor.id] = history
        }
        if let averageRPM = updatedSnapshot.fans.averageRPM {
            append(averageRPM, at: updatedSnapshot.timestamp, to: &fanHistory)
        }
        for fan in updatedSnapshot.fans.fans {
            var history = fanHistories[fan.id] ?? []
            append(fan.currentRPM, at: updatedSnapshot.timestamp, to: &history)
            fanHistories[fan.id] = history
        }
        append(updatedSnapshot.storage.usedFraction, at: updatedSnapshot.timestamp, to: &storageHistory)
        append(
            updatedSnapshot.storage.readBytesPerSecond + updatedSnapshot.storage.writeBytesPerSecond,
            at: updatedSnapshot.timestamp,
            to: &diskHistory
        )
        append(updatedSnapshot.network.downloadBytesPerSecond, at: updatedSnapshot.timestamp, to: &networkHistory)
        if let watts = updatedSnapshot.power.powerWatts {
            append(watts, at: updatedSnapshot.timestamp, to: &powerHistory)
        }
    }

    private func append(_ value: Double, at date: Date, to history: inout [MetricHistoryPoint]) {
        history.append(MetricHistoryPoint(timestamp: date, value: value))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}
