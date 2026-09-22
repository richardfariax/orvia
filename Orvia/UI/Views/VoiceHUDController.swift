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
    /// 0...1 — progresso da leitura do texto pelo TTS.
    @Published var speechProgress: Double = 0
    @Published var didCopyResponse = false
}

/// Painel compacto de voz que mantém o aplicativo em uso visível.
@MainActor
final class VoiceHUDController {
    private enum FeedbackSound: String {
        case wake = "Pop"
        case success = "Glass"
        case failure = "Basso"
    }

    var isSoundEnabled: () -> Bool = { true }
    var localize: (String, String) -> String = { ptBR, _ in ptBR }
    /// Esc: aborta a interação atual (fala, captura, follow-up) e fecha o HUD.
    var onEscape: (() -> Void)?

    private var panel: NSPanel?
    private let model = VoiceHUDModel()
    private var hideWorkItem: DispatchWorkItem?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var presentationGeneration = 0

    var isVisible: Bool {
        panel?.isVisible == true && (panel?.alphaValue ?? 0) > 0.05
    }

    func showListening(hint: String) {
        hideWorkItem?.cancel()
        model.phase = .listening
        model.transcript = ""
        model.hintText = hint
        model.statusText = ""
        model.speechProgress = 0
        model.didCopyResponse = false
        presentPanel()
        play(.wake)
        announce(hint)
    }

    func updateTranscript(_ transcript: String) {
        let wasLong = model.transcript.count > 85
        model.transcript = transcript
        if wasLong != (transcript.count > 85) { presentPanel() }
    }

    func showSearching(message: String) {
        hideWorkItem?.cancel()
        model.phase = .searchingWeb
        model.statusText = message
        model.userLevel = 0
        model.speechProgress = 0
        model.didCopyResponse = false
        presentPanel()
        announce(message)
    }

    func showThinking(message: String) {
        hideWorkItem?.cancel()
        model.phase = .thinking
        model.statusText = message
        model.userLevel = 0
        model.speechProgress = 0
        model.didCopyResponse = false
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
        model.didCopyResponse = false
        model.userLevel = 0
        model.speechProgress = 0
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

    func updateSpeechProgress(_ progress: Double) {
        model.speechProgress = max(0, min(1, progress))
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        removeEscapeMonitors()
        model.userLevel = 0
        model.speechProgress = 0
        guard let panel else { return }
        presentationGeneration += 1
        let generation = presentationGeneration

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard self?.presentationGeneration == generation else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func copyResponse() {
        let message: String
        switch model.phase {
        case .speaking(let text, _), .feedback(let text, _):
            message = text
        case .listening, .searchingWeb, .thinking:
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(message, forType: .string) else { return }
        model.didCopyResponse = true
        announce(localize("Resposta copiada", "Response copied"))
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

        presentationGeneration += 1
        let frame = hudFrame()
        if panel.isVisible, panel.frame != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        installEscapeMonitorsIfNeeded()

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: VoiceHUDView(
            model: model,
            localize: { [weak self] ptBR, en in self?.localize(ptBR, en) ?? ptBR },
            onClose: { [weak self] in self?.handleEscape() },
            onCopy: { [weak self] in self?.copyResponse() }
        ))

        let panel = NSPanel(
            contentRect: hudFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel("Orvia")
        return panel
    }

    private func hudFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(600, max(320, visible.width - 32))
        let contentLength: Int
        switch model.phase {
        case .listening:
            contentLength = model.transcript.count
        case .searchingWeb, .thinking:
            contentLength = 0
        case .speaking(let message, _), .feedback(let message, _):
            contentLength = message.count
        }
        let height: CGFloat = contentLength > 85 ? 232 : 174
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + 20,
            width: width,
            height: height
        )
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
    let localize: (String, String) -> String
    let onClose: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VoiceFieldView(
            phaseLabel: phaseLabel,
            message: primaryMessage,
            speaker: activeSpeaker,
            userLevel: model.userLevel,
            speechProgress: model.speechProgress,
            isProcessing: isProcessing,
            isShowingAnswer: isShowingAnswer,
            accent: accent,
            closeLabel: localize("Fechar assistente", "Close assistant"),
            copyLabel: model.didCopyResponse
                ? localize("Resposta copiada", "Response copied")
                : localize("Copiar resposta", "Copy response"),
            didCopy: model.didCopyResponse,
            shortcutHint: localize("Esc para fechar", "Esc to close"),
            onClose: onClose,
            onCopy: onCopy
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: moodKey)
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

    private var phaseLabel: String {
        switch model.phase {
        case .listening:
            return localize("Ouvindo", "Listening")
        case .searchingWeb:
            return localize("Consultando a web", "Searching the web")
        case .thinking:
            return localize("Pensando", "Thinking")
        case .speaking:
            return localize("Falando", "Speaking")
        case .feedback(_, let success):
            return success ? localize("Pronto", "Done") : localize("Não concluído", "Not completed")
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

    private var isShowingAnswer: Bool {
        switch model.phase {
        case .speaking, .feedback: return true
        case .listening, .searchingWeb, .thinking: return false
        }
    }

    private var isProcessing: Bool {
        switch model.phase {
        case .searchingWeb, .thinking:
            return true
        default:
            return false
        }
    }

    private var accent: Color {
        switch model.phase {
        case .listening, .searchingWeb, .thinking, .speaking:
            return .accentColor
        case .feedback(_, let success):
            return success
                ? .accentColor
                : .orange
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
