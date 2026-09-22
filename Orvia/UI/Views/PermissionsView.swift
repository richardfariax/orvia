import SwiftUI
import Combine

struct PermissionsView: View {
    @ObservedObject var permissionsManager: PermissionsManager
    @ObservedObject var settings: AppSettings
    @State private var refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                permissionProgress
            }

            Section {
                Text(t(
                    "Orvia precisa de Accessibility somente para colar automaticamente. Voz e captura de tela pedem permissões quando usadas.",
                    "Orvia needs Accessibility only for automatic paste. Voice and screen capture ask for access when used."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if permissionsManager.requiresRegrantAfterUpdate {
                    updateRegrantBanner
                } else if permissionsManager.missingRequiredPermissions {
                    Label(
                        t(
                            "Accessibility ausente — a colagem automática precisa desta permissão.",
                            "Accessibility missing — automatic paste needs this permission."
                        ),
                        systemImage: "lock.trianglebadge.exclamationmark.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if isRunningFromDerivedData {
                    Text(t(
                        "Rodando via Xcode/DerivedData — permissões valem só para este build. Use o .app em Applications para TCC estável.",
                        "Running from Xcode/DerivedData — permissions apply only to this build. Use the .app in Applications for stable TCC."
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section {
                permissionRow(
                    title: "Accessibility",
                    granted: permissionsManager.isAccessibilityGranted,
                    requestAction: permissionsManager.requestAccessibility,
                    openAction: permissionsManager.openAccessibilitySettings
                )

                permissionRow(
                    title: t("Microfone", "Microphone"),
                    granted: permissionsManager.isMicrophoneGranted,
                    requestAction: { permissionsManager.requestMicrophone() },
                    openAction: permissionsManager.openMicrophoneSettings
                )

                permissionRow(
                    title: t("Reconhecimento de Fala", "Speech Recognition"),
                    granted: permissionsManager.isSpeechRecognitionGranted,
                    requestAction: { permissionsManager.requestSpeechRecognition() },
                    openAction: permissionsManager.openSpeechRecognitionSettings
                )

                permissionRow(
                    title: t("Gravação de Tela", "Screen Recording"),
                    granted: permissionsManager.isScreenCaptureGranted,
                    requestAction: permissionsManager.requestScreenCapture,
                    openAction: permissionsManager.openScreenCaptureSettings
                )
            } footer: {
                Text(t(
                    "Depois de conceder, volte ao app. Gravação de Tela pode exigir reiniciar o Orvia.",
                    "After granting, return to the app. Screen Recording may require restarting Orvia."
                ))
            }
        }
        .orviaSettingsFormStyle()
        .onAppear {
            permissionsManager.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionsManager.refresh()
        }
        .onReceive(refreshTimer) { _ in
            permissionsManager.refresh()
        }
    }

    private var permissionProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    permissionsManager.hasAllFeaturePermissions
                        ? t("Tudo pronto", "All set")
                        : t("Configuração guiada", "Guided setup"),
                    systemImage: permissionsManager.hasAllFeaturePermissions ? "checkmark.shield.fill" : "wand.and.stars"
                )
                .font(.headline)
                .foregroundStyle(permissionsManager.hasAllFeaturePermissions ? .green : .blue)
                Spacer()
                Text("\(grantedPermissionCount)/4")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(grantedPermissionCount), total: 4)

            if !permissionsManager.hasAllFeaturePermissions {
                Button(t("Configurar próxima permissão", "Configure next permission")) {
                    permissionsManager.requestNextMissingPermission()
                }
                .buttonStyle(.borderedProminent)
            }

            Text(t(
                "O app conduz uma permissão por vez. Por segurança, o macOS sempre exige sua confirmação nos Ajustes.",
                "The app guides you through one permission at a time. For security, macOS always requires your confirmation in Settings."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var grantedPermissionCount: Int {
        [
            permissionsManager.isAccessibilityGranted,
            permissionsManager.isScreenCaptureGranted,
            permissionsManager.isMicrophoneGranted,
            permissionsManager.isSpeechRecognitionGranted
        ].filter { $0 }.count
    }

    private var updateRegrantBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                t(
                    "Update/reinstall — reconceda Accessibility",
                    "Update/reinstall — re-grant Accessibility"
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)

            Text(t(
                "O macOS amarra essas permissões ao binário. Solicite de novo ou reative em Ajustes → Privacidade.",
                "macOS binds these permissions to the binary. Request again or re-enable in Settings → Privacy."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(t("Solicitar de novo", "Request again")) {
                    permissionsManager.requestNextMissingPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(t("Abrir Accessibility", "Open Accessibility")) {
                    permissionsManager.openAccessibilitySettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(.bottom, 4)
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        requestAction: @escaping () -> Void,
        openAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(granted ? t("Concedida", "Granted") : t("Não concedida", "Not granted"))
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
            }

            Spacer()

            Button(t("Solicitar", "Request")) {
                requestAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(granted)

            Button {
                permissionsManager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(t("Reverificar status", "Refresh status"))

            Button(t("Abrir Ajustes", "Open Settings")) {
                openAction()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var isRunningFromDerivedData: Bool {
        Bundle.main.bundlePath.contains("DerivedData")
    }

    private func t(_ pt: String, _ en: String) -> String {
        settings.text(ptBR: pt, en: en)
    }
}
