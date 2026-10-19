import AppKit
import SwiftUI

/// Records what Clash is served by the Tailscale → Clash Verge daemon, but only when it changes. The
/// daemon rewrites its state every 2 seconds; a record is written for a different served value
/// (Direct↔Reject, another utun, another reason), never for a routine rewrite.
@MainActor
final class TailscaleVergeWatcher {
    static let shared = TailscaleVergeWatcher()

    private var timer: Timer?
    private var lastRecorded: TailscaleVergeStatus.Served?

    func start() {
        guard timer == nil else { return }
        check()
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { TailscaleVergeWatcher.shared.check() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        guard TailscaleVergeProvider.isInstalled() else {
            lastRecorded = nil
            return
        }
        let text = try? String(contentsOf: TailscaleVergeProvider.stateFileURL, encoding: .utf8)
        let served = TailscaleVergeStatus.evaluate(stateText: text, now: Date()).served
        guard let change = TailscaleVergeChange.next(previous: lastRecorded, current: served) else { return }
        lastRecorded = change
        RuntimeLog.shared.info("tailscale_provider_changed", fields: TailscaleVergeChange.logFields(change))
    }
}

/// The Event Log window's lines: history from the log files when it opens, then live records.
@MainActor
final class EventLogModel: ObservableObject {
    @Published private(set) var lines: [String] = []
    private var buffer = EventLogBuffer(limit: 500)
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        var history = EventLogBuffer(limit: 500)
        for file in RuntimeLog.shared.logFiles() {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                history.append(jsonLines: text)
            }
        }
        buffer = history
        lines = buffer.lines
        observer = NotificationCenter.default.addObserver(forName: RuntimeLog.recordWritten, object: nil, queue: .main) { note in
            let timestamp = note.userInfo?["timestamp"] as? String
            let event = note.userInfo?["event"] as? String
            let fields = note.userInfo?["fields"] as? [String: String] ?? [:]
            MainActor.assumeIsolated {
                guard let timestamp, let event else { return }
                EventLogWindowController.shared.model.append(timestamp: timestamp, event: event, fields: fields)
            }
        }
    }

    func append(timestamp: String, event: String, fields: [String: String]) {
        if buffer.append(timestamp: timestamp, event: event, fields: fields) {
            lines = buffer.lines
        }
    }
}

struct EventLogView: View {
    @ObservedObject var model: EventLogModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(14)
                }
                .onAppear { proxy.scrollTo(model.lines.count - 1, anchor: .bottom) }
                .onChange(of: model.lines) { _, lines in
                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                }
            }
            Divider()
            HStack {
                Text("\(model.lines.count) events · newest last · times in UTC")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.lines.joined(separator: "\n") + "\n", forType: .string)
                }
                Button("Show Log Files") {
                    NSWorkspace.shared.activateFileViewerSelecting([RuntimeLog.shared.directory])
                }
            }
            .padding(12)
        }
    }
}

/// A retained AppKit window, like the dashboard and Settings.
@MainActor
final class EventLogWindowController: NSObject, NSWindowDelegate {
    static let shared = EventLogWindowController()

    let model = EventLogModel()
    private(set) var window: NSWindow?

    func show() {
        model.start()
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        keepWindowOnScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("exit-ip-event-log")
        window.title = "Exit IP Event Log"
        window.contentViewController = fixedSizeHostingController(
            EventLogView(model: model).frame(minWidth: 520, minHeight: 240)
        )
        window.setContentSize(NSSize(width: 820, height: 520))
        window.contentMinSize = NSSize(width: 520, height: 240)
        window.isReleasedWhenClosed = false
        window.delegate = self
        placeOnActiveScreen(window)
        return window
    }
}
