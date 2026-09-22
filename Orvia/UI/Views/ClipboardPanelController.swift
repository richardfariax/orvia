import AppKit
import Carbon
import SwiftUI

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardPanelController {
    private let panel: FloatingPanel
    private let onMoveSelection: (Bool) -> Void
    private let onConfirmSelection: () -> Void
    private let onToggleFavoriteSelection: () -> Void
    private let onTogglePinSelection: () -> Void
    private let onCopySelection: () -> Void
    private let onSelectFilter: (ClipboardPanelFilter) -> Void
    private let onStackSelection: () -> Void
    private var keyMonitor: Any?

    var isVisible: Bool {
        panel.isVisible
    }

    init(
        rootView: ClipboardPanelView,
        onMoveSelection: @escaping (Bool) -> Void,
        onConfirmSelection: @escaping () -> Void,
        onToggleFavoriteSelection: @escaping () -> Void,
        onTogglePinSelection: @escaping () -> Void,
        onCopySelection: @escaping () -> Void,
        onSelectFilter: @escaping (ClipboardPanelFilter) -> Void,
        onStackSelection: @escaping () -> Void
    ) {
        self.onMoveSelection = onMoveSelection
        self.onConfirmSelection = onConfirmSelection
        self.onToggleFavoriteSelection = onToggleFavoriteSelection
        self.onTogglePinSelection = onTogglePinSelection
        self.onCopySelection = onCopySelection
        self.onSelectFilter = onSelectFilter
        self.onStackSelection = onStackSelection

        let hosting = NSHostingView(rootView: rootView)

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .moveToActiveSpace]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = hosting
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        installKeyMonitorIfNeeded()
        centerOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        panel.orderOut(nil)
    }

    private func centerOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.panel.isVisible, event.window == self.panel else {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) {
                switch Int(event.keyCode) {
                case kVK_ANSI_1:
                    self.onSelectFilter(.all)
                    return nil
                case kVK_ANSI_2:
                    self.onSelectFilter(.favorites)
                    return nil
                case kVK_ANSI_3:
                    self.onSelectFilter(.pinned)
                    return nil
                case kVK_ANSI_4:
                    self.onSelectFilter(.textOnly)
                    return nil
                case kVK_ANSI_5:
                    self.onSelectFilter(.imagesOnly)
                    return nil
                case kVK_ANSI_6:
                    self.onSelectFilter(.snippets)
                    return nil
                case kVK_ANSI_S:
                    self.onStackSelection()
                    return nil
                case kVK_ANSI_D:
                    self.onToggleFavoriteSelection()
                    return nil
                case kVK_ANSI_P:
                    self.onTogglePinSelection()
                    return nil
                case kVK_ANSI_C:
                    self.onCopySelection()
                    return nil
                default:
                    break
                }
            }

            switch Int(event.keyCode) {
            case kVK_UpArrow:
                self.onMoveSelection(true)
                return nil
            case kVK_DownArrow:
                self.onMoveSelection(false)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.onConfirmSelection()
                return nil
            case kVK_Escape:
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }
}
