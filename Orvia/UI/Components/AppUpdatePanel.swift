import SwiftUI

/// Painel completo de atualização in-app: etapas, barra de progresso, bytes e ações.
struct AppUpdatePanel: View {
    @ObservedObject var service: AppUpdateService
    @ObservedObject var settings: AppSettings
    var showsAppIdentity = true
    var isEmbedded = false

    var body: some View {
        if isEmbedded {
            content
        } else {
            content
                .padding(16)
                .orviaSettingsSurface(cornerRadius: 14)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsAppIdentity {
                header
                Divider()
            }

            statusContent

            if let progress = service.phase.progress {
                progressSection(progress)
            }

            actions

            if let release = service.phase.availableRelease, !release.notes.isEmpty, !service.phase.isBusy {
                notesSection(release)
            }

            footerNote
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            BrandLogoView(size: 44, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text("Orvia")
                    .font(.headline)
                Text(AppVersion.displayLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let lastChecked = service.lastCheckedAt {
                    Text(t("Verificado ", "Checked ") + relative(lastChecked))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if service.hasUpdateAvailable {
                Text(t("Nova", "New"))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.teal.opacity(0.18), in: Capsule())
                    .foregroundStyle(.teal)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch service.phase {
        case .idle:
            Label(t("Pronto para verificar atualizações.", "Ready to check for updates."), systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(t("Consultando GitHub Releases…", "Checking GitHub Releases…"))
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Label(t("Você está na versão mais recente.", "You're on the latest version."), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .available(let release):
            VStack(alignment: .leading, spacing: 6) {
                Text(t("Versão \(release.version) disponível", "Version \(release.version) available"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.teal)
                Text(release.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if release.zipByteCount > 0 {
                    Text(byteCount(Int64(release.zipByteCount)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        case .updating(let release, let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text(stageTitle(progress.stage, version: release.version))
                    .font(.headline)
                Text(stageSubtitle(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message, _):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressSection(_ progress: AppUpdateProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            stageStepper(current: progress.stage)

            if progress.stageFraction < 0 {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: progress.overallFraction)
                    .progressViewStyle(.linear)
                    .tint(.teal)
            }

            HStack {
                Text(percentLabel(progress.overallFraction))
                    .font(.caption.monospacedDigit().weight(.semibold))
                Spacer()
                if progress.stage == .downloading {
                    Text(downloadBytesLabel(progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 2)
    }

    private func stageStepper(current: AppUpdateProgress.Stage) -> some View {
        let stages: [(AppUpdateProgress.Stage, String)] = [
            (.downloading, t("Baixar", "Download")),
            (.verifying, t("Verificar", "Verify")),
            (.extracting, t("Extrair", "Extract")),
            (.installing, t("Instalar", "Install"))
        ]

        return HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, item in
                let done = stageIndex(current) > index
                let active = stageIndex(current) == index
                VStack(spacing: 4) {
                    Circle()
                        .fill(done || active ? Color.teal : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                    Text(item.1)
                        .font(.caption2.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)

                if index < stages.count - 1 {
                    Rectangle()
                        .fill(done ? Color.teal.opacity(0.7) : Color.secondary.opacity(0.2))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(t("Buscar", "Check")) {
                Task { await service.checkForUpdates(userInitiated: true) }
            }
            .buttonStyle(.bordered)
            .disabled(service.phase.isBusy)

            if case .available = service.phase {
                Button(t("Atualizar agora", "Update Now")) {
                    Task { await service.installAvailableUpdate() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            }

            if service.phase.canCancel {
                Button(t("Cancelar", "Cancel")) {
                    service.cancel()
                }
                .buttonStyle(.bordered)
            }

            if service.phase.availableRelease != nil {
                Button(t("Abrir no GitHub", "Open on GitHub")) {
                    service.openReleasePage()
                }
                .buttonStyle(.borderless)
            }

            Spacer(minLength: 0)
        }
    }

    private func notesSection(_ release: AppUpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Novidades", "What's New"))
                .font(.subheadline.weight(.semibold))
            ScrollView {
                Text(release.notes)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
        }
        .padding(.top, 4)
    }

    private var footerNote: some View {
        Text(t(
            "A instalação acontece dentro do app e substitui o Orvia no mesmo local, para preservar permissões sempre que o macOS permitir.",
            "Installation happens inside the app and replaces Orvia in the same location to preserve permissions whenever macOS allows."
        ))
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    private func stageTitle(_ stage: AppUpdateProgress.Stage, version: String) -> String {
        switch stage {
        case .checking:
            return t("Verificando…", "Checking…")
        case .downloading:
            return t("Baixando \(version)…", "Downloading \(version)…")
        case .verifying:
            return t("Verificando integridade…", "Verifying integrity…")
        case .extracting:
            return t("Preparando pacote…", "Preparing package…")
        case .installing:
            return t("Instalando e reiniciando…", "Installing and relaunching…")
        }
    }

    private func stageSubtitle(_ progress: AppUpdateProgress) -> String {
        switch progress.stage {
        case .checking:
            return t("Lendo a release mais recente.", "Reading the latest release.")
        case .downloading:
            return t("Download do Orvia.zip em andamento.", "Downloading Orvia.zip.")
        case .verifying:
            return t("Conferindo SHA-256 do pacote.", "Checking package SHA-256.")
        case .extracting:
            return t("Extraindo Orvia.app.", "Extracting Orvia.app.")
        case .installing:
            return t("Trocando o app no mesmo path.", "Replacing the app at the same path.")
        }
    }

    private func stageIndex(_ stage: AppUpdateProgress.Stage) -> Int {
        switch stage {
        case .checking: return -1
        case .downloading: return 0
        case .verifying: return 1
        case .extracting: return 2
        case .installing: return 3
        }
    }

    private func percentLabel(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    private func downloadBytesLabel(_ progress: AppUpdateProgress) -> String {
        if progress.bytesTotal > 0 {
            return "\(byteCount(progress.bytesReceived)) / \(byteCount(progress.bytesTotal))"
        }
        if progress.bytesReceived > 0 {
            return byteCount(progress.bytesReceived)
        }
        return t("calculando…", "calculating…")
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func t(_ pt: String, _ en: String) -> String {
        settings.text(ptBR: pt, en: en)
    }
}
