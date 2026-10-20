import Foundation
import ServiceManagement

/// Applies the remembered Launch at login choice to `SMAppService.mainApp` once per launch, so a
/// registration macOS dropped (for example when a reinstall replaced the bundle) comes back.
@MainActor
enum LoginItemSync {
    static var storedChoice: Bool? {
        ExitIPAppGroup.defaults.object(forKey: ExitIPPreferenceKey.launchAtLogin) as? Bool
    }

    static func store(_ enabled: Bool) {
        ExitIPAppGroup.defaults.set(enabled, forKey: ExitIPPreferenceKey.launchAtLogin)
    }

    static var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    static func syncAtLaunch() {
        let before = status
        let action = LoginItemPolicy.action(stored: storedChoice, status: before)
        var fields = ["action": action.rawValue, "status": before.rawValue]
        do {
            switch action {
            case .register: try SMAppService.mainApp.register()
            case .unregister: try SMAppService.mainApp.unregister()
            case .adopt: store(true)
            case .none: break
            }
            fields["result"] = "ok"
            fields["status_after"] = status.rawValue
            RuntimeLog.shared.info("login_item_synced", fields: fields)
        } catch {
            fields["result"] = "failed"
            fields["error"] = error.localizedDescription
            RuntimeLog.shared.error("login_item_synced", fields: fields)
        }
    }
}
