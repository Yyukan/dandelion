//
//  ZenBalance.swift
//  Dandelion
//
//  Live Zen pay-as-you-go balance, as surfaced by the private workspace
//  billing page (no public REST API exposes this - see UsageService).
//

import Foundation

/// Current Zen account balance plus auto-reload/monthly-limit context, all
/// read straight from the OpenCode Zen web dashboard.
struct ZenBalance: Sendable, Equatable {
    /// Current pay-as-you-go credit balance, in US dollars.
    let currentUSD: Double
    /// Whether auto-reload is currently configured/enabled on the account.
    let autoReloadEnabled: Bool
    /// Balance level (in USD) that triggers an auto-reload, if enabled.
    let autoReloadThresholdUSD: Double
    /// Amount (in USD) added back to the balance on an auto-reload.
    let autoReloadAmountUSD: Double
    /// Optional monthly spend cap the user configured on the workspace.
    let monthlyLimitUSD: Double?
    /// Spend so far in the current calendar month, in US dollars.
    let monthlyUsageUSD: Double?
}
