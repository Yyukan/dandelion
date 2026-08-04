//
//  ModelCatalogView.swift
//  Dandelion
//
//  Full, searchable Zen + Go model catalog with per-model input/output/cache
//  pricing and context/output limits, plus the disconnected-state UI shown
//  when no local API key was found.
//

import AppKit
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
                    ForEach(viewModel.availableSortOptions) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .font(TerminalTheme.Fonts.caption)
                .labelsHidden()
                .fixedSize()
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

/// A single catalog row: vendor icon, name, colorized in/out pricing, and
/// (Go only) colorized usage-window limits. The model ID is never shown -
/// it's the click-to-copy target instead, confirmed by a brief border flash.
private struct CatalogModelRow: View {
    let model: CatalogModel

    @State private var justCopied = false

    var body: some View {
        HStack(spacing: TerminalTheme.Spacing.sm) {
            vendorIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(TerminalTheme.Fonts.body.weight(.semibold))
                    .lineLimit(1)
                if model.provider == .go, let usageLimits = model.usageLimits {
                    usageLimitsRow(usageLimits)
                }
            }
            Spacer()
            priceStack
        }
        .padding(TerminalTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(TerminalTheme.Colors.accent, lineWidth: justCopied ? 1.5 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: copyModelID)
        .help("Click to copy model ID")
    }

    private var vendorIcon: some View {
        Group {
            if let asset = ModelVendor.assetName(forModelID: model.modelID) {
                Image(asset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: ModelVendor.fallbackSystemImage)
                    .foregroundStyle(TerminalTheme.Colors.textTertiary)
            }
        }
        .frame(width: 20, height: 20)
    }

    /// Input/output on one line, "/"-separated, each independently colored -
    /// more compact than stacking them, and the slash reads like a ratio.
    private var priceStack: some View {
        Group {
            if model.pricing.isFree {
                Text("Free")
                    .foregroundStyle(TerminalTheme.Colors.textTertiary)
            } else {
                HStack(spacing: 2) {
                    Text(Self.simplePrice(model.pricing.inputPerM))
                        .foregroundStyle(Self.priceColor(model.pricing.inputPerM, max: Self.maxInputPrice(model.provider)))
                    Text("/")
                        .foregroundStyle(TerminalTheme.Colors.textTertiary)
                    Text(Self.simplePrice(model.pricing.outputPerM))
                        .foregroundStyle(Self.priceColor(model.pricing.outputPerM, max: Self.maxOutputPrice(model.provider)))
                }
            }
        }
        .font(TerminalTheme.Fonts.caption)
    }

    /// Go-only: estimated requests per 5h / week / month, from OpenCode's
    /// docs usage-limits table, each colored on the same blue scale as
    /// price - but inverted, since a *higher* request count is the "cheap"
    /// (generous) end and a *lower* one is the "expensive" (scarce) end.
    /// Icons stand in for the "5h"/"Week"/"Month" labels to keep the row compact.
    private func usageLimitsRow(_ limits: GoUsageLimits) -> some View {
        HStack(spacing: 4) {
            usageSegment("clock", limits.requestsPer5h, max: Self.maxUsage5h)
            dot
            usageSegment("calendar", limits.requestsPerWeek, max: Self.maxUsageWeek)
            dot
            usageSegment("calendar.circle", limits.requestsPerMonth, max: Self.maxUsageMonth)
        }
        .font(TerminalTheme.Fonts.caption)
    }

    private var dot: some View {
        Text("·").foregroundStyle(TerminalTheme.Colors.textTertiary)
    }

    private func usageSegment(_ systemImage: String, _ value: Int, max: Double) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .foregroundStyle(TerminalTheme.Colors.textTertiary)
            Text(Self.count(value))
                .foregroundStyle(Self.limitColor(value, max: max))
                .fixedSize()
        }
    }

    /// Copies the (hidden) model ID to the clipboard and briefly flashes the
    /// row's border as the only copy confirmation.
    private func copyModelID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.modelID, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.3)) { justCopied = false }
        }
    }

    // MARK: Formatting

    /// Per-provider price ceilings used to normalize the log-scale color -
    /// Go's real catalog tops out far below Zen's ($3/$15 vs $30/$180), so
    /// sharing one ceiling would paint the entire Go tab a uniform cyan.
    private static func maxInputPrice(_ provider: CatalogProvider) -> Double {
        provider == .zen ? 30 : 3
    }

    private static func maxOutputPrice(_ provider: CatalogProvider) -> Double {
        provider == .zen ? 180 : 15
    }

    /// Usage-window ceilings, from the current Go catalog's own extremes
    /// (rounded up), used the same way to normalize the limit color.
    private static let maxUsage5h = 32_000.0
    private static let maxUsageWeek = 80_000.0
    private static let maxUsageMonth = 160_000.0

    private static func simplePrice(_ value: Double) -> String {
        "$" + String(format: "%.2f", value)
    }

    private static func count(_ value: Int) -> String {
        if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// Colors a price on a log scale within the app's blue accent family
    /// (cyan for cheap, indigo for pricey) instead of a green-to-red scheme,
    /// so pricier models read as "hotter blue" rather than alarming.
    private static func priceColor(_ value: Double, max: Double) -> Color {
        guard value > 0 else { return TerminalTheme.Colors.textTertiary }
        return blueGradient(min(1, log10(value + 1) / log10(max + 1)))
    }

    /// Colors a usage limit on the same blue scale, but inverted: a high
    /// request count is the "cheap" end (cyan), a low one is the
    /// "expensive"/scarce end (indigo).
    private static func limitColor(_ value: Int, max: Double) -> Color {
        let t = min(1, log10(Double(value) + 1) / log10(max + 1))
        return blueGradient(1 - t)
    }

    private static func blueGradient(_ t: Double) -> Color {
        Color(hue: 0.52 + 0.18 * t, saturation: 0.45 + 0.30 * t, brightness: 0.95 - 0.10 * t)
    }
}

#Preview {
    ModelCatalogView(viewModel: ModelCatalogViewModel())
        .padding()
        .frame(width: TerminalTheme.Metrics.panelWidth)
        .background(TerminalTheme.Colors.background)
}
