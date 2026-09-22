import Darwin
import Foundation

/// Reads Apple Silicon thermal sensors through the HID event service used by macOS.
/// These symbols are capability-detected at runtime because macOS does not expose a
/// stable public temperature API. Failure is represented as unavailable data.
final class ThermalMetricsSampler {
    private typealias EventSystemClientCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias EventSystemClientSetMatching = @convention(c) (UnsafeMutableRawPointer?, CFDictionary?) -> Void
    private typealias EventSystemClientCopyServices = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFArray>?
    private typealias ServiceClientCopyEvent = @convention(c) (UnsafeMutableRawPointer?, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias ServiceClientCopyProperty = @convention(c) (UnsafeMutableRawPointer?, CFString) -> Unmanaged<CFTypeRef>?
    private typealias EventGetFloatValue = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double

    private static let temperatureEventType: Int64 = 15
    private static let temperatureLevelField: Int32 = 15 << 16

    private let libraryHandle: UnsafeMutableRawPointer?
    private let createClient: EventSystemClientCreate?
    private let setMatching: EventSystemClientSetMatching?
    private let copyServices: EventSystemClientCopyServices?
    private let copyEvent: ServiceClientCopyEvent?
    private let copyProperty: ServiceClientCopyProperty?
    private let getFloatValue: EventGetFloatValue?
    private var client: UnsafeMutableRawPointer?

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        libraryHandle = handle
        createClient = Self.loadSymbol("IOHIDEventSystemClientCreate", from: handle, as: EventSystemClientCreate.self)
        setMatching = Self.loadSymbol("IOHIDEventSystemClientSetMatching", from: handle, as: EventSystemClientSetMatching.self)
        copyServices = Self.loadSymbol("IOHIDEventSystemClientCopyServices", from: handle, as: EventSystemClientCopyServices.self)
        copyEvent = Self.loadSymbol("IOHIDServiceClientCopyEvent", from: handle, as: ServiceClientCopyEvent.self)
        copyProperty = Self.loadSymbol("IOHIDServiceClientCopyProperty", from: handle, as: ServiceClientCopyProperty.self)
        getFloatValue = Self.loadSymbol("IOHIDEventGetFloatValue", from: handle, as: EventGetFloatValue.self)

        guard let createClient, let setMatching else { return }
        client = createClient(kCFAllocatorDefault)
        let matching = [
            "PrimaryUsagePage": 0xFF00,
            "PrimaryUsage": 5
        ] as CFDictionary
        setMatching(client, matching)
    }

    deinit {
        if let client {
            Unmanaged<CFTypeRef>.fromOpaque(client).release()
        }
        if let libraryHandle {
            dlclose(libraryHandle)
        }
    }

    func sample() -> ThermalMetrics {
        guard let client, let copyServices, let copyEvent, let getFloatValue,
              let unmanagedServices = copyServices(client) else {
            return .unavailable
        }

        let services = unmanagedServices.takeRetainedValue()
        var sensors: [ThermalSensorReading] = []
        let serviceCount = CFArrayGetCount(services)
        sensors.reserveCapacity(serviceCount)

        for index in 0 ..< serviceCount {
            guard let rawService = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: rawService)
            guard let event = copyEvent(service, Self.temperatureEventType, 0, 0) else { continue }
            defer { Unmanaged<CFTypeRef>.fromOpaque(event).release() }

            let temperature = getFloatValue(event, Self.temperatureLevelField)
            guard temperature.isFinite, (5 ... 125).contains(temperature) else { continue }
            let hardwareName = serviceName(service) 
            let group = Self.sensorGroup(for: hardwareName)
            sensors.append(ThermalSensorReading(
                id: "\(hardwareName ?? "thermal")-\(index)",
                ordinal: 0,
                hardwareName: hardwareName,
                group: group,
                temperature: temperature
            ))
        }

        guard !sensors.isEmpty else { return .unavailable }
        sensors.sort {
            if $0.group.sortOrder != $1.group.sortOrder {
                return $0.group.sortOrder < $1.group.sortOrder
            }
            return $0.temperature > $1.temperature
        }
        var counts: [ThermalSensorGroup: Int] = [:]
        let numberedSensors = sensors.map { sensor in
            let ordinal = (counts[sensor.group] ?? 0) + 1
            counts[sensor.group] = ordinal
            return ThermalSensorReading(
                id: sensor.id,
                ordinal: ordinal,
                hardwareName: sensor.hardwareName,
                group: sensor.group,
                temperature: sensor.temperature
            )
        }
        return ThermalMetrics(sensors: numberedSensors)
    }

    private func serviceName(_ service: UnsafeMutableRawPointer) -> String? {
        guard let copyProperty else { return nil }
        for key in ["Product", "Name", "SerialNumber"] {
            guard let value = copyProperty(service, key as CFString)?.takeRetainedValue() else { continue }
            if let name = value as? String {
                let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private static func sensorGroup(for hardwareName: String?) -> ThermalSensorGroup {
        guard let name = hardwareName?.uppercased() else { return .other }
        if name.contains("GPU") || name.contains("GFX") { return .gpu }
        if name.contains("CPU") || name.contains("PACC") || name.contains("EACC") { return .cpu }
        if name.contains("SOC") || name.contains("PMU") || name.contains("TDIE") { return .soc }
        if name.contains("MEM") || name.contains("DRAM") { return .memory }
        if name.contains("BAT") { return .battery }
        if name.contains("SSD") || name.contains("NAND") { return .storage }
        if name.contains("PALM") || name.contains("AIR") || name.contains("AMBIENT") || name.contains("ENCLOSURE") {
            return .enclosure
        }
        return .other
    }

    private static func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}
