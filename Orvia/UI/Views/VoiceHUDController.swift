import AppKit
import Carbon
import SwiftUI

@MainActor
final class VoiceHUDModel: ObservableObject {
    enum Phase: Equatable {
        case listening
        case searchingWeb
        case thinking
        case speaking(message: String, success: Bool)
        case feedback(message: String, success: Bool)
    }

    @Published var phase: Phase = .listening
    @Published var transcript: String = ""
    @Published var hintText: String = ""
    @Published var statusText: String = ""
    /// 0...1 — energia do microfone (usuário falando).
    @Published var userLevel: Double = 0
    /// 0...1 — energia do TTS (Orvia falando).
    @Published var assistantLevel: Double = 0
    /// 0...1 — progresso da leitura do texto pelo TTS.
    @Published var speechProgress: Double = 0
}

/// Overlay de tela cheia com campo de voz profissional (user vs Orvia).
@MainActor
final class VoiceHUDController {
    private enum FeedbackSound: String {
        case wake = "Pop"
        case success = "Glass"
        case failure = "Basso"
    }

    var isSoundEnabled: () -> Bool = { true }
    /// Esc: aborta a interação atual (fala, captura, follow-up) e fecha o HUD.
    var onEscape: (() -> Void)?

    private var panel: NSPanel?
    private let model = VoiceHUDModel()
    private var hideWorkItem: DispatchWorkItem?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    var isVisible: Bool {
        panel?.isVisible == true && (panel?.alphaValue ?? 0) > 0.05
    }

    func showListening(hint: String) {
        hideWorkItem?.cancel()
        model.phase = .listening
        model.transcript = ""
        model.hintText = hint
        model.statusText = ""
        model.assistantLevel = 0
        model.speechProgress = 0
        presentPanel()
        play(.wake)
        announce(hint)
    }

    func updateTranscript(_ transcript: String) {
        model.transcript = transcript
    }

    func showSearching(message: String) {
        hideWorkItem?.cancel()
        model.phase = .searchingWeb
        model.statusText = message
        model.userLevel = 0
        model.assistantLevel = 0
        model.speechProgress = 0
        presentPanel()
        announce(message)
    }

    func showThinking(message: String) {
        hideWorkItem?.cancel()
        model.phase = .thinking
        model.statusText = message
        model.userLevel = 0
        model.assistantLevel = 0
        model.speechProgress = 0
        presentPanel()
        announce(message)
    }

    /// Mostra a resposta. `speaking` só deve ser true quando o áudio já estiver tocando.
    func showFeedback(message: String, success: Bool, autoHide: Bool = true, speaking: Bool = false) {
        hideWorkItem?.cancel()
        if speaking {
            model.phase = .speaking(message: message, success: success)
        } else {
            model.phase = .feedback(message: message, success: success)
        }
        model.statusText = ""
        model.userLevel = 0
        if !speaking {
            model.assistantLevel = 0
            model.speechProgress = 0
        } else {
            model.speechProgress = 0
        }
        presentPanel()
        play(success ? .success : .failure)
        announce(message)
        if autoHide {
            scheduleHide(after: 2.6)
        }
    }

    func setSpeaking(_ speaking: Bool) {
        switch model.phase {
        case .speaking(let message, let success):
            if !speaking {
                model.phase = .feedback(message: message, success: success)
                model.assistantLevel = 0
                model.speechProgress = 1
            }
        case .feedback(let message, let success):
            if speaking {
                model.phase = .speaking(message: message, success: success)
                model.speechProgress = 0
            }
        case .thinking, .searchingWeb, .listening:
            break
        }
    }

    func updateUserLevel(_ level: Double) {
        guard case .listening = model.phase else {
            model.userLevel = 0
            return
        }
        model.userLevel = max(0, min(1, level))
    }

    func updateAssistantLevel(_ level: Double) {
        model.assistantLevel = max(0, min(1, level))
    }

    func updateSpeechProgress(_ progress: Double) {
        model.speechProgress = max(0, min(1, progress))
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        removeEscapeMonitors()
        model.userLevel = 0
        model.assistantLevel = 0
        model.speechProgress = 0
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func handleEscape() {
        onEscape?()
    }

    private func installEscapeMonitorsIfNeeded() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isVisible, Int(event.keyCode) == kVK_Escape else {
                    return event
                }
                self.handleEscape()
                return nil
            }
        }

        if globalKeyMonitor == nil {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isVisible, Int(event.keyCode) == kVK_Escape else { return }
                DispatchQueue.main.async {
                    self.handleEscape()
                }
            }
        }
    }

    private func removeEscapeMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private func play(_ sound: FeedbackSound) {
        guard isSoundEnabled() else { return }
        NSSound(named: sound.rawValue)?.play()
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func presentPanel() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }

        panel.setFrame(activeScreenFrame(), display: true)
        installEscapeMonitorsIfNeeded()

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: VoiceHUDView(model: model))

        let panel = NSPanel(
            contentRect: activeScreenFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel("Orvia")
        return panel
    }

    private func activeScreenFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        return screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
    }
}

// MARK: - View

struct VoiceHUDView: View {
    @ObservedObject var model: VoiceHUDModel

    var body: some View {
        VoiceFieldView(
            phaseLabel: phaseLabel,
            message: primaryMessage,
            statusLine: statusLine,
            speaker: activeSpeaker,
            userLevel: model.userLevel,
            assistantLevel: model.assistantLevel,
            speechProgress: model.speechProgress,
            isSpeakingCaption: isSpeakingCaption,
            isProcessing: isProcessing,
            accent: accent,
            successTint: successTint
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.28), value: moodKey)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(primaryMessage)
    }

    private var primaryMessage: String {
        switch model.phase {
        case .listening:
            return model.transcript.isEmpty ? model.hintText : model.transcript
        case .searchingWeb, .thinking:
            return model.statusText
        case .speaking(let message, _), .feedback(let message, _):
            return message
        }
    }

    private var statusLine: String {
        switch model.phase {
        case .listening:
            return model.transcript.isEmpty ? "" : "Transcrição"
        case .searchingWeb:
            return "Internet"
        case .thinking:
            return "Modelo"
        case .speaking:
            return "Resposta"
        case .feedback(_, let success):
            return success ? "Concluído" : "Falhou"
        }
    }

    private var phaseLabel: String {
        switch model.phase {
        case .listening:
            return activeSpeaker == .user ? "OUVINDO VOCÊ" : "OUVINDO"
        case .searchingWeb:
            return "CONSULTANDO"
        case .thinking:
            return "PROCESSANDO"
        case .speaking:
            return "ORVIA FALANDO"
        case .feedback(_, let success):
            return success ? "PRONTO" : "ERRO"
        }
    }

    private var activeSpeaker: VoiceActiveSpeaker {
        switch model.phase {
        case .speaking:
            return .assistant
        case .listening:
            return model.userLevel > 0.08 ? .user : .none
        case .searchingWeb, .thinking, .feedback:
            return .none
        }
    }

    private var isSpeakingCaption: Bool {
        if case .speaking = model.phase { return true }
        return false
    }

    private var isProcessing: Bool {
        switch model.phase {
        case .searchingWeb, .thinking:
            return true
        default:
            return false
        }
    }

    private var successTint: Bool? {
        switch model.phase {
        case .feedback(_, let success), .speaking(_, let success):
            return success
        default:
            return nil
        }
    }

    private var accent: Color {
        switch model.phase {
        case .listening, .searchingWeb, .thinking, .speaking:
            return Color(red: 0.45, green: 0.82, blue: 1.0)
        case .feedback(_, let success):
            return success
                ? Color(red: 0.4, green: 0.92, blue: 0.72)
                : Color(red: 1.0, green: 0.55, blue: 0.35)
        }
    }

    private var moodKey: Int {
        switch model.phase {
        case .listening: return 0
        case .searchingWeb: return 1
        case .thinking: return 2
        case .speaking: return 3
        case .feedback(_, let success): return success ? 4 : 5
        }
    }
}
