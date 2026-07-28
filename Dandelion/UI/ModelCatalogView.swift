//
//  ModelCatalogView.swift
//  Dandelion
//
//  Full, searchable Zen + Go model catalog with per-model input/output/cache
//  pricing and context/output limits, plus the disconnected-state UI shown
//  when no local API key was found.
//

import SwiftUI

struct ModelCatalogView: View {
    @Bindable var viewModel: ModelCatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.sm) {
            switch viewModel.connectionState {
            case .checking:
                HStack(spacing: TerminalTheme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for OpenCode credentials…")
                        .font(TerminalTheme.Fonts.caption)
                        .foregroundStyle(TerminalTheme.Colors.textSecondary)
                }
            case .disconnected:
                DisconnectedStateView()
            case .connected:
                controls
                catalogList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await viewModel.loadInitial() }
    }

    private var controls: some View {
        VStack(spacing: TerminalTheme.Spacing.xs) {
            HStack(spacing: TerminalTheme.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(TerminalTheme.Colors.textTertiary)
                TextField("Search models…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(TerminalTheme.Fonts.body)
                if viewModel.isLoadingCatalog {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, TerminalTheme.Spacing.sm)
            .padding(.vertical, 6)
            .background(TerminalTheme.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Picker("Provider", selection: $viewModel.providerFilter) {
                    ForEach(CatalogProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Spacer()

                Picker("Sort", selection: $viewModel.sortOption) {
                    ForEach(CatalogSortOption.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .font(TerminalTheme.Fonts.caption)
                .labelsHidden()
                .frame(width: 150)
            }
        }
    }

    private var catalogList: some View {
        ScrollView {
            LazyVStack(spacing: TerminalTheme.Spacing.xs) {
                if viewModel.filteredModels.isEmpty {
                    Text(viewModel.isLoadingCatalog ? "Loading catalog…" : "No models match your search.")
                        .font(TerminalTheme.Fonts.caption)
                        .foregroundStyle(TerminalTheme.Colors.textTertiary)
                        .padding(.vertical, TerminalTheme.Spacing.md)
                } else {
                    ForEach(viewModel.filteredModels) { model in
                        CatalogModelRow(model: model)
                    }
                }
            }
        }
        .frame(maxHeight: 220)
    }
}

/// Shown when no `opencode` / `opencode-go` key was found in `auth.json`.
private struct DisconnectedStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TerminalTheme.Spacing.xs) {
            Text("No OpenCode account connected")
                .font(TerminalTheme.Fonts.heading)
            Text("Run /connect in OpenCode to link your Zen or Go account, then reopen this panel.")
                .font(TerminalTheme.Fonts.caption)
                .foregroundStyle(TerminalTheme.Colors.textSecondary)
        }
    }
}

/// A single catalog row: name/id, provider badge, and its pricing/limit stats.
private struct CatalogModelRow: View {
    let model: CatalogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(model.displayName)
                    .font(TerminalTheme.Fonts.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(model.provider.displayName)
                    .font(TerminalTheme.Fonts.caption)
                    .foregroundStyle(TerminalTheme.Colors.accent)
            }

            Text(model.modelID)
                .font(TerminalTheme.Fonts.caption)
                .foregroundStyle(TerminalTheme.Colors.textTertiary)
                .lineLimit(1)

            Text(statsLine)
                .font(TerminalTheme.Fonts.caption)
                .foregroundStyle(TerminalTheme.Colors.textSecondary)
                .lineLimit(1)

            if let usageLine {
                Text(usageLine)
                    .font(TerminalTheme.Fonts.caption)
                    .foregroundStyle(TerminalTheme.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(TerminalTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statsLine: String {
        let pricing = model.pricing
        if model.provider == .zen {
            if pricing.isFree {
                return "Free"
            }
            return "\(Self.simplePrice(pricing.inputPerM)) · \(Self.simplePrice(pricing.outputPerM))"
        }

        if pricing.isFree {
            return "Free"
        }
        return "In \(Self.price(pricing.inputPerM)) · Out \(Self.price(pricing.outputPerM))"
    }

    /// Go-only second line: estimated requests per 5h / week / month, from
    /// OpenCode's docs usage-limits table. `nil` for Zen or when a Go model
    /// isn't covered by that table.
    private var usageLine: String? {
        guard model.provider == .go, let usageLimits = model.usageLimits else { return nil }
        return "5h \(Self.count(usageLimits.requestsPer5h)) · Week \(Self.count(usageLimits.requestsPerWeek))"
            + " · Month \(Self.count(usageLimits.requestsPerMonth))"
    }

    private static func price(_ value: Double) -> String {
        "$" + String(format: "%.2f", value) + "/M"
    }

    private static func simplePrice(_ value: Double) -> String {
        "$" + String(format: "%.2f", value)
    }

    private static func count(_ value: Int) -> String {
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

#Preview {
    ModelCatalogView(viewModel: ModelCatalogViewModel())
        .padding()
        .frame(width: TerminalTheme.Metrics.panelWidth)
        .background(TerminalTheme.Colors.background)
}
