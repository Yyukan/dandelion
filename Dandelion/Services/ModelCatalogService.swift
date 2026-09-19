//
//  ModelCatalogService.swift
//  Dandelion
//
//  Builds the Zen/Go model catalog from OpenCode's own sources only:
//
//  1. `https://opencode.ai/zen/v1/models` and `https://opencode.ai/zen/go/v1/models`
//     define *which* models exist. Each entry is only
//     `{id, object, created, owned_by}` - no name, price or limit metadata.
//  2. The console docs pages supply that metadata, joined by model ID:
//       https://opencode.ai/v2/docs/console/models -> Zen prices
//       https://opencode.ai/v2/docs/console/go     -> Go prices + the 5h/weekly/
//                                                     monthly usage-limit table
//  3. Models the docs mark as deprecated are dropped; models the docs don't
//     cover yet are still listed with the model ID as their name and no price.
//
//  Cached locally for 24h, falling back to the last successful catalog when a
//  fetch or parse fails, so an OpenCode docs redesign never empties the view.
//

import Foundation

/// Fetches, joins and caches OpenCode's Zen/Go catalog into `CatalogModel`.
actor ModelCatalogService {
    private static let zenModelsURL = URL(string: "https://opencode.ai/zen/v1/models")!
    private static let goModelsURL = URL(string: "https://opencode.ai/zen/go/v1/models")!
    private static let zenDocsURL = URL(string: "https://opencode.ai/v2/docs/console/models")!
    private static let goDocsURL = URL(string: "https://opencode.ai/v2/docs/console/go")!

    private static let refreshInterval: TimeInterval = 24 * 60 * 60 // daily cadence
    /// The console docs pages are occasionally served without their tables (an
    /// empty shell), so one fetch isn't reliable enough for a 24h cache.
    private static let fetchAttempts = 3
    private static let retryDelay: Duration = .seconds(2)

    private let session: URLSession
    private let cacheFileURL: URL
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
    /// successful cache when a fetch or parse fails.
    func loadCatalog(forceRefresh: Bool = false) async -> [CatalogModel] {
        let cached = readCache()

        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.refreshInterval {
            return cached.models
        }

        do {
            let models = try await fetchCatalog()
            writeCache(CachedCatalog(fetchedAt: Date(), models: models))
            removeLegacyCaches()
            return models
        } catch {
            return cached?.models ?? []
        }
    }

    // MARK: Remote fetch + join

    private func fetchCatalog() async throws -> [CatalogModel] {
        async let zenIDs = fetchModelIDs(from: Self.zenModelsURL)
        async let goIDs = fetchModelIDs(from: Self.goModelsURL)
        async let zenHTML = fetchDocsHTML(from: Self.zenDocsURL)
        async let goHTML = fetchDocsHTML(from: Self.goDocsURL)

        let (zen, go, zenDocs, goDocs) = try await (zenIDs, goIDs, zenHTML, goHTML)
        guard !zen.isEmpty, !go.isEmpty else { throw URLError(.cannotParseResponse) }

        let zenPage = Self.parseDocs(zenDocs)
        let goPage = Self.parseDocs(goDocs)
        guard !zenPage.isEmpty || !goPage.isEmpty else { throw URLError(.cannotParseResponse) }

        var models = zen
            .filter { !zenPage.isDeprecated($0, slug: Self.slug($0)) }
            .map { id in
                CatalogModel(
                    modelID: id,
                    displayName: zenPage.nameByID[id] ?? id,
                    provider: .zen,
                    pricing: zenPage.pricingByID[id] ?? .unpublished,
                    usageLimits: nil
                )
            }
        models += go.map { id in
            CatalogModel(
                modelID: id,
                displayName: goPage.nameByID[id] ?? id,
                provider: .go,
                pricing: goPage.pricingByID[id] ?? .unpublished,
                usageLimits: goPage.limitsByID[id]
            )
        }

        return models.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private struct ModelListResponse: Decodable {
        struct Entry: Decodable {
            let id: String
        }
        let data: [Entry]
    }

    private func fetchModelIDs(from url: URL) async throws -> [String] {
        let data = try await get(url)
        return try JSONDecoder().decode(ModelListResponse.self, from: data).data.map(\.id)
    }

    /// Fetches a docs page, retrying while the response contains no tables at
    /// all (a degraded response), and failing rather than returning a page we
    /// would silently parse into "no models".
    private func fetchDocsHTML(from url: URL) async throws -> String {
        var lastError: Error = URLError(.cannotParseResponse)

        for attempt in 0..<Self.fetchAttempts {
            do {
                let data = try await get(url)
                let html = String(decoding: data, as: UTF8.self)
                if !Self.parseRows(html).isEmpty { return html }
            } catch {
                lastError = error
            }
            if attempt < Self.fetchAttempts - 1 {
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
        throw lastError
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

    // MARK: Docs-page parsing

    /// Metadata scraped out of one console docs page, keyed by model ID.
    private struct DocsPage {
        var nameByID: [String: String] = [:]
        var pricingByID: [String: ModelPricing] = [:]
        var limitsByID: [String: GoUsageLimits] = [:]
        var deprecatedIDs: Set<String> = []
        /// Deprecated models can be listed without an endpoint row (and so
        /// without a model ID); matching their slug against the official model
        /// IDs still lets us drop them.
        var deprecatedSlugs: Set<String> = []

        var isEmpty: Bool {
            nameByID.isEmpty && pricingByID.isEmpty && limitsByID.isEmpty
        }

        func isDeprecated(_ modelID: String, slug modelSlug: String) -> Bool {
            deprecatedIDs.contains(modelID) || deprecatedSlugs.contains(modelSlug)
        }
    }

    private static func parseDocs(_ html: String) -> DocsPage {
        let tables = rawTables(in: html)
        var page = DocsPage()
        var nameToID: [String: String] = [:]
        var slugToID: [String: String] = [:]

        // Pass 1: the "Model | Model ID | Endpoint | AI SDK Package" reference
        // table is what lets every other table be joined by ID instead of by
        // display name (name joins broke on decorated promo rows).
        for table in tables where isReferenceTable(table) {
            for cells in table.dropFirst() where cells.count >= 2 {
                let name = baseName(primaryLabel(cells[0]))
                let id = cellText(cells[1])
                guard !name.isEmpty, !id.isEmpty else { continue }
                nameToID[name] = id
                slugToID[slug(name)] = id
                page.nameByID[id] = name
            }
        }

        func resolveID(_ rawName: String) -> String? {
            let name = baseName(primaryLabel(rawName))
            guard !name.isEmpty else { return nil }
            return nameToID[name] ?? slugToID[slug(name)]
        }

        // Pass 2: prices, usage limits and the deprecation table.
        for table in tables {
            guard let header = table.first else { continue }
            let columns = header.map { cellText($0).lowercased() }

            if columns.contains("model id") {
                continue
            } else if columns.contains("deprecation date") {
                for cells in table.dropFirst() {
                    guard let cell = cells.first else { continue }
                    let name = baseName(primaryLabel(cell))
                    guard !name.isEmpty else { continue }
                    if let id = resolveID(cell) {
                        page.deprecatedIDs.insert(id)
                    }
                    page.deprecatedSlugs.insert(slug(name))
                }
            } else if columns.count >= 3, columns[0] == "model", columns[1] == "input", columns[2] == "output" {
                for cells in table.dropFirst() where cells.count >= 3 {
                    guard let id = resolveID(cells[0]) else { continue }
                    // Long-context and peak/off-peak variants repeat a model;
                    // the docs list the cheapest tier first, so keep the first.
                    guard page.pricingByID[id] == nil else { continue }
                    page.pricingByID[id] = ModelPricing(
                        inputPerM: price(cells[1]),
                        outputPerM: price(cells[2])
                    )
                }
            } else if columns.count == 4, columns[1].contains("requests per 5 hour") {
                for cells in table.dropFirst() where cells.count >= 4 {
                    guard let id = resolveID(cells[0]),
                          let h5 = firstNumber(cells[1]),
                          let week = firstNumber(cells[2]),
                          let month = firstNumber(cells[3]) else { continue }
                    page.limitsByID[id] = GoUsageLimits(
                        requestsPer5h: h5,
                        requestsPerWeek: week,
                        requestsPerMonth: month
                    )
                }
            }
        }

        return page
    }

    private static func isReferenceTable(_ table: [[String]]) -> Bool {
        guard let header = table.first else { return false }
        return header.map({ cellText($0).lowercased() }).contains("model id")
    }

    /// All tables in the document, each as rows of raw cell HTML (callers apply
    /// `primaryLabel`/`cellText`/`firstNumber` as appropriate).
    private static func rawTables(in html: String) -> [[[String]]] {
        guard let regex = try? NSRegularExpression(
            pattern: "<table[^>]*>([\\s\\S]*?)</table>",
            options: [.caseInsensitive]
        ) else { return [] }

        let nsHTML = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
            .map { parseRows(nsHTML.substring(with: $0.range(at: 1))) }
            .filter { !$0.isEmpty }
    }

    /// A price cell: `"$0.14"` -> 0.14, `"Free"` -> 0 (free), `"-"`/blank -> nil.
    private static func price(_ cellHTML: String) -> Double? {
        let text = cellText(removingDeletedSpans(cellHTML)).lowercased()
        if text == "free" { return 0 }
        guard let match = text.range(of: #"\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text[match])
    }

    /// Drops a trailing parenthetical qualifier ("Qwen3.7 Plus (≤ 256K tokens)"
    /// -> "Qwen3.7 Plus") so variant rows join to the plain model.
    private static func baseName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func slug(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: HTML helpers

    /// Splits a `<table>` block into rows of raw cell HTML (tags intact).
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
    /// values) are dropped and everything from the first `<br>` on (e.g.
    /// "4x · Ends Sep 20") is discarded.
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

    private func readCache() -> CachedCatalog? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        return try? JSONDecoder().decode(CachedCatalog.self, from: data)
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
