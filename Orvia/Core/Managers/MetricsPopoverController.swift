import AppKit
import SwiftUI

@MainActor
final class MetricsPopoverController: NSObject, NSPopoverDelegate {
    private let metrics: SystemMetricsService
    private let settings: AppSettings
    private let onOpenDashboard: () -> Void
    private let popover = NSPopover()

    init(
        metrics: SystemMetricsService,
        settings: AppSettings,
        onOpenDashboard: @escaping () -> Void
    ) {
        self.metrics = metrics
        self.settings = settings
        self.onOpenDashboard = onOpenDashboard
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 560, height: 720)
    }

    func toggle(relativeTo anchor: NSView, preferredMetric: MenuBarMetric) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        let content = MetricsPopoverView(
            metrics: metrics,
            settings: settings,
            initialMetric: preferredMetric,
            onOpenDashboard: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenDashboard()
            }
        )
        popover.contentViewController = NSHostingController(rootView: content)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
