//
//  CookieDiscoveryService.swift
//  Dandelion
//
//  Discovers the user's opencode.ai session cookie from the browsers already
//  logged in to OpenCode, so the live Zen balance can light up with no
//  manual setup - mirroring the cookie-jar techniques opencode-bar itself
//  uses for other providers. Chromium-based browsers encrypt cookie values
//  with an AES-128-CBC key derived from a password stored in the macOS
//  Keychain; Safari stores cookies in its own binary `Cookies.binarycookies`
//  format, which needs Full Disk Access to read.
//

import Foundation
import SQLite3
import CommonCrypto
import Security

/// A discovered `opencode.ai` session cookie value, plus which browser it came from.
struct SessionCookie: Sendable, Equatable {
    let value: String
    let source: String
}

/// Passed to `sqlite3_bind_text` so SQLite copies the bound string instead of
/// assuming the caller keeps the buffer alive.
private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct CookieDiscoveryService: Sendable {
    private static let targetDomain = "opencode.ai"
    private static let targetCookieName = "auth"

    private let overrideStore: CookieOverrideStore

    init(overrideStore: CookieOverrideStore = CookieOverrideStore()) {
        self.overrideStore = overrideStore
    }

    /// A Chromium-family browser's cookie DB path and matching Keychain "Safe Storage" item.
    private struct ChromiumBrowser {
        let displayName: String
        let cookiesRelativePath: String
        let keychainService: String
        let keychainAccount: String
    }

    private let chromiumBrowsers: [ChromiumBrowser] = [
        ChromiumBrowser(
            displayName: "Google Chrome",
            cookiesRelativePath: "Library/Application Support/Google/Chrome/Default/Cookies",
            keychainService: "Chrome Safe Storage",
            keychainAccount: "Chrome"
        ),
        ChromiumBrowser(
            displayName: "Brave",
            cookiesRelativePath: "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
            keychainService: "Brave Safe Storage",
            keychainAccount: "Brave"
        ),
        ChromiumBrowser(
            displayName: "Microsoft Edge",
            cookiesRelativePath: "Library/Application Support/Microsoft Edge/Default/Cookies",
            keychainService: "Microsoft Edge Safe Storage",
            keychainAccount: "Microsoft Edge"
        ),
        ChromiumBrowser(
            displayName: "Arc",
            cookiesRelativePath: "Library/Application Support/Arc/User Data/Default/Cookies",
            keychainService: "Arc Safe Storage",
            keychainAccount: "Arc"
        ),
    ]

    /// Prefers a manually-pasted cookie from Settings (the documented
    /// fallback for when auto-discovery fails), then tries every supported
    /// browser in turn. Never throws: a locked/missing store, a denied
    /// Keychain prompt, or a parsing failure for one browser simply falls
    /// through to the next, so callers can show the graceful fallback state
    /// instead of crashing.
    func discoverSessionCookie() -> SessionCookie? {
        if let manual = overrideStore.load() {
            return SessionCookie(value: manual, source: "Manual override")
        }

        for browser in chromiumBrowsers {
            if let cookie = readChromiumCookie(browser) {
                return cookie
            }
        }
        return readSafariCookie()
    }

    // MARK: - Chromium-based browsers

    private func readChromiumCookie(_ browser: ChromiumBrowser) -> SessionCookie? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cookiesURL = home.appendingPathComponent(browser.cookiesRelativePath)
        guard FileManager.default.fileExists(atPath: cookiesURL.path) else { return nil }

        // Copy first: the live Cookies DB can be exclusively locked while
        // the browser is running.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dandelion-cookies-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard (try? FileManager.default.copyItem(at: cookiesURL, to: tempURL)) != nil else { return nil }

        guard let encryptedValue = queryEncryptedCookie(dbPath: tempURL.path),
              let key = chromiumEncryptionKey(service: browser.keychainService, account: browser.keychainAccount),
              let decrypted = decryptChromiumCookie(encryptedValue, key: key)
        else { return nil }

        return SessionCookie(value: decrypted, source: browser.displayName)
    }

    private func queryEncryptedCookie(dbPath: String) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }

        let query = "SELECT encrypted_value FROM cookies WHERE host_key LIKE ? AND name = ? ORDER BY length(encrypted_value) DESC LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, "%\(Self.targetDomain)", -1, sqliteTransientDestructor)
        sqlite3_bind_text(statement, 2, Self.targetCookieName, -1, sqliteTransientDestructor)

        guard sqlite3_step(statement) == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, 0))
        return Data(bytes: blob, count: length)
    }

    /// Reads the browser's cookie-encryption password from the Keychain and
    /// derives the AES-128 key Chromium uses on macOS (PBKDF2-HMAC-SHA1,
    /// salt "saltysalt", 1003 iterations, 16-byte key). The very first read
    /// prompts the user for a one-time Keychain access approval.
    private func chromiumEncryptionKey(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let passwordData = result as? Data
        else { return nil }

        let saltData = Data("saltysalt".utf8)
        var derivedKey = Data(count: 16)
        let status = derivedKey.withUnsafeMutableBytes { keyBytes -> Int32 in
            passwordData.withUnsafeBytes { passwordBytes -> Int32 in
                saltData.withUnsafeBytes { saltBytes -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress, 16
                    )
                }
            }
        }
        return status == kCCSuccess ? derivedKey : nil
    }

    /// Decrypts a Chromium `encrypted_value` blob: a 3-byte "v10"/"v11"
    /// prefix followed by AES-128-CBC ciphertext with a fixed 16-space IV.
    /// Newer Chrome builds additionally prepend a 32-byte domain-binding
    /// hash to the plaintext; since OpenCode's session cookie is a
    /// Hapi/Iron seal that always starts with "Fe26.", that known prefix
    /// lets us reliably detect and strip it without reimplementing that
    /// hardening scheme.
    private func decryptChromiumCookie(_ encrypted: Data, key: Data) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(data: encrypted.prefix(3), encoding: .utf8)
        guard prefix == "v10" || prefix == "v11" else { return nil }
        let ciphertext = encrypted.suffix(from: 3)

        let iv = Data(repeating: 0x20, count: 16)
        var decrypted = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let decryptedCapacity = decrypted.count
        var decryptedLength = 0

        let status = decrypted.withUnsafeMutableBytes { outBytes -> Int32 in
            ciphertext.withUnsafeBytes { inBytes -> Int32 in
                iv.withUnsafeBytes { ivBytes -> Int32 in
                    key.withUnsafeBytes { keyBytes -> Int32 in
                        Int32(CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, ciphertext.count,
                            outBytes.baseAddress, decryptedCapacity,
                            &decryptedLength
                        ))
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        decrypted = decrypted.prefix(decryptedLength)

        if decrypted.count > 32 {
            let stripped = decrypted.suffix(from: 32)
            if let value = String(data: stripped, encoding: .utf8), value.hasPrefix("Fe26.") {
                return value
            }
        }
        if let value = String(data: decrypted, encoding: .utf8), value.hasPrefix("Fe26.") {
            return value
        }
        return nil
    }

    // MARK: - Safari

    /// Parses Safari's `Cookies.binarycookies` container format directly
    /// (no public API exists for it). Requires Full Disk Access; returns
    /// `nil` (not a crash) when the file can't be read or contains no match.
    private func readSafariCookie() -> SessionCookie? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
            home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let value = SafariBinaryCookieParser.findCookieValue(
                      in: data,
                      domainSuffix: Self.targetDomain,
                      name: Self.targetCookieName
                  )
            else { continue }
            return SessionCookie(value: value, source: "Safari")
        }
        return nil
    }
}

/// Minimal reader for Apple's reverse-engineered `.binarycookies` format:
/// a "cook" magic header, a big-endian page count/size table, then that
/// many pages each holding a flat array of cookie records.
private enum SafariBinaryCookieParser {
    static func findCookieValue(in data: Data, domainSuffix: String, name: String) -> String? {
        guard data.count > 8, data.prefix(4).elementsEqual([0x63, 0x6f, 0x6f, 0x6b]) else { return nil } // "cook"

        var offset = 4
        let pageCount = Int(readUInt32BE(data, at: offset))
        offset += 4

        var pageSizes: [Int] = []
        pageSizes.reserveCapacity(pageCount)
        for _ in 0..<pageCount {
            pageSizes.append(Int(readUInt32BE(data, at: offset)))
            offset += 4
        }

        for pageSize in pageSizes {
            guard offset + pageSize <= data.count else { break }
            let page = data.subdata(in: offset..<(offset + pageSize))
            if let value = findCookieValue(inPage: page, domainSuffix: domainSuffix, name: name) {
                return value
            }
            offset += pageSize
        }
        return nil
    }

    private static func findCookieValue(inPage page: Data, domainSuffix: String, name: String) -> String? {
        // Page header (4 bytes) + cookie count (4 bytes, little-endian).
        guard page.count > 8 else { return nil }
        let cookieCount = Int(readUInt32LE(page, at: 4))
        var cursor = 8

        var cookieOffsets: [Int] = []
        for _ in 0..<cookieCount {
            guard cursor + 4 <= page.count else { return nil }
            cookieOffsets.append(Int(readUInt32LE(page, at: cursor)))
            cursor += 4
        }

        for cookieOffset in cookieOffsets {
            guard cookieOffset < page.count else { continue }
            if let value = parseCookieRecord(page, at: cookieOffset, domainSuffix: domainSuffix, name: name) {
                return value
            }
        }
        return nil
    }

    private static func parseCookieRecord(_ page: Data, at start: Int, domainSuffix: String, name: String) -> String? {
        guard start + 56 <= page.count else { return nil }
        let domainOffset = Int(readUInt32LE(page, at: start + 16))
        let nameOffset = Int(readUInt32LE(page, at: start + 20))
        let valueOffset = Int(readUInt32LE(page, at: start + 28))

        guard let domain = readCString(page, at: start + domainOffset), domain.hasSuffix(domainSuffix),
              let cookieName = readCString(page, at: start + nameOffset), cookieName == name,
              let value = readCString(page, at: start + valueOffset)
        else { return nil }

        return value
    }

    private static func readCString(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var end = offset
        while end < data.count, data[data.startIndex + end] != 0 { end += 1 }
        let bytes = data.subdata(in: offset..<end)
        return String(data: bytes, encoding: .utf8)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
    }
}
