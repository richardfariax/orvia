import AVFoundation
import Foundation

/// Speaks locally using macOS voices. No transcript or audio leaves the Mac.
@MainActor
final class SpokenResponseService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?
    private var activeUtterance: AVSpeechUtterance?

    private(set) var speechProgress: Double = 0
    var playbackStartedHandler: (() -> Void)?
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
        speechProgress = 0
        speechProgressHandler?(0)
    }

    static func voice(for languageCode: String, preferredIdentifier: String) -> AVSpeechSynthesisVoice? {
        if !preferredIdentifier.isEmpty,
           let preferred = AVSpeechSynthesisVoice(identifier: preferredIdentifier),
           preferred.language.lowercased().hasPrefix(String(languageCode.lowercased().prefix(2))) {
            return preferred
        }
        if let automaticID = SpeechVoiceCatalog.shared.automaticVoiceIdentifier(for: languageCode),
           let automatic = AVSpeechSynthesisVoice(identifier: automaticID) {
            return automatic
        }
        return AVSpeechSynthesisVoice(language: languageCode)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard activeUtterance === utterance else { return }
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
            speechProgress = 1
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
        }
    }
}
