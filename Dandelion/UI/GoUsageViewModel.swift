//
//  GoUsageViewModel.swift
//  Dandelion
//
//  Drives GoUsageCard: reuses the same cookie-discovery pipeline as the Zen
//  balance widget to fetch the live 5h/weekly/monthly usage windows.
//

import Foundation
import Observation

/// Load state for the live Go usage widget.
enum GoUsageState: Equatable {
    case loading
    case loaded(GoUsageSummary)
    /// No session cookie could be found at all - show "—" + a link to the
    /// real console instead of crashing or blocking the rest of the UI.
    case unavailable
    /// A cookie was found, but the endpoint no longer recognizes it - most
    /// likely the browser session has expired and needs a fresh login.
    case sessionExpired
}

@MainActor
@Observable
final class GoUsageViewModel {
    private(set) var state: GoUsageState = .loading

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
            let usage = try await usageService.fetchGoUsage(
                cookie: cookie,
                workspaceIDOverride: workspaceOverride.isEmpty ? nil : workspaceOverride
            )
            state = .loaded(usage)
        } catch let error as UsageServiceError {
            switch error {
            case .workspaceNotFound, .goUsageNotFound:
                // A cookie was found, but the authenticated page couldn't be
                // parsed - the most likely cause is that the browser session
                // behind it has since expired.
                state = .sessionExpired
            case .balanceNotFound, .network:
                state = .unavailable
            }
        } catch {
            state = .unavailable
        }
    }
}
