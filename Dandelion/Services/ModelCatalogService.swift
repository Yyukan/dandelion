//
//  ModelCatalogService.swift
//  Dandelion
//
//  Fetches the Zen/Go model catalog (pricing + limits) from models.dev - the
//  only source that carries this metadata, since OpenCode's own /v1/models
//  endpoints only return {id, object, created, owned_by}. Cached locally and
//  refreshed on a slow, independent cadence.
//

import Foundation

/// Fetches, maps and caches the `opencode` (Zen) / `opencode-go` (Go)
/// provider blocks from `https://models.dev/api.json` into `CatalogModel`.
actor ModelCatalogService {
    private static let catalogURL = URL(string: "https://models.dev/api.json")!
    private static let refreshInterval: TimeInterval = 24 * 60 * 60 // daily cadence

    private let session: URLSession
    private let cacheFileURL: URL

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session

        let cacheDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Dandelion", isDirectory: true))
            ?? fileManager.temporaryDirectory.appendingPathComponent("Dandelion", isDirectory: true)

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheFileURL = cacheDirectory.appendingPathComponent("model-catalog-cache.json")
    }

    /// Returns the merged Zen + Go catalog, preferring a fresh local cache
    /// (younger than 24h) unless `forceRefresh` is set. Falls back to the
    /// last successful cache when the network call fails, so a `models.dev`
    /// outage never blinks the catalog view empty.
    func loadCatalog(forceRefresh: Bool = false) async -> [CatalogModel] {
        let cached = readCache()

        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.refreshInterval {
            return cached.models
        }

        do {
            let models = try await fetchRemoteCatalog()
            writeCache(CachedCatalog(fetchedAt: Date(), models: models))
            return models
        } catch {
            return cached?.models ?? []
        }
    }

    // MARK: Remote fetch + mapping

    private func fetchRemoteCatalog() async throws -> [CatalogModel] {
        var request = URLRequest(url: Self.catalogURL)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(ModelsDevCatalogResponse.self, from: data)
        var models: [CatalogModel] = []
        if let zen = decoded.opencodeZen { models += map(zen, provider: .zen) }
        if let go = decoded.opencodeGo { models += map(go, provider: .go) }
        return models.sorted { $0.displayName < $1.displayName }
    }

    private func map(_ provider: ModelsDevProvider, provider catalogProvider: CatalogProvider) -> [CatalogModel] {
        provider.models.values.map { model in
            CatalogModel(
                modelID: model.id,
                displayName: model.name,
                provider: catalogProvider,
                pricing: mapPricing(model.cost),
                limit: ModelLimit(
                    contextTokens: model.limit.context,
                    inputTokens: model.limit.input,
                    outputTokens: model.limit.output
                )
            )
        }
    }

    private func mapPricing(_ cost: ModelsDevCost?) -> ModelPricing {
        guard let cost else {
            return ModelPricing(inputPerM: 0, outputPerM: 0, cacheReadPerM: nil, cacheWritePerM: nil, longContextTiers: [])
        }

        var tiers: [PricingTier] = (cost.tiers ?? []).map { tier in
            PricingTier(
                contextThreshold: tier.tier?.size ?? 200_000,
                inputPerM: tier.input,
                outputPerM: tier.output,
                cacheReadPerM: tier.cacheRead,
                cacheWritePerM: tier.cacheWrite
            )
        }
        if tiers.isEmpty, let over200k = cost.contextOver200k {
            tiers.append(PricingTier(
                contextThreshold: 200_000,
                inputPerM: over200k.input,
                outputPerM: over200k.output,
                cacheReadPerM: over200k.cacheRead,
                cacheWritePerM: over200k.cacheWrite
            ))
        }

        return ModelPricing(
            inputPerM: cost.input,
            outputPerM: cost.output,
            cacheReadPerM: cost.cacheRead,
            cacheWritePerM: cost.cacheWrite,
            longContextTiers: tiers.sorted { $0.contextThreshold < $1.contextThreshold }
        )
    }

    // MARK: Local disk cache

    private struct CachedCatalog: Codable {
        let fetchedAt: Date
        let models: [CatalogModel]
    }

    private func readCache() -> CachedCatalog? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        return try? JSONDecoder().decode(CachedCatalog.self, from: data)
    }

    private func writeCache(_ catalog: CachedCatalog) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }
}

// MARK: - models.dev wire format (only the subset Dandelion needs)

private struct ModelsDevCatalogResponse: Decodable {
    let opencodeZen: ModelsDevProvider?
    let opencodeGo: ModelsDevProvider?

    enum CodingKeys: String, CodingKey {
        case opencodeZen = "opencode"
        case opencodeGo = "opencode-go"
    }
}

private struct ModelsDevProvider: Decodable {
    let models: [String: ModelsDevModel]
}

private struct ModelsDevModel: Decodable {
    let id: String
    let name: String
    let limit: ModelsDevLimit
    let cost: ModelsDevCost?
}

private struct ModelsDevLimit: Decodable {
    let context: Int
    let input: Int?
    let output: Int
}

private struct ModelsDevCost: Decodable {
    let input: Double
    let output: Double
    let cacheRead: Double?
    let cacheWrite: Double?
    let contextOver200k: ModelsDevCostTier?
    let tiers: [ModelsDevCostTierWithThreshold]?

    enum CodingKeys: String, CodingKey {
        case input, output, tiers
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case contextOver200k = "context_over_200k"
    }
}

private struct ModelsDevCostTier: Decodable {
    let input: Double
    let output: Double
    let cacheRead: Double?
    let cacheWrite: Double?

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }
}

private struct ModelsDevCostTierWithThreshold: Decodable {
    struct TierInfo: Decodable {
        let type: String
        let size: Int
    }

    let input: Double
    let output: Double
    let cacheRead: Double?
    let cacheWrite: Double?
    let tier: TierInfo?

    enum CodingKeys: String, CodingKey {
        case input, output, tier
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }
}
