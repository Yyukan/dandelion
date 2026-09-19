//
//  GoUsageWindow.swift
//  Dandelion
//
//  Live OpenCode Go subscription usage windows, from the official
//  `GET /zen/go/v1/usage` endpoint (see UsageService).
//

import Foundation

/// One Go usage-window reading (5h rolling / weekly / monthly).
struct GoUsageWindow: Sendable, Equatable {
    let label: String
    /// Already a 0...100 percentage, as reported by the dashboard.
    let usedPercent: Double
    let resetsIn: TimeInterval
    /// `false` when the window itself reports a non-"ok" status (e.g. exceeded).
    let isHealthy: Bool
}

/// The full set of Go usage windows for a workspace.
struct GoUsageSummary: Sendable, Equatable {
    let rolling5h: GoUsageWindow
    let weekly: GoUsageWindow
    let monthly: GoUsageWindow
}
