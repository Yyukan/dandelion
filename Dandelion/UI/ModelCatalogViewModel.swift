//
//  ModelCatalogViewModel.swift
//  Dandelion
//
//  Drives ModelCatalogView: discovers/validates the local API keys and
//  loads the merged Zen + Go pricing/limit catalog.
//

import Foundation
import Observation

/// Connection state for the locally discovered OpenCode credentials.
enum CredentialConnectionState: Equatable {
    case checking
    /// No `opencode` / `opencode-go` entry found in `auth.json`.
    case disconnected
    /// At least one credential was found; each flag is `nil` while validation
    /// for that surface hasn't completed yet.
    case connected(zenValid: Bool?, goValid: Bool?)
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
    private let validationService: KeyValidationService
    private let catalogService: ModelCatalogService

    init(
        authService: AuthDiscoveryService = AuthDiscoveryService(),
        validationService: KeyValidationService = KeyValidationService(),
        catalogService: ModelCatalogService = ModelCatalogService()
    ) {
        self.authService = authService
        self.validationService = validationService
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

    /// Runs credential discovery/validation and the catalog load in parallel
    /// on first appearance.
    func loadInitial() async {
        async let connection: Void = refreshConnection()
        async let catalog: Void = refreshCatalog()
        _ = await (connection, catalog)
    }

    func refreshConnection() async {
        let credentials = authService.discoverCredentials()
        guard !credentials.isEmpty else {
            connectionState = .disconnected
            return
        }

        connectionState = .connected(zenValid: nil, goValid: nil)

        for credential in credentials {
            let isValid = await validationService.validate(credential) == .valid
            guard case .connected(var zenValid, var goValid) = connectionState else { continue }
            switch credential.provider {
            case .zen: zenValid = isValid
            case .go: goValid = isValid
            }
            connectionState = .connected(zenValid: zenValid, goValid: goValid)
        }
    }

    func refreshCatalog(forceRefresh: Bool = false) async {
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        models = await catalogService.loadCatalog(forceRefresh: forceRefresh)
    }
}
