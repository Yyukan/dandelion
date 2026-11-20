//
//  ModelCatalogService.swift
//  Dandelion
//
//  Builds the Zen/Go model catalog from OpenCode's model endpoints only:
//
//    https://opencode.ai/zen/v1/models     -> Zen models
//    https://opencode.ai/zen/go/v1/models  -> Go models (+ `go.monthly_usage`)
//
//  Each entry carries the model's name, limits, text/cache prices (with any
//  long-context override), audio/image unit prices and, on Go, the monthly
//  dollar allowance per plan. No docs page is fetched or parsed.
//
//  Cached locally for 24h, falling back to the last successful catalog when a
//  fetch or decode fails, so an endpoint outage never empties the view.
//

import Foundation

/// Fetches, decodes and caches OpenCode's Zen/Go catalog into `CatalogModel`.
actor ModelCatalogService {
    private static let zenModelsURL = URL(string: "https://opencode.ai/zen/v1/models")!
    private static let goModelsURL = URL(string: "https://opencode.ai/zen/go/v1/models")!

    private static let refreshInterval: TimeInterval = 24 * 60 * 60 // daily cadence
    /// Bumped whenever `CatalogModel`'s shape or meaning changes, so a cache
    /// written by an older build is refetched instead of misread.
    private static let cacheFormatVersion = 3

    private let session: URLSession
    private let cacheFileURL: URL
    /// Reads the `opencode-go` key used for the console Go page.
    private let authDiscovery = AuthDiscoveryService()
    /// Pre-migration caches (models.dev catalog + separate Go limits table).
    private let legacyCacheFileURLs: [URL]

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
        self.cacheFileURL = cacheDirectory.appendingPathComponent("catalog-cache.json")
        self.legacyCacheFileURLs = ["model-catalog-cache.json", "go-usage-limits-cache.json"]
            .map { cacheDirectory.appendingPathComponent($0) }
    }

    /// Returns the Zen + Go catalog, preferring a fresh local cache (younger
    /// than 24h) unless `forceRefresh` is set. Falls back to the last
    /// successful cache when a fetch or decode fails.
    func loadCatalog(forceRefresh: Bool = false) async -> [CatalogModel] {
        let cached = readCache()

        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.refreshInterval {
            return cached.models
        }

        do {
            let models = try await fetchCatalog()
            writeCache(CachedCatalog(formatVersion: Self.cacheFormatVersion, fetchedAt: Date(), models: models))
            removeLegacyCaches()
            return models
        } catch {
            return cached?.models ?? []
        }
    }

    // MARK: Remote fetch

    private func fetchCatalog() async throws -> [CatalogModel] {
        async let zenModels = fetchModels(from: Self.zenModelsURL, provider: .zen)
        async let goModels = fetchModels(from: Self.goModelsURL, provider: .go)
        let (zen, go) = try await (zenModels, goModels)
        guard !zen.isEmpty, !go.isEmpty else { throw URLError(.cannotParseResponse) }

        var models = (zen + go).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        models = await applyingGoRequestEstimates(to: models)
        return models
    }

    // MARK: Go 5h request estimates

    /// The console's Go page publishes the one number no API exposes: an
    /// estimate of requests per rolling 5-hour window, per plan. It is
    /// server-rendered HTML behind the API key (the page returns 401 without
    /// it), so it is parsed here. Treated as optional: any failure leaves
    /// `requestEstimate` nil and the catalog otherwise untouched.
    private func applyingGoRequestEstimates(to models: [CatalogModel]) async -> [CatalogModel] {
        guard let key = authDiscovery.discoverCredentials()
            .first(where: { $0.provider == .go })?.apiKey
        else { return models }

        var request = URLRequest(url: URL(string: "https://opencode.ai/console/go")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Dandelion)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { return models }

        let estimates = Self.parseRequestEstimates(from: html)
        guard !estimates.isEmpty else { return models }

        let named = estimates.map { (Self.normalized($0.name), $0.estimate) }
        var updated = models
        for index in updated.indices where updated[index].provider == .go {
            let target = Self.normalized(updated[index].displayName)
            guard let match = named.first(where: { target.hasPrefix($0.0) || $0.0.hasPrefix(target) })
            else { continue }
            updated[index].requestEstimate = match.1
        }
        return updated
    }

    /// Reads rows shaped like:
    /// `<tr><td>DeepSeek V4 Pro …</td><td>…</td><td>… Go: 1,040; Go Plus: 4,180 …</td>…`
    /// and returns the model name with its per-plan estimate.
    static func parseRequestEstimates(from html: String) -> [(name: String, estimate: GoRequestEstimate)] {
        var entries: [(String, GoRequestEstimate)] = []

        let rowRegex = try? NSRegularExpression(
            pattern: "<tr[^>]*>([\\s\\S]*?)</tr>",
            options: [.caseInsensitive]
        )
        let cellRegex = try? NSRegularExpression(
            pattern: "<t[dh][^>]*>([\\s\\S]*?)</t[dh]>",
            options: [.caseInsensitive]
        )
        let nsHTML = html as NSString
        rowRegex?.enumerateMatches(in: html, range: NSRange(location: 0, length: nsHTML.length)) { match, _, _ in
            guard let match, let cellRegex else { return }
            let row = nsHTML.substring(with: match.range(at: 1))
            let nsRow = row as NSString
            let cells = cellRegex.matches(in: row, range: NSRange(location: 0, length: nsRow.length))
                .map { nsRow.substring(with: $0.range(at: 1)) }
            guard cells.count >= 3 else { return }

            let name = Self.plainText(cells[0])
            guard !name.isEmpty, name != "Model" else { return }

            let numbers = Self.plainText(cells.joined(separator: " "))
            guard let go = Self.requestCount(in: numbers, label: "Go:"),
                  let plus = Self.requestCount(in: numbers, label: "Go Plus:")
            else { return }

            var estimate = GoRequestEstimate(go: go >= 0 ? go : nil, goPlus: plus >= 0 ? plus : nil)
            estimate.isUnlimited = go < 0 || plus < 0
            entries.append((name, estimate))
        }
        return entries
    }

    /// `"Go: 1,040"` -> 1040, `"Go: ∞"` -> -1, missing -> nil.
    private static func requestCount(in text: String, label: String) -> Int? {
        guard let range = text.range(of: label) else { return nil }
        let tail = text[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .prefix(24)
        if tail.hasPrefix("∞") { return -1 }
        let digits = tail.prefix { $0.isNumber || $0 == "," }
            .replacingOccurrences(of: ",", with: "")
        return Int(digits)
    }

    private static func plainText(_ html: String) -> String {
        let stripped = html.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Lowercases and drops the console table's badge words so
    /// "Muse Spark 1.2 Contributor Limited regions" still matches
    /// "Muse Spark 1.2 Contributor".
    private static func normalized(_ name: String) -> String {
        var text = name.lowercased()
        for noise in ["limited regions", "limited time", "new", "free"] {
            text = text.replacingOccurrences(of: noise, with: "")
        }
        return text.filter { $0.isLetter || $0.isNumber }
    }

    private func fetchModels(from url: URL, provider: CatalogProvider) async throws -> [CatalogModel] {
        let data = try await get(url)
        return try JSONDecoder().decode(ModelListResponse.self, from: data).data
            .compactMap { $0.value?.catalogModel(provider: provider) }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (Dandelion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: Endpoint payload

    private struct ModelListResponse: Decodable {
        let data: [Lossy<ModelEntry>]
    }

    /// Decodes one element, or `nil` if it doesn't fit - one odd model must not
    /// empty the whole list.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct ModelEntry: Decodable {
        let id: String
        let name: String?
        let family: String?
        let description: String?
        let releaseDate: String?
        let openWeights: Bool?
        let modalities: Modalities?
        let capabilities: Capabilities?
        let limit: Limit?
        let cost: Cost?
        let go: GoInfo?

        enum CodingKeys: String, CodingKey {
            case id, name, family, description, modalities, capabilities, limit, cost, go
            case releaseDate = "release_date"
            case openWeights = "open_weights"
        }

        func catalogModel(provider: CatalogProvider) -> CatalogModel {
            CatalogModel(
                modelID: id,
                displayName: name ?? id,
                provider: provider,
                pricing: cost?.pricing ?? .unpublished,
                goAllowance: provider == .go ? go?.monthlyUsage?.allowance : nil,
                family: family,
                description: description,
                contextLimit: limit?.context,
                outputLimit: limit?.output,
                modalities: modalities.map {
                    ModelModalities(input: $0.input ?? [], output: $0.output ?? [])
                },
                capabilities: capabilities?.supported ?? [],
                releaseDate: releaseDate,
                openWeights: openWeights
            )
        }
    }

    private struct Modalities: Decodable {
        let input: [String]?
        let output: [String]?
    }

    /// Capabilities come either as a bare flag (`"structured_output": true`)
    /// or as an object (`"tools": {"supported": true}`); keeps the names of
    /// those marked supported.
    private struct Capabilities: Decodable {
        let supported: [String]

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        private struct Flag: Decodable {
            let supported: Bool?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            supported = container.allKeys.filter { key in
                if let flag = try? container.decode(Bool.self, forKey: key) { return flag }
                return (try? container.decode(Flag.self, forKey: key))?.supported == true
            }
            .map(\.stringValue)
            .sorted()
        }
    }

    private struct Limit: Decodable {
        let context: Int?
        let output: Int?
    }

    private struct Cost: Decodable {
        let text: Media?
        let audio: Media?
        let image: Media?

        var pricing: ModelPricing {
            ModelPricing(
                inputPerM: text?.input?.price,
                outputPerM: text?.output?.price,
                cacheReadPerM: text?.input?.cache?.read,
                cacheWritePerM: text?.input?.cache?.write,
                longContext: text?.longContext,
                unitPrice: text == nil ? (audio?.unitPrice ?? image?.unitPrice) : nil
            )
        }
    }

    private struct Media: Decodable {
        let input: Rate?
        let output: Rate?

        /// The first context-size override, joined across input and output.
        var longContext: LongContextPricing? {
            let threshold = input?.contextThreshold ?? output?.contextThreshold
            guard let threshold else { return nil }
            let inputPrice = input?.override(above: threshold)?.price
            let outputPrice = output?.override(above: threshold)?.price
            guard inputPrice != nil || outputPrice != nil else { return nil }
            return LongContextPricing(aboveTokens: threshold, inputPerM: inputPrice, outputPerM: outputPrice)
        }

        var unitPrice: UnitPrice? {
            for rate in [input, output] {
                if let price = rate?.price, let unit = rate?.unit {
                    return UnitPrice(price: price, unit: unit)
                }
            }
            return nil
        }
    }

    private struct Rate: Decodable {
        let price: Double?
        let unit: String?
        let cache: Cache?
        let overrides: [Lossy<Override>]?

        var contextThreshold: Int? {
            overrides?.lazy.compactMap { $0.value?.when?.context?.gt }.first
        }

        func override(above threshold: Int) -> Override? {
            overrides?.lazy.compactMap(\.value).first { $0.when?.context?.gt == threshold }
        }
    }

    /// Cache prices. `read` is always a flat number, but `write` is either a
    /// flat number or an object keyed by retention window
    /// (`{"30m": 0.125, "12h": 0.25}`, `{"5m": 1.875, "1h": 3}`). Models that
    /// use the tiered form must not be dropped: decode either shape and keep
    /// the shortest-retention price (the lowest one), which is what a default
    /// request actually pays.
    private struct Cache: Decodable {
        let read: Double?
        let write: Double?

        private enum CodingKeys: String, CodingKey {
            case read, write
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            read = Self.number(container, forKey: .read)
            write = Self.number(container, forKey: .write)
        }

        private static func number(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Double? {
            if let flat = try? container.decodeIfPresent(Double.self, forKey: key) {
                return flat
            }
            if let tiers = try? container.decodeIfPresent([String: Double].self, forKey: key) {
                return tiers.values.min()
            }
            return nil
        }
    }

    private struct Override: Decodable {
        struct When: Decodable {
            struct Bound: Decodable {
                let gt: Int?
            }
            let context: Bound?
        }
        let when: When?
        let price: Double?
    }

    private struct GoInfo: Decodable {
        struct MonthlyUsage: Decodable {
            let go: Double?
            let goPlus: Double?
            let goTeams: Double?

            enum CodingKeys: String, CodingKey {
                case go
                case goPlus = "go-plus"
                case goTeams = "go-teams"
            }

            var allowance: GoMonthlyAllowance? {
                guard go != nil || goPlus != nil || goTeams != nil else { return nil }
                return GoMonthlyAllowance(go: go, goPlus: goPlus, goTeams: goTeams)
            }
        }

        let monthlyUsage: MonthlyUsage?

        enum CodingKeys: String, CodingKey {
            case monthlyUsage = "monthly_usage"
        }
    }

    // MARK: Local disk cache

    private struct CachedCatalog: Codable {
        let formatVersion: Int
        let fetchedAt: Date
        let models: [CatalogModel]
    }

    private func readCache() -> CachedCatalog? {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data),
              cached.formatVersion == Self.cacheFormatVersion else { return nil }
        return cached
    }

    private func writeCache(_ catalog: CachedCatalog) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    private func removeLegacyCaches() {
        for url in legacyCacheFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
