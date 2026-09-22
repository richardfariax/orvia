import Foundation

extension Notification.Name {
    static let openSettingsDashboard = Notification.Name("openSettingsDashboard")
    static let openSettingsClipboard = Notification.Name("openSettingsClipboard")
    static let openSettingsCleaner = Notification.Name("openSettingsCleaner")
    static let clipboardDidUpdate = Notification.Name("OrviaClipboardDidUpdate")
    static let clipboardDidProgrammaticWrite = Notification.Name("OrviaClipboardDidProgrammaticWrite")
    static let openSettingsPermissions = Notification.Name("OrviaOpenSettingsPermissions")
    static let openSettingsUpdates = Notification.Name("OrviaOpenSettingsUpdates")
    static let showMetricsPopover = Notification.Name("OrviaShowMetricsPopover")
}
