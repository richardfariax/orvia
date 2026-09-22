import Carbon
import Foundation

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "Sistema"
        case .light:
            return "Claro"
        case .dark:
            return "Escuro"
        }
    }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .system:
            return language.text(ptBR: "Sistema", en: "System")
        case .light:
            return language.text(ptBR: "Claro", en: "Light")
        case .dark:
            return language.text(ptBR: "Escuro", en: "Dark")
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case portuguese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .portuguese:
            return "Português"
        case .english:
            return "English"
        }
    }

    func text(ptBR: String, en: String) -> String {
        switch self {
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("pt") == true ? ptBR : en
        case .portuguese:
            return ptBR
        case .english:
            return en
        }
    }
}

enum VoiceActivationMode: String, CaseIterable, Identifiable {
    /// Microfone sempre aberto, aguardando a wake word (indicador do macOS fica aceso).
    case wakeWord
    /// Microfone abre apenas ao pressionar o atalho e fecha após o comando.
    case hotkey

    var id: String { rawValue }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .wakeWord:
            return language.text(ptBR: "Sempre ouvindo (wake word)", en: "Always listening (wake word)")
        case .hotkey:
            return language.text(ptBR: "Atalho (⌥⇧V)", en: "Hotkey (⌥⇧V)")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let historyLimit = "historyLimit"
        static let historyRetentionDays = "historyRetentionDays"
        static let pauseMonitoring = "pauseMonitoring"
        static let enableEncryption = "enableEncryption"
        static let ignoredBundleIDs = "ignoredBundleIDs"
        static let hotkeyCode = "hotkeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let launchAtLogin = "launchAtLogin"
        static let appearance = "appearance"
        static let language = "language"
        static let voiceControlEnabled = "voiceControlEnabled"
        static let voiceWakeWord = "voiceWakeWord"
        static let voiceSoundFeedback = "voiceSoundFeedback"
        static let voiceActivationMode = "voiceActivationMode"
        static let voiceSpokenResponses = "voiceSpokenResponses"
        static let generativeAnswersEnabled = "generativeAnswersEnabled"
        static let generativeUseWebContext = "generativeUseWebContext"
        static let userName = "userName"
        static let menuBarMetrics = "menuBarMetrics"
        static let legacyMenuBarPrimaryMetric = "menuBarPrimaryMetric"
        static let legacyUseNotchLeftOverflow = "useNotchLeftOverflow"
        static let metricsPopoverMode = "metricsPopoverMode"
    }

    @Published var historyLimit: Int {
        didSet {
            let normalized = Self.normalizedHistoryLimit(historyLimit)
            if historyLimit != normalized {
                historyLimit = normalized
                return
            }
            userDefaults.set(historyLimit, forKey: Keys.historyLimit)
        }
    }

    @Published var historyRetentionDays: Int {
        didSet {
            let normalized = min(max(historyRetentionDays, 0), 365)
            if historyRetentionDays != normalized {
                historyRetentionDays = normalized
                return
            }
            userDefaults.set(historyRetentionDays, forKey: Keys.historyRetentionDays)
        }
    }

    @Published var pauseMonitoring: Bool {
        didSet { userDefaults.set(pauseMonitoring, forKey: Keys.pauseMonitoring) }
    }

    @Published var enableEncryption: Bool {
        didSet { userDefaults.set(enableEncryption, forKey: Keys.enableEncryption) }
    }

    @Published var launchAtLogin: Bool {
        didSet { userDefaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    @Published var ignoredBundleIDs: [String] {
        didSet {
            let normalized = Self.normalizedBundleIDs(ignoredBundleIDs)
            if ignoredBundleIDs != normalized {
                ignoredBundleIDs = normalized
                return
            }
            userDefaults.set(ignoredBundleIDs, forKey: Keys.ignoredBundleIDs)
        }
    }

    @Published var hotkeyCode: UInt32 {
        didSet {
            let normalized = Self.normalizedHotkeyCode(hotkeyCode)
            if hotkeyCode != normalized {
                hotkeyCode = normalized
                return
            }
            userDefaults.set(Int(hotkeyCode), forKey: Keys.hotkeyCode)
        }
    }

    @Published var hotkeyModifiers: UInt32 {
        didSet {
            let normalized = Self.normalizedHotkeyModifiers(hotkeyModifiers)
            if hotkeyModifiers != normalized {
                hotkeyModifiers = normalized
                return
            }
            userDefaults.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers)
        }
    }

    @Published var appearance: AppAppearance {
        didSet { userDefaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var language: AppLanguage {
        didSet { userDefaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published var voiceControlEnabled: Bool {
        didSet { userDefaults.set(voiceControlEnabled, forKey: Keys.voiceControlEnabled) }
    }

    @Published var voiceSoundFeedback: Bool {
        didSet { userDefaults.set(voiceSoundFeedback, forKey: Keys.voiceSoundFeedback) }
    }

    @Published var voiceSpokenResponses: Bool {
        didSet { userDefaults.set(voiceSpokenResponses, forKey: Keys.voiceSpokenResponses) }
    }

    /// Respostas generativas via Apple Foundation Models (Apple Intelligence).
    @Published var generativeAnswersEnabled: Bool {
        didSet { userDefaults.set(generativeAnswersEnabled, forKey: Keys.generativeAnswersEnabled) }
    }

    /// Enriquece o prompt com trechos da web (gratuito) para fatos recentes.
    @Published var generativeUseWebContext: Bool {
        didSet { userDefaults.set(generativeUseWebContext, forKey: Keys.generativeUseWebContext) }
    }

    @Published var voiceActivationMode: VoiceActivationMode {
        didSet { userDefaults.set(voiceActivationMode.rawValue, forKey: Keys.voiceActivationMode) }
    }

    @Published var userName: String {
        didSet { userDefaults.set(userName, forKey: Keys.userName) }
    }

    @Published var voiceWakeWord: String {
        didSet {
            let normalized = Self.normalizedWakeWord(voiceWakeWord)
            if voiceWakeWord != normalized {
                voiceWakeWord = normalized
                return
            }
            userDefaults.set(voiceWakeWord, forKey: Keys.voiceWakeWord)
        }
    }

    @Published var menuBarMetrics: [MenuBarMetric] {
        didSet {
            let normalized = Self.normalizedMenuBarMetrics(menuBarMetrics)
            if menuBarMetrics != normalized {
                menuBarMetrics = normalized
                return
            }
            userDefaults.set(menuBarMetrics.map(\.rawValue), forKey: Keys.menuBarMetrics)
        }
    }

    @Published var metricsPopoverMode: MetricsPopoverMode {
        didSet { userDefaults.set(metricsPopoverMode.rawValue, forKey: Keys.metricsPopoverMode) }
    }

    private let userDefaults: UserDefaults

    var hotkeyDisplay: String {
        HotkeyFormatter.displayString(keyCode: hotkeyCode, modifiers: hotkeyModifiers)
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let savedHistoryLimit = userDefaults.object(forKey: Keys.historyLimit) as? Int ?? 500
        historyLimit = Self.normalizedHistoryLimit(savedHistoryLimit)
        historyRetentionDays = min(max(userDefaults.object(forKey: Keys.historyRetentionDays) as? Int ?? 0, 0), 365)

        pauseMonitoring = userDefaults.object(forKey: Keys.pauseMonitoring) as? Bool ?? false
        enableEncryption = userDefaults.object(forKey: Keys.enableEncryption) as? Bool ?? false
        launchAtLogin = userDefaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false

        if let savedIgnored = userDefaults.object(forKey: Keys.ignoredBundleIDs) as? [String] {
            ignoredBundleIDs = Self.normalizedBundleIDs(savedIgnored)
        } else {
            let emptyIgnoredBundleIDs: [String] = []
            ignoredBundleIDs = emptyIgnoredBundleIDs
            userDefaults.set(emptyIgnoredBundleIDs, forKey: Keys.ignoredBundleIDs)
        }

        let savedHotkeyCode = UInt32(userDefaults.object(forKey: Keys.hotkeyCode) as? Int ?? Int(kVK_ANSI_V))
        hotkeyCode = Self.normalizedHotkeyCode(savedHotkeyCode)

        let savedModifiers = UInt32(userDefaults.object(forKey: Keys.hotkeyModifiers) as? Int ?? optionKey)
        hotkeyModifiers = Self.normalizedHotkeyModifiers(savedModifiers)

        if let storedAppearanceRaw = userDefaults.string(forKey: Keys.appearance),
           let storedAppearance = AppAppearance(rawValue: storedAppearanceRaw) {
            appearance = storedAppearance
        } else {
            appearance = .system
        }

        if let storedLanguageRaw = userDefaults.string(forKey: Keys.language),
           let storedLanguage = AppLanguage(rawValue: storedLanguageRaw) {
            language = storedLanguage
        } else {
            language = .system
        }

        voiceControlEnabled = userDefaults.object(forKey: Keys.voiceControlEnabled) as? Bool ?? false
        voiceSoundFeedback = userDefaults.object(forKey: Keys.voiceSoundFeedback) as? Bool ?? true
        voiceSpokenResponses = userDefaults.object(forKey: Keys.voiceSpokenResponses) as? Bool ?? true
        generativeAnswersEnabled = userDefaults.object(forKey: Keys.generativeAnswersEnabled) as? Bool ?? true
        generativeUseWebContext = userDefaults.object(forKey: Keys.generativeUseWebContext) as? Bool ?? true
        voiceWakeWord = Self.normalizedWakeWord(userDefaults.string(forKey: Keys.voiceWakeWord) ?? "orvia")
        userName = userDefaults.string(forKey: Keys.userName) ?? ""

        if let storedModeRaw = userDefaults.string(forKey: Keys.voiceActivationMode),
           let storedMode = VoiceActivationMode(rawValue: storedModeRaw) {
            voiceActivationMode = storedMode
        } else {
            // Padrão discreto: microfone abre apenas quando o atalho é pressionado.
            voiceActivationMode = .hotkey
        }

        if let stored = userDefaults.stringArray(forKey: Keys.menuBarMetrics) {
            menuBarMetrics = Self.normalizedMenuBarMetrics(stored.compactMap(MenuBarMetric.init(rawValue:)))
        } else if let previous = userDefaults.string(forKey: Keys.legacyMenuBarPrimaryMetric)
            .flatMap(MenuBarMetric.init(rawValue:)), MenuBarMetric.statusBarChoices.contains(previous) {
            menuBarMetrics = Self.normalizedMenuBarMetrics(
                [previous] + MenuBarMetric.defaultStatusBarMetrics
            )
        } else {
            menuBarMetrics = MenuBarMetric.defaultStatusBarMetrics
        }
        userDefaults.removeObject(forKey: Keys.legacyMenuBarPrimaryMetric)
        userDefaults.removeObject(forKey: Keys.legacyUseNotchLeftOverflow)
        metricsPopoverMode = userDefaults.string(forKey: Keys.metricsPopoverMode)
            .flatMap(MetricsPopoverMode.init(rawValue:)) ?? .summary
    }

    private static func normalizedHistoryLimit(_ value: Int) -> Int {
        min(max(value, 50), 5000)
    }

    private static func normalizedMenuBarMetrics(_ metrics: [MenuBarMetric]) -> [MenuBarMetric] {
        var seen: Set<MenuBarMetric> = []
        return Array(metrics.filter { MenuBarMetric.statusBarChoices.contains($0) && seen.insert($0).inserted }.prefix(3))
    }

    private static func normalizedBundleIDs(_ value: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for item in value {
            let cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            normalized.append(cleaned)
        }

        return normalized
    }

    private static func normalizedHotkeyCode(_ value: UInt32) -> UInt32 {
        if value == 0 {
            return UInt32(kVK_ANSI_V)
        }
        return value
    }

    private static func normalizedWakeWord(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned.isEmpty ? "orvia" : cleaned
    }

    private static func normalizedHotkeyModifiers(_ value: UInt32) -> UInt32 {
        if value == 0 {
            return UInt32(optionKey)
        }
        return value
    }

    func text(ptBR: String, en: String) -> String {
        language.text(ptBR: ptBR, en: en)
    }
}
