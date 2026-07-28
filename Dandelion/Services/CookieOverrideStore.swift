//
//  CookieOverrideStore.swift
//  Dandelion
//
//  Stores the user's manually-pasted opencode.ai session cookie in the
//  macOS Keychain (never plaintext), for use when automatic browser cookie
//  discovery fails - the fallback path Settings exposes.
//

import Foundation
import Security

struct CookieOverrideStore: Sendable {
    private static let service = "nl.ostconsultancy.Dandelion"
    private static let account = "opencode-session-cookie-override"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let data = Data(trimmed.utf8)

        var updateQuery = baseQuery
        updateQuery[kSecValueData as String] = data
        let status = SecItemAdd(updateQuery as CFDictionary, nil)

        if status == errSecDuplicateItem {
            SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
