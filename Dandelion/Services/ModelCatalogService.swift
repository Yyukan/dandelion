//
//  ModelCatalogService.swift
//  Dandelion
//
//  Fetches the Zen/Go model catalog (pricing + limits) from models.dev - the
//  only source that carries this metadata, since OpenCode's own /v1/models
//  endpoints only return {id, object, created, owned_by}. Cached locally and
//  refreshed on a slow, independent cadence. Go's per-model usage-window
//  limits (5h/week/month) aren't in that catalog either, so they're scraped
//  from the plain-HTML "Usage limits" table on https://opencode.ai/docs/go
//  on the same cadence, with a hand-maintained static table as last resort.
//

import Foundation

/// Fetches, maps and caches the `opencode` (Zen) / `opencode-go` (Go)
/// provider blocks from `https://models.dev/api.json` into `CatalogModel`.
actor ModelCatalogService {
    private static let catalogURL = URL(string: "https://models.dev/api.json")!
    private static let goDocsURL = URL(string: "https://opencode.ai/docs/go")!
    private static let refreshInterval: TimeInterval = 24 * 60 * 60 // daily cadence

    private let session: URLSession
    private let cacheFileURL: URL
    private let usageLimitsCacheFileURL: URL

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
        self.usageLimitsCacheFileURL = cacheDirectory.appendingPathComponent("go-usage-limits-cache.json")
    }

    /// Returns the merged Zen + Go catalog, preferring a fresh local cache
    /// (younger than 24h) unless `forceRefresh` is set. Falls back to the
    /// last successful cache when the network call fails, so a `models.dev`
    /// outage never blinks the catalog view empty. Go models are overlaid
    /// with usage-window limits scraped from OpenCode's own docs page (see
    /// `loadGoUsageLimits`), refreshed on the same cadence.
    func loadCatalog(forceRefresh: Bool = false) async -> [CatalogModel] {
        async let modelsTask = loadModels(forceRefresh: forceRefresh)
        async let usageLimitsTask = loadGoUsageLimits(forceRefresh: forceRefresh)
        let (models, usageLimits) = await (modelsTask, usageLimitsTask)

        return models.map { model in
            guard model.provider == .go else { return model }
            var model = model
            model.usageLimits = usageLimits[model.modelID] ?? Self.fallbackGoUsageLimits[model.modelID]
            return model
        }
    }

    private func loadModels(forceRefresh: Bool) async -> [CatalogModel] {
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

    /// Returns the Go usage-window request-count table, scraped fresh from
    /// `https://opencode.ai/docs/go` (younger-than-24h cache unless
    /// `forceRefresh`), falling back to the last successful scrape when the
    /// fetch/parse fails so an OpenCode docs redesign never breaks the
    /// catalog - the static `fallbackGoUsageLimits` table is the ultimate
    /// fallback in `loadCatalog` if no scrape has ever succeeded.
    private func loadGoUsageLimits(forceRefresh: Bool) async -> [String: GoUsageLimits] {
        let cached = readUsageLimitsCache()

        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.refreshInterval {
            return cached.limits
        }

        do {
            let limits = try await fetchGoUsageLimitsFromDocs()
            writeUsageLimitsCache(CachedUsageLimits(fetchedAt: Date(), limits: limits))
            return limits
        } catch {
            return cached?.limits ?? [:]
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
                ),
                usageLimits: nil // filled in by `loadCatalog` from the scraped/static table
            )
        }
    }

    /// Last-resort snapshot of the table published on
    /// `https://opencode.ai/docs/go` ("Usage limits" section), used only when
    /// scraping it fresh has never once succeeded (no cache, first launch
    /// offline). Go's 5h/weekly/monthly limits are dollar-value based, so
    /// this is the docs' own request-count estimate per model.
    private static let fallbackGoUsageLimits: [String: GoUsageLimits] = [
        "deepseek-v4.1-flash": GoUsageLimits(requestsPer5h: 26_000, requestsPerWeek: 65_000, requestsPerMonth: 130_000),
        "deepseek-v4-flash": GoUsageLimits(requestsPer5h: 13_000, requestsPerWeek: 32_500, requestsPerMonth: 65_000),
        "deepseek-v4-flash-vision-exp": GoUsageLimits(requestsPer5h: 6_500, requestsPerWeek: 16_250, requestsPerMonth: 32_500),
        "deepseek-v4-pro": GoUsageLimits(requestsPer5h: 1_050, requestsPerWeek: 2_600, requestsPerMonth: 5_200),
        "glm-5.1": GoUsageLimits(requestsPer5h: 880, requestsPerWeek: 2_150, requestsPerMonth: 4_300),
        "glm-5.2": GoUsageLimits(requestsPer5h: 880, requestsPerWeek: 2_150, requestsPerMonth: 4_300),
        "glm-5.3": GoUsageLimits(requestsPer5h: 220, requestsPerWeek: 540, requestsPerMonth: 1_080),
        "glm-5.3-flash": GoUsageLimits(requestsPer5h: 6_320, requestsPerWeek: 15_790, requestsPerMonth: 31_580),
        "gpt-5.6-luna": GoUsageLimits(requestsPer5h: 2_050, requestsPerWeek: 5_100, requestsPerMonth: 10_250),
        "grok-4.6": GoUsageLimits(requestsPer5h: 169, requestsPerWeek: 423, requestsPerMonth: 845),
        "hy3": GoUsageLimits(requestsPer5h: 4_300, requestsPerWeek: 10_750, requestsPerMonth: 21_500),
        "hy4-preview": GoUsageLimits(requestsPer5h: 1_350, requestsPerWeek: 3_380, requestsPerMonth: 6_770),
        "kimi-k2.6": GoUsageLimits(requestsPer5h: 1_150, requestsPerWeek: 2_880, requestsPerMonth: 5_750),
        "kimi-k2.7-code": GoUsageLimits(requestsPer5h: 1_350, requestsPerWeek: 3_380, requestsPerMonth: 6_750),
        "kimi-k3": GoUsageLimits(requestsPer5h: 110, requestsPerWeek: 250, requestsPerMonth: 490),
        "longcat-2.0": GoUsageLimits(requestsPer5h: 11_400, requestsPerWeek: 28_600, requestsPerMonth: 57_200),
        "mimo-v2.5": GoUsageLimits(requestsPer5h: 30_100, requestsPerWeek: 75_200, requestsPerMonth: 150_400),
        "mimo-v2.5-pro": GoUsageLimits(requestsPer5h: 3_250, requestsPerWeek: 8_150, requestsPerMonth: 16_300),
        "minimax-m2.7": GoUsageLimits(requestsPer5h: 3_400, requestsPerWeek: 8_500, requestsPerMonth: 17_000),
        "minimax-m3": GoUsageLimits(requestsPer5h: 3_200, requestsPerWeek: 8_000, requestsPerMonth: 16_000),
        "muse-spark-1.2-contributor": GoUsageLimits(requestsPer5h: 45_300, requestsPerWeek: 113_300, requestsPerMonth: 226_600),
        "muse-spark-1.3-contributor": GoUsageLimits(requestsPer5h: 45_300, requestsPerWeek: 113_300, requestsPerMonth: 226_600),
        "qwen3.6-plus": GoUsageLimits(requestsPer5h: 3_300, requestsPerWeek: 8_200, requestsPerMonth: 16_300),
        "qwen3.7-max": GoUsageLimits(requestsPer5h: 170, requestsPerWeek: 420, requestsPerMonth: 840),
        "qwen3.7-plus": GoUsageLimits(requestsPer5h: 4_300, requestsPerWeek: 10_800, requestsPerMonth: 21_600),
        "qwen3.8-flash": GoUsageLimits(requestsPer5h: 5_400, requestsPerWeek: 13_500, requestsPerMonth: 27_000),
        "qwen3.8-max": GoUsageLimits(requestsPer5h: 160, requestsPerWeek: 400, requestsPerMonth: 810),
    ]

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

    // MARK: Go usage-limits docs scrape

    /// Fetches `https://opencode.ai/docs/go` and parses its two plain-HTML
    /// static tables: the "Usage limits" table (display name -> 5h/week/month
    /// request counts) and the "Model ID" reference table (display name ->
    /// model ID), then joins them on display name. No JS rendering or HTML
    /// parser dependency is needed - Starlight renders both tables as static
    /// markup in the raw response.
    private func fetchGoUsageLimitsFromDocs() async throws -> [String: GoUsageLimits] {
        var request = URLRequest(url: Self.goDocsURL)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        let nameToID = Self.parseModelIDTable(html: html)
        let usageByName = Self.parseUsageLimitsTable(html: html)
        guard !nameToID.isEmpty, !usageByName.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        var result: [String: GoUsageLimits] = [:]
        for (name, limits) in usageByName {
            if let id = nameToID[name] {
                result[id] = limits
            }
        }
        guard !result.isEmpty else { throw URLError(.cannotParseResponse) }
        return result
    }

    /// Parses the "Model" | "requests per 5 hour" | "requests per week" |
    /// "requests per month" table into `[displayName: GoUsageLimits]`.
    ///
    /// The docs now decorate promo rows: `DeepSeek V4.1 Flash<br><small>4x ·
    /// Ends Sep 20</small>` over `<del>6,500</del><br><strong>26,000</strong>`.
    /// Concatenating that yields "DeepSeek V4.1 Flash4x · Ends Sep 20" and
    /// "6,50026,000", so both the name join and the integer parse used to
    /// fail and the model silently lost its limits. Hence `primaryLabel` /
    /// `firstNumber` below, which drop `<del>` values and stop at `<br>`.
    private static func parseUsageLimitsTable(html: String) -> [String: GoUsageLimits] {
        guard let tableHTML = extractTable(containing: "requests per 5 hour", in: html) else { return [:] }

        var result: [String: GoUsageLimits] = [:]
        for cells in parseRows(tableHTML) where cells.count >= 4 {
            let name = primaryLabel(cells[0])
            guard !name.isEmpty, name != "Model" else { continue }
            guard let h5 = firstNumber(cells[1]),
                  let week = firstNumber(cells[2]),
                  let month = firstNumber(cells[3]) else { continue }
            result[name] = GoUsageLimits(requestsPer5h: h5, requestsPerWeek: week, requestsPerMonth: month)
        }
        return result
    }

    /// Parses the "Model" | "Model ID" | "Endpoint" | "AI SDK Package"
    /// reference table into `[displayName: modelID]`.
    private static func parseModelIDTable(html: String) -> [String: String] {
        guard let tableHTML = extractTable(containing: "Model ID", in: html) else { return [:] }

        var result: [String: String] = [:]
        for cells in parseRows(tableHTML) where cells.count >= 2 {
            let name = primaryLabel(cells[0])
            guard !name.isEmpty, name != "Model" else { continue }
            result[name] = cellText(cells[1])
        }
        return result
    }

    /// Extracts the full `<table>...</table>` HTML block that contains the
    /// given marker text (searches for the nearest preceding `<table` tag and
    /// the next `</table>` closing tag around the marker).
    private static func extractTable(containing marker: String, in html: String) -> String? {
        guard let markerRange = html.range(of: marker) else { return nil }
        guard let tableStart = html.range(
            of: "<table",
            options: .backwards,
            range: html.startIndex..<markerRange.lowerBound
        ) else { return nil }
        guard let tableEnd = html.range(
            of: "</table>",
            range: markerRange.upperBound..<html.endIndex
        ) else { return nil }
        return String(html[tableStart.lowerBound..<tableEnd.upperBound])
    }

    /// Splits a `<table>` HTML block into rows of raw cell HTML (tags intact -
    /// callers apply `cellText`/`primaryLabel`/`firstNumber` as appropriate).
    private static func parseRows(_ tableHTML: String) -> [[String]] {
        guard let rowRegex = try? NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: [.dotMatchesLineSeparators]),
              let cellRegex = try? NSRegularExpression(pattern: "<t[dh][^>]*>(.*?)</t[dh]>", options: [.dotMatchesLineSeparators])
        else { return [] }

        let nsHTML = tableHTML as NSString
        var rows: [[String]] = []
        for rowMatch in rowRegex.matches(in: tableHTML, range: NSRange(location: 0, length: nsHTML.length)) {
            let rowHTML = nsHTML.substring(with: rowMatch.range(at: 1))
            let nsRow = rowHTML as NSString
            let cellMatches = cellRegex.matches(in: rowHTML, range: NSRange(location: 0, length: nsRow.length))
            guard !cellMatches.isEmpty else { continue }
            rows.append(cellMatches.map { nsRow.substring(with: $0.range(at: 1)) })
        }
        return rows
    }

    /// Cell text with the row's flair removed: `<del>` blocks (superseded
    /// promo values) are dropped and everything from the first `<br>` on
    /// (e.g. "4x · Ends Sep 20") is discarded.
    private static func primaryLabel(_ cellHTML: String) -> String {
        let withoutDeleted = removingDeletedSpans(cellHTML)
        return cellText(withoutDeleted.components(separatedBy: "<br").first ?? "")
    }

    /// The first number in a cell, ignoring thousands separators and any
    /// struck-through value ahead of it (`<del>6,500</del>…26,000` -> 26,000).
    private static func firstNumber(_ cellHTML: String) -> Int? {
        let text = cellText(removingDeletedSpans(cellHTML))
        guard let match = text.range(of: #"[\d][\d,]*"#, options: .regularExpression) else { return nil }
        return Int(text[match].replacingOccurrences(of: ",", with: ""))
    }

    private static func removingDeletedSpans(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<del[^>]*>[\\s\\S]*?</del>",
            options: [.caseInsensitive]
        ) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    private static func cellText(_ html: String) -> String {
        stripTags(html).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Local disk cache

    private struct CachedCatalog: Codable {
        let fetchedAt: Date
        let models: [CatalogModel]
    }

    private struct CachedUsageLimits: Codable {
        let fetchedAt: Date
        let limits: [String: GoUsageLimits]
    }

    private func readCache() -> CachedCatalog? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        return try? JSONDecoder().decode(CachedCatalog.self, from: data)
    }

    private func writeCache(_ catalog: CachedCatalog) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    private func readUsageLimitsCache() -> CachedUsageLimits? {
        guard let data = try? Data(contentsOf: usageLimitsCacheFileURL) else { return nil }
        return try? JSONDecoder().decode(CachedUsageLimits.self, from: data)
    }

    private func writeUsageLimitsCache(_ cache: CachedUsageLimits) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: usageLimitsCacheFileURL, options: .atomic)
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
