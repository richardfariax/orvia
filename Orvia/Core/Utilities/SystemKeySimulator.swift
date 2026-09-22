import Carbon
import CoreGraphics
import Foundation

/// Simula teclas de mídia e atalhos do sistema via CGEvent (mais confiável que AppleScript).
enum SystemKeySimulator {
    static func volumeUp(steps: Int = 3) {
        repeatKey(CGKeyCode(kVK_VolumeUp), count: steps)
    }

    static func volumeDown(steps: Int = 3) {
        repeatKey(CGKeyCode(kVK_VolumeDown), count: steps)
    }

    static func mute() {
        let key = CGKeyCode(kVK_Mute)
        postKey(key, keyDown: true)
        postKey(key, keyDown: false)
    }

    static func brightnessUp(steps: Int = 2) {
        // Teclas de brilho em teclados Apple; F2 como fallback em MacBooks.
        if repeatKey(CGKeyCode(144), count: steps) == 0 {
            repeatKey(CGKeyCode(kVK_F2), count: steps)
        }
    }

    static func brightnessDown(steps: Int = 2) {
        if repeatKey(CGKeyCode(145), count: steps) == 0 {
            repeatKey(CGKeyCode(kVK_F1), count: steps)
        }
    }

    static func openSpotlight() {
        postShortcut(keyCode: CGKeyCode(kVK_Space), modifiers: CGEventFlags.maskCommand)
    }

    // MARK: - Private

    @discardableResult
    private static func repeatKey(_ keyCode: CGKeyCode, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var posted = 0
        for _ in 0..<count {
            if postKey(keyCode, keyDown: true), postKey(keyCode, keyDown: false) {
                posted += 1
            }
        }
        return posted
    }

    @discardableResult
    private static func postKey(_ keyCode: CGKeyCode, keyDown: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func postShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
