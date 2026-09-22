import Charts
import SwiftUI

struct MetricsPopoverView: View {
    @ObservedObject var metrics: SystemMetricsService
    @ObservedObject var settings: AppSettings
    let onOpenDashboard: () -> Void

    @State private var selectedMetric: MenuBarMetric

    init(
        metrics: SystemMetricsService,
        settings: AppSettings,
        initialMetric: MenuBarMetric,
        onOpenDashboard: @escaping () -> Void
    ) {
        self.metrics = metrics
        self.settings = settings
        self.onOpenDashboard = onOpenDashboard
        _selectedMetric = State(initialValue: initialMetric)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if settings.metricsPopoverMode == .summary {
                    summaryContent
                } else {
                    detailedContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 560, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandLogoView(size: 32, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t("Central do Mac", "Mac Command Center"))
                        .font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(t("Atualização em tempo real", "Live updates"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(metrics.snapshot.timestamp, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: $settings.metricsPopoverMode) {
                Text(t("Visão rápida", "Quick view")).tag(MetricsPopoverMode.summary)
                Text(t("Detalhado", "Detailed")).tag(MetricsPopoverMode.detailed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(16)
    }

    private var summaryContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                summaryCard(.cpu, value: percent(metrics.snapshot.cpu.total), subtitle: metrics.hardware.processorName, history: metrics.cpuHistory, accent: .blue, range: 0 ... 1)
                summaryCard(.gpu, value: metrics.snapshot.gpu.map { percent($0.device) } ?? "—", subtitle: metrics.hardware.gpuName, history: metrics.gpuHistory, accent: .cyan, range: 0 ... 1)
                summaryCard(.memory, value: percent(metrics.snapshot.memory.usedFraction), subtitle: "\(bytes(metrics.snapshot.memory.usedBytes)) / \(bytes(metrics.snapshot.memory.totalBytes))", history: metrics.memoryHistory, accent: .purple, range: 0 ... 1)
                summaryCard(.temperature, value: temperature(metrics.snapshot.thermal.peakTemperature), subtitle: "\(metrics.snapshot.thermal.sensorCount) \(t("sensores", "sensors"))", history: metrics.temperatureHistory, accent: temperatureColor(metrics.snapshot.thermal.peakTemperature), range: 20 ... 110)
                summaryCard(.fans, value: rpm(metrics.snapshot.fans.averageRPM), subtitle: "\(metrics.snapshot.fans.fans.count) \(t("ventoinhas", "fans"))", history: metrics.fanHistory, accent: .mint, range: 0 ... metrics.snapshot.fans.chartMaximum)
                summaryCard(.storage, value: percent(metrics.snapshot.storage.usedFraction), subtitle: "\(bytes(metrics.snapshot.storage.availableBytes)) \(t("livres", "free"))", history: metrics.storageHistory, accent: .indigo, range: 0 ... 1)
                summaryCard(.network, value: "↓ \(rate(metrics.snapshot.network.downloadBytesPerSecond))", subtitle: "↑ \(rate(metrics.snapshot.network.uploadBytesPerSecond))", history: metrics.networkHistory, accent: .teal, range: adaptiveRange(metrics.networkHistory))
                summaryCard(.power, value: powerSummary, subtitle: powerSubtitle, history: metrics.powerHistory, accent: .green, range: adaptiveRange(metrics.powerHistory))
            }
            .padding(14)
        }
    }

    private func summaryCard(
        _ metric: MenuBarMetric,
        value: String,
        subtitle: String,
        history: [MetricHistoryPoint],
        accent: Color,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(metricTitle(metric), systemImage: metricSymbol(metric))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    metricValueButton(metric: metric, value: value, accent: accent, font: .title3)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            activityMonitorChart(metric: metric, history: history, accent: accent, range: range)
                .frame(height: 52)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .orviaSettingsSurface(cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        }
    }

    private func activityMonitorChart(
        metric: MenuBarMetric,
        history: [MetricHistoryPoint],
        accent: Color,
        range: ClosedRange<Double>
    ) -> some View {
        Button {
            ActivityMonitorLauncher.open(for: metric)
        } label: {
            CompactMetricChart(history: history, accent: accent, range: range)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nativeActionLabel(for: metric))
        .accessibilityHint(nativeActionHint(for: metric))
        .help(nativeActionHint(for: metric))
    }

    private var detailedContent: some View {
        VStack(spacing: 0) {
            metricSelector
            Divider()
            ScrollView {
                detailBody
                    .padding(16)
            }
        }
    }

    private var metricSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(MenuBarMetric.allCases) { metric in
                    Button {
                        selectedMetric = metric
                    } label: {
                        Label(metricTitle(metric), systemImage: metricSymbol(metric))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .foregroundStyle(selectedMetric == metric ? Color.white : Color.primary)
                            .background(
                                selectedMetric == metric ? Color.accentColor : Color.primary.opacity(0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var detailBody: some View {
        switch selectedMetric {
        case .cpu: cpuDetails
        case .gpu: gpuDetails
        case .memory: memoryDetails
        case .temperature: temperatureDetails
        case .fans: fanDetails
        case .storage: storageDetails
        case .network: networkDetails
        case .power: powerDetails
        }
    }

    private var cpuDetails: some View {
        detailSection(
            metric: .cpu,
            value: percent(metrics.snapshot.cpu.total),
            subtitle: metrics.hardware.processorName,
            history: metrics.cpuHistory,
            accent: .blue,
            range: 0 ... 1
        ) {
            detailRow(t("Usuário", "User"), percent(metrics.snapshot.cpu.user), color: .blue)
            detailRow(t("Sistema", "System"), percent(metrics.snapshot.cpu.system), color: .pink)
            detailRow(t("Ociosa", "Idle"), percent(metrics.snapshot.cpu.idle), color: .secondary)
            detailRow(t("Núcleos", "Cores"), "\(metrics.hardware.physicalCoreCount)", color: .secondary)
        }
    }

    private var gpuDetails: some View {
        detailSection(
            metric: .gpu,
            value: metrics.snapshot.gpu.map { percent($0.device) } ?? "—",
            subtitle: metrics.hardware.gpuName,
            history: metrics.gpuHistory,
            accent: .cyan,
            range: 0 ... 1
        ) {
            if let gpu = metrics.snapshot.gpu {
                detailRow(t("Dispositivo", "Device"), percent(gpu.device), color: .cyan)
                detailRow("Renderer", gpu.renderer.map(percent) ?? "—", color: .pink)
                detailRow("Tiler", gpu.tiler.map(percent) ?? "—", color: .mint)
                detailRow(t("Memória alocada", "Allocated memory"), gpu.allocatedBytes.map(bytes) ?? "—", color: .secondary)
            }
        }
    }

    private var memoryDetails: some View {
        let memory = metrics.snapshot.memory
        return detailSection(
            metric: .memory,
            value: percent(memory.usedFraction),
            subtitle: "\(bytes(memory.usedBytes)) / \(bytes(memory.totalBytes))",
            history: metrics.memoryHistory,
            accent: .purple,
            range: 0 ... 1
        ) {
            detailRow(t("Em uso", "In use"), bytes(memory.usedBytes), color: .purple)
            detailRow(t("Disponível", "Available"), bytes(memory.availableBytes), color: .green)
            detailRow(t("Comprimida", "Compressed"), bytes(memory.compressedBytes), color: .indigo)
            detailRow(t("Conectada", "Wired"), bytes(memory.wiredBytes), color: .orange)
            detailRow("Cache", bytes(memory.cachedBytes), color: .secondary)
            detailRow("Swap", bytes(memory.swapUsedBytes), color: memory.swapUsedBytes > 0 ? .orange : .secondary)
        }
    }

    private var temperatureDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailHeader(
                metric: .temperature,
                value: temperature(metrics.snapshot.thermal.peakTemperature),
                subtitle: "\(metrics.snapshot.thermal.sensorCount) \(t("sensores ativos", "active sensors"))",
                accent: temperatureColor(metrics.snapshot.thermal.peakTemperature)
            )

            activityMonitorChart(
                metric: .temperature,
                history: metrics.temperatureHistory,
                accent: .green,
                range: 20 ... 110
            )
                .frame(height: 120)
                .padding(10)
                .orviaSettingsSurface()

            HStack(spacing: 10) {
                statistic(t("Pico", "Peak"), temperature(metrics.snapshot.thermal.peakTemperature))
                statistic(t("Média", "Average"), temperature(metrics.snapshot.thermal.averageTemperature))
                statistic(t("Sensores", "Sensors"), "\(metrics.snapshot.thermal.sensorCount)")
            }

            ForEach(ThermalSensorGroup.allCases, id: \.self) { group in
                let sensors = metrics.snapshot.thermal.sensors.filter { $0.group == group }
                if !sensors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sensorGroupTitle(group))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(sensors) { sensor in
                            ThermalSensorRow(
                                sensor: sensor,
                                displayName: "\(sensorGroupTitle(group)) \(sensor.ordinal)",
                                history: metrics.thermalSensorHistories[sensor.id] ?? [],
                                hardwareLabel: t("ID do hardware", "Hardware ID"),
                                activityMonitorHint: nativeActionHint(for: .temperature)
                            )
                        }
                    }
                }
            }
        }
    }

    private var storageDetails: some View {
        let storage = metrics.snapshot.storage
        return detailSection(
            metric: .storage,
            value: percent(storage.usedFraction),
            subtitle: storage.volumeName,
            history: metrics.diskHistory,
            accent: .indigo,
            range: adaptiveRange(metrics.diskHistory)
        ) {
            detailRow(t("Em uso", "In use"), bytes(storage.usedBytes), color: .indigo)
            detailRow(t("Disponível", "Available"), bytes(storage.availableBytes), color: .green)
            detailRow(t("Capacidade", "Capacity"), bytes(storage.totalBytes), color: .secondary)
            detailRow(t("Leitura", "Read"), rate(storage.readBytesPerSecond), color: .blue)
            detailRow(t("Gravação", "Write"), rate(storage.writeBytesPerSecond), color: .orange)
        }
    }

    private var fanDetails: some View {
        let fans = metrics.snapshot.fans
        return VStack(alignment: .leading, spacing: 14) {
            detailHeader(
                metric: .fans,
                value: rpm(fans.averageRPM),
                subtitle: "\(fans.fans.count) \(t("ventoinhas detectadas", "detected fans"))",
                accent: .mint
            )

            activityMonitorChart(
                metric: .fans,
                history: metrics.fanHistory,
                accent: .mint,
                range: 0 ... fans.chartMaximum
            )
            .frame(height: 120)
            .padding(10)
            .orviaSettingsSurface()

            HStack(spacing: 10) {
                statistic(t("Média", "Average"), rpm(fans.averageRPM))
                statistic(t("Pico atual", "Current peak"), rpm(fans.peakRPM))
                statistic(t("Ventoinhas", "Fans"), "\(fans.fans.count)")
            }

            if fans.fans.isEmpty {
                Label(
                    t(
                        "Este Mac não expôs sensores de ventoinha.",
                        "This Mac did not expose fan sensors."
                    ),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(fans.fans) { fan in
                    FanSensorRow(
                        fan: fan,
                        displayName: "\(t("Ventoinha", "Fan")) \(fan.id + 1)",
                        history: metrics.fanHistories[fan.id] ?? [],
                        chartMaximum: max(fan.maximumRPM ?? fans.chartMaximum, 1),
                        activityMonitorHint: nativeActionHint(for: .fans)
                    )
                }
            }
        }
    }

    private var networkDetails: some View {
        let network = metrics.snapshot.network
        return detailSection(
            metric: .network,
            value: "↓ \(rate(network.downloadBytesPerSecond))",
            subtitle: "↑ \(rate(network.uploadBytesPerSecond))",
            history: metrics.networkHistory,
            accent: .teal,
            range: adaptiveRange(metrics.networkHistory)
        ) {
            detailRow(t("Recebendo", "Download"), rate(network.downloadBytesPerSecond), color: .teal)
            detailRow(t("Enviando", "Upload"), rate(network.uploadBytesPerSecond), color: .blue)
            detailRow(t("Interfaces ativas", "Active interfaces"), "\(network.activeInterfaces.count)", color: .secondary)
            if !network.activeInterfaces.isEmpty {
                Text(network.activeInterfaces.joined(separator: "  ·  "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private var powerDetails: some View {
        let power = metrics.snapshot.power
        return detailSection(
            metric: .power,
            value: powerSummary,
            subtitle: powerSubtitle,
            history: metrics.powerHistory,
            accent: .green,
            range: adaptiveRange(metrics.powerHistory)
        ) {
            detailRow(t("Fonte", "Source"), power.source == .external ? t("Adaptador", "Power adapter") : t("Bateria", "Battery"), color: .green)
            detailRow(t("Carregando", "Charging"), power.isCharging ? t("Sim", "Yes") : t("Não", "No"), color: power.isCharging ? .green : .secondary)
            detailRow(t("Consumo", "Power draw"), power.powerWatts.map { String(format: "%.2f W", $0) } ?? "—", color: .yellow)
            detailRow(t("Ciclos", "Cycles"), power.cycleCount.map(String.init) ?? "—", color: .secondary)
            detailRow(t("Saúde", "Health"), power.healthPercent.map(percent) ?? "—", color: .mint)
        }
    }

    private func detailSection<Content: View>(
        metric: MenuBarMetric,
        value: String,
        subtitle: String,
        history: [MetricHistoryPoint],
        accent: Color,
        range: ClosedRange<Double>,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            detailHeader(metric: metric, value: value, subtitle: subtitle, accent: accent)
            activityMonitorChart(metric: metric, history: history, accent: accent, range: range)
                .frame(height: 180)
                .padding(10)
                .orviaSettingsSurface()
            VStack(spacing: 8) { rows() }
                .padding(12)
                .orviaSettingsSurface()
        }
    }

    private func detailHeader(metric: MenuBarMetric, value: String, subtitle: String, accent: Color) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Label(metricTitle(metric), systemImage: metricSymbol(metric))
                    .font(.title3.weight(.bold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            metricValueButton(metric: metric, value: value, accent: accent, font: .title2)
        }
    }

    private func metricValueButton(
        metric: MenuBarMetric,
        value: String,
        accent: Color,
        font: Font
    ) -> some View {
        Button {
            ActivityMonitorLauncher.open(for: metric)
        } label: {
            Text(value)
                .font(font.monospacedDigit().weight(.bold))
                .foregroundStyle(accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nativeActionLabel(for: metric))
        .accessibilityHint(nativeActionHint(for: metric))
        .help(nativeActionHint(for: metric))
    }

    private func detailRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private func statistic(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orviaSettingsSurface(cornerRadius: 10)
    }

    private var footer: some View {
        HStack {
            Text(t(
                "Clique em um número ou gráfico para abrir o Monitor de Atividade",
                "Click a number or chart to open Activity Monitor"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(t("Abrir Central completa", "Open full Command Center"), action: onOpenDashboard)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
    }

    private var powerSummary: String {
        metrics.snapshot.power.batteryLevel.map(percent)
            ?? (metrics.snapshot.power.source == .external ? "AC" : "—")
    }

    private var powerSubtitle: String {
        metrics.snapshot.power.powerWatts.map { String(format: "%.1f W", $0) }
            ?? t("Consumo indisponível", "Power unavailable")
    }

    private func metricTitle(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: t("Memória", "Memory")
        case .temperature: t("Temperatura", "Temperature")
        case .fans: t("Ventoinhas", "Fans")
        case .storage: t("Armazenamento", "Storage")
        case .network: t("Rede", "Network")
        case .power: t("Energia", "Power")
        }
    }

    private func metricSymbol(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .cpu: "cpu"
        case .gpu: "square.3.layers.3d"
        case .memory: "memorychip"
        case .temperature: "thermometer.medium"
        case .fans: "fan"
        case .storage: "internaldrive"
        case .network: "network"
        case .power: "bolt.fill"
        }
    }

    private func nativeActionLabel(for metric: MenuBarMetric) -> String {
        t(
            "Abrir \(metricTitle(metric)) no Monitor de Atividade",
            "Open \(metricTitle(metric)) in Activity Monitor"
        )
    }

    private func nativeActionHint(for metric: MenuBarMetric) -> String {
        switch metric {
        case .gpu:
            return t(
                "Abre a janela nativa Histórico da GPU",
                "Opens the native GPU History window"
            )
        case .temperature:
            return t(
                "O macOS não possui painel térmico nativo; abre CPU para investigar a carga relacionada",
                "macOS has no native thermal pane; opens CPU to investigate related load"
            )
        case .fans:
            return t(
                "O macOS não possui painel nativo de ventoinhas; abre CPU para investigar a carga relacionada",
                "macOS has no native fan pane; opens CPU to investigate related load"
            )
        default:
            return t(
                "Abre o Monitor de Atividade diretamente na categoria correspondente",
                "Opens Activity Monitor directly in the matching category"
            )
        }
    }

    private func sensorGroupTitle(_ group: ThermalSensorGroup) -> String {
        switch group {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .soc: "SoC"
        case .memory: t("Memória", "Memory")
        case .battery: t("Bateria", "Battery")
        case .storage: t("Armazenamento", "Storage")
        case .enclosure: t("Estrutura e ambiente", "Enclosure and ambient")
        case .other: t("Outros sensores", "Other sensors")
        }
    }

    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
    private func temperature(_ value: Double?) -> String { value.map { String(format: "%.1f °C", $0) } ?? "—" }
    private func rpm(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))) RPM" } ?? "— RPM"
    }

    private func rate(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return "\(formatter.string(fromByteCount: Int64(max(value, 0))))/s"
    }

    private func adaptiveRange(_ history: [MetricHistoryPoint]) -> ClosedRange<Double> {
        0 ... max(history.suffix(90).map(\.value).max() ?? 1, 1)
    }

    private func temperatureColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 95 { return .red }
        if value >= 80 { return .orange }
        return .green
    }

    private func t(_ pt: String, _ en: String) -> String { settings.text(ptBR: pt, en: en) }
}

private struct CompactMetricChart: View {
    let history: [MetricHistoryPoint]
    let accent: Color
    let range: ClosedRange<Double>

    var body: some View {
        Chart(history) { point in
            AreaMark(x: .value("Time", point.timestamp), y: .value("Value", point.value))
                .foregroundStyle(LinearGradient(colors: [accent.opacity(0.5), accent.opacity(0.03)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", point.timestamp), y: .value("Value", point.value))
                .foregroundStyle(accent)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .chartYScale(domain: range)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }
}

private struct ThermalSensorRow: View {
    let sensor: ThermalSensorReading
    let displayName: String
    let history: [MetricHistoryPoint]
    let hardwareLabel: String
    let activityMonitorHint: String

    private var accent: Color {
        if sensor.temperature >= 95 { return .red }
        if sensor.temperature >= 80 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(accent).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.subheadline.weight(.semibold))
                if let hardwareName = sensor.hardwareName {
                    Text("\(hardwareLabel): \(hardwareName)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                ActivityMonitorLauncher.open(for: .temperature)
            } label: {
                CompactMetricChart(history: history, accent: accent, range: 20 ... 110)
                    .frame(width: 74, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activityMonitorHint)
            .help(activityMonitorHint)

            Button {
                ActivityMonitorLauncher.open(for: .temperature)
            } label: {
                Text(String(format: "%.1f °C", sensor.temperature))
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(accent)
                    .frame(width: 66, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activityMonitorHint)
            .help(activityMonitorHint)
        }
        .padding(10)
        .orviaSettingsSurface(cornerRadius: 10)
    }
}

private struct FanSensorRow: View {
    let fan: FanReading
    let displayName: String
    let history: [MetricHistoryPoint]
    let chartMaximum: Double
    let activityMonitorHint: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "fan")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.mint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.subheadline.weight(.semibold))
                Text(speedRange)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                ActivityMonitorLauncher.open(for: .fans)
            } label: {
                CompactMetricChart(history: history, accent: .mint, range: 0 ... chartMaximum)
                    .frame(width: 74, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activityMonitorHint)
            .help(activityMonitorHint)

            Button {
                ActivityMonitorLauncher.open(for: .fans)
            } label: {
                Text("\(fan.currentRPM.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))) RPM")
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(.mint)
                    .frame(width: 92, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activityMonitorHint)
            .help(activityMonitorHint)
        }
        .padding(10)
        .orviaSettingsSurface(cornerRadius: 10)
    }

    private var speedRange: String {
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM else {
            return "RPM"
        }
        return "\(Int(minimum))–\(Int(maximum)) RPM"
    }
}
