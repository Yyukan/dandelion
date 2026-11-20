//
//  ModelCatalogView.swift
//  Dandelion
//
//  Full, searchable Zen + Go model catalog: per-model input/output pricing
//  (long-context tier and audio/image unit prices included), plus the Go-only
//  monthly dollar allowance per plan, and the disconnected-state UI shown when
//  no local API key was found.
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
                    let allowanceCeiling = viewModel.filteredModels
                        .compactMap { $0.goAllowance?.largest }
                        .max() ?? 0
                    ForEach(viewModel.filteredModels) { model in
                        CatalogModelRow(model: model, allowanceCeiling: allowanceCeiling)
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

/// A single catalog row: vendor icon, name, colorized in/out pricing (plus
/// any long-context tier), and (Go only) the colorized monthly allowance per
/// plan. The model ID is never shown - it's the click-to-copy target instead,
/// confirmed by a brief border flash.
private struct CatalogModelRow: View {
    let model: CatalogModel
    /// Largest Go plan allowance in the list, used to normalize its color.
    let allowanceCeiling: Double

    @State private var justCopied = false

    var body: some View {
        HStack(spacing: TerminalTheme.Spacing.sm) {
            vendorIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(TerminalTheme.Fonts.body.weight(.semibold))
                    .lineLimit(1)
                if model.provider == .go {
                    goLimitsRow
                } else if let longContext = model.pricing.longContext {
                    longContextRow(longContext)
                }
            }
            // The name column must win the space before the trailing price
            // does; without this, SwiftUI truncates names like
            // "DeepSeek V4 Flash" even when the row has room to spare.
            .layoutPriority(1)
            Spacer(minLength: TerminalTheme.Spacing.sm)
            priceStack
                .fixedSize()
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
            if let unitPrice = model.pricing.unitPrice {
                // Audio/image models are priced per minute/image, not per token.
                Text(Self.unitPrice(unitPrice))
                    .foregroundStyle(Self.priceColor(unitPrice.price, max: Self.maxInputPrice(model.provider)))
            } else if !model.pricing.isPublished {
                // The endpoint lists the model without any cost.
                Text("—")
                    .foregroundStyle(TerminalTheme.Colors.textTertiary)
            } else if model.pricing.isFree {
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

    /// The higher per-1M price that applies above a context size, e.g.
    /// ">100k ctx: $0.50 in / $2.50 out".
    private func longContextRow(_ tier: LongContextPricing) -> some View {
        Text(">\(Self.tokens(tier.aboveTokens)) ctx: \(Self.simplePrice(tier.inputPerM)) in / \(Self.simplePrice(tier.outputPerM)) out")
            .font(TerminalTheme.Fonts.caption)
            .foregroundStyle(TerminalTheme.Colors.textTertiary)
            .lineLimit(1)
    }

    /// Go-only, one line: the three limit icons, exactly as OpenCode documents
    /// them — the 5-hour limit is 20% of the monthly allowance, the weekly
    /// limit is 50% (resets Monday 00:00 UTC), the monthly limit is 100%.
    /// Kept deliberately terse: name, icons, price.
    private var goLimitsRow: some View {
        let monthly = model.goAllowance?.go
        let unlimited = model.requestEstimate?.isUnlimited ?? false

        func value(_ fraction: Double) -> String {
            if unlimited { return "∞" }
            guard let monthly else { return "—" }
            return Self.money(monthly * fraction)
        }

        return HStack(spacing: 10) {
            limitChip("clock", value(0.20), help: "5-hour limit — 20% of the monthly allowance")
            limitChip("calendar", value(0.50), help: "Weekly limit — 50% of the monthly allowance, resets Monday 00:00 UTC")
            limitChip("dollarsign.circle", value(1), help: "Monthly allowance for the Go plan")
        }
        .font(TerminalTheme.Fonts.caption)
    }

    private func limitChip(_ systemImage: String, _ value: String, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .foregroundStyle(TerminalTheme.Colors.textTertiary)
            Text(value)
                .foregroundStyle(TerminalTheme.Colors.textSecondary)
        }
        .fixedSize()
        .help(help)
    }

    /// 1040 -> "1,040"
    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private var dot: some View {
        Text("·").foregroundStyle(TerminalTheme.Colors.textTertiary)
    }

    private func allowanceSegment(_ plan: String, _ dollars: Double) -> some View {
        HStack(spacing: 2) {
            Text(plan)
                .foregroundStyle(TerminalTheme.Colors.textTertiary)
            Text(Self.money(dollars))
                .foregroundStyle(Self.limitColor(dollars, max: allowanceCeiling))
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

    private static func simplePrice(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "$" + String(format: "%.2f", value)
    }

    /// "$0.05/min", "$0.01/image".
    private static func unitPrice(_ unitPrice: UnitPrice) -> String {
        let unit = unitPrice.unit == "minute" ? "min" : unitPrice.unit
        return simplePrice(unitPrice.price) + "/" + unit
    }

    /// Whole dollars without cents ("$100"), otherwise two decimals.
    private static func money(_ value: Double) -> String {
        value == value.rounded() ? String(format: "$%.0f", value) : simplePrice(value)
    }

    /// Token counts as "100k" / "1M".
    private static func tokens(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        return "\(value)"
    }

    /// Colors a price on a log scale within the app's blue accent family
    /// (cyan for cheap, indigo for pricey) instead of a green-to-red scheme,
    /// so pricier models read as "hotter blue" rather than alarming.
    private static func priceColor(_ value: Double?, max: Double) -> Color {
        guard let value, value > 0 else { return TerminalTheme.Colors.textTertiary }
        return blueGradient(min(1, log10(value + 1) / log10(max + 1)))
    }

    /// Colors an allowance on the same blue scale, but inverted: a high
    /// allowance is the "cheap" end (cyan), a low one is the
    /// "expensive"/scarce end (indigo).
    private static func limitColor(_ value: Double, max: Double) -> Color {
        guard max > 0 else { return blueGradient(0) }
        let t = min(1, log10(value + 1) / log10(max + 1))
        return blueGradient(1 - t)
    }

    private static func blueGradient(_ t: Double) -> Color {
        Color(hue: 0.52 + 0.18 * t, saturation: 0.45 + 0.30 * t, brightness: 0.95 - 0.10 * t)
    }
}

private extension GoMonthlyAllowance {
    /// The biggest allowance across the plans.
    var largest: Double? { [go, goPlus, goTeams].compactMap { $0 }.max() }
}

#Preview {
    ModelCatalogView(viewModel: ModelCatalogViewModel())
        .padding()
        .frame(width: TerminalTheme.Metrics.panelWidth)
        .background(TerminalTheme.Colors.background)
}
