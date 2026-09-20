//
//  ModelCatalogViewModel.swift
//  Dandelion
//
//  Drives ModelCatalogView: discovers the local API keys and loads the
//  merged Zen + Go pricing/limit catalog.
//

import Foundation
import Observation

/// Whether OpenCode credentials exist locally.
///
/// Existence only, and it only ever was that: the old validation ping answered
/// "does this key work?" for both surfaces, but OpenCode now refuses free-tier
/// models to non-OpenCode clients (`FreeTierError`) and no free endpoint
/// authenticates a key, so the ping was removed rather than re-pointed.
///
/// What verifies a key today:
/// - **Go** - the Go usage card sends the stored `opencode-go` key to
///   `/zen/go/v1/usage` on every refresh and a rejected key lands in its
///   `.sessionExpired` state. That is a real check.
/// - **Zen** - nothing. The Zen card authenticates with a browser session
///   cookie (`CookieDiscoveryService`) and never uses the stored `opencode` API
///   key, so for Zen this state means only "an entry exists in `auth.json`" -
///   it says nothing about whether that key is still valid.
enum CredentialConnectionState: Equatable {
    case checking
    /// No `opencode` / `opencode-go` entry found in `auth.json`.
    case disconnected
    /// At least one credential was found.
    case connected
}

enum CatalogSortOption: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case priceAscending = "Price ascending"
    case priceDescending = "Price descending"
    case usageLimitAscending = "Usage limit ascending"
    case usageLimitDescending = "Usage limit descending"

    var id: String { rawValue }

    /// Text shown in the sort picker; ascending/descending pairs share the
    /// same title and are distinguished by their `systemImage` arrow glyph.
    var title: String {
        switch self {
        case .name: "Name"
        case .priceAscending, .priceDescending: "Price"
        case .usageLimitAscending, .usageLimitDescending: "Usage limit"
        }
    }

    var systemImage: String {
        switch self {
        case .name: "textformat"
        case .priceAscending, .usageLimitAscending: "arrow.up"
        case .priceDescending, .usageLimitDescending: "arrow.down"
        }
    }
}

@MainActor
@Observable
final class ModelCatalogViewModel {
    private(set) var connectionState: CredentialConnectionState = .checking
    private(set) var models: [CatalogModel] = []
    private(set) var isLoadingCatalog = false

    var searchText: String = ""
    var providerFilter: CatalogProvider = .zen {
        didSet {
            guard !availableSortOptions.contains(sortOption) else { return }
            sortOption = .name
        }
    }
    var sortOption: CatalogSortOption = .name

    /// Usage-limit sorting only makes sense for Go (Zen models never carry
    /// `usageLimits`), so hide those options unless Go is the active filter.
    var availableSortOptions: [CatalogSortOption] {
        switch providerFilter {
        case .zen: [.name, .priceAscending, .priceDescending]
        case .go: CatalogSortOption.allCases
        }
    }

    private let authService: AuthDiscoveryService
    private let catalogService: ModelCatalogService

    init(
        authService: AuthDiscoveryService = AuthDiscoveryService(),
        catalogService: ModelCatalogService = ModelCatalogService()
    ) {
        self.authService = authService
        self.catalogService = catalogService
    }

    var filteredModels: [CatalogModel] {
        var result = models.filter { $0.provider == providerFilter }

        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
                    || $0.modelID.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOption {
        case .name:
            result.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .priceAscending:
            result.sort { isOrdered($0.pricing.inputPerM, $1.pricing.inputPerM, ascending: true, lhs: $0, rhs: $1) }
        case .priceDescending:
            result.sort { isOrdered($0.pricing.inputPerM, $1.pricing.inputPerM, ascending: false, lhs: $0, rhs: $1) }
        case .usageLimitAscending:
            result.sort { isOrdered($0.usageLimits?.requestsPerMonth, $1.usageLimits?.requestsPerMonth, ascending: true, lhs: $0, rhs: $1) }
        case .usageLimitDescending:
            result.sort { isOrdered($0.usageLimits?.requestsPerMonth, $1.usageLimits?.requestsPerMonth, ascending: false, lhs: $0, rhs: $1) }
        }

        return result
    }

    /// Orders two optional sort keys, keeping models without a published price
    /// or usage limit at the bottom of the list in both directions, and
    /// breaking ties (and the "no value" case) by name.
    private func isOrdered<T: Comparable>(
        _ lhsKey: T?,
        _ rhsKey: T?,
        ascending: Bool,
        lhs: CatalogModel,
        rhs: CatalogModel
    ) -> Bool {
        switch (lhsKey, rhsKey) {
        case let (l?, r?):
            guard l != r else { return nameComesFirst(lhs, rhs) }
            return ascending ? l < r : l > r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return nameComesFirst(lhs, rhs)
        }
    }

    private func nameComesFirst(_ lhs: CatalogModel, _ rhs: CatalogModel) -> Bool {
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    /// Runs credential discovery and the catalog load in parallel on first
    /// appearance.
    func loadInitial() async {
        async let connection: Void = refreshDiscovery()
        async let catalog: Void = refreshCatalog()
        _ = await (connection, catalog)
    }

    /// Reads `auth.json` and decides between showing the catalog and showing
    /// the connect instructions. No request is made and no key is pinged.
    ///
    /// Synchronous work (one file read) despite the `async`: it is declared
    /// this way so the refresh coordinator can run it inside the same TaskGroup
    /// as the real fetches.
    func refreshDiscovery() async {
        connectionState = authService.discoverCredentials().isEmpty ? .disconnected : .connected
    }

    func refreshCatalog(forceRefresh: Bool = false) async {
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        models = await catalogService.loadCatalog(forceRefresh: forceRefresh)
    }
}
