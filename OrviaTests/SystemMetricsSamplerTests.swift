import AppKit
import XCTest
@testable import Orvia

final class SystemMetricsSamplerTests: XCTestCase {
    func testActivityMonitorDestinationsMatchNativeMetricViews() {
        XCTAssertEqual(ActivityMonitorDestination.destination(for: .cpu), .cpu)
        XCTAssertEqual(ActivityMonitorDestination.destination(for: .gpu), .gpuHistory)
        XCTAssertEqual(ActivityMonitorDestination.destination(for: .memory), .memory)
        XCTAssertEqual(ActivityMonitorDestination.destination(for: .temperature), .cpu)
        XCTAssertEqual(ActivityMonitorDestination.destination(for: .fans), .cpu)
        XCTAssertEqual(ActivityMonitorDestination.destination(for: .storage), .disk)
        XCTAssertEqual(ActivityMonitorDestination.destination(for: .network), .network)
        XCTAssertEqual(ActivityMonitorDestination.destination(for: .power), .energy)
    }

    func testCPUSampleProducesNormalizedFractions() throws {
        let sampler = CPUMetricsSampler()
        _ = try XCTUnwrap(sampler.sample())
        usleep(50_000)

        let sample = try XCTUnwrap(sampler.sample())
        XCTAssertTrue((0 ... 1).contains(sample.user))
        XCTAssertTrue((0 ... 1).contains(sample.system))
        XCTAssertTrue((0 ... 1).contains(sample.idle))
        XCTAssertEqual(sample.user + sample.system + sample.idle, 1, accuracy: 0.001)
    }

    func testMemorySampleStaysWithinPhysicalMemory() throws {
        let sample = try XCTUnwrap(MemoryMetricsSampler().sample())

        XCTAssertGreaterThan(sample.totalBytes, 0)
        XCTAssertLessThanOrEqual(sample.usedBytes, sample.totalBytes)
        XCTAssertTrue((0 ... 1).contains(sample.usedFraction))
    }

    func testGPUReadsIOAcceleratorStatisticsWhenAvailable() throws {
        let sampler = GPUMetricsSampler()
        XCTAssertFalse(sampler.deviceName.isEmpty)
        if let coreCount = sampler.coreCount {
            XCTAssertGreaterThan(coreCount, 0)
        }
        guard let sample = sampler.sample() else {
            throw XCTSkip("IOAccelerator statistics are unavailable on this Mac")
        }
        XCTAssertTrue((0 ... 1).contains(sample.device))
    }

    func testThermalSampleRejectsInvalidSensorValues() throws {
        for value in [Double.nan, .infinity, -.infinity, 4.99, 125.01] {
            XCTAssertNil(ThermalMetricsSampler.validatedTemperature(value))
        }
        XCTAssertEqual(ThermalMetricsSampler.validatedTemperature(5), 5)
        XCTAssertEqual(ThermalMetricsSampler.validatedTemperature(125), 125)

        let sample = ThermalMetricsSampler().sample()
        guard let temperature = sample.peakTemperature else {
            XCTAssertEqual(sample, .unavailable)
            return
        }

        XCTAssertTrue((5 ... 125).contains(temperature))
        XCTAssertGreaterThan(sample.sensorCount, 0)
        XCTAssertEqual(sample.sensorCount, Set(sample.sensors.map(\.id)).count)
        XCTAssertEqual(temperature, try XCTUnwrap(sample.sensors.map(\.temperature).max()), accuracy: 0.001)
        XCTAssertTrue(sample.sensors.allSatisfy { $0.ordinal > 0 })
        for group in ThermalSensorGroup.allCases {
            let ordinals = sample.sensors.filter { $0.group == group }.map(\.ordinal)
            if !ordinals.isEmpty {
                XCTAssertEqual(ordinals, Array(1 ... ordinals.count))
            }
        }
    }

    func testFanMetricsAggregateAndSamplerStayWithinPlausibleRanges() {
        let aggregate = FanMetrics(fans: [
            FanReading(id: 0, currentRPM: 2_000, minimumRPM: 1_200, maximumRPM: 6_000),
            FanReading(id: 1, currentRPM: 2_400, minimumRPM: 1_200, maximumRPM: 5_800)
        ])
        XCTAssertEqual(aggregate.averageRPM, 2_200)
        XCTAssertEqual(aggregate.peakRPM, 2_400)
        XCTAssertEqual(aggregate.chartMaximum, 6_000)

        let sample = FanMetricsSampler().sample()
        XCTAssertLessThanOrEqual(sample.fans.count, 8)
        XCTAssertEqual(sample.fans.count, Set(sample.fans.map(\.id)).count)
        XCTAssertTrue(sample.fans.allSatisfy { (0 ... 20_000).contains($0.currentRPM) })
        XCTAssertTrue(sample.fans.compactMap(\.minimumRPM).allSatisfy { (0 ... 20_000).contains($0) })
        XCTAssertTrue(sample.fans.compactMap(\.maximumRPM).allSatisfy { (0 ... 20_000).contains($0) })
    }

    func testStorageSampleReportsCapacityAndNormalizedUsage() {
        let sample = StorageMetricsSampler().sample()

        XCTAssertGreaterThan(sample.totalBytes, 0)
        XCTAssertLessThanOrEqual(sample.availableBytes, sample.totalBytes)
        XCTAssertTrue((0 ... 1).contains(sample.usedFraction))
        XCTAssertFalse(sample.volumeName.isEmpty)
    }

    func testNetworkSampleNeverProducesNegativeRates() {
        let sampler = NetworkMetricsSampler()
        _ = sampler.sample()
        usleep(50_000)
        let sample = sampler.sample()

        XCTAssertGreaterThanOrEqual(sample.downloadBytesPerSecond, 0)
        XCTAssertGreaterThanOrEqual(sample.uploadBytesPerSecond, 0)
    }

    func testPowerSampleUsesValidRangesWhenBatteryIsAvailable() {
        let sample = PowerMetricsSampler().sample()

        if let level = sample.batteryLevel {
            XCTAssertTrue((0 ... 1).contains(level))
        }
        if let health = sample.healthPercent {
            XCTAssertTrue((0 ... 1).contains(health))
        }
        if let watts = sample.powerWatts {
            XCTAssertGreaterThanOrEqual(watts, 0)
        }
    }

    @MainActor
    func testMenuBarMetricsPersistAndNormalize() throws {
        let suiteName = "SystemMetricsSamplerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "useNotchLeftOverflow")

        let settings = AppSettings(userDefaults: defaults)
        XCTAssertEqual(settings.menuBarMetrics, [.cpu, .memory, .temperature])
        settings.menuBarMetrics = [.temperature, .memory, .temperature, .gpu, .cpu]
        settings.metricsPopoverMode = .detailed

        let restored = AppSettings(userDefaults: defaults)
        XCTAssertEqual(restored.menuBarMetrics, [.temperature, .memory, .gpu])
        XCTAssertEqual(restored.metricsPopoverMode, .detailed)
        XCTAssertNil(defaults.object(forKey: "useNotchLeftOverflow"))
    }

    @MainActor
    func testLegacyMenuBarChoiceMigrates() throws {
        let suiteName = "SystemMetricsSamplerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("storage", forKey: "menuBarPrimaryMetric")

        let settings = AppSettings(userDefaults: defaults)
        XCTAssertEqual(settings.menuBarMetrics, [.storage, .cpu, .memory])
        XCTAssertNil(defaults.object(forKey: "menuBarPrimaryMetric"))
    }

    func testUnavailableStatusBarReadingHasPlaceholder() {
        XCTAssertEqual(MenuBarMetric.temperature.statusBarValue(in: .empty), "—")
        XCTAssertEqual(MenuBarMetric.gpu.statusBarValue(in: .empty), "—")
        XCTAssertEqual(MenuBarMetric.storage.statusBarValue(in: .empty), "—")
    }

    func testStatusBarChoicesHaveAvailableSymbols() {
        for metric in MenuBarMetric.statusBarChoices {
            XCTAssertNotNil(NSImage(systemSymbolName: metric.statusBarSymbol, accessibilityDescription: nil))
        }
    }
}
