import AVFoundation
import Foundation

/// Speaks locally using macOS voices. No transcript or audio leaves the Mac.
@MainActor
final class SpokenResponseService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?
    private var activeUtterance: AVSpeechUtterance?

    private(set) var speechLevel: Double = 0
    private(set) var speechProgress: Double = 0
    var playbackStartedHandler: (() -> Void)?
    var speechLevelHandler: ((Double) -> Void)?
    var speechProgressHandler: ((Double) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ text: String,
        languageCode: String,
        preferredVoiceIdentifier: String = "",
        completion: (() -> Void)? = nil
    ) {
        stop()
        guard !text.isEmpty else {
            completion?()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: languageCode, preferredIdentifier: preferredVoiceIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        activeUtterance = utterance
        onFinish = completion
        synthesizer.speak(utterance)
    }

    func stop() {
        onFinish = nil
        activeUtterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speechLevel = 0
        speechProgress = 0
        speechLevelHandler?(0)
        speechProgressHandler?(0)
    }

    static func availableVoices(for languageCode: String) -> [AVSpeechSynthesisVoice] {
        let target = languageCode.lowercased()
        let prefix = String(target.prefix(2))
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let exact = installed.filter { $0.language.lowercased() == target }
        let matching = exact.isEmpty
            ? installed.filter { $0.language.lowercased().hasPrefix(prefix) }
            : exact
        return matching.enumerated().sorted {
            if $0.element.quality.rawValue != $1.element.quality.rawValue {
                return $0.element.quality.rawValue > $1.element.quality.rawValue
            }
            let firstIsEffect = $0.element.voiceTraits.contains(.isNoveltyVoice)
                || $0.element.identifier.contains(".eloquence.")
            let secondIsEffect = $1.element.voiceTraits.contains(.isNoveltyVoice)
                || $1.element.identifier.contains(".eloquence.")
            if firstIsEffect != secondIsEffect { return !firstIsEffect }
            // Mantém a preferência do sistema quando qualidade e tipo são equivalentes.
            return $0.offset < $1.offset
        }.map(\.element)
    }

    static func voice(for languageCode: String, preferredIdentifier: String) -> AVSpeechSynthesisVoice? {
        let voices = availableVoices(for: languageCode)
        if let preferred = voices.first(where: { $0.identifier == preferredIdentifier }) {
            return preferred
        }
        return voices.first ?? AVSpeechSynthesisVoice(language: languageCode)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard activeUtterance === utterance else { return }
            speechLevel = 1
            speechLevelHandler?(1)
            playbackStartedHandler?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard activeUtterance === utterance else { return }
            let length = (utterance.speechString as NSString).length
            guard length > 0 else { return }
            speechProgress = min(1, Double(NSMaxRange(characterRange)) / Double(length))
            speechProgressHandler?(speechProgress)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard activeUtterance === utterance else { return }
            activeUtterance = nil
            speechLevel = 0
            speechProgress = 1
            speechLevelHandler?(0)
            speechProgressHandler?(1)
            let completion = onFinish
            onFinish = nil
            completion?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard activeUtterance === utterance else { return }
            activeUtterance = nil
            speechLevel = 0
            speechLevelHandler?(0)
        }
    }
}
