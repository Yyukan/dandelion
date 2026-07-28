//
//  SettingsView.swift
//  Dandelion
//
//  Auto-refresh interval picker and manual cookie/workspace-id override
//  fields (the fallback for when browser cookie/workspace auto-discovery
//  fails).
//

import SwiftUI

struct SettingsView: View {
    @Bindable var appSettings: AppSettings
    let refreshCoordinator: RefreshCoordinator

    @State private var cookieOverrideText: String = ""
    @State private var didSaveCookie = false
    private let overrideStore = CookieOverrideStore()

    var body: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.lg) {
            Text("Settings")
                .font(TerminalTheme.Fonts.title)

            refreshSection
            Divider().overlay(TerminalTheme.Colors.border)
            overrideSection
        }
        .padding(TerminalTheme.Spacing.lg)
        .frame(width: 360)
        .background(TerminalTheme.Colors.background)
        .foregroundStyle(TerminalTheme.Colors.textPrimary)
        .onAppear { cookieOverrideText = overrideStore.load() ?? "" }
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

    private var overrideSection: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.sm) {
            Text("Manual override")
                .font(TerminalTheme.Fonts.heading)
            Text("Used only when automatic browser session discovery fails.")
                .font(TerminalTheme.Fonts.caption)
                .foregroundStyle(TerminalTheme.Colors.textSecondary)

            TextField("opencode.ai session cookie", text: $cookieOverrideText)
                .textFieldStyle(.plain)
                .font(TerminalTheme.Fonts.body)
                .padding(TerminalTheme.Spacing.sm)
                .background(TerminalTheme.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            TextField("Workspace ID (e.g. wrk_...)", text: $appSettings.manualWorkspaceID)
                .textFieldStyle(.plain)
                .font(TerminalTheme.Fonts.body)
                .padding(TerminalTheme.Spacing.sm)
                .background(TerminalTheme.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Save Cookie") {
                    overrideStore.save(cookieOverrideText)
                    didSaveCookie = true
                }
                .font(TerminalTheme.Fonts.caption)

                if didSaveCookie {
                    Text("Saved")
                        .font(TerminalTheme.Fonts.caption)
                        .foregroundStyle(TerminalTheme.Colors.accent)
                }

                Spacer()
            }
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
