//
//  SettingsView.swift
//  Dandelion
//
//  Auto-refresh interval picker.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var appSettings: AppSettings
    let refreshCoordinator: RefreshCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.lg) {
            Text("Settings")
                .font(TerminalTheme.Fonts.title)

            refreshSection
        }
        .padding(TerminalTheme.Spacing.lg)
        .frame(width: 360)
        .background(TerminalTheme.Colors.background)
        .foregroundStyle(TerminalTheme.Colors.textPrimary)
    }

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.sm) {
            Text("Refresh")
                .font(TerminalTheme.Fonts.heading)

            Toggle("Auto-refresh", isOn: Binding(
                get: { appSettings.autoRefreshEnabled },
                set: { refreshCoordinator.setAutoRefreshEnabled($0) }
            ))
            .toggleStyle(.switch)
            .font(TerminalTheme.Fonts.body)

            Picker("Interval", selection: Binding(
                get: { appSettings.autoRefreshInterval },
                set: { refreshCoordinator.setAutoRefreshInterval($0) }
            )) {
                ForEach(AppSettings.availableIntervals, id: \.self) { interval in
                    Text(Self.intervalLabel(interval)).tag(interval)
                }
            }
            .font(TerminalTheme.Fonts.body)
            .disabled(!appSettings.autoRefreshEnabled)
        }
    }

    private static func intervalLabel(_ interval: TimeInterval) -> String {
        switch interval {
        case 300: "5 minutes"
        case 1800: "30 minutes"
        case 3600: "1 hour"
        default: "\(Int(interval))s"
        }
    }
}

#Preview {
    let appSettings = AppSettings()
    let catalogViewModel = ModelCatalogViewModel()
    return SettingsView(
        appSettings: appSettings,
        refreshCoordinator: RefreshCoordinator(
            appSettings: appSettings,
            catalogViewModel: catalogViewModel,
            zenBalanceViewModel: ZenBalanceViewModel(appSettings: appSettings),
            goUsageViewModel: GoUsageViewModel(appSettings: appSettings)
        )
    )
}
