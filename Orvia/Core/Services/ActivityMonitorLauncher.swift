import AppKit
import ApplicationServices
import Foundation

enum ActivityMonitorDestination: Equatable {
    case cpu
    case gpuHistory
    case memory
    case energy
    case disk
    case network

    static func destination(for metric: MenuBarMetric) -> ActivityMonitorDestination {
        switch metric {
        case .cpu, .temperature, .fans:
            return .cpu
        case .gpu:
            return .gpuHistory
        case .memory:
            return .memory
        case .storage:
            return .disk
        case .network:
            return .network
        case .power:
            return .energy
        }
    }
}

/// Opens Apple's Activity Monitor and, when Accessibility is available, moves it
/// directly to the native view that best matches the selected Orvia metric.
@MainActor
enum ActivityMonitorLauncher {
    private static let bundleIdentifier = "com.apple.ActivityMonitor"
    private static let maximumSelectionAttempts = 24
    private static let retryDelay: TimeInterval = 0.125

    static func open(for metric: MenuBarMetric) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return
        }

        let destination = ActivityMonitorDestination.destination(for: metric)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { application, _ in
            guard let application else { return }
            DispatchQueue.main.async {
                application.activate()
                select(destination, in: application, attempt: 0)
            }
        }
    }

    private static func select(
        _ destination: ActivityMonitorDestination,
        in application: NSRunningApplication,
        attempt: Int
    ) {
        guard attempt < maximumSelectionAttempts else { return }
        guard AXIsProcessTrusted() else { return }

        let root = AXUIElementCreateApplication(application.processIdentifier)
        let didSelect: Bool

        switch destination {
        case .gpuHistory:
            didSelect = pressGPUHistory(in: root)
        default:
            didSelect = pressFirstElement(
                matching: tabTitles(for: destination),
                in: root,
                requiresSelection: true
            )
        }

        guard !didSelect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
            select(destination, in: application, attempt: attempt + 1)
        }
    }

    private static func pressGPUHistory(in root: AXUIElement) -> Bool {
        let gpuHistoryTitles = [
            "GPU History", "Histórico da GPU", "Historico da GPU"
        ]

        if pressFirstElement(matching: gpuHistoryTitles, in: root) {
            return true
        }

        // Menu items are often created lazily. Opening Window/Janela makes the
        // native GPU History command discoverable on the next retry.
        _ = pressFirstElement(matching: ["Window", "Janela"], in: root)
        return false
    }

    private static func tabTitles(for destination: ActivityMonitorDestination) -> [String] {
        switch destination {
        case .cpu:
            return ["CPU"]
        case .memory:
            return ["Memory", "Memória", "Memoria"]
        case .energy:
            return ["Energy", "Energia"]
        case .disk:
            return ["Disk", "Disco"]
        case .network:
            return ["Network", "Rede"]
        case .gpuHistory:
            return []
        }
    }

    private static func pressFirstElement(
        matching titles: [String],
        in root: AXUIElement,
        requiresSelection: Bool = false
    ) -> Bool {
        let normalizedTitles = Set(titles.map(normalized))
        guard !normalizedTitles.isEmpty else { return false }

        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0

        while index < queue.count, index < 1_500 {
            let current = queue[index]
            index += 1

            if isInteractiveControl(current.element),
               labels(for: current.element).contains(where: { normalizedTitles.contains(normalized($0)) }),
               performPress(on: current.element, requiresSelection: requiresSelection) {
                return true
            }

            guard current.depth < 14 else { continue }
            for child in children(of: current.element) {
                queue.append((child, current.depth + 1))
            }
        }

        return false
    }

    private static func performPress(on element: AXUIElement, requiresSelection: Bool) -> Bool {
        if requiresSelection, isSelected(element) {
            return true
        }

        let preferredActions = ["AXPress", "AXPick", "AXConfirm"]
        let supportedActions = actionNames(for: element)
        for action in preferredActions where supportedActions.contains(action) {
            if AXUIElementPerformAction(element, action as CFString) == .success {
                if !requiresSelection || isSelected(element) {
                    return true
                }
            }
        }

        // Activity Monitor's toolbar categories are segmented selectors on
        // recent macOS releases. Some versions expose them as selectable or
        // settable values instead of pressable buttons.
        if AXUIElementSetAttributeValue(
            element,
            kAXSelectedAttribute as CFString,
            kCFBooleanTrue
        ) == .success {
            if !requiresSelection || isSelected(element) {
                return true
            }
        }

        let didSetValue = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            kCFBooleanTrue
        ) == .success
        return didSetValue && (!requiresSelection || isSelected(element))
    }

    private static func isSelected(_ element: AXUIElement) -> Bool {
        [kAXSelectedAttribute, kAXValueAttribute].contains { attribute in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            ) == .success,
            let number = value as? NSNumber else {
                return false
            }
            return number.boolValue
        }
    }

    private static func labels(for element: AXUIElement) -> [String] {
        [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXValueAttribute
        ].compactMap { stringAttribute($0 as CFString, of: element) }
    }

    private static func isInteractiveControl(_ element: AXUIElement) -> Bool {
        let actionableNames = Set(["AXPress", "AXPick", "AXConfirm"])
        if !actionableNames.isDisjoint(with: actionNames(for: element)) {
            return true
        }

        guard let role = stringAttribute(kAXRoleAttribute as CFString, of: element) else { return false }

        return [
            kAXButtonRole,
            kAXRadioButtonRole,
            kAXMenuItemRole,
            kAXMenuBarItemRole,
            kAXPopUpButtonRole
        ].contains(role)
    }

    private static func actionNames(for element: AXUIElement) -> [String] {
        var rawActionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &rawActionNames) == .success,
              let actionNames = rawActionNames as? [String] else {
            return []
        }
        return actionNames
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
        let children = value as? [AXUIElement] else {
            return []
        }
        return children
    }

    private static func stringAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
