import AppKit
import SwiftUI

@MainActor
final class ExitIPAppDelegate: NSObject, NSApplicationDelegate {
    static let monitor = PublicIPMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchDiagnostics.record("application_did_finish_launching")
        Self.monitor.start()
        LaunchDiagnostics.record("startup_profile_begin")
        do {
            try maintainClashVergeProfile()
        } catch {
            RuntimeLog.shared.error("clash_profile_write_failed", fields: ["error": error.localizedDescription])
        }
        TailscaleVergeWatcher.shared.start()
        LaunchDiagnostics.record("startup_services_ready")
        // The app is menu-bar only, and a crowded menu bar can hide its item, so the very first
        // launch opens the dashboard once to show the app is running.
        let defaults = ExitIPAppGroup.defaults
        if !defaults.bool(forKey: ExitIPPreferenceKey.firstLaunchDashboardShown) {
            defaults.set(true, forKey: ExitIPPreferenceKey.firstLaunchDashboardShown)
            Self.showDashboard()
        }
        SingleInstanceController.didFinishLaunching()
        // Schedule after the launch callback so readiness proves the main queue is servicing work.
        DispatchQueue.main.async { LaunchDiagnostics.markReady() }
    }

    /// Opening the app again while it runs (Finder, Spotlight, Launchpad, `open`) shows the
    /// dashboard instead of doing nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showDashboard()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.monitor.applicationDidBecomeActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        LaunchDiagnostics.stop()
        Self.monitor.stop()
    }

    static func showDashboard() {
        DashboardWindowController.shared.show(monitor: monitor)
    }

    static func showSettings() {
        SettingsWindowController.shared.show(monitor: monitor)
    }

    static func showEventLog() {
        EventLogWindowController.shared.show()
    }

    /// The dashboard and settings windows each make the app `.regular` while open; only return
    /// to accessory mode once neither is still on screen.
    static func restoreAccessoryModeIfNoWindowsVisible(closing: NSWindow) {
        let stillVisible = [DashboardWindowController.shared.window, SettingsWindowController.shared.window,
                            EventLogWindowController.shared.window]
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
        placeOnActiveScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        ExitIPAppDelegate.restoreAccessoryModeIfNoWindowsVisible(closing: window)
    }

    private func makeWindow(monitor: PublicIPMonitor) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("exit-ip-settings")
        window.title = "Exit IP Settings"
        window.contentViewController = fixedSizeHostingController(SettingsView(monitor: monitor))
        window.setContentSize(NSSize(width: 560, height: 700))
        window.contentMinSize = NSSize(width: 520, height: 420)
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
        placeOnActiveScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        LaunchDiagnostics.record("dashboard_presented")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        ExitIPAppDelegate.restoreAccessoryModeIfNoWindowsVisible(closing: window)
    }

    private func makeWindow(monitor: PublicIPMonitor) -> NSWindow {
        // Opens wide enough for two columns, so nothing needs scrolling.
        let hostingController = fixedSizeHostingController(
            DashboardView(monitor: monitor)
                .frame(minWidth: 520, minHeight: 380)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("exit-ip-dashboard")
        window.title = "Exit IP Dashboard"
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 1000, height: 860))
        window.contentMinSize = NSSize(width: 520, height: 380)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

/// The proxy saved from the dashboard (Keychain), or nil when none was saved.
@MainActor
func loadClashProxySettings() -> ClashProxySettings? {
    guard let text = try? SecureTokenStore.read(account: ClashVergeProfile.keychainAccount) else { return nil }
    return ClashVergeProfile.decode(text)
}

/// Keeps the full Clash Verge profile (~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml,
/// mode 0600) current with the saved proxy and the app's template, at launch and on Save. Only the app
/// writes it; no installer deploys it, and nothing is written into Clash Verge. Never logs the settings.
/// Returns nil when no proxy has been saved.
@MainActor
@discardableResult
func maintainClashVergeProfile(_ settings: ClashProxySettings? = nil) throws -> ClashVergeProfile.WriteOutcome? {
    // An earlier build kept only the provider part here.
    try? FileManager.default.removeItem(at: ClashVergeProfile.legacyPartialFileURL)
    guard let settings = settings ?? loadClashProxySettings() else { return nil }
    let outcome = try ClashVergeProfile.write(ClashVergeProfile.render(settings), to: ClashVergeProfile.fileURL)
    if outcome == .written {
        RuntimeLog.shared.info("clash_profile_written", fields: ["path": ClashVergeProfile.fileURL.path])
    }
    return outcome
}

/// A hosting controller that only enforces the view's minimum size. With the default sizing
/// options, the window hugs the SwiftUI content and collapses to its minimum: the dashboard opened
/// at 520 × 380 (one stacked column to scroll) and the scrolling Settings form as a bare title bar.
@MainActor
func fixedSizeHostingController<Content: View>(_ rootView: Content) -> NSHostingController<Content> {
    let controller = NSHostingController(rootView: rootView)
    controller.sizingOptions = .minSize
    return controller
}

/// Opens a window at the true center of the screen the pointer is on (the one whose menu bar was
/// just clicked); `NSWindow.center()` places it above center. A window larger than that screen's
/// visible area is shrunk to fit, so a small display never gets an off-screen title bar.
@MainActor
func placeOnActiveScreen(_ window: NSWindow) {
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
        window.center()
        return
    }
    // The hosting controller sizes the window during layout; place it with the final size.
    window.layoutIfNeeded()
    let visible = screen.visibleFrame
    let size = NSSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
    window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height), display: false)
}

@MainActor
struct ExitIPMonitorApp: App {
    @NSApplicationDelegateAdaptor(ExitIPAppDelegate.self) private var appDelegate
    @StateObject private var monitor = ExitIPAppDelegate.monitor

    // Settings live in `SettingsWindowController`, not a SwiftUI `Settings` scene: that scene
    // opened its own window at every launch and couldn't be foregrounded from the popover.
    init() {
        LaunchDiagnostics.record("app_initialized")
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
