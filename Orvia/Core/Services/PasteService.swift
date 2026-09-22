import AppKit
import ApplicationServices
import Foundation
import OSLog

/// O campo ativo antes de o painel do Orvia assumir o foco.
struct PasteFocus {
    private static let logger = Logger(subsystem: "com.richadfarias.orvia", category: "paste")

    let processIdentifier: pid_t
    private let window: AXUIElement?
    private let element: AXUIElement?

    init?(application: NSRunningApplication?) {
        guard let application, !application.isTerminated else { return nil }

        processIdentifier = application.processIdentifier
        let accessibilityApplication = AXUIElementCreateApplication(processIdentifier)
        window = Self.element(for: kAXFocusedWindowAttribute, in: accessibilityApplication)
        element = Self.element(for: kAXFocusedUIElementAttribute, in: accessibilityApplication)
    }

    func restore() {
        let accessibilityApplication = AXUIElementCreateApplication(processIdentifier)
        if let window {
            let result = AXUIElementSetAttributeValue(
                accessibilityApplication, kAXFocusedWindowAttribute as CFString, window
            )
            if result != .success {
                Self.logger.debug("Could not restore the target window: \(result.rawValue)")
            }
        }
        if let element {
            let result = AXUIElementSetAttributeValue(
                element, kAXFocusedAttribute as CFString, kCFBooleanTrue
            )
            if result != .success {
                Self.logger.debug("Could not restore the target field: \(result.rawValue)")
            }
        }
    }

    private static func element(for attribute: String, in application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        // CFTypeID foi validado acima; a ponte CoreFoundation exige o cast explícito.
        return (value as! AXUIElement)
    }
}

@MainActor
final class PasteService {
    private let logger = Logger(subsystem: "com.richadfarias.orvia", category: "paste")
    private let permissionsManager: PermissionsManager
    private let focusRetryDelay: TimeInterval = 0.07
    private let initialPasteDelay: TimeInterval = 0.14
    private let restoredFocusDelay: TimeInterval = 0.05
    private let maxFocusRetries: Int = 14

    init(permissionsManager: PermissionsManager) {
        self.permissionsManager = permissionsManager
    }

    func paste(
        item: DecodedClipboardItem,
        targetApplication: NSRunningApplication?,
        targetFocus: PasteFocus? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        pastePreparingPasteboard(
            targetApplication: targetApplication, targetFocus: targetFocus, completion: completion
        ) { pasteboard in
            switch item.kind {
            case .text:
                guard let text = item.text else { return false }
                pasteboard.setString(text, forType: .string)
            case .image:
                guard let image = item.image else { return false }
                pasteboard.writeObjects([image])
            }
            return true
        }
    }

    /// Cola texto arbitrário (ex.: ditado por voz) no app em foco.
    func paste(
        text: String,
        targetApplication: NSRunningApplication?,
        completion: ((Bool) -> Void)? = nil
    ) {
        pastePreparingPasteboard(
            targetApplication: targetApplication, targetFocus: nil, completion: completion
        ) { pasteboard in
            guard !text.isEmpty else { return false }
            pasteboard.setString(text, forType: .string)
            return true
        }
    }

    private func pastePreparingPasteboard(
        targetApplication: NSRunningApplication?,
        targetFocus: PasteFocus?,
        completion: ((Bool) -> Void)?,
        write: (NSPasteboard) -> Bool
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard write(pasteboard) else {
            completion?(false)
            return
        }

        NotificationCenter.default.post(name: .clipboardDidProgrammaticWrite, object: nil)

        permissionsManager.refresh()
        guard permissionsManager.isAccessibilityGranted else {
            // The item is still available for a manual ⌘V when TCC denies automation.
            permissionsManager.requestAccessibility()
            completion?(false)
            return
        }

        let target = resolveTargetApplication(from: targetApplication)
        guard let target else {
            logger.warning("Paste was copied to the clipboard because no target application was available")
            completion?(false)
            return
        }
        target.activate(options: [])

        pasteWithFocusRetry(
            targetApplication: target, targetFocus: targetFocus, attempt: 0, completion: completion
        )
    }

    private func resolveTargetApplication(from targetApplication: NSRunningApplication?) -> NSRunningApplication? {
        guard let targetApplication else { return nil }
        guard targetApplication.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        guard !targetApplication.isTerminated else { return nil }
        return targetApplication
    }

    private func pasteWithFocusRetry(
        targetApplication: NSRunningApplication,
        targetFocus: PasteFocus?,
        attempt: Int,
        completion: ((Bool) -> Void)?
    ) {
        let delay = attempt == 0 ? initialPasteDelay : focusRetryDelay

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                completion?(false)
                return
            }

            if targetApplication.isTerminated {
                completion?(false)
                return
            }

            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let hasFocus = frontmostPID == targetApplication.processIdentifier

            if !hasFocus, attempt < self.maxFocusRetries {
                if attempt == 2 || attempt == 5 || attempt == 8 {
                    targetApplication.activate(options: [])
                }
                self.pasteWithFocusRetry(
                    targetApplication: targetApplication,
                    targetFocus: targetFocus,
                    attempt: attempt + 1,
                    completion: completion
                )
                return
            }

            if !hasFocus {
                self.logger.warning("Paste target did not regain focus: \(targetApplication.processIdentifier)")
                completion?(false)
                return
            }

            if targetFocus?.processIdentifier == targetApplication.processIdentifier {
                targetFocus?.restore()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restoredFocusDelay) {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApplication.processIdentifier else {
                    completion?(false)
                    return
                }
                completion?(self.triggerCommandV(to: targetApplication.processIdentifier))
            }
        }
    }

    private func triggerCommandV(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }
}
