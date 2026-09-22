import Carbon
import Foundation
import OSLog

final class HotkeyManager {
    static let hotkeyPressedNotification = Notification.Name("OrviaHotkeyPressed")
    static let voiceHotkeyPressedNotification = Notification.Name("OrviaVoiceHotkeyPressed")

    private enum HotkeyID: UInt32 {
        case panel = 1
        case voice = 2
    }

    private var hotKeyRef: EventHotKeyRef?
    private var voiceHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregisterPanelHotkey()
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5654), id: HotkeyID.panel.rawValue) // CLVT

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            Logger(subsystem: "com.richadfarias.orvia", category: "hotkeys").error("[Orvia] Falha ao registrar hotkey global: \(status)")
        }
    }

    func registerVoiceHotkey(keyCode: UInt32, modifiers: UInt32) {
        unregisterVoiceHotkey()
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5654), id: HotkeyID.voice.rawValue)

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &voiceHotKeyRef
        )

        if status != noErr {
            Logger(subsystem: "com.richadfarias.orvia", category: "hotkeys").error("[Orvia] Falha ao registrar hotkey de voz: \(status)")
        }
    }

    func unregisterVoiceHotkey() {
        if let voiceHotKeyRef {
            UnregisterEventHotKey(voiceHotKeyRef)
            self.voiceHotKeyRef = nil
        }
    }

    func unregister() {
        unregisterPanelHotkey()
        unregisterVoiceHotkey()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func unregisterPanelHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            guard let event else { return noErr }

            var incomingID = EventHotKeyID()
            let eventParamStatus = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &incomingID
            )

            guard eventParamStatus == noErr else { return noErr }

            switch incomingID.id {
            case HotkeyID.panel.rawValue:
                NotificationCenter.default.post(name: HotkeyManager.hotkeyPressedNotification, object: nil)
            case HotkeyID.voice.rawValue:
                NotificationCenter.default.post(name: HotkeyManager.voiceHotkeyPressedNotification, object: nil)
            default:
                break
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)
    }

    deinit {
        unregister()
    }
}
