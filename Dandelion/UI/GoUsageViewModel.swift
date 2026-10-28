//
//  GoUsageViewModel.swift
//  Dandelion
//
//  Drives GoUsageCard from OpenCode's official usage API
//  (https://opencode.ai/inference/go/v1/usage), authenticated with the
//  `opencode-go` key discovered in auth.json - no browser session needed.
//

import Foundation
import Observation

/// Load state for the live Go usage widget.
enum GoUsageState: Equatable {
    case loading
    case loaded(GoUsageSummary)
    /// No `opencode-go` key in auth.json - show the "connect Go" hint.
    case needsKey
    /// A key was found, but the endpoint rejected it - revoked or rotated, or
    /// the account has no Go subscription.
    case unauthorized
    /// No credential problem: the request failed or the payload was unusable.
    case unavailable
}

@MainActor
@Observable
final class GoUsageViewModel {
    private(set) var state: GoUsageState = .loading

    private let usageService: UsageService

    init(usageService: UsageService = UsageService()) {
        self.usageService = usageService
    }

    func refresh() async {
        state = .loading

        do {
            state = .loaded(try await usageService.fetchGoUsage())
        } catch let error as UsageServiceError {
            switch error {
            case .missingAPIKey:
                state = .needsKey
            case .unauthorized:
                state = .unauthorized
            case .balanceNotFound, .goUsageNotFound, .network:
                state = .unavailable
            }
        } catch {
            state = .unavailable
        }
    }
}
