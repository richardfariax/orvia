import AppKit
import Foundation
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private enum ItemTag: Int {
        case openDashboard = 999
        case openPanel = 1000
        case togglePause = 1001
        case settings = 1002
        case quit = 1003
        case toggleVoice = 1004
        case checkUpdates = 1005
        case systemMetrics = 1006
        case openCleanCenter = 1007
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let popover = NSPopover()
    private let metrics: SystemMetricsService
    private let settings: AppSettings
    private let clipboardCount: () -> Int

    private let onOpenDashboard: () -> Void
    private let onOpenCleanCenter: () -> Void
    private let onOpenPanel: () -> Void
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onTogglePause: (Bool) -> Void
    private let onToggleVoice: (Bool) -> Void
    private let onQuit: () -> Void
    private let isPausedProvider: () -> Bool
    private let isVoiceEnabledProvider: () -> Bool
    private let languageProvider: () -> AppLanguage
    private let updateAvailableProvider: () -> Bool

    var statusBarButton: NSStatusBarButton? { statusItem.button }

    init(
        onOpenDashboard: @escaping () -> Void,
        onOpenCleanCenter: @escaping () -> Void,
        onOpenPanel: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onTogglePause: @escaping (Bool) -> Void,
        onToggleVoice: @escaping (Bool) -> Void,
        onQuit: @escaping () -> Void,
        isPausedProvider: @escaping () -> Bool,
        isVoiceEnabledProvider: @escaping () -> Bool,
        languageProvider: @escaping () -> AppLanguage,
        updateAvailableProvider: @escaping () -> Bool,
        metrics: SystemMetricsService,
        settings: AppSettings,
        clipboardCount: @escaping () -> Int
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.onOpenDashboard = onOpenDashboard
        self.onOpenCleanCenter = onOpenCleanCenter
        self.onOpenPanel = onOpenPanel
        self.onOpenSettings = onOpenSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onTogglePause = onTogglePause
        self.onToggleVoice = onToggleVoice
        self.onQuit = onQuit
        self.isPausedProvider = isPausedProvider
        self.isVoiceEnabledProvider = isVoiceEnabledProvider
        self.languageProvider = languageProvider
        self.updateAvailableProvider = updateAvailableProvider
        self.metrics = metrics
        self.settings = settings
        self.clipboardCount = clipboardCount
        super.init()

        configureStatusItem()
        configureMenu()
        popover.behavior = .transient
    }

    func refreshPauseState() {
        guard let pauseItem = menu.item(withTag: ItemTag.togglePause.rawValue) else { return }
        pauseItem.state = isPausedProvider() ? .on : .off
    }

    func refreshVoiceState() {
        guard let voiceItem = menu.item(withTag: ItemTag.toggleVoice.rawValue) else { return }
        voiceItem.state = isVoiceEnabledProvider() ? .on : .off
    }

    func refreshAppearance() {
        applyStatusItemIcon()
        refreshSystemMetrics(metrics.snapshot)
    }

    func refreshUpdateItem() {
        guard let updates = menu.item(withTag: ItemTag.checkUpdates.rawValue) else { return }
        updates.title = updateMenuTitle()
    }

    func refreshSystemMetrics(_ snapshot: SystemMetricsSnapshot) {
        let displayed = settings.menuBarMetrics
        let title = NSMutableAttributedString(string: "")
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: NSObject] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        for metric in displayed {
            title.append(NSAttributedString(string: "  ", attributes: attributes))
            if let symbol = NSImage(systemSymbolName: metric.statusBarSymbol,
                                    accessibilityDescription: metric.statusBarTitle(language: languageProvider())) {
                symbol.isTemplate = true
                let attachment = NSTextAttachment()
                attachment.image = symbol
                attachment.bounds = NSRect(x: 0, y: -2, width: 12, height: 12)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " ", attributes: attributes))
            }
            title.append(NSAttributedString(string: metric.statusBarValue(in: snapshot), attributes: attributes))
        }
        statusItem.button?.title = ""
        statusItem.button?.attributedTitle = title
        statusItem.button?.imagePosition = displayed.isEmpty ? .imageOnly : .imageLeading
        let accessibilitySummary = displayed.map {
            "\($0.statusBarTitle(language: languageProvider())) \($0.statusBarValue(in: snapshot))"
        }.joined(separator: ", ")
        statusItem.button?.setAccessibilityLabel(accessibilitySummary.isEmpty ? "Orvia" : "Orvia, \(accessibilitySummary)")
        guard let item = menu.item(withTag: ItemTag.systemMetrics.rawValue) else { return }
        let cpu = snapshot.cpu.total.formatted(.percent.precision(.fractionLength(0)))
        let memory = snapshot.memory.usedFraction.formatted(.percent.precision(.fractionLength(0)))
        let gpu = snapshot.gpu?.device.formatted(.percent.precision(.fractionLength(0))) ?? "—"
        let temperature = snapshot.thermal.peakTemperature.map { String(format: "%.0f°C", $0) } ?? "—"
        let fans = snapshot.fans.averageRPM.map { String(format: "%.0f RPM", $0) } ?? "— RPM"
        item.title = "CPU \(cpu)  ·  RAM \(memory)  ·  GPU \(gpu)  ·  \(temperature)  ·  \(fans)"
    }

    func refreshLocalizedContent() {
        guard let openDashboard = menu.item(withTag: ItemTag.openDashboard.rawValue),
              let openPanel = menu.item(withTag: ItemTag.openPanel.rawValue),
              let pause = menu.item(withTag: ItemTag.togglePause.rawValue),
              let voice = menu.item(withTag: ItemTag.toggleVoice.rawValue),
              let updates = menu.item(withTag: ItemTag.checkUpdates.rawValue),
              let settings = menu.item(withTag: ItemTag.settings.rawValue),
              let quit = menu.item(withTag: ItemTag.quit.rawValue) else {
            return
        }

        openDashboard.title = t("Abrir Central do Mac", "Open Mac Command Center")
        menu.item(withTag: ItemTag.openCleanCenter.rawValue)?.title = t("Abrir Cuidado", "Open Care")
        openPanel.title = t("Abrir Clipboard", "Open Clipboard")
        pause.title = t("Pausar Monitoramento", "Pause Monitoring")
        voice.title = t("Comandos de Voz", "Voice Commands")
        updates.title = updateMenuTitle()
        settings.title = t("Preferências...", "Preferences...")
        quit.title = t("Sair do Orvia", "Quit Orvia")
        refreshSystemMetrics(metrics.snapshot)
    }

    private func updateMenuTitle() -> String {
        if updateAvailableProvider() {
            return t("Atualização Disponível...", "Update Available...")
        }
        return t("Buscar Atualizações...", "Check for Updates...")
    }

    private func configureStatusItem() {
        applyStatusItemIcon()
        refreshSystemMetrics(metrics.snapshot)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleStatusItemClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = t(
            "Clique para abrir Orvia · botão direito para o menu",
            "Click to open Orvia · right-click for menu"
        )
    }

    private func applyStatusItemIcon() {
        if let button = statusItem.button {
            if let menuBarLogo = NSImage(named: "OrviaMenuBarIcon") {
                menuBarLogo.size = NSSize(width: 18, height: 18)
                menuBarLogo.isTemplate = true
                button.image = menuBarLogo
            } else {
                button.image = NSImage(
                    systemSymbolName: "doc.on.clipboard",
                    accessibilityDescription: "Orvia"
                )
            }
        }
    }

    private func configureMenu() {
        menu.autoenablesItems = false

        let dashboardItem = NSMenuItem(
            title: t("Abrir Central do Mac", "Open Mac Command Center"),
            action: #selector(openDashboard),
            keyEquivalent: ""
        )
        dashboardItem.target = self
        dashboardItem.tag = ItemTag.openDashboard.rawValue
        menu.addItem(dashboardItem)

        let cleanCenterItem = NSMenuItem(
            title: t("Abrir Cuidado", "Open Care"),
            action: #selector(openCleanCenter),
            keyEquivalent: ""
        )
        cleanCenterItem.target = self
        cleanCenterItem.tag = ItemTag.openCleanCenter.rawValue
        menu.addItem(cleanCenterItem)

        let metricsItem = NSMenuItem(title: "CPU —  ·  RAM —  ·  GPU —  ·  —", action: nil, keyEquivalent: "")
        metricsItem.tag = ItemTag.systemMetrics.rawValue
        metricsItem.isEnabled = false
        menu.addItem(metricsItem)

        menu.addItem(.separator())

        let openPanelItem = NSMenuItem(title: t("Abrir Clipboard", "Open Clipboard"), action: #selector(openPanel), keyEquivalent: "")
        openPanelItem.target = self
        openPanelItem.tag = ItemTag.openPanel.rawValue
        menu.addItem(openPanelItem)

        let pauseItem = NSMenuItem(title: t("Pausar Monitoramento", "Pause Monitoring"), action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.tag = ItemTag.togglePause.rawValue
        pauseItem.state = isPausedProvider() ? .on : .off
        menu.addItem(pauseItem)

        let voiceItem = NSMenuItem(title: t("Comandos de Voz", "Voice Commands"), action: #selector(toggleVoice), keyEquivalent: "")
        voiceItem.target = self
        voiceItem.tag = ItemTag.toggleVoice.rawValue
        voiceItem.state = isVoiceEnabledProvider() ? .on : .off
        menu.addItem(voiceItem)

        menu.addItem(.separator())

        let updatesItem = NSMenuItem(title: updateMenuTitle(), action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        updatesItem.tag = ItemTag.checkUpdates.rawValue
        menu.addItem(updatesItem)

        let settingsItem = NSMenuItem(title: t("Preferências...", "Preferences..."), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.tag = ItemTag.settings.rawValue
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: t("Sair do Orvia", "Quit Orvia"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.tag = ItemTag.quit.rawValue
        menu.addItem(quitItem)
    }

    @objc private func openPanel() {
        onOpenPanel()
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(
            metrics: metrics,
            settings: settings,
            clipboardCount: clipboardCount,
            openDashboard: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenDashboard()
            },
            openClipboard: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenPanel()
            },
            openCleaner: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenCleanCenter()
            }
        ))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func openDashboard() {
        onOpenDashboard()
    }

    @objc private func openCleanCenter() {
        onOpenCleanCenter()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates()
    }

    @objc private func togglePause() {
        let updated = !isPausedProvider()
        onTogglePause(updated)
        refreshPauseState()
    }

    @objc private func toggleVoice() {
        let updated = !isVoiceEnabledProvider()
        onToggleVoice(updated)
        refreshVoiceState()
    }

    @objc private func quitApp() {
        onQuit()
    }

    private func t(_ pt: String, _ en: String) -> String {
        languageProvider().text(ptBR: pt, en: en)
    }
}
