import AVFoundation
import Combine
import Foundation

struct SpeechVoiceOption: Identifiable, Equatable, Sendable {
    enum Quality: Sendable {
        case standard
        case enhanced
        case premium
    }

    let id: String
    let name: String
    let quality: Quality
}

/// Loads the system voice inventory off the UI thread. The system call can stall
/// while speech is active, so SwiftUI must only read this published snapshot.
@MainActor
final class SpeechVoiceCatalog: ObservableObject {
    static let shared = SpeechVoiceCatalog()

    @Published private(set) var voices: [SpeechVoiceOption] = []
    @Published private(set) var isLoading = false

    private(set) var languageCode = ""
    private var requestID = 0
    private var voicesChangedObserver: NSObjectProtocol?

    private init() {
        voicesChangedObserver = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.languageCode.isEmpty else { return }
                self.load(for: self.languageCode, force: true)
            }
        }
    }

    func load(for languageCode: String, force: Bool = false) {
        let requestedLanguage = languageCode.lowercased()
        guard force || requestedLanguage != self.languageCode || voices.isEmpty && !isLoading else { return }

        self.languageCode = requestedLanguage
        requestID += 1
        let currentRequestID = requestID
        isLoading = true

        Task { [weak self] in
            let discovered = await Task.detached(priority: .userInitiated) {
                Self.discover(for: requestedLanguage)
            }.value
            guard let self, self.requestID == currentRequestID else { return }
            self.voices = discovered
            self.isLoading = false
        }
    }

    func automaticVoiceIdentifier(for languageCode: String) -> String? {
        guard self.languageCode == languageCode.lowercased() else { return nil }
        return voices.first?.id
    }

    nonisolated private static func discover(for languageCode: String) -> [SpeechVoiceOption] {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let exact = installed.filter { $0.language.lowercased() == languageCode }
        let prefix = String(languageCode.prefix(2))
        let matching = exact.isEmpty
            ? installed.filter { $0.language.lowercased().hasPrefix(prefix) }
            : exact

        return matching.enumerated().sorted { first, second in
            if first.element.quality.rawValue != second.element.quality.rawValue {
                return first.element.quality.rawValue > second.element.quality.rawValue
            }
            let firstIsEffect = first.element.voiceTraits.contains(.isNoveltyVoice)
                || first.element.identifier.contains(".eloquence.")
            let secondIsEffect = second.element.voiceTraits.contains(.isNoveltyVoice)
                || second.element.identifier.contains(".eloquence.")
            if firstIsEffect != secondIsEffect { return !firstIsEffect }
            return first.offset < second.offset
        }.map { indexedVoice in
            let voice = indexedVoice.element
            let quality: SpeechVoiceOption.Quality
            switch voice.quality {
            case .premium: quality = .premium
            case .enhanced: quality = .enhanced
            default: quality = .standard
            }
            return SpeechVoiceOption(id: voice.identifier, name: voice.name, quality: quality)
        }
    }
}
