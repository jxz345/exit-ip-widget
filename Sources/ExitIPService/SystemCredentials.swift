import Foundation
import Security

/// The daemon runs in the system context. Never consult a user's login keychain, never show UI,
/// and never send the saved value back to a client. Every query targets the System file keychain.
struct SystemCredentials: CredentialBackend {
    private func query() throws -> [String: Any] {
        var keychain: SecKeychain?
        let status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
        guard status == errSecSuccess, let keychain else { throw KeychainError.unexpectedStatus(status) }
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: ExitIPService.label,
         kSecAttrAccount as String: SecureTokenStore.ipinfoLiteAccount,
         kSecMatchSearchList as String: [keychain],
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    func read(account: String) throws -> String? {
        var query = try query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedStatus(status)
        }
        return token
    }

    func save(_ value: String, account: String) throws {
        let query = try query()
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            // A root-only ACL survives an ad-hoc executable's code hash changing at upgrade.
            var add = query
            add[kSecUseKeychain as String] = (add.removeValue(forKey: kSecMatchSearchList as String) as? [SecKeychain])?.first
            add[kSecValueData as String] = data
            add[kSecAttrAccess as String] = try Self.ownerAccess()
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError.unexpectedStatus(result) }
        } else if status != errSecSuccess { throw KeychainError.unexpectedStatus(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }

    static func ownerAccess() throws -> SecAccess {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessCreateWithOwnerAndACL(getuid(), getgid(), UInt32(kSecUseOnlyUID), [kSecACLAuthorizationAny] as CFArray, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw DaemonFailure.credential
        }
        return access
    }
}

enum ServiceAuthorization {
    static func installRight() throws {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else {
            throw DaemonFailure.unauthorized
        }
        defer { AuthorizationFree(authorization, []) }
        let rule: [String: Any] = ["class": "user", "group": "admin", "authenticate-user": true,
                                   "shared": false, "timeout": 300, "allow-root": true]
        guard AuthorizationRightSet(authorization, ExitIPService.settingsRight, rule as CFDictionary,
                                    "Change shared Exit IP monitoring settings" as CFString, nil, nil) == errAuthorizationSuccess else {
            throw DaemonFailure.unauthorized
        }
    }

    static func validate(_ data: Data?) -> Bool {
        guard let data, data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var external = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &external) { _ = data.copyBytes(to: $0) }
        var authorization: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&external, &authorization) == errAuthorizationSuccess,
              let authorization else { return false }
        defer { AuthorizationFree(authorization, []) }
        return ExitIPService.settingsRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                // The UI obtained the right; the daemon must recheck it without prompting.
                return AuthorizationCopyRights(authorization, &rights, nil, [], nil) == errAuthorizationSuccess
            }
        }
    }
}
