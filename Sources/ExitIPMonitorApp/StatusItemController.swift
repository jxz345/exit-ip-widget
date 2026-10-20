import AppKit
import Combine
import SwiftUI

/// Retained independently of all windows. The status button always opens the same dashboard.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: PublicIPMonitor
    private var observation: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var hostingView: StatusLabelHostingView?

    var isVisible: Bool { item.isVisible }

    init(monitor: PublicIPMonitor) {
        self.monitor = monitor
        super.init()
        item.autosaveName = "ExitIPMonitorStatusItem"
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(openDashboard(_:))
        item.button?.setAccessibilityIdentifier("exit-ip-menu-bar")
        update()
        // objectWillChange is sent before the properties change; render on the next main turn.
        observation = monitor.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // The Dock follows the system appearance (the menu bar may differ with the wallpaper), so
        // the monochrome text and stop symbol of the Dock copy are re-colored when it changes.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
        RuntimeLog.shared.info("status_item_created")
    }

    @objc private func openDashboard(_ sender: Any?) {
        RuntimeLog.shared.info("status_item_clicked")
        ExitIPAppDelegate.showDashboard()
    }

    private func update() {
        guard let button = item.button else { return }
        let label = MenuBarCountryLabel(snapshot: monitor.snapshot,
                                        displayStyle: monitor.preferences.menuBarDisplayStyle,
                                        refreshInterval: monitor.preferences.refreshInterval,
                                        indicators: monitor.indicators,
                                        outsideAllowlist: monitor.authorizationState.isNotAllowed,
                                        date: monitor.displayDate)
        let host = hostingView ?? StatusLabelHostingView(rootView: label)
        host.rootView = label
        if hostingView == nil {
            host.sizingOptions = .intrinsicContentSize
            host.setAccessibilityElement(false)
            button.addSubview(host)
            hostingView = host
        }
        let size = host.fittingSize
        item.length = ceil(size.width) + 12
        host.frame = NSRect(x: 6, y: (button.bounds.height - size.height) / 2,
                            width: ceil(size.width), height: size.height)
        button.setAccessibilityLabel(label.accessibilityText(at: monitor.displayDate))
        button.toolTip = label.accessibilityText(at: monitor.displayDate) + " — Open Dashboard"
        // The Dock and ⌘-Tab icon is the same label, redrawn at the same moment, colored for the
        // Dock's (system) appearance so monochrome text and symbols stay legible there.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        DockIconController.shared.update(label: label, darkAppearance: dark)
    }
}

/// The native status button owns mouse and keyboard interaction, including its pressed highlight.
private final class StatusLabelHostingView: NSHostingView<MenuBarCountryLabel> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
