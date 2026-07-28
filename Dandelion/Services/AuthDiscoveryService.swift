//
//  AuthDiscoveryService.swift
//  Dandelion
//
//  Locates and parses OpenCode's local auth.json to auto-detect the user's
//  Zen/Go API keys, so no manual key entry is needed.
//

import Foundation

/// A discovered OpenCode API key for one of the two supported surfaces.
struct OpenCodeCredential: Sendable, Equatable {
    enum Provider: String, Sendable {
        /// Entry name OpenCode stores for the pay-as-you-go Zen surface.
        case zen = "opencode"
        /// Entry name OpenCode stores for the Go subscription surface.
        case go = "opencode-go"
    }

    let provider: Provider
    let apiKey: String
}

/// Reads `~/.local/share/opencode/auth.json` (or the path in
/// `OPENCODE_AUTH_JSON`, if set) and extracts the `opencode` / `opencode-go`
/// API key entries OpenCode itself writes there after `/connect`.
///
/// `@unchecked Sendable`: `FileManager` isn't `Sendable` itself, but this
/// type only reads its `homeDirectoryForCurrentUser`/`.default` instance,
/// which Apple documents as safe to use from any thread.
struct AuthDiscoveryService: @unchecked Sendable {
    private let fileManager: FileManager
    private let environment: [String: String]

    init(fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileManager = fileManager
        self.environment = environment
    }

    /// Resolves the auth.json location, honoring the `OPENCODE_AUTH_JSON` override.
    func resolveAuthFileURL() -> URL {
        if let override = environment["OPENCODE_AUTH_JSON"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    /// Loads and parses the Zen/Go API key credentials.
    ///
    /// Never throws: a missing file, unreadable permissions, or malformed
    /// JSON all resolve to an empty result so callers can show the
    /// disconnected/instructions state instead of crashing.
    func discoverCredentials() -> [OpenCodeCredential] {
        let url = resolveAuthFileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }

        return [OpenCodeCredential.Provider.zen, .go].compactMap { provider in
            guard let entry = json[provider.rawValue] as? [String: Any],
                  (entry["type"] as? String) == "api",
                  let key = entry["key"] as? String,
                  !key.isEmpty
            else { return nil }
            return OpenCodeCredential(provider: provider, apiKey: key)
        }
    }
}
