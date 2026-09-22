import Foundation

struct MetricHistoryPoint: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

struct CPUUsage: Equatable {
    let user: Double
    let system: Double
    let idle: Double

    var total: Double { min(max(user + system, 0), 1) }

    static let zero = CPUUsage(user: 0, system: 0, idle: 1)
}

struct MemoryUsage: Equatable {
    let usedBytes: UInt64
    let cachedBytes: UInt64
    let compressedBytes: UInt64
    let wiredBytes: UInt64
    let totalBytes: UInt64
    let swapUsedBytes: UInt64

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    var availableBytes: UInt64 {
        totalBytes > usedBytes ? totalBytes - usedBytes : 0
    }

    static let zero = MemoryUsage(
        usedBytes: 0,
        cachedBytes: 0,
        compressedBytes: 0,
        wiredBytes: 0,
        totalBytes: ProcessInfo.processInfo.physicalMemory,
        swapUsedBytes: 0
    )
}

struct GPUUsage: Equatable {
    let device: Double
    let renderer: Double?
    let tiler: Double?
    let allocatedBytes: UInt64?

    static let unavailable = GPUUsage(device: 0, renderer: nil, tiler: nil, allocatedBytes: nil)
}

enum ThermalSensorGroup: String, CaseIterable, Equatable {
    case cpu
    case gpu
    case soc
    case memory
    case battery
    case storage
    case enclosure
    case other

    var sortOrder: Int {
        switch self {
        case .cpu: 0
        case .gpu: 1
        case .soc: 2
        case .memory: 3
        case .battery: 4
        case .storage: 5
        case .enclosure: 6
        case .other: 7
        }
    }
}

struct ThermalSensorReading: Identifiable, Equatable {
    let id: String
    let ordinal: Int
    let hardwareName: String?
    let group: ThermalSensorGroup
    let temperature: Double
}

struct ThermalMetrics: Equatable {
    let sensors: [ThermalSensorReading]

    var peakTemperature: Double? { sensors.map(\.temperature).max() }
    var averageTemperature: Double? {
        guard !sensors.isEmpty else { return nil }
        return sensors.map(\.temperature).reduce(0, +) / Double(sensors.count)
    }
    var sensorCount: Int { sensors.count }

    static let unavailable = ThermalMetrics(sensors: [])
}

struct FanReading: Identifiable, Equatable {
    let id: Int
    let currentRPM: Double
    let minimumRPM: Double?
    let maximumRPM: Double?
}

struct FanMetrics: Equatable {
    let fans: [FanReading]

    var averageRPM: Double? {
        guard !fans.isEmpty else { return nil }
        return fans.map(\.currentRPM).reduce(0, +) / Double(fans.count)
    }

    var peakRPM: Double? { fans.map(\.currentRPM).max() }
    var chartMaximum: Double {
        max(fans.compactMap(\.maximumRPM).max() ?? peakRPM ?? 1, 1)
    }

    static let unavailable = FanMetrics(fans: [])
}

struct StorageMetrics: Equatable {
    let volumeName: String
    let totalBytes: UInt64
    let availableBytes: UInt64
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double

    var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    static let unavailable = StorageMetrics(
        volumeName: "Macintosh HD",
        totalBytes: 0,
        availableBytes: 0,
        readBytesPerSecond: 0,
        writeBytesPerSecond: 0
    )
}

struct NetworkMetrics: Equatable {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let activeInterfaces: [String]

    static let zero = NetworkMetrics(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0, activeInterfaces: [])
}

enum PowerSource: String, Equatable {
    case battery
    case external
    case unknown
}

struct PowerMetrics: Equatable {
    let source: PowerSource
    let batteryLevel: Double?
    let isCharging: Bool
    let powerWatts: Double?
    let cycleCount: Int?
    let healthPercent: Double?
    let timeRemainingMinutes: Int?

    static let unavailable = PowerMetrics(
        source: .unknown,
        batteryLevel: nil,
        isCharging: false,
        powerWatts: nil,
        cycleCount: nil,
        healthPercent: nil,
        timeRemainingMinutes: nil
    )
}

enum MenuBarMetric: String, CaseIterable, Identifiable, Codable {
    case cpu
    case gpu
    case memory
    case temperature
    case fans
    case storage
    case network
    case power

    var id: String { rawValue }

    static let statusBarChoices: [MenuBarMetric] = [.cpu, .memory, .temperature, .gpu, .storage, .power]
    static let defaultStatusBarMetrics: [MenuBarMetric] = [.cpu, .memory, .temperature]

    var statusBarSymbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .temperature: "thermometer.medium"
        case .gpu: "display"
        case .storage: "internaldrive"
        case .power: "battery.100"
        case .fans: "fanblades"
        case .network: "network"
        }
    }

    func statusBarTitle(language: AppLanguage) -> String {
        switch self {
        case .cpu: "CPU"
        case .memory: language.text(ptBR: "Memória", en: "Memory")
        case .temperature: language.text(ptBR: "Temperatura", en: "Temperature")
        case .gpu: "GPU"
        case .storage: language.text(ptBR: "Espaço livre", en: "Free space")
        case .power: language.text(ptBR: "Bateria", en: "Battery")
        case .fans: language.text(ptBR: "Ventoinhas", en: "Fans")
        case .network: language.text(ptBR: "Rede", en: "Network")
        }
    }

    func statusBarValue(in snapshot: SystemMetricsSnapshot) -> String {
        switch self {
        case .cpu: snapshot.cpu.total.formatted(.percent.precision(.fractionLength(0)))
        case .memory: snapshot.memory.usedFraction.formatted(.percent.precision(.fractionLength(0)))
        case .temperature:
            snapshot.thermal.peakTemperature.map { String(format: "%.0f°", $0) } ?? "—"
        case .gpu: snapshot.gpu?.device.formatted(.percent.precision(.fractionLength(0))) ?? "—"
        case .storage:
            snapshot.storage.availableBytes > 0
                ? ByteCountFormatter.string(fromByteCount: Int64(snapshot.storage.availableBytes), countStyle: .file)
                : "—"
        case .power:
            snapshot.power.batteryLevel?.formatted(.percent.precision(.fractionLength(0))) ?? "—"
        case .fans: snapshot.fans.averageRPM.map { String(format: "%.0f RPM", $0) } ?? "—"
        case .network: "—"
        }
    }
}

enum MetricsPopoverMode: String, CaseIterable, Identifiable {
    case summary
    case detailed

    var id: String { rawValue }
}

struct SystemMetricsSnapshot: Equatable {
    let timestamp: Date
    let cpu: CPUUsage
    let memory: MemoryUsage
    let gpu: GPUUsage?
    let thermal: ThermalMetrics
    let fans: FanMetrics
    let storage: StorageMetrics
    let network: NetworkMetrics
    let power: PowerMetrics

    static let empty = SystemMetricsSnapshot(
        timestamp: .now,
        cpu: .zero,
        memory: .zero,
        gpu: nil,
        thermal: .unavailable,
        fans: .unavailable,
        storage: .unavailable,
        network: .zero,
        power: .unavailable
    )
}

struct SystemHardwareInfo: Equatable {
    let modelIdentifier: String
    let processorName: String
    let physicalCoreCount: Int
    let logicalCoreCount: Int
    let gpuName: String
    let gpuCoreCount: Int?
    let memoryBytes: UInt64
    let operatingSystem: String

    static func current(gpuName: String, gpuCoreCount: Int?) -> SystemHardwareInfo {
        SystemHardwareInfo(
            modelIdentifier: SystemInformation.sysctlString("hw.model") ?? "Mac",
            processorName: SystemInformation.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            physicalCoreCount: ProcessInfo.processInfo.processorCount,
            logicalCoreCount: ProcessInfo.processInfo.activeProcessorCount,
            gpuName: gpuName,
            gpuCoreCount: gpuCoreCount,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

enum SystemInformation {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}
