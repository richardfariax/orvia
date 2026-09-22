import Darwin
import Foundation
import IOKit
import IOKit.ps
import Metal

final class CPUMetricsSampler {
    private var previousTicks: [UInt64]?

    func sample() -> CPUUsage? {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }

        defer {
            let byteCount = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), byteCount)
        }

        var ticks = [UInt64](repeating: 0, count: Int(CPU_STATE_MAX))
        for cpuIndex in 0 ..< Int(cpuCount) {
            let base = cpuIndex * Int(CPU_STATE_MAX)
            for state in 0 ..< Int(CPU_STATE_MAX) {
                ticks[state] += UInt64(cpuInfo[base + state])
            }
        }

        let deltas: [UInt64]
        if let previousTicks, previousTicks.count == ticks.count {
            deltas = zip(ticks, previousTicks).map { current, previous in
                current >= previous ? current - previous : current
            }
        } else {
            deltas = ticks
        }
        previousTicks = ticks

        let userTicks = deltas[Int(CPU_STATE_USER)] + deltas[Int(CPU_STATE_NICE)]
        let systemTicks = deltas[Int(CPU_STATE_SYSTEM)]
        let idleTicks = deltas[Int(CPU_STATE_IDLE)]
        let totalTicks = userTicks + systemTicks + idleTicks
        guard totalTicks > 0 else { return nil }

        return CPUUsage(
            user: Double(userTicks) / Double(totalTicks),
            system: Double(systemTicks) / Double(totalTicks),
            idle: Double(idleTicks) / Double(totalTicks)
        )
    }
}

struct MemoryMetricsSampler {
    func sample() -> MemoryUsage? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let pageBytes = UInt64(pageSize)
        let active = UInt64(statistics.active_count) * pageBytes
        let wired = UInt64(statistics.wire_count) * pageBytes
        let compressed = UInt64(statistics.compressor_page_count) * pageBytes
        let cached = UInt64(statistics.inactive_count + statistics.speculative_count) * pageBytes
        let total = ProcessInfo.processInfo.physicalMemory
        let calculatedUsed = active + wired + compressed

        return MemoryUsage(
            usedBytes: min(calculatedUsed, total),
            cachedBytes: cached,
            compressedBytes: compressed,
            wiredBytes: wired,
            totalBytes: total,
            swapUsedBytes: swapUsedBytes()
        )
    }

    private func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
}

final class GPUMetricsSampler {
    let deviceName: String
    private(set) var coreCount: Int?

    init() {
        deviceName = MTLCreateSystemDefaultDevice()?.name ?? "GPU"
        coreCount = Self.readGPUCoreCount()
    }

    func sample() -> GPUUsage? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var deviceUtilization: Double?
        var rendererUtilization: Double?
        var tilerUtilization: Double?
        var allocatedBytes: UInt64?

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let property = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue(), let statistics = property as? NSDictionary else {
                continue
            }

            deviceUtilization = maximum(deviceUtilization, fraction(statistics["Device Utilization %"]))
            rendererUtilization = maximum(rendererUtilization, fraction(statistics["Renderer Utilization %"]))
            tilerUtilization = maximum(tilerUtilization, fraction(statistics["Tiler Utilization %"]))

            if let bytes = number(statistics["Alloc system memory"])?.uint64Value {
                allocatedBytes = max(allocatedBytes ?? 0, bytes)
            }
        }

        guard let deviceUtilization else { return nil }
        return GPUUsage(
            device: deviceUtilization,
            renderer: rendererUtilization,
            tiler: tilerUtilization,
            allocatedBytes: allocatedBytes
        )
    }

    private func maximum(_ current: Double?, _ candidate: Double?) -> Double? {
        guard let candidate else { return current }
        return max(current ?? 0, candidate)
    }

    private func fraction(_ value: Any?) -> Double? {
        guard let value = number(value)?.doubleValue else { return nil }
        return min(max(value / 100, 0), 1)
    }

    private func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    private static func readGPUCoreCount() -> Int? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let property = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "gpu-core-count" as CFString,
            kCFAllocatorDefault,
            options
        ) as? NSNumber else {
            return nil
        }
        return property.intValue
    }
}

final class StorageMetricsSampler {
    private var previousCounters: (read: UInt64, write: UInt64, date: Date)?

    func sample(at date: Date = .now) -> StorageMetrics {
        let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        let values = try? rootURL.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let totalBytes = UInt64(max(values?.volumeTotalCapacity ?? 0, 0))
        let availableBytes = UInt64(max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0))
        let counters = diskCounters()
        let rates = rates(for: counters, at: date)

        return StorageMetrics(
            volumeName: values?.volumeName ?? "Macintosh HD",
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            readBytesPerSecond: rates.read,
            writeBytesPerSecond: rates.write
        )
    }

    private func rates(for counters: (read: UInt64, write: UInt64), at date: Date) -> (read: Double, write: Double) {
        defer { previousCounters = (counters.read, counters.write, date) }
        guard let previousCounters else { return (0, 0) }
        let interval = max(date.timeIntervalSince(previousCounters.date), 0.001)
        let readDelta = counters.read >= previousCounters.read ? counters.read - previousCounters.read : 0
        let writeDelta = counters.write >= previousCounters.write ? counters.write - previousCounters.write : 0
        return (Double(readDelta) / interval, Double(writeDelta) / interval)
    }

    private func diskCounters() -> (read: UInt64, write: UInt64) {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return (0, 0) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            read += (property["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (property["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}

final class NetworkMetricsSampler {
    private var previousCounters: (received: UInt64, sent: UInt64, date: Date)?

    func sample(at date: Date = .now) -> NetworkMetrics {
        let counters = networkCounters()
        defer { previousCounters = (counters.received, counters.sent, date) }
        guard let previousCounters else {
            return NetworkMetrics(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0, activeInterfaces: counters.interfaces)
        }

        let interval = max(date.timeIntervalSince(previousCounters.date), 0.001)
        let received = counters.received >= previousCounters.received ? counters.received - previousCounters.received : 0
        let sent = counters.sent >= previousCounters.sent ? counters.sent - previousCounters.sent : 0
        return NetworkMetrics(
            downloadBytesPerSecond: Double(received) / interval,
            uploadBytesPerSecond: Double(sent) / interval,
            activeInterfaces: counters.interfaces
        )
    }

    private func networkCounters() -> (received: UInt64, sent: UInt64, interfaces: [String]) {
        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let first = addressPointer else { return (0, 0, []) }
        defer { freeifaddrs(addressPointer) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var interfaces: [String] = []
        var visited: Set<String> = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first

        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let address = current.pointee
            guard let socketAddress = address.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_LINK),
                  (Int32(address.ifa_flags) & IFF_UP) != 0,
                  (Int32(address.ifa_flags) & IFF_LOOPBACK) == 0,
                  let namePointer = address.ifa_name,
                  let dataPointer = address.ifa_data else { continue }

            let name = String(cString: namePointer)
            guard !visited.contains(name), Self.shouldMeasure(interface: name) else { continue }
            visited.insert(name)
            interfaces.append(name)
            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(data.ifi_ibytes)
            sent += UInt64(data.ifi_obytes)
        }

        return (received, sent, interfaces.sorted())
    }

    private static func shouldMeasure(interface name: String) -> Bool {
        let excludedPrefixes = ["lo", "utun", "awdl", "llw", "anpi", "gif", "stf"]
        return !excludedPrefixes.contains(where: name.hasPrefix)
    }
}

struct PowerMetricsSampler {
    func sample() -> PowerMetrics {
        let batteryProperties = registryBatteryProperties()
        let voltageMillivolts = number(batteryProperties?["Voltage"])?.doubleValue
        let amperageMilliamps = number(batteryProperties?["Amperage"])?.doubleValue
        let measuredWatts: Double? = if let voltageMillivolts, let amperageMilliamps {
            abs(voltageMillivolts * amperageMilliamps) / 1_000_000
        } else {
            nil
        }

        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
            return PowerMetrics(
                source: batteryProperties == nil ? .external : .unknown,
                batteryLevel: nil,
                isCharging: false,
                powerWatts: measuredWatts,
                cycleCount: number(batteryProperties?["CycleCount"])?.intValue,
                healthPercent: healthPercent(from: batteryProperties),
                timeRemainingMinutes: nil
            )
        }

        let currentCapacity = number(description[kIOPSCurrentCapacityKey as String])?.doubleValue
        let maxCapacity = number(description[kIOPSMaxCapacityKey as String])?.doubleValue
        let level: Double? = if let currentCapacity, let maxCapacity, maxCapacity > 0 {
            min(max(currentCapacity / maxCapacity, 0), 1)
        } else {
            nil
        }
        let state = description[kIOPSPowerSourceStateKey as String] as? String
        let charging = (description[kIOPSIsChargingKey as String] as? NSNumber)?.boolValue ?? false
        let time = number(description[kIOPSTimeToEmptyKey as String])?.intValue

        return PowerMetrics(
            source: state == kIOPSACPowerValue ? .external : .battery,
            batteryLevel: level,
            isCharging: charging,
            powerWatts: measuredWatts,
            cycleCount: number(batteryProperties?["CycleCount"])?.intValue,
            healthPercent: healthPercent(from: batteryProperties),
            timeRemainingMinutes: time.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private func registryBatteryProperties() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    private func healthPercent(from properties: [String: Any]?) -> Double? {
        guard let currentMaximum = number(properties?["AppleRawMaxCapacity"])?.doubleValue
                ?? number(properties?["MaxCapacity"])?.doubleValue,
              let design = number(properties?["DesignCapacity"])?.doubleValue,
              design > 0 else { return nil }
        return min(max(currentMaximum / design, 0), 1)
    }

    private func number(_ value: Any?) -> NSNumber? { value as? NSNumber }
}
