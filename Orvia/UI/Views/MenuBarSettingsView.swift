import SwiftUI

struct MenuBarSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var metrics: SystemMetricsService

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    GlassEffectContainer {
                        HStack(spacing: 8) {
                            Image("OrviaMenuBarIcon")
                                .renderingMode(.template)
                                .resizable()
                                .frame(width: 18, height: 18)
                            ForEach(settings.menuBarMetrics) { metric in
                                HStack(spacing: 3) {
                                    Image(systemName: metric.statusBarSymbol)
                                    Text(metric.statusBarValue(in: metrics.snapshot))
                                        .monospacedDigit()
                                }
                                .font(.caption.weight(.medium))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: Capsule())
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            } header: {
                Text(settings.text(ptBR: "Prévia da barra superior", en: "Menu bar preview"))
            } footer: {
                Text(settings.text(
                    ptBR: "Todos os indicadores ficam lado a lado com o ícone do Orvia. Um clique abre o mesmo painel rápido.",
                    en: "All indicators sit beside the Orvia icon. One click opens the same quick panel."
                ))
            }

            Section {
                ForEach(MenuBarMetric.statusBarChoices) { metric in
                    metricRow(metric)
                }
            } header: {
                Text(settings.text(ptBR: "Indicadores", en: "Indicators"))
            } footer: {
                Text(settings.text(
                    ptBR: "Escolha até três. Use as setas para mudar a ordem. Uma leitura indisponível aparece como —.",
                    en: "Choose up to three. Use the arrows to change their order. Unavailable readings appear as —."
                ))
            }

            Section {
                Button(settings.text(ptBR: "Abrir painel detalhado de métricas", en: "Open detailed metrics panel")) {
                    NotificationCenter.default.post(name: .showMetricsPopover, object: nil)
                }
            }
        }
        .orviaSettingsFormStyle()
    }

    private func metricRow(_ metric: MenuBarMetric) -> some View {
        let selectedIndex = settings.menuBarMetrics.firstIndex(of: metric)
        return HStack(spacing: 12) {
            Image(systemName: metric.statusBarSymbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            Text(metric.statusBarTitle(language: settings.language))
            Spacer()
            if let selectedIndex {
                HStack(spacing: 2) {
                    Button {
                        moveMetric(from: selectedIndex, by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(selectedIndex == 0)
                    .help(settings.text(ptBR: "Mover para a esquerda", en: "Move left"))

                    Button {
                        moveMetric(from: selectedIndex, by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(selectedIndex == settings.menuBarMetrics.count - 1)
                    .help(settings.text(ptBR: "Mover para a direita", en: "Move right"))
                }
                .buttonStyle(.borderless)
            }
            Toggle(metric.statusBarTitle(language: settings.language), isOn: Binding(
                get: { settings.menuBarMetrics.contains(metric) },
                set: { isVisible in
                    if isVisible {
                        settings.menuBarMetrics.append(metric)
                    } else {
                        settings.menuBarMetrics.removeAll { $0 == metric }
                    }
                }
            ))
            .labelsHidden()
            .disabled(selectedIndex == nil && settings.menuBarMetrics.count >= 3)
        }
    }

    private func moveMetric(from index: Int, by offset: Int) {
        var reordered = settings.menuBarMetrics
        let destination = index + offset
        guard reordered.indices.contains(index), reordered.indices.contains(destination) else { return }
        reordered.swapAt(index, destination)
        settings.menuBarMetrics = reordered
    }
}
