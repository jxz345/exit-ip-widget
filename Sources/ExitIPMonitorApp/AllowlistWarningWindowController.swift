import AppKit
import SwiftUI

/// Non-blocking warning shown when a verified exit IP is outside a non-empty allowlist. The app only
/// warns; it never changes networking. `PublicIPMonitor` opens it once per address and dismisses it when
/// the address becomes allowed or the list is emptied.
@MainActor
final class AllowlistWarningWindowController: NSObject, NSWindowDelegate {
    static let shared = AllowlistWarningWindowController()

    private var window: NSPanel?
    private(set) var isPresented = false

    func show(address: String) {
        let panel = window ?? makePanel()
        window = panel
        isPresented = true
        panel.contentViewController = NSHostingController(
            rootView: AllowlistWarningView(address: address) { [weak self] in
                self?.dismiss()
            }
        )
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        isPresented = false
        window?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("exit-ip-allowlist-warning")
        panel.title = "Exit IP Not Allowed"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}

private struct AllowlistWarningView: View {
    let address: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Exit IP is not on the allowlist", systemImage: "exclamationmark.triangle.fill")
                .font(.title.weight(.bold))
                .foregroundStyle(.orange)
            Text(address)
                .font(.title2.monospaced())
                .textSelection(.enabled)
            Text("Exit IP Monitor only warns; it does not block the connection. This warning clears when the exit IP changes to an allowed address or you add this address to the allowlist.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Open Dashboard") {
                    dismiss()
                    ExitIPAppDelegate.showDashboard()
                }
                Spacer()
                Button("Close", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 320)
    }
}
