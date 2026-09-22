import Charts
import SwiftUI

struct SystemDashboardView: View {
    @ObservedObject var metrics: SystemMetricsService
    let language: AppLanguage
    var showsHeader = true

    private let columns = [
        GridItem(.flexible(minimum: 260), spacing: 14),
        GridItem(.flexible(minimum: 260), spacing: 14)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                header
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                cpuCard
                gpuCard
                memoryCard
                thermalCard
                fanCard
                storageCard
                networkCard
                powerCard
            }

            hardwareCard
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(t("Central do Mac", "Mac Command Center"))
                    .font(.largeTitle.weight(.bold))
                Text(t(
                    "Saúde e desempenho do seu Mac em tempo real.",
                    "Real-time health and performance for your Mac."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 7) {
                Circle()
                    .fill(metrics.isRunning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(metrics.isRunning ? t("Ao vivo", "Live") : t("Pausado", "Paused"))
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.7), in: Capsule())
        }
    }

    private var cpuCard: some View {
        MetricCard(
            metric: .cpu,
            activityMonitorHint: activityMonitorHint(for: .cpu),
            title: "CPU",
            symbol: "cpu",
            accent: .blue,
            value: percent(metrics.snapshot.cpu.total),
            subtitle: metrics.hardware.processorName,
            history: metrics.cpuHistory,
            chartMaximum: 1
        ) {
            MetricLegendRow(color: .blue, label: t("Usuário", "User"), value: percent(metrics.snapshot.cpu.user))
            MetricLegendRow(color: .pink, label: t("Sistema", "System"), value: percent(metrics.snapshot.cpu.system))
            MetricLegendRow(color: .secondary, label: t("Ociosa", "Idle"), value: percent(metrics.snapshot.cpu.idle))
        }
    }

    private var gpuCard: some View {
        MetricCard(
            metric: .gpu,
            activityMonitorHint: activityMonitorHint(for: .gpu),
            title: "GPU",
            symbol: "square.3.layers.3d",
            accent: .cyan,
            value: metrics.snapshot.gpu.map { percent($0.device) } ?? unavailable,
            subtitle: gpuSubtitle,
            history: metrics.gpuHistory,
            chartMaximum: 1
        ) {
            if let gpu = metrics.snapshot.gpu {
                MetricLegendRow(color: .cyan, label: t("Dispositivo", "Device"), value: percent(gpu.device))
                if let renderer = gpu.renderer {
                    MetricLegendRow(color: .pink, label: "Renderer", value: percent(renderer))
                }
                if let tiler = gpu.tiler {
                    MetricLegendRow(color: .mint, label: "Tiler", value: percent(tiler))
                }
                if let allocatedBytes = gpu.allocatedBytes {
                    MetricLegendRow(color: .secondary, label: t("Memória alocada", "Allocated memory"), value: bytes(allocatedBytes))
                }
            } else {
                unavailableRow
            }
        }
    }

    private var memoryCard: some View {
        let memory = metrics.snapshot.memory
        return MetricCard(
            metric: .memory,
            activityMonitorHint: activityMonitorHint(for: .memory),
            title: t("Memória", "Memory"),
            symbol: "memorychip",
            accent: .purple,
            value: percent(memory.usedFraction),
            subtitle: "\(bytes(memory.usedBytes)) / \(bytes(memory.totalBytes))",
            history: metrics.memoryHistory,
            chartMaximum: 1
        ) {
            MetricLegendRow(color: .purple, label: t("Em uso", "In use"), value: bytes(memory.usedBytes))
            MetricLegendRow(color: .indigo, label: t("Comprimida", "Compressed"), value: bytes(memory.compressedBytes))
            MetricLegendRow(color: .secondary, label: "Cache", value: bytes(memory.cachedBytes))
            MetricLegendRow(color: .orange, label: "Swap", value: bytes(memory.swapUsedBytes))
        }
    }

    private var thermalCard: some View {
        let thermal = metrics.snapshot.thermal
        return MetricCard(
            metric: .temperature,
            activityMonitorHint: activityMonitorHint(for: .temperature),
            title: t("Temperatura", "Temperature"),
            symbol: "thermometer.medium",
            accent: temperatureColor,
            value: thermal.peakTemperature.map { String(format: "%.1f °C", $0) } ?? unavailable,
            subtitle: t("Pico térmico dos sensores do Mac", "Mac thermal sensor peak"),
            history: metrics.temperatureHistory,
            chartMaximum: 110
        ) {
            if let temperature = thermal.peakTemperature {
                MetricLegendRow(
                    color: temperatureColor,
                    label: t("Sensor mais quente", "Hottest sensor"),
                    value: String(format: "%.1f °C", temperature)
                )
                MetricLegendRow(
                    color: .secondary,
                    label: t("Sensores ativos", "Active sensors"),
                    value: "\(thermal.sensorCount)"
                )
            } else {
                unavailableRow
            }
        }
    }

    private var storageCard: some View {
        let storage = metrics.snapshot.storage
        return MetricCard(
            metric: .storage,
            activityMonitorHint: activityMonitorHint(for: .storage),
            title: t("Armazenamento", "Storage"),
            symbol: "internaldrive",
            accent: .indigo,
            value: percent(storage.usedFraction),
            subtitle: "\(storage.volumeName) · \(bytes(storage.usedBytes)) / \(bytes(storage.totalBytes))",
            history: metrics.storageHistory,
            chartMaximum: 1
        ) {
            MetricLegendRow(color: .indigo, label: t("Em uso", "In use"), value: bytes(storage.usedBytes))
            MetricLegendRow(color: .green, label: t("Disponível", "Available"), value: bytes(storage.availableBytes))
            MetricLegendRow(color: .blue, label: t("Leitura", "Read"), value: rate(storage.readBytesPerSecond))
            MetricLegendRow(color: .orange, label: t("Gravação", "Write"), value: rate(storage.writeBytesPerSecond))
        }
    }

    private var fanCard: some View {
        let fans = metrics.snapshot.fans
        return MetricCard(
            metric: .fans,
            activityMonitorHint: activityMonitorHint(for: .fans),
            title: t("Ventoinhas", "Fans"),
            symbol: "fan",
            accent: .mint,
            value: fans.averageRPM.map(rpm) ?? unavailable,
            subtitle: fans.fans.isEmpty
                ? t("Sensores de RPM não expostos neste Mac", "RPM sensors not exposed on this Mac")
                : "\(fans.fans.count) \(t("ventoinhas detectadas", "detected fans"))",
            history: metrics.fanHistory,
            chartMaximum: fans.chartMaximum
        ) {
            if fans.fans.isEmpty {
                unavailableRow
            } else {
                ForEach(fans.fans) { fan in
                    MetricLegendRow(
                        color: .mint,
                        label: "\(t("Ventoinha", "Fan")) \(fan.id + 1)",
                        value: rpm(fan.currentRPM)
                    )
                }
            }
        }
    }

    private var networkCard: some View {
        let network = metrics.snapshot.network
        return MetricCard(
            metric: .network,
            activityMonitorHint: activityMonitorHint(for: .network),
            title: t("Rede", "Network"),
            symbol: "network",
            accent: .teal,
            value: "↓ \(rate(network.downloadBytesPerSecond))",
            subtitle: network.activeInterfaces.isEmpty
                ? t("Nenhuma interface ativa", "No active interface")
                : network.activeInterfaces.joined(separator: ", "),
            history: metrics.networkHistory,
            chartMaximum: adaptiveMaximum(metrics.networkHistory)
        ) {
            MetricLegendRow(color: .teal, label: t("Recebendo", "Download"), value: rate(network.downloadBytesPerSecond))
            MetricLegendRow(color: .blue, label: t("Enviando", "Upload"), value: rate(network.uploadBytesPerSecond))
            MetricLegendRow(
                color: .secondary,
                label: t("Interfaces", "Interfaces"),
                value: network.activeInterfaces.isEmpty ? "—" : "\(network.activeInterfaces.count)"
            )
        }
    }

    private var powerCard: some View {
        let power = metrics.snapshot.power
        return MetricCard(
            metric: .power,
            activityMonitorHint: activityMonitorHint(for: .power),
            title: t("Energia", "Power"),
            symbol: power.isCharging ? "battery.100percent.bolt" : "bolt.fill",
            accent: power.isCharging ? .green : .yellow,
            value: power.batteryLevel.map(percent) ?? (power.source == .external ? "AC" : unavailable),
            subtitle: power.powerWatts.map { String(format: "%.2f W", $0) }
                ?? t("Consumo não exposto pelo hardware", "Power draw not exposed by hardware"),
            history: metrics.powerHistory,
            chartMaximum: adaptiveMaximum(metrics.powerHistory)
        ) {
            MetricLegendRow(
                color: power.source == .external ? .green : .yellow,
                label: t("Fonte", "Source"),
                value: power.source == .external ? t("Adaptador", "Power adapter") : t("Bateria", "Battery")
            )
            if let cycles = power.cycleCount {
                MetricLegendRow(color: .secondary, label: t("Ciclos", "Cycles"), value: "\(cycles)")
            }
            if let health = power.healthPercent {
                MetricLegendRow(color: .mint, label: t("Saúde", "Health"), value: percent(health))
            }
            if let minutes = power.timeRemainingMinutes {
                MetricLegendRow(color: .secondary, label: t("Tempo estimado", "Estimated time"), value: duration(minutes))
            }
        }
    }

    private var hardwareCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(t("Este Mac", "This Mac"), systemImage: "laptopcomputer")
                .font(.headline)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                HardwareFact(label: t("Modelo", "Model"), value: metrics.hardware.modelIdentifier)
                HardwareFact(
                    label: "CPU",
                    value: "\(metrics.hardware.physicalCoreCount) \(t("núcleos", "cores"))"
                )
                HardwareFact(label: "GPU", value: gpuSubtitle)
                HardwareFact(label: t("Memória unificada", "Unified memory"), value: bytes(metrics.hardware.memoryBytes))
                HardwareFact(label: "macOS", value: metrics.hardware.operatingSystem)
                HardwareFact(
                    label: t("Processadores lógicos", "Logical processors"),
                    value: "\(metrics.hardware.logicalCoreCount)"
                )
            }
        }
        .padding(16)
        .orviaSettingsSurface(cornerRadius: 18)
    }

    private var unavailableRow: some View {
        Label(
            t("Leitura não disponível neste Mac", "Reading unavailable on this Mac"),
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var gpuSubtitle: String {
        guard let cores = metrics.hardware.gpuCoreCount else { return metrics.hardware.gpuName }
        return "\(metrics.hardware.gpuName) · \(cores) \(t("núcleos", "cores"))"
    }

    private var temperatureColor: Color {
        guard let temperature = metrics.snapshot.thermal.peakTemperature else { return .orange }
        if temperature >= 95 { return .red }
        if temperature >= 80 { return .orange }
        return .green
    }

    private var unavailable: String { t("Indisponível", "Unavailable") }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return "\(formatter.string(fromByteCount: Int64(max(bytesPerSecond, 0))))/s"
    }

    private func rpm(_ value: Double) -> String {
        "\(value.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))) RPM"
    }

    private func adaptiveMaximum(_ history: [MetricHistoryPoint]) -> Double {
        max(history.suffix(90).map(\.value).max() ?? 1, 1)
    }

    private func duration(_ minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "—"
    }

    private func activityMonitorHint(for metric: MenuBarMetric) -> String {
        switch metric {
        case .gpu:
            return t("Abrir Histórico da GPU", "Open GPU History")
        case .temperature:
            return t(
                "Abrir CPU no Monitor de Atividade",
                "Open CPU in Activity Monitor"
            )
        case .fans:
            return t(
                "Abrir CPU no Monitor de Atividade",
                "Open CPU in Activity Monitor"
            )
        default:
            return t("Abrir no Monitor de Atividade", "Open in Activity Monitor")
        }
    }

    private func t(_ pt: String, _ en: String) -> String {
        language.text(ptBR: pt, en: en)
    }
}

private struct MetricCard<Details: View>: View {
    let metric: MenuBarMetric
    let activityMonitorHint: String
    let title: String
    let symbol: String
    let accent: Color
    let value: String
    let subtitle: String
    let history: [MetricHistoryPoint]
    let chartMaximum: Double
    @ViewBuilder let details: Details

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Button {
                    ActivityMonitorLauncher.open(for: metric)
                } label: {
                    Text(value)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(activityMonitorHint)
                .help(activityMonitorHint)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                ActivityMonitorLauncher.open(for: metric)
            } label: {
                Chart(history) { point in
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accent.opacity(0.5), accent.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: 0 ... chartMaximum)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 74)
            .accessibilityLabel(activityMonitorHint)
            .help(activityMonitorHint)

            VStack(alignment: .leading, spacing: 5) {
                details
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 224, alignment: .topLeading)
        .orviaSettingsSurface(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        }
    }

}

private struct MetricLegendRow: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct HardwareFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
