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

    func speak(_ text: String, languageCode: String, completion: (() -> Void)? = nil) {
        stop()
        guard !text.isEmpty else {
            completion?()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(for: languageCode)
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

    private func bestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let target = languageCode.lowercased()
        let prefix = String(target.prefix(2))
        let exact = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased() == target }
        let related = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix(prefix) }
        for pool in [exact, related] {
            if let premium = pool.first(where: { $0.quality == .premium }) { return premium }
            if let enhanced = pool.first(where: { $0.quality == .enhanced }) { return enhanced }
            if let standard = pool.first { return standard }
        }
        return AVSpeechSynthesisVoice(language: languageCode)
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
