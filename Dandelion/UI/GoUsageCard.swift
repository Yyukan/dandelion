//
//  GoUsageCard.swift
//  Dandelion
//
//  Live 5h/weekly/monthly Go usage-window ring gauges with reset countdowns,
//  reusing the same discovery pipeline as ZenBalanceCard - with the same
//  graceful fallback state when discovery/the private endpoint fails.
//

import SwiftUI

struct GoUsageCard: View {
    @Bindable var viewModel: GoUsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.sm) {
            HStack {
                Text("Go Usage")
                    .font(TerminalTheme.Fonts.heading)
                Spacer()
                if case .loading = viewModel.state {
                    ProgressView().controlSize(.mini)
                }
            }

            switch viewModel.state {
            case .loading:
                loadingRings
            case .loaded(let summary):
                loadedContent(summary)
            case .unavailable:
                UnavailableStateView()
            case .sessionExpired:
                SessionExpiredStateView(consoleURL: URL(string: "https://opencode.ai/go")!)
            }
        }
        .task { await viewModel.refresh() }
    }

    private var loadingRings: some View {
        HStack(spacing: TerminalTheme.Spacing.lg) {
            RingGaugeView(progress: 0, valueText: "—", label: "5h", size: 72, lineWidth: 3)
            RingGaugeView(progress: 0, valueText: "—", label: "Weekly", size: 72, lineWidth: 3)
            RingGaugeView(progress: 0, valueText: "—", label: "Monthly", size: 72, lineWidth: 3)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func loadedContent(_ summary: GoUsageSummary) -> some View {
        VStack(spacing: TerminalTheme.Spacing.sm) {
            HStack(spacing: TerminalTheme.Spacing.lg) {
                usageRing(summary.rolling5h)
                usageRing(summary.weekly)
                usageRing(summary.monthly)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            if summary.isUsingZenBalance {
                Text("Go limits reached - now billing from Zen balance")
                    .font(TerminalTheme.Fonts.caption)
                    .foregroundStyle(TerminalTheme.Colors.warning)
            }
        }
    }

    private func usageRing(_ window: GoUsageWindow) -> some View {
        VStack(spacing: 2) {
            RingGaugeView(
                progress: window.usedPercent / 100,
                valueText: String(format: "%.1f%%", window.usedPercent),
                label: window.label,
                tint: window.isHealthy ? TerminalTheme.Colors.accent : TerminalTheme.Colors.danger,
                size: 72,
                lineWidth: 3,
                valueFont: TerminalTheme.Fonts.metricSmall
            )
            Text(Self.countdownText(window.resetsIn))
                .font(TerminalTheme.Fonts.caption)
                .foregroundStyle(TerminalTheme.Colors.textTertiary)
        }
    }

    private static func countdownText(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "resets soon" }
        let totalMinutes = Int(interval / 60)
        if totalMinutes < 60 {
            return "resets \(totalMinutes)m"
        }
        let hours = totalMinutes / 60
        if hours < 24 {
            return "resets \(hours)h"
        }
        return "resets \(hours / 24)d"
    }
}

/// Shown when browser cookie discovery or the private endpoint fails -
/// never blocks the rest of the dashboard, just links out to the real console.
private struct UnavailableStateView: View {
    var body: some View {
        HStack(spacing: TerminalTheme.Spacing.sm) {
            RingGaugeView(progress: 0, valueText: "—", label: "Usage", tint: TerminalTheme.Colors.textTertiary, size: 72, lineWidth: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage unavailable")
                    .font(TerminalTheme.Fonts.body.weight(.semibold))
                Text("Sign in to opencode.ai in your browser, then refresh.")
                    .font(TerminalTheme.Fonts.caption)
                    .foregroundStyle(TerminalTheme.Colors.textSecondary)
                Link("Open Console", destination: URL(string: "https://opencode.ai/go")!)
                    .font(TerminalTheme.Fonts.caption)
                    .foregroundStyle(TerminalTheme.Colors.accent)
            }
        }
    }
}

/// Shown when a cookie was found but the endpoint no longer recognizes it -
/// most likely the browser session has expired since it was discovered.
private struct SessionExpiredStateView: View {
    let consoleURL: URL

    var body: some View {
        HStack(spacing: TerminalTheme.Spacing.sm) {
            RingGaugeView(progress: 0, valueText: "—", label: "Usage", tint: TerminalTheme.Colors.textTertiary, size: 72, lineWidth: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session expired")
                    .font(TerminalTheme.Fonts.body.weight(.semibold))
                Text("Please relogin in the browser, then refresh.")
                    .font(TerminalTheme.Fonts.caption)
                    .foregroundStyle(TerminalTheme.Colors.textSecondary)
                Link("Open Console", destination: consoleURL)
                    .font(TerminalTheme.Fonts.caption)
                    .foregroundStyle(TerminalTheme.Colors.accent)
            }
        }
    }
}

#Preview {
    GoUsageCard(viewModel: GoUsageViewModel(appSettings: AppSettings()))
        .padding()
        .frame(width: TerminalTheme.Metrics.panelWidth)
        .background(TerminalTheme.Colors.background)
}
