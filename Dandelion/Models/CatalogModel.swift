//
//  CatalogModel.swift
//  Dandelion
//
//  Provider-agnostic catalog contracts, populated by ModelCatalogService from
//  OpenCode's own sources: the `/zen|/zen/go/v1/models` endpoints say which
//  models exist, and OpenCode's console docs pages supply the metadata.
//

import Foundation

/// Per-1M-token pricing for a model, as published on OpenCode's docs pages.
///
/// Both values are optional because the docs only price the models they list:
/// `nil` means OpenCode hasn't published a price for that model (yet), which
/// is different from `0` ("Free").
struct ModelPricing: Codable, Sendable, Hashable {
    let inputPerM: Double?
    let outputPerM: Double?

    /// The docs list the model without a price.
    static let unpublished = ModelPricing(inputPerM: nil, outputPerM: nil)

    var isFree: Bool { inputPerM == 0 && outputPerM == 0 }
    var isPublished: Bool { inputPerM != nil || outputPerM != nil }
}

/// Estimated Go usage-window request counts for a model, as published in the
/// "Usage limits" table on OpenCode's Go console docs page (the 5h/weekly/
/// monthly limits are dollar-based, so the request count depends on the
/// model's own price - this is the docs' own per-model estimate). Not
/// available via any API.
struct GoUsageLimits: Codable, Sendable, Hashable {
    let requestsPer5h: Int
    let requestsPerWeek: Int
    let requestsPerMonth: Int
}

/// Which OpenCode surface a catalog model belongs to.
enum CatalogProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case zen
    case go

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zen: "Zen"
        case .go: "Go"
        }
    }
}

/// A single model available on Zen or Go, with the metadata the docs publish
/// for it. Models the docs don't cover are still listed (the official model
/// endpoint says they exist) with the model ID as the display name and no
/// price, rather than being hidden.
///
/// Note: `modelID` is not unique across providers on its own (several models,
/// e.g. `glm-5.2`, are offered by both Zen and Go), so `id` combines provider +
/// modelID to stay a stable `Identifiable` key for SwiftUI lists.
struct CatalogModel: Codable, Sendable, Hashable, Identifiable {
    let modelID: String
    let displayName: String
    let provider: CatalogProvider
    let pricing: ModelPricing
    /// Go-only estimated usage-window request counts; always `nil` for Zen.
    var usageLimits: GoUsageLimits?

    var id: String { "\(provider.rawValue):\(modelID)" }
}
