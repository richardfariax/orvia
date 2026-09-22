import Foundation
import IOKit

private typealias FanSMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct FanSMCKeyData {
    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var powerLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: FanSMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

/// Capability-detected, read-only access to fan tachometers exposed by AppleSMC.
/// macOS has no public fan API, so unsupported hardware cleanly reports no fans.
final class FanMetricsSampler {
    private static let readBytesCommand: UInt8 = 5
    private static let readKeyInfoCommand: UInt8 = 9
    private static let smcSelector: UInt32 = 2
    private static let maximumSupportedFanCount = 8

    private var connection: io_connect_t = 0
    private var cachedFanCount: Int?

    init() {
        guard let matching = IOServiceMatching("AppleSMC") else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            connection = 0
            return
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func sample() -> FanMetrics {
        guard connection != 0 else { return .unavailable }
        let count = fanCount()
        guard count > 0 else { return .unavailable }

        let fans = (0 ..< count).compactMap { index -> FanReading? in
            guard let currentRPM = readNumericValue(for: "F\(index)Ac"),
                  currentRPM.isFinite,
                  (0 ... 20_000).contains(currentRPM) else {
                return nil
            }

            return FanReading(
                id: index,
                currentRPM: currentRPM,
                minimumRPM: validatedRPM(readNumericValue(for: "F\(index)Mn")),
                maximumRPM: validatedRPM(readNumericValue(for: "F\(index)Mx"))
            )
        }

        return fans.isEmpty ? .unavailable : FanMetrics(fans: fans)
    }

    private func fanCount() -> Int {
        if let cachedFanCount { return cachedFanCount }
        guard let count = readBytes(for: "FNum").first else {
            cachedFanCount = 0
            return 0
        }
        let normalized = min(max(Int(count), 0), Self.maximumSupportedFanCount)
        cachedFanCount = normalized
        return normalized
    }

    private func validatedRPM(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0 ... 20_000).contains(value) else { return nil }
        return value
    }

    private func readNumericValue(for key: String) -> Double? {
        let bytes = readBytes(for: key)
        switch bytes.count {
        case 4:
            let bitPattern = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            let value = Double(Float(bitPattern: bitPattern))
            return value.isFinite ? value : nil
        case 2:
            let fixedPoint = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(fixedPoint) / 4
        default:
            return nil
        }
    }

    private func readBytes(for key: String) -> [UInt8] {
        guard key.utf8.count == 4 else { return [] }

        var input = FanSMCKeyData()
        var output = FanSMCKeyData()
        input.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        input.command = Self.readKeyInfoCommand

        guard call(input: &input, output: &output) == kIOReturnSuccess else { return [] }
        let dataSize = Int(output.keyInfo.dataSize)
        guard (1 ... 32).contains(dataSize) else { return [] }

        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.command = Self.readBytesCommand
        output = FanSMCKeyData()
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return [] }

        return withUnsafeBytes(of: output.bytes) { rawBytes in
            Array(rawBytes.prefix(dataSize))
        }
    }

    private func call(
        input: inout FanSMCKeyData,
        output: inout FanSMCKeyData
    ) -> kern_return_t {
        var outputSize = MemoryLayout<FanSMCKeyData>.stride
        return IOConnectCallStructMethod(
            connection,
            Self.smcSelector,
            &input,
            MemoryLayout<FanSMCKeyData>.stride,
            &output,
            &outputSize
        )
    }
}
