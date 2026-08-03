//
//  ZenBalanceCard.swift
//  Dandelion
//
//  Live Zen balance ring, auto-reload threshold and monthly limit info,
//  discovered automatically from the user's browser session - with a
//  graceful fallback state when discovery/the private endpoint fails.
//

import SwiftUI

struct ZenBalanceCard: View {
    @Bindable var viewModel: ZenBalanceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.sm) {
            HStack {
                Text("Zen Balance")
                    .font(TerminalTheme.Fonts.heading)
                Spacer()
                if case .loading = viewModel.state {
                    ProgressView().controlSize(.mini)
                }
            }

            switch viewModel.state {
            case .loading:
                RingGaugeView(progress: 0, valueText: "—", label: "Balance", lineWidth: 3)
                    .frame(maxWidth: .infinity, alignment: .center)
            case .loaded(let balance):
                loadedContent(balance)
            case .unavailable:
                UnavailableStateView()
            case .sessionExpired:
                SessionExpiredStateView(consoleURL: URL(string: "https://opencode.ai/zen")!)
            }
        }
        .task { await viewModel.refresh() }
    }

    private func loadedContent(_ balance: ZenBalance) -> some View {
        VStack(spacing: TerminalTheme.Spacing.sm) {
            RingGaugeView(
                progress: progress(for: balance),
                valueText: "$" + String(format: "%.2f", balance.currentUSD),
                label: "Balance",
                tint: ringTint(for: balance),
                lineWidth: 3
            )
            .frame(maxWidth: .infinity, alignment: .center)

            if let monthlyLimit = balance.monthlyLimitUSD {
                Text("Monthly limit: $\(Self.formatted(monthlyLimit))"
                    + (balance.monthlyUsageUSD.map { " · used $\(Self.formatted($0))" } ?? ""))
                    .font(TerminalTheme.Fonts.caption)
                    .foregroundStyle(TerminalTheme.Colors.textSecondary)
            }
        }
    }

    private func progress(for balance: ZenBalance) -> Double {
        if let monthlyLimit = balance.monthlyLimitUSD, monthlyLimit > 0 {
            return balance.currentUSD / monthlyLimit
        }
        // With no configured monthly limit, show progress toward the
        // auto-reload amount as a reasonable reference ceiling.
        guard balance.autoReloadAmountUSD > 0 else { return 1 }
        return balance.currentUSD / balance.autoReloadAmountUSD
    }

    private func ringTint(for balance: ZenBalance) -> Color {
        balance.currentUSD <= balance.autoReloadThresholdUSD
            ? TerminalTheme.Colors.warning
            : TerminalTheme.Colors.accent
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// Shown when browser cookie discovery or the private endpoint fails -
/// never blocks the rest of the dashboard, just links out to the real console.
private struct UnavailableStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.xs) {
            HStack(spacing: TerminalTheme.Spacing.sm) {
                RingGaugeView(progress: 0, valueText: "—", label: "Balance", tint: TerminalTheme.Colors.textTertiary, size: 72, lineWidth: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Balance unavailable")
                        .font(TerminalTheme.Fonts.body.weight(.semibold))
                    Text("Sign in to opencode.ai in your browser, then refresh.")
                        .font(TerminalTheme.Fonts.caption)
                        .foregroundStyle(TerminalTheme.Colors.textSecondary)
                    Link("Open Console", destination: URL(string: "https://opencode.ai/zen")!)
                        .font(TerminalTheme.Fonts.caption)
                        .foregroundStyle(TerminalTheme.Colors.accent)
                }
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
            RingGaugeView(progress: 0, valueText: "—", label: "Balance", tint: TerminalTheme.Colors.textTertiary, size: 72, lineWidth: 3)
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
    ZenBalanceCard(viewModel: ZenBalanceViewModel(appSettings: AppSettings()))
        .padding()
        .frame(width: TerminalTheme.Metrics.panelWidth)
        .background(TerminalTheme.Colors.background)
}
