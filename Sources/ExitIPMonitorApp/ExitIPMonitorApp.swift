import AppKit
import SwiftUI

@MainActor
final class ExitIPAppDelegate: NSObject, NSApplicationDelegate {
    static let monitor = PublicIPMonitor()
    private var statusItem: StatusItemController?

    var statusItemIsVisible: Bool { statusItem?.isVisible == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchDiagnostics.record("application_did_finish_launching")
        installApplicationMenus()
        statusItem = StatusItemController(monitor: Self.monitor)
        Self.monitor.start()
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static func showDashboard() {
        DashboardWindowController.shared.show(monitor: monitor)
    }

    static func showSettings() {
        SettingsWindowController.shared.show(monitor: monitor)
    }

    static func showEventLog() {
        EventLogWindowController.shared.show()
    }

    /// Minimizing is not closing. Only the dashboard owns the app's Dock presence.
    static func updateActivationPolicy() {
        NSApp.setActivationPolicy(DashboardWindowController.shared.isOpen ? .regular : .accessory)
    }

    @objc private func openDashboard(_ sender: Any?) { Self.showDashboard() }
    @objc private func openSettings(_ sender: Any?) { Self.showSettings() }
    @objc private func openEventLog(_ sender: Any?) { Self.showEventLog() }

    private func installApplicationMenus() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            return menu
        }
        let app = submenu("Exit IP Monitor")
        app.addItem(withTitle: "About Exit IP Monitor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Exit IP Monitor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Exit IP Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        submenu("File").addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                     ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let windows = submenu("Window")
        windows.addItem(withTitle: "Dashboard", action: #selector(openDashboard(_:)), keyEquivalent: "1").target = self
        windows.addItem(withTitle: "Event Log", action: #selector(openEventLog(_:)), keyEquivalent: "").target = self
        windows.addItem(.separator())
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
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
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        keepWindowOnScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
        placeOnActiveScreen(window)
        return window
    }
}

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()

    private(set) var window: NSWindow?
    private(set) var isOpen = false
    private var screenObserver: NSObjectProtocol?

    override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let window = self?.window { keepWindowOnScreen(window) }
            }
        }
    }

    func show(monitor: PublicIPMonitor) {
        let window = window ?? makeWindow(monitor: monitor)
        self.window = window

        isOpen = true
        ExitIPAppDelegate.updateActivationPolicy()
        if window.isMiniaturized { window.deminiaturize(nil) }
        keepWindowOnScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        // Dock/activation changes finish asynchronously. Request focus again after that turn,
        // when the normal window is already ordered on the active Space.
        DispatchQueue.main.async { [weak self, weak window] in
            guard self?.isOpen == true, let window else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            LaunchDiagnostics.record("dashboard_front_requested")
        }
        LaunchDiagnostics.record("dashboard_presented")
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        ExitIPAppDelegate.updateActivationPolicy()
        LaunchDiagnostics.record("dashboard_closed")
    }

    private func makeWindow(monitor: PublicIPMonitor) -> NSWindow {
        // Content scrolls when needed, while the footer remains available.
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
        window.level = .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.managed, .primary, .participatesInCycle, .fullScreenPrimary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.delegate = self
        let restored = window.setFrameUsingName("ExitIPDashboard")
        window.setFrameAutosaveName("ExitIPDashboard")
        if restored { keepWindowOnScreen(window) } else { placeOnActiveScreen(window) }
        return window
    }
}

/// Keeps the full Clash Verge profile (~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml,
/// mode 0600) current with the explicitly loaded/saved proxy and the app's template. Only the app
/// writes it; no installer deploys it, and nothing is written into Clash Verge. Never logs the settings.
@MainActor
@discardableResult
func maintainClashVergeProfile(_ settings: ClashProxySettings) throws -> ClashVergeProfile.WriteOutcome {
    // An earlier build kept only the provider part here.
    try? FileManager.default.removeItem(at: ClashVergeProfile.legacyPartialFileURL)
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

/// Keep a remembered frame when possible; recover it when a display is removed or resized.
@MainActor
func keepWindowOnScreen(_ window: NSWindow) {
    guard !window.styleMask.contains(.fullScreen) else { return }
    let frame = window.frame
    let screens = NSScreen.screens.map(\.visibleFrame)
    guard let visible = screens.max(by: {
        let a = $0.intersection(frame), b = $1.intersection(frame)
        return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
    }), visible.intersects(frame) else {
        placeOnActiveScreen(window)
        return
    }
    let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
    let origin = NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                         y: min(max(frame.minY, visible.minY), visible.maxY - size.height))
    let fitted = NSRect(origin: origin, size: size)
    if fitted != frame { window.setFrame(fitted, display: true) }
}
