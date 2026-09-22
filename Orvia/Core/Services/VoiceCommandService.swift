import AVFoundation
import Foundation
import OSLog
import Speech

/// Escuta contínua do microfone usando Speech nativo (SFSpeechRecognizer, on-device
/// quando disponível). Detecta a wake word (ex.: "Orvia") e captura o comando falado
/// após ela, finalizando por pausa de fala.
@MainActor
final class VoiceCommandService: ObservableObject {
    enum ListeningState: Equatable {
        case disabled
        case listening
        case capturingCommand
        case unavailable(String)
    }

    @Published private(set) var state: ListeningState = .disabled
    @Published private(set) var capturedTranscript: String = ""

    /// Chamado quando a wake word é detectada (para exibir o HUD).
    var onWakeWordDetected: (() -> Void)?
    /// Transcript parcial do comando (para HUD ao vivo).
    var onPartialCommand: ((String) -> Void)?
    /// Comando finalizado (texto cru após a wake word).
    var onCommandCaptured: ((String) -> Void)?
    /// Nenhum comando falado dentro da janela após a wake word.
    var onCaptureCancelled: (() -> Void)?
    /// Nível do microfone 0...1 enquanto o engine está ativo (para o HUD).
    var inputLevelHandler: ((Double) -> Void)?

    private let settings: AppSettings

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var silenceTimer: Timer?
    private var sessionRestartTimer: Timer?
    private var commandTimeoutTimer: Timer?
    private var isEngineRunning = false
    private var commandStartOffset: Int?
    /// Verdadeiro entre a wake word e a finalização/timeout do comando.
    /// Sobrevive a reinícios de sessão de reconhecimento.
    private var isAwaitingCommand = false
    /// Sessão iniciada por atalho (push-to-talk): o microfone desliga ao terminar.
    private var isManualSession = false
    /// Identifica a sessão atual; callbacks de sessões canceladas são ignorados
    /// (cancelar uma task gera um callback de erro que causava loop de reinícios).
    private var sessionGeneration = 0
    private var isRestartScheduled = false
    /// Microfone pausado enquanto o assistente fala (evita auto-captura da própria voz).
    private var isPausedForSpeechOutput = false
    private var wasListeningBeforeSpeechPause = false
    /// Throttle do metering do mic (~30 Hz).
    private var lastInputLevelPublish: CFTimeInterval = 0
    private var smoothedInputLevel: Double = 0

    private let silenceInterval: TimeInterval = 1.2
    private let commandTimeoutInterval: TimeInterval = 8
    private let followUpTimeoutInterval: TimeInterval = 22
    private let followUpSilenceInterval: TimeInterval = 1.6
    private let sessionRestartInterval: TimeInterval = 50
    /// Timeout ativo da captura atual (comando normal vs follow-up).
    private var activeCaptureTimeout: TimeInterval = 8
    private var activeSilenceInterval: TimeInterval = 1.2
    /// Captura de resposta a uma pergunta do Orvia (sem wake word).
    private var isFollowUpCapture = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        guard state == .disabled || isUnavailable else { return }

        Task {
            let speechGranted = await Self.requestSpeechAuthorization()
            let micGranted = await Self.requestMicrophoneAuthorization()

            guard speechGranted, micGranted else {
                self.state = .unavailable(
                    self.settings.text(
                        ptBR: "Permissão de microfone ou reconhecimento de fala negada.",
                        en: "Microphone or speech recognition permission denied."
                    )
                )
                return
            }

            self.startRecognitionSession()
        }
    }

    func stop() {
        cancelCommandTimeout()
        isAwaitingCommand = false
        isFollowUpCapture = false
        isManualSession = false
        isPausedForSpeechOutput = false
        wasListeningBeforeSpeechPause = false
        tearDownRecognition()
        stopAudioEngine()
        publishInputLevel(0)
        state = .disabled
    }

    /// Suspende microfone e reconhecimento enquanto o Orvia fala a resposta.
    func pauseForSpeechOutput() {
        guard !isPausedForSpeechOutput else { return }

        isPausedForSpeechOutput = true
        wasListeningBeforeSpeechPause = settings.voiceActivationMode == .wakeWord
            && !isManualSession
            && state != .disabled
            && !isUnavailable

        isRestartScheduled = false
        cancelCommandTimeout()
        isAwaitingCommand = false
        isFollowUpCapture = false
        commandStartOffset = nil
        capturedTranscript = ""
        activeCaptureTimeout = commandTimeoutInterval
        activeSilenceInterval = silenceInterval
        tearDownRecognition()
        stopAudioEngine()
        publishInputLevel(0)
    }

    /// Retoma a escuta contínua (wake word) após a resposta falada terminar.
    func resumeAfterSpeechOutput() {
        guard isPausedForSpeechOutput else {
            // Já não está pausado (ex.: após follow-up): garante wake word se aplicável.
            if settings.voiceActivationMode == .wakeWord,
               state == .disabled || isUnavailable {
                startRecognitionSession()
            }
            return
        }

        isPausedForSpeechOutput = false
        let shouldResume = wasListeningBeforeSpeechPause
        wasListeningBeforeSpeechPause = false

        guard shouldResume, settings.voiceActivationMode == .wakeWord else { return }
        startRecognitionSession()
    }

    /// Ouve a resposta a uma pergunta do assistente, sem exigir wake word.
    func beginFollowUpCapture() {
        isPausedForSpeechOutput = false
        wasListeningBeforeSpeechPause = false
        isFollowUpCapture = true
        isAwaitingCommand = true
        activeCaptureTimeout = followUpTimeoutInterval
        activeSilenceInterval = followUpSilenceInterval

        // Hotkey / mic desligado: liga só para a resposta.
        if state == .disabled || isUnavailable || !isEngineRunning {
            beginManualCapture(isFollowUp: true)
            return
        }

        startRecognitionSession()
        guard state == .capturingCommand else {
            beginManualCapture(isFollowUp: true)
            return
        }
        startCommandTimeout()
        onWakeWordDetected?()
    }

    /// Push-to-talk: liga o microfone apenas para capturar um comando.
    /// Ao finalizar (ou expirar), o microfone é desligado por completo.
    func beginManualCapture(isFollowUp: Bool = false) {
        guard state == .disabled || isUnavailable || isFollowUp else { return }

        Task {
            let speechGranted = await Self.requestSpeechAuthorization()
            let micGranted = await Self.requestMicrophoneAuthorization()

            guard speechGranted, micGranted else {
                self.state = .unavailable(
                    self.settings.text(
                        ptBR: "Permissão de microfone ou reconhecimento de fala negada.",
                        en: "Microphone or speech recognition permission denied."
                    )
                )
                return
            }

            self.isManualSession = self.settings.voiceActivationMode == .hotkey
            self.isFollowUpCapture = isFollowUp
            self.isAwaitingCommand = true
            self.activeCaptureTimeout = isFollowUp ? self.followUpTimeoutInterval : self.commandTimeoutInterval
            self.activeSilenceInterval = isFollowUp ? self.followUpSilenceInterval : self.silenceInterval
            self.startRecognitionSession()
            guard self.state == .capturingCommand else { return }
            self.startCommandTimeout()
            self.onWakeWordDetected?()
        }
    }

    /// Aborta captura/follow-up em andamento (ex.: Esc no HUD) sem disparar comando.
    func cancelActiveInteraction() {
        cancelCommandTimeout()
        isAwaitingCommand = false
        isFollowUpCapture = false
        commandStartOffset = nil
        capturedTranscript = ""
        isPausedForSpeechOutput = false
        wasListeningBeforeSpeechPause = false
        publishInputLevel(0)

        if isManualSession || settings.voiceActivationMode == .hotkey {
            isManualSession = false
            tearDownRecognition()
            stopAudioEngine()
            state = .disabled
            return
        }

        // Wake word: volta a escutar a palavra de ativação.
        if state != .disabled {
            startRecognitionSession()
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    // MARK: - Recognition session

    private func startRecognitionSession() {
        guard !isPausedForSpeechOutput else { return }

        tearDownRecognition()

        let localeIdentifier = settings.text(ptBR: "pt-BR", en: "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            state = .unavailable(
                settings.text(
                    ptBR: "Reconhecimento de fala indisponível neste Mac.",
                    en: "Speech recognition unavailable on this Mac."
                )
            )
            return
        }
        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        if !startAudioEngineIfNeeded(feeding: request) {
            state = .unavailable(
                settings.text(
                    ptBR: "Não foi possível acessar o microfone.",
                    en: "Could not access the microphone."
                )
            )
            return
        }

        commandStartOffset = nil
        capturedTranscript = ""
        // Follow-up ou sessão que já espera comando: transcript inteiro é a resposta.
        if isAwaitingCommand || isFollowUpCapture {
            isAwaitingCommand = true
            commandStartOffset = 0
            state = .capturingCommand
        } else {
            state = .listening
        }

        sessionGeneration += 1
        let generation = sessionGeneration
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.sessionGeneration else { return }
                self.handleRecognition(result: result, error: error)
            }
        }

        if !isManualSession {
            scheduleSessionRestart()
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            processTranscript(result.bestTranscription.formattedString, isFinal: result.isFinal)
        }

        if error != nil || result?.isFinal == true {
            // Sessão terminou (limite de duração, silêncio longo ou erro): reinicia se ainda ativo.
            guard state != .disabled, !isUnavailable else { return }
            let pendingCommand = pendingCommandText()
            if let pendingCommand, !pendingCommand.isEmpty {
                finalizeCommand(pendingCommand)
            } else {
                restartAfterDelay()
            }
        }
    }

    private var lastFullTranscript: String = ""

    private func processTranscript(_ transcript: String, isFinal: Bool) {
        lastFullTranscript = transcript
        let normalized = VoiceCommandParser.normalize(transcript)

        if commandStartOffset == nil {
            guard let range = rangeOfWakeWord(in: normalized) else { return }
            commandStartOffset = normalized.distance(from: normalized.startIndex, to: range.upperBound)
            isAwaitingCommand = true
            state = .capturingCommand
            startCommandTimeout()
            onWakeWordDetected?()
        }

        let commandText = pendingCommandText() ?? ""
        capturedTranscript = commandText
        if !commandText.isEmpty {
            onPartialCommand?(commandText)
        }

        if isFinal, !commandText.isEmpty {
            finalizeCommand(commandText)
        } else {
            restartSilenceTimer()
        }
    }

    /// Texto após a wake word, extraído do transcript completo mais recente.
    /// Se a sessão foi reiniciada após a wake word (transcript zerado),
    /// o transcript inteiro é o comando.
    private func pendingCommandText() -> String? {
        guard commandStartOffset != nil else { return nil }

        // Extrai sufixo do transcript original preservando caixa/acentos.
        let folded = lastFullTranscript
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()

        let start: String.Index
        if let foldedRange = rangeOfWakeWord(in: folded) {
            let offset = folded.distance(from: folded.startIndex, to: foldedRange.upperBound)
            guard let mapped = lastFullTranscript.index(
                lastFullTranscript.startIndex,
                offsetBy: offset,
                limitedBy: lastFullTranscript.endIndex
            ) else { return nil }
            start = mapped
        } else if isAwaitingCommand {
            start = lastFullTranscript.startIndex
        } else {
            return nil
        }

        return String(lastFullTranscript[start...])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func restartSilenceTimer() {
        guard commandStartOffset != nil else { return }
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: activeSilenceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let command = self.pendingCommandText() ?? ""
                // Só finaliza quando há comando; se vazio, continua aguardando
                // dentro da janela de timeout (usuário pode ter pausado após a wake word).
                if !command.isEmpty {
                    self.finalizeCommand(command)
                }
            }
        }
    }

    private func finalizeCommand(_ command: String) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        cancelCommandTimeout()

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        commandStartOffset = nil
        isAwaitingCommand = false
        isFollowUpCapture = false
        activeCaptureTimeout = commandTimeoutInterval
        activeSilenceInterval = silenceInterval

        if !trimmed.isEmpty {
            onCommandCaptured?(trimmed)
        }

        concludeCaptureCycle()
    }

    // MARK: - Janela de comando

    private func startCommandTimeout() {
        cancelCommandTimeout()
        let timeout = activeCaptureTimeout
        commandTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAwaitingCommand else { return }
                let command = self.pendingCommandText() ?? ""
                if !command.isEmpty {
                    self.finalizeCommand(command)
                    return
                }
                self.isAwaitingCommand = false
                self.isFollowUpCapture = false
                self.commandStartOffset = nil
                self.activeCaptureTimeout = self.commandTimeoutInterval
                self.activeSilenceInterval = self.silenceInterval
                self.onCaptureCancelled?()
                self.concludeCaptureCycle()
            }
        }
    }

    private func cancelCommandTimeout() {
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = nil
    }

    // MARK: - Wake word

    /// Aceita variantes curtas do nome, priorizando as mais longas.
    private func wakeWordVariants() -> [String] {
        let base = normalizedWakeWord()
        var variants = [base]
        if base.hasSuffix("e") {
            variants.append(String(base.dropLast()))
        } else {
            variants.append(base + "e")
        }
        return variants.sorted { $0.count > $1.count }
    }

    private func rangeOfWakeWord(in text: String) -> Range<String.Index>? {
        for variant in wakeWordVariants() {
            if let range = text.range(of: variant, options: .backwards) {
                return range
            }
        }
        return nil
    }

    /// Fim de captura: em sessão manual desliga o microfone por completo;
    /// em escuta contínua reinicia a sessão de reconhecimento.
    private func concludeCaptureCycle() {
        if isManualSession {
            isManualSession = false
            tearDownRecognition()
            stopAudioEngine()
            state = .disabled
            return
        }
        restartAfterDelay()
    }

    private func restartAfterDelay() {
        guard !isRestartScheduled, !isPausedForSpeechOutput else { return }
        isRestartScheduled = true
        tearDownRecognition(keepEngine: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.isRestartScheduled = false
            guard self.state != .disabled else { return }
            self.startRecognitionSession()
        }
    }

    private func scheduleSessionRestart() {
        sessionRestartTimer?.invalidate()
        sessionRestartTimer = Timer.scheduledTimer(withTimeInterval: sessionRestartInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .listening, !self.isPausedForSpeechOutput else { return }
                self.startRecognitionSession()
            }
        }
    }

    private func normalizedWakeWord() -> String {
        let word = VoiceCommandParser.normalize(settings.voiceWakeWord)
        return word.isEmpty ? "orvia" : word
    }

    // MARK: - Audio engine

    private func startAudioEngineIfNeeded(feeding request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        let audioEngine = audioEngine ?? AVAudioEngine()
        self.audioEngine = audioEngine
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }

        inputNode.removeTap(onBus: 0)
        // Captura o request da sessão atual; o tap é reinstalado a cada sessão.
        do {
            try inputNode.__installTap(onBus: 0, bufferSize: 1024, format: format, error: ()) { [weak self, weak request] buffer, _ in
                request?.append(buffer)
                self?.handleInputBuffer(buffer)
            }
        } catch {
            Logger(subsystem: "com.richadfarias.orvia", category: "audio").error("[Orvia] Falha ao instalar tap de áudio: \(error.localizedDescription)")
            return false
        }

        if !isEngineRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
                isEngineRunning = true
            } catch {
                Logger(subsystem: "com.richadfarias.orvia", category: "audio").error("[Orvia] Falha ao iniciar AVAudioEngine: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        let raw = Self.normalizedRMS(from: buffer)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.smoothedInputLevel = self.smoothedInputLevel * 0.55 + Double(raw) * 0.45
            let now = CACurrentMediaTime()
            guard now - self.lastInputLevelPublish >= (1.0 / 30.0) else { return }
            self.lastInputLevelPublish = now
            self.inputLevelHandler?(self.smoothedInputLevel)
        }
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        let samples = UnsafeBufferPointer(start: channelData, count: frameCount)
        for sample in samples {
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let db = 20 * log10(max(rms, 1e-7))
        // Fala típica ~ -50…-8 dBFS
        return max(0, min(1, (db + 50) / 42))
    }

    private func publishInputLevel(_ level: Double) {
        smoothedInputLevel = level
        lastInputLevelPublish = 0
        inputLevelHandler?(level)
    }

    private func stopAudioEngine() {
        guard let audioEngine else {
            publishInputLevel(0)
            return
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        if isEngineRunning {
            audioEngine.stop()
            isEngineRunning = false
        }
        publishInputLevel(0)
    }

    private func tearDownRecognition(keepEngine: Bool = false) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        sessionRestartTimer?.invalidate()
        sessionRestartTimer = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        commandStartOffset = nil
        lastFullTranscript = ""

        if !keepEngine {
            stopAudioEngine()
        }
    }

    // MARK: - Authorization

    static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
