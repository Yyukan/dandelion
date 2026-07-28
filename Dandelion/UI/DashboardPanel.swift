//
//  DashboardPanel.swift
//  Dandelion
//
//  Root SwiftUI content hosted inside the custom borderless NSPanel that
//  opens from the status bar item. For now this wires up static placeholder
//  content to validate the visual shell end-to-end; the real Zen/Go cards
//  and model catalog land in later steps.
//

import SwiftUI

struct DashboardPanel: View {
    let appSettings: AppSettings
    let catalogViewModel: ModelCatalogViewModel
    let zenBalanceViewModel: ZenBalanceViewModel
    let goUsageViewModel: GoUsageViewModel
    let refreshCoordinator: RefreshCoordinator

    /// Injected so these buttons can drive the status bar controller
    /// (opening the Settings window, quitting the app).
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(TerminalTheme.Colors.border)

            VStack(spacing: TerminalTheme.Spacing.md) {
                CardContainer {
                    ZenBalanceCard(viewModel: zenBalanceViewModel)
                }

                CardContainer {
                    GoUsageCard(viewModel: goUsageViewModel)
                }

                PlaceholderCard(
                    title: "Model Catalog",
                    subtitle: "Zen + Go models, pricing and limits"
                ) {
                    ModelCatalogView(viewModel: catalogViewModel)
                }
            }
            .padding(TerminalTheme.Spacing.lg)

            Divider().overlay(TerminalTheme.Colors.border)
            footer
        }
        .frame(width: TerminalTheme.Metrics.panelWidth)
        .background(TerminalTheme.Colors.background)
        .foregroundStyle(TerminalTheme.Colors.textPrimary)
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(TerminalTheme.Colors.accent)
                .frame(width: 8, height: 8)
            Text("Dandelion")
                .font(TerminalTheme.Fonts.title)
            Spacer()
            Text("Zen · Go")
                .font(TerminalTheme.Fonts.caption)
                .foregroundStyle(TerminalTheme.Colors.textTertiary)
        }
        .padding(TerminalTheme.Spacing.lg)
    }

    private var footer: some View {
        HStack(spacing: TerminalTheme.Spacing.sm) {
            FooterButton(title: "Refresh", systemImage: "arrow.clockwise") {
                Task { await refreshCoordinator.refreshNow() }
            }

            FooterButton(
                title: appSettings.autoRefreshEnabled ? "Auto: On" : "Auto: Off",
                systemImage: "timer",
                isActive: appSettings.autoRefreshEnabled
            ) {
                refreshCoordinator.setAutoRefreshEnabled(!appSettings.autoRefreshEnabled)
            }

            Spacer()

            FooterButton(title: "Settings", systemImage: "gearshape", action: onOpenSettings)
            FooterButton(title: "Quit", systemImage: "power", action: onQuit)
        }
        .padding(TerminalTheme.Spacing.md)
    }
}

/// A generic dark card container used for each dashboard section.
private struct PlaceholderCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TerminalTheme.Fonts.heading)
                    .foregroundStyle(TerminalTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(TerminalTheme.Fonts.caption)
                    .foregroundStyle(TerminalTheme.Colors.textTertiary)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(TerminalTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: TerminalTheme.Metrics.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: TerminalTheme.Metrics.cardCornerRadius)
                .stroke(TerminalTheme.Colors.border, lineWidth: 1)
        )
    }
}

/// A plain dark card container for sections (like `ZenBalanceCard`) that
/// render their own title/subtitle, so it skips `PlaceholderCard`'s fixed header.
private struct CardContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(TerminalTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TerminalTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: TerminalTheme.Metrics.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: TerminalTheme.Metrics.cardCornerRadius)
                    .stroke(TerminalTheme.Colors.border, lineWidth: 1)
            )
    }
}

/// A small monospace footer action button with a hover-friendly tap target.
private struct FooterButton: View {
    let title: String
    let systemImage: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(TerminalTheme.Fonts.caption)
            .foregroundStyle(isActive ? TerminalTheme.Colors.accent : TerminalTheme.Colors.textSecondary)
            .padding(.horizontal, TerminalTheme.Spacing.sm)
            .padding(.vertical, 6)
            .background(isHovering ? TerminalTheme.Colors.surfaceElevated : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    let appSettings = AppSettings()
    let catalogViewModel = ModelCatalogViewModel()
    let zenBalanceViewModel = ZenBalanceViewModel(appSettings: appSettings)
    let goUsageViewModel = GoUsageViewModel(appSettings: appSettings)
    return DashboardPanel(
        appSettings: appSettings,
        catalogViewModel: catalogViewModel,
        zenBalanceViewModel: zenBalanceViewModel,
        goUsageViewModel: goUsageViewModel,
        refreshCoordinator: RefreshCoordinator(
            appSettings: appSettings,
            catalogViewModel: catalogViewModel,
            zenBalanceViewModel: zenBalanceViewModel,
            goUsageViewModel: goUsageViewModel
        )
    )
}
