import AppKit
import SwiftUI

@MainActor
final class ExitIPAppDelegate: NSObject, NSApplicationDelegate {
    static let monitor = PublicIPMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.monitor.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.monitor.applicationDidBecomeActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.monitor.stop()
    }

    static func showDashboard() {
        DashboardWindowController.shared.show(monitor: monitor)
    }

    static func showSettings() {
        SettingsWindowController.shared.show(monitor: monitor)
    }

    /// The dashboard and settings windows each make the app `.regular` while open; only return
    /// to accessory mode once neither is still on screen.
    static func restoreAccessoryModeIfNoWindowsVisible(closing: NSWindow) {
        let stillVisible = [DashboardWindowController.shared.window, SettingsWindowController.shared.window]
            .contains { $0 != nil && $0 !== closing && $0!.isVisible }
        if !stillVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// `SettingsLink` and the SwiftUI `Settings` scene don't reliably bring a window forward from an
/// LSUIElement app, so settings use a retained AppKit window like the dashboard.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?

    func show(monitor: PublicIPMonitor) {
        let window = window ?? makeWindow(monitor: monitor)
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        ExitIPAppDelegate.restoreAccessoryModeIfNoWindowsVisible(closing: window)
    }

    private func makeWindow(monitor: PublicIPMonitor) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("exit-ip-settings")
        window.title = "Exit IP Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(monitor: monitor))
        window.minSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()

    private(set) var window: NSWindow?

    func show(monitor: PublicIPMonitor) {
        let window = window ?? makeWindow(monitor: monitor)
        self.window = window

        // The MenuBarExtra panel never makes this LSUIElement app active, and macOS 14+
        // refuses activation requests from an inactive accessory app. Becoming a regular
        // app while the dashboard is open lets activation succeed (and gives the window a
        // Dock icon and Cmd-Tab entry); `windowWillClose` restores accessory mode.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        centerOnActiveScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// `NSWindow.center()` places windows above center; the dashboard opens at the true center
    /// of the screen the pointer is on (the one whose menu bar was just clicked).
    private func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            window.center()
            return
        }
        // The hosting controller sizes the window during layout; center with the final size.
        window.layoutIfNeeded()
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        ExitIPAppDelegate.restoreAccessoryModeIfNoWindowsVisible(closing: window)
    }

    private func makeWindow(monitor: PublicIPMonitor) -> NSWindow {
        let hostingController = NSHostingController(
            rootView: DashboardView(monitor: monitor)
                .frame(minWidth: 520, minHeight: 380)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("exit-ip-dashboard")
        window.title = "Exit IP Dashboard"
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 520, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

@main
@MainActor
struct ExitIPMonitorApp: App {
    @NSApplicationDelegateAdaptor(ExitIPAppDelegate.self) private var appDelegate
    @StateObject private var monitor = ExitIPAppDelegate.monitor

    // Settings live in `SettingsWindowController`, not a SwiftUI `Settings` scene: that scene
    // opened its own window at every launch and couldn't be foregrounded from the popover.
    init() {
        let sharedMonitor = ExitIPAppDelegate.monitor
        _monitor = StateObject(wrappedValue: sharedMonitor)
        sharedMonitor.start()
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(monitor: monitor)
        } label: {
            MenuBarCountryLabel(
                snapshot: monitor.snapshot,
                displayStyle: monitor.preferences.menuBarDisplayStyle,
                refreshInterval: monitor.preferences.refreshInterval,
                indicators: monitor.indicators,
                date: monitor.displayDate
            )
            .task { monitor.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
