//
//  GoUsageViewModel.swift
//  Dandelion
//
//  Drives GoUsageCard from OpenCode's official usage API
//  (https://opencode.ai/zen/go/v1/usage), authenticated with the locally
//  discovered `opencode-go` API key - no browser session needed.
//

import Foundation
import Observation

/// Load state for the live Go usage widget.
enum GoUsageState: Equatable {
    case loading
    case loaded(GoUsageSummary)
    /// No Go API key could be found locally - show the "connect Go" hint
    /// instead of crashing or blocking the rest of the UI.
    case unavailable
    /// A key was found, but the endpoint rejected it - the key was revoked
    /// or rotated and OpenCode needs reconnecting.
    case sessionExpired
}

@MainActor
@Observable
final class GoUsageViewModel {
    private(set) var state: GoUsageState = .loading

    private let usageService: UsageService
    private let appSettings: AppSettings

    init(
        appSettings: AppSettings,
        usageService: UsageService = UsageService()
    ) {
        self.appSettings = appSettings
        self.usageService = usageService
    }

    func refresh() async {
        state = .loading

        do {
            let workspaceOverride = appSettings.manualWorkspaceID
            let usage = try await usageService.fetchGoUsage(
                workspaceIDOverride: workspaceOverride.isEmpty ? nil : workspaceOverride
            )
            state = .loaded(usage)
        } catch let error as UsageServiceError {
            switch error {
            case .sessionExpired:
                // The key was rejected upstream: revoked, rotated, or the
                // account has no Go subscription.
                state = .sessionExpired
            case .workspaceNotFound, .balanceNotFound, .goUsageNotFound, .missingGoAPIKey, .network:
                state = .unavailable
            }
        } catch {
            state = .unavailable
        }
    }
}
