import Foundation

/// Small JSON-lines logger for diagnosing refresh lifecycle and provider behavior.
/// The log directory can be overridden with EXIT_IP_LOG_DIRECTORY during local testing.
final class RuntimeLog: @unchecked Sendable {
    static let shared = RuntimeLog()

    private let lock = NSLock()
    private let fileURL: URL?

    private init() {
        let fileManager = FileManager.default
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["EXIT_IP_LOG_DIRECTORY"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ExitIPMonitor/Logs", isDirectory: true)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.cleanupOldLogs(in: directory, retentionDays: DiagnosticPreferencesStore().load().retentionDays)
            let stamp = ISO8601DateFormatter().string(from: .now)
                .replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("runtime-\(stamp).jsonl")
            fileManager.createFile(atPath: url.path, contents: nil)
            fileURL = url
        } catch {
            fileURL = nil
        }
    }

    func info(_ event: String, fields: [String: String] = [:]) {
        write(level: "info", event: event, fields: fields)
    }

    func error(_ event: String, fields: [String: String] = [:]) {
        write(level: "error", event: event, fields: fields)
    }

    private func write(level: String, event: String, fields: [String: String]) {
        guard let fileURL else { return }
        let preferences = DiagnosticPreferencesStore().load()
        let safeFields = fields.mapValues { value in
            preferences.includeFullIPAddresses ? value : LogRedactor.redactIPAddresses(in: value)
        }
        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "level": level,
            "event": event,
            "fields": safeFields
        ]
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")

        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: Data(line.utf8))
    }

    private static func cleanupOldLogs(in directory: URL, retentionDays: Int) {
        let cutoff = Date.now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("runtime-") && file.pathExtension == "jsonl" {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
