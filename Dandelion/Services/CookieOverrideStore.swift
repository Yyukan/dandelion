//
//  CookieOverrideStore.swift
//  Dandelion
//
//  Reads a manually-pasted opencode.ai session cookie from the macOS Keychain
//  (never plaintext), used as a fallback when automatic browser cookie
//  discovery fails. The Settings field that wrote it has been removed, so
//  only cookies saved by an earlier build are found here.
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
}
