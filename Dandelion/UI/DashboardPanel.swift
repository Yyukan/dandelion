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
            VStack(spacing: TerminalTheme.Spacing.md) {
                CardContainer {
                    ZenBalanceCard(viewModel: zenBalanceViewModel)
                }

                CardContainer {
                    GoUsageCard(viewModel: goUsageViewModel)
                }

                CardContainer {
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

    private var footer: some View {
        HStack {
            FooterButton(title: "Refresh", systemImage: "arrow.clockwise") {
                Task { await refreshCoordinator.refreshNow() }
            }

            Spacer()

            FooterButton(
                title: appSettings.autoRefreshEnabled ? "Auto Refresh: On" : "Auto Refresh: Off",
                systemImage: "timer",
                isActive: appSettings.autoRefreshEnabled
            ) {
                refreshCoordinator.setAutoRefreshEnabled(!appSettings.autoRefreshEnabled)
            }

            Spacer()

            FooterButton(title: "Settings", systemImage: "gearshape", action: onOpenSettings)

            Spacer()

            FooterButton(title: "Quit", systemImage: "power", action: onQuit)
        }
        .padding(TerminalTheme.Spacing.md)
    }
}

/// A dark card container used for each dashboard section; sections render
/// their own title/subtitle (or none, like the model catalog), so this
/// intentionally has no fixed header of its own.
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

/// An icon-only monospace footer action button with a hover-friendly tap target.
private struct FooterButton: View {
    let title: String
    let systemImage: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(TerminalTheme.Fonts.body)
                .foregroundStyle(isActive ? TerminalTheme.Colors.accent : TerminalTheme.Colors.textSecondary)
                .frame(width: 30, height: 26)
                .background(isHovering ? TerminalTheme.Colors.surfaceElevated : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(title)
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
