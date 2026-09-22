import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import Speech

/// Identidade da instalação. Update/reinstall/path novo pode invalidar TCC;
/// flags de "já pedi" em UserDefaults ficam obsoletos.
private struct AppInstallIdentity: Codable, Equatable {
    var marketingVersion: String
    var build: String
    var bundlePath: String
    var executableFingerprint: String

    static func current() -> AppInstallIdentity {
        let executableURL = Bundle.main.executableURL
        var fingerprint = "unknown"
        if let executableURL,
           let values = try? executableURL.resourceValues(forKeys: [.fileSizeKey]) {
            let size = values.fileSize ?? 0
            fingerprint = "\(size)"
        }

        return AppInstallIdentity(
            marketingVersion: AppVersion.marketing,
            build: AppVersion.build,
            bundlePath: Bundle.main.bundlePath,
            executableFingerprint: fingerprint
        )
    }
}

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var isAccessibilityGranted: Bool = AXIsProcessTrusted()
    @Published private(set) var isMicrophoneGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var isSpeechRecognitionGranted: Bool = SFSpeechRecognizer.authorizationStatus() == .authorized
    @Published private(set) var isScreenCaptureGranted: Bool = false

    /// Acessibilidade é necessária apenas para colagem automática.
    @Published private(set) var missingRequiredPermissions: Bool = false

    /// Update/reinstall detectado com permissões críticas ausentes.
    @Published private(set) var requiresRegrantAfterUpdate: Bool = false

    private let defaults = UserDefaults.standard
    private let identityKey = "orvia.permissions.installIdentity"

    var hasRequiredPermissions: Bool {
        isAccessibilityGranted
    }

    var hasAllFeaturePermissions: Bool {
        hasRequiredPermissions && isMicrophoneGranted && isSpeechRecognitionGranted && isScreenCaptureGranted
    }

    func refresh() {
        isAccessibilityGranted = AXIsProcessTrusted()
        isMicrophoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        isSpeechRecognitionGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        isScreenCaptureGranted = screenCaptureAccessGranted()
        missingRequiredPermissions = !hasRequiredPermissions

        if hasRequiredPermissions {
            requiresRegrantAfterUpdate = false
        }
    }

    /// Valida TCC na abertura; re-solicita se a instalação mudou ou faltam permissões críticas.
    func validatePermissionsOnLaunch() {
        refresh()

        let currentIdentity = AppInstallIdentity.current()
        let previousIdentity = loadStoredIdentity()
        let identityChanged = previousIdentity != currentIdentity

        if identityChanged {
            clearPromptedFlags()

            let hadPreviousInstall = previousIdentity != nil
            if hadPreviousInstall && !hasRequiredPermissions {
                requiresRegrantAfterUpdate = true
            }
        }

        saveIdentity(currentIdentity)
        // A configuração é guiada dentro do app. Abrir vários prompts do macOS
        // durante o launch gera uma experiência confusa e difícil de recuperar.
    }

    func requestScreenCapture() {
        ScreenAnalysisService.requestScreenCaptureAccessIfNeeded()
        scheduleRefreshes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.isScreenCaptureGranted else { return }
            self.openScreenCaptureSettings()
        }
    }

    func openScreenCaptureSettings() {
        openPrivacySettings(urls: [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ])
        scheduleRefreshes()
    }

    func requestVoicePermissions(completion: @escaping (Bool) -> Void) {
        requestSpeechRecognition { [weak self] speechGranted in
            self?.requestMicrophone { microphoneGranted in
                completion(speechGranted && microphoneGranted)
            }
        }
    }

    func requestMicrophone(completion: @escaping (Bool) -> Void = { _ in }) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.refresh()
                completion(granted)
            }
        }
    }

    func requestSpeechRecognition(completion: @escaping (Bool) -> Void = { _ in }) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.refresh()
                completion(status == .authorized)
            }
        }
    }

    func requestNextMissingPermission() {
        refresh()
        if !isAccessibilityGranted {
            requestAccessibility()
        } else if !isScreenCaptureGranted {
            requestScreenCapture()
        } else if !isMicrophoneGranted {
            requestMicrophone()
        } else if !isSpeechRecognitionGranted {
            requestSpeechRecognition()
        }
    }

    func openMicrophoneSettings() {
        openPrivacySettings(urls: [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ])
        scheduleRefreshes()
    }

    func openSpeechRecognitionSettings() {
        openPrivacySettings(urls: [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        ])
        scheduleRefreshes()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        scheduleRefreshes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.isAccessibilityGranted else { return }
            self.openAccessibilitySettings()
        }
    }

    func openAccessibilitySettings() {
        openPrivacySettings(urls: [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ])
        scheduleRefreshes()
    }

    // MARK: - Private

    private func clearPromptedFlags() {
        // Compatibilidade com versões anteriores, que persistiam prompts no launch.
        defaults.removeObject(forKey: "orvia.permissions.prompted.accessibility")
        defaults.removeObject(forKey: "orvia.permissions.prompted.inputMonitoring")
    }

    private func loadStoredIdentity() -> AppInstallIdentity? {
        guard let data = defaults.data(forKey: identityKey) else { return nil }
        return try? JSONDecoder().decode(AppInstallIdentity.self, from: data)
    }

    private func saveIdentity(_ identity: AppInstallIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: identityKey)
    }

    private func screenCaptureAccessGranted() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return false
    }

    private func openPrivacySettings(urls: [String]) {
        for rawURL in urls {
            guard let url = URL(string: rawURL) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func scheduleRefreshes() {
        refresh()
        let delays: [TimeInterval] = [0.6, 1.5, 3.0, 5.0, 8.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }
}
