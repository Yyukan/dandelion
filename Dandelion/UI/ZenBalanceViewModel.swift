//
//  ZenBalanceViewModel.swift
//  Dandelion
//
//  Drives ZenBalanceCard: discovers a browser session cookie and uses it to
//  fetch the live Zen balance, degrading gracefully when discovery or the
//  private endpoint fails.
//

import Foundation
import Observation

/// Load state for the live Zen balance widget.
enum ZenBalanceState: Equatable {
    case loading
    case loaded(ZenBalance)
    /// Cookie discovery or the private endpoint failed - show "—" + a link
    /// to the real console instead of crashing or blocking the rest of the UI.
    case unavailable
}

@MainActor
@Observable
final class ZenBalanceViewModel {
    private(set) var state: ZenBalanceState = .loading

    private let cookieDiscoveryService: CookieDiscoveryService
    private let usageService: UsageService
    private let appSettings: AppSettings

    init(
        appSettings: AppSettings,
        cookieDiscoveryService: CookieDiscoveryService = CookieDiscoveryService(),
        usageService: UsageService = UsageService()
    ) {
        self.appSettings = appSettings
        self.cookieDiscoveryService = cookieDiscoveryService
        self.usageService = usageService
    }

    func refresh() async {
        state = .loading

        // Cookie discovery does blocking disk/Keychain I/O, so it runs off
        // the main actor to keep the panel responsive while it works.
        let discoveryService = cookieDiscoveryService
        let cookie = await Task.detached(priority: .userInitiated) {
            discoveryService.discoverSessionCookie()
        }.value

        guard let cookie else {
            state = .unavailable
            return
        }

        do {
            let workspaceOverride = appSettings.manualWorkspaceID
            let balance = try await usageService.fetchZenBalance(
                cookie: cookie,
                workspaceIDOverride: workspaceOverride.isEmpty ? nil : workspaceOverride
            )
            state = .loaded(balance)
        } catch {
            state = .unavailable
        }
    }
}
