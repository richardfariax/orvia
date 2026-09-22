import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var metrics: SystemMetricsService
    @ObservedObject var settings: AppSettings
    let clipboardCount: () -> Int
    let openDashboard: () -> Void
    let openClipboard: () -> Void
    let openCleaner: () -> Void

    private var snapshot: SystemMetricsSnapshot { metrics.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                BrandLogoView(size: 34, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Orvia").font(.headline)
                    Text(settings.text(ptBR: "Seu Mac agora", en: "Your Mac now"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(metrics.isRunning ? .green : .secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(metrics.isRunning ? "Live" : "Paused")
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    metric("CPU", snapshot.cpu.total.formatted(.percent.precision(.fractionLength(0))))
                    metric(settings.text(ptBR: "Memória", en: "Memory"),
                           snapshot.memory.usedFraction.formatted(.percent.precision(.fractionLength(0))))
                }
                GridRow {
                    metric(settings.text(ptBR: "Temperatura", en: "Temperature"),
                           snapshot.thermal.peakTemperature.map { String(format: "%.0f°C", $0) } ?? "—")
                    metric(settings.text(ptBR: "Bateria", en: "Battery"),
                           snapshot.power.batteryLevel?.formatted(.percent.precision(.fractionLength(0))) ?? "—")
                }
                GridRow {
                    metric(settings.text(ptBR: "Armazenamento livre", en: "Free storage"),
                           snapshot.storage.availableBytes > 0
                               ? ByteCountFormatter.string(fromByteCount: Int64(snapshot.storage.availableBytes), countStyle: .file)
                               : "—")
                    metric("Clipboard", String(clipboardCount()))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(settings.text(ptBR: "Central", en: "Overview"), action: openDashboard)
                    Button("Clipboard", action: openClipboard)
                    Button(settings.text(ptBR: "Cuidado", en: "Care"), action: openCleaner)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
