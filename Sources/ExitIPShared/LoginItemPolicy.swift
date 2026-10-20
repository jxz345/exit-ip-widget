import Foundation

/// The login item's state as macOS reports it (`SMAppService.Status`, kept here so the policy is testable).
public enum LoginItemStatus: String, Sendable, Equatable {
    case enabled, requiresApproval, notRegistered, notFound
}

public enum LoginItemAction: String, Sendable, Equatable {
    /// Nothing to do: the registration already matches the stored choice.
    case none
    /// The user chose Launch at login, but macOS dropped the registration (for example after a reinstall).
    case register
    /// The user turned it off, but a registration remains.
    case unregister
    /// A registration exists from before the app remembered the choice: store it as chosen.
    case adopt
}

/// Launch at login is the user's remembered choice (`ExitIPPreferenceKey.launchAtLogin`), applied
/// again at every launch so a lost registration can't silently turn it off.
public enum LoginItemPolicy {
    public static func action(stored: Bool?, status: LoginItemStatus) -> LoginItemAction {
        switch (stored, status) {
        case (nil, .enabled), (nil, .requiresApproval): .adopt
        case (nil, _): .none
        // Waiting for approval in System Settings is the user's step; registering again would loop.
        case (true?, .enabled), (true?, .requiresApproval): .none
        case (true?, _): .register
        case (false?, .enabled), (false?, .requiresApproval): .unregister
        case (false?, _): .none
        }
    }
}
