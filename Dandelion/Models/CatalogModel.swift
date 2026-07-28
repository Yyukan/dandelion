//
//  CatalogModel.swift
//  Dandelion
//
//  Provider-agnostic pricing/limit catalog contracts, populated by
//  ModelCatalogService from models.dev's opencode / opencode-go blocks.
//

import Foundation

/// A single long-context pricing tier (e.g. the ">200K tokens" rate some models switch to).
struct PricingTier: Codable, Sendable, Hashable {
    let contextThreshold: Int
    let inputPerM: Double
    let outputPerM: Double
    let cacheReadPerM: Double?
    let cacheWritePerM: Double?
}

/// Per-1M-token pricing for a model, including optional prompt-cache rates.
struct ModelPricing: Codable, Sendable, Hashable {
    let inputPerM: Double
    let outputPerM: Double
    let cacheReadPerM: Double?
    let cacheWritePerM: Double?
    let longContextTiers: [PricingTier]

    var isFree: Bool { inputPerM == 0 && outputPerM == 0 }
}

/// Context/input/output token limits for a model.
struct ModelLimit: Codable, Sendable, Hashable {
    let contextTokens: Int
    let inputTokens: Int?
    let outputTokens: Int
}

/// Estimated Go usage-window request counts for a model, as published on
/// OpenCode's `/docs/go` page (5h/weekly/monthly limits are dollar-value
/// based, so the request count depends on the model's own price - this is
/// the docs' own per-model estimate). Not available via any API, so it's
/// maintained as a static table in `ModelCatalogService`.
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

/// A single model available on Zen or Go, with its pricing and limits.
///
/// Note: `modelID` is not unique across providers on its own (several models,
/// e.g. `glm-5`, are offered by both Zen and Go), so `id` combines provider +
/// modelID to stay a stable `Identifiable` key for SwiftUI lists.
struct CatalogModel: Codable, Sendable, Hashable, Identifiable {
    let modelID: String
    let displayName: String
    let provider: CatalogProvider
    let pricing: ModelPricing
    let limit: ModelLimit
    /// Go-only estimated usage-window request counts; always `nil` for Zen.
    var usageLimits: GoUsageLimits?

    var id: String { "\(provider.rawValue):\(modelID)" }
}
