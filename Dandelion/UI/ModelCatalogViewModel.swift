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
    case inputPrice = "Input $/M"
    case outputPrice = "Output $/M"
    case context = "Context"

    var id: String { rawValue }
}

@MainActor
@Observable
final class ModelCatalogViewModel {
    private(set) var connectionState: CredentialConnectionState = .checking
    private(set) var models: [CatalogModel] = []
    private(set) var isLoadingCatalog = false

    var searchText: String = ""
    var providerFilter: CatalogProvider?
    var sortOption: CatalogSortOption = .name

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
        var result = models

        if let providerFilter {
            result = result.filter { $0.provider == providerFilter }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
                    || $0.modelID.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOption {
        case .name:
            result.sort { $0.displayName < $1.displayName }
        case .inputPrice:
            result.sort { $0.pricing.inputPerM < $1.pricing.inputPerM }
        case .outputPrice:
            result.sort { $0.pricing.outputPerM < $1.pricing.outputPerM }
        case .context:
            result.sort { $0.limit.contextTokens > $1.limit.contextTokens }
        }

        return result
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
