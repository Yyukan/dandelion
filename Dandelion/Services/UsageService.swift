//
//  UsageService.swift
//  Dandelion
//
//  Reads live Zen credit and OpenCode Go usage. Both surfaces authenticate
//  with an API key discovered from `~/.local/share/opencode/auth.json` - no
//  browser session, no cookies, no scraping:
//
//  - Zen balance comes from the console's JSON API:
//        GET https://opencode.ai/console/api/billing/status
//        GET https://opencode.ai/console/api/billing/auto-recharge
//        Authorization: Bearer <opencode key>
//    Money is `*MicroCents`, as strings, at 1e8 per dollar (verified live:
//    505700511 renders as "$5.06" in the console).
//    The billing endpoints resolve the workspace from the key itself, so no
//    org id and no `x-org-id` header are needed (`/console/api/orgs` still
//    refuses API keys with 401, but it isn't used any more).
//
//  - Go usage uses OpenCode's documented endpoint:
//        GET https://opencode.ai/inference/go/v1/usage
//        Authorization: Bearer <opencode-go key>
//    returning `{rolling,weekly,monthly}` percentages with absolute reset
//    timestamps.
//
//  Every failure throws (callers show the graceful fallback state) rather than
//  returning stale/zeroed data.
//

import Foundation

enum UsageServiceError: Error, Sendable, Equatable {
    /// No `opencode` / `opencode-go` key found in auth.json.
    case missingAPIKey
    /// The key was rejected upstream (401/403): revoked, rotated, or not valid
    /// for that surface.
    case unauthorized
    /// The console answered, but the billing payload had no usable balance.
    case balanceNotFound
    /// The usage endpoint answered, but the payload had no usable windows.
    case goUsageNotFound
    case network
}

actor UsageService {
    /// Console JSON API, exactly as the console web app calls it.
    private static let consoleAPIBase = URL(string: "https://opencode.ai/console/api")!
    /// Documented Go subscription usage endpoint (API-key authenticated).
    private static let goUsageURL = URL(string: "https://opencode.ai/inference/go/v1/usage")!

    /// Console money fields are micro-cents: one hundred million per dollar
    /// (confirmed live - 505700511 == $5.06).
    private static let microCentsPerDollar = 100_000_000.0

    private let session: URLSession
    private let authDiscovery: AuthDiscoveryService

    init(session: URLSession = .shared, authDiscovery: AuthDiscoveryService = AuthDiscoveryService()) {
        self.session = session
        self.authDiscovery = authDiscovery
    }

    // MARK: - Zen balance

    /// Reads the account's billing status (plus auto-recharge settings) to
    /// build a `ZenBalance`.
    ///
    /// Tries the pay-as-you-go `opencode` key first and falls back to the
    /// `opencode-go` key: both belong to the same account and the console
    /// accepts either, so a Go-only install still shows a balance.
    func fetchZenBalance() async throws -> ZenBalance {
        let credentials = authDiscovery.discoverCredentials()
        guard !credentials.isEmpty else { throw UsageServiceError.missingAPIKey }

        // Zen key first, then Go - stable order, one attempt each.
        let ordered = credentials.filter { $0.provider == .zen }
            + credentials.filter { $0.provider == .go }

        var lastError: UsageServiceError = .unauthorized
        for credential in ordered {
            do {
                return try await fetchZenBalance(apiKey: credential.apiKey)
            } catch let error as UsageServiceError {
                lastError = error
                // A rejected key is worth retrying with the other one; a
                // network or payload failure is not.
                if case .unauthorized = error { continue }
                throw error
            }
        }
        throw lastError
    }

    private func fetchZenBalance(apiKey: String) async throws -> ZenBalance {
        let status: BillingStatus = try await getJSON(
            path: "/billing/status", apiKey: apiKey, as: BillingStatus.self
        )
        // Auto-recharge is context only: never fail the balance over it.
        let autoRecharge: AutoRecharge? = try? await getJSON(
            path: "/billing/auto-recharge", apiKey: apiKey, as: AutoRecharge.self
        )

        guard let rawMicroCents = status.availableMicroCents ?? status.balanceMicroCents,
              let availableMicroCents = Double(rawMicroCents)
        else {
            throw UsageServiceError.balanceNotFound
        }

        return ZenBalance(
            currentUSD: availableMicroCents / Self.microCentsPerDollar,
            autoReloadEnabled: autoRecharge?.enabled ?? false,
            autoReloadThresholdUSD: autoRecharge?.thresholdDollars ?? 0,
            autoReloadAmountUSD: autoRecharge?.rechargeAmountDollars ?? 0,
            monthlyLimitUSD: status.creditLimitMicroCents
                .flatMap(Double.init)
                .map { $0 / Self.microCentsPerDollar },
            // The console's billing payload does not report month-to-date
            // spend alongside the limit, so this stays empty rather than
            // showing an unrelated (30-day) usage figure.
            monthlyUsageUSD: nil
        )
    }

    // MARK: - Go usage

    /// Reads the Go subscription's 5h/weekly/monthly windows.
    func fetchGoUsage() async throws -> GoUsageSummary {
        guard let apiKey = authDiscovery.discoverCredentials()
            .first(where: { $0.provider == .go })?.apiKey
        else {
            throw UsageServiceError.missingAPIKey
        }

        var request = URLRequest(url: Self.goUsageURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Dandelion)", forHTTPHeaderField: "User-Agent")

        let data = try await perform(request)
        guard let payload = try? Self.decoder.decode(GoUsageResponse.self, from: data) else {
            throw UsageServiceError.goUsageNotFound
        }

        let now = Date()
        func window(_ value: GoUsageWindowPayload, label: String) -> GoUsageWindow {
            GoUsageWindow(
                label: label,
                usedPercent: value.percent,
                resetsIn: max(0, value.resetsAt.timeIntervalSince(now)),
                isHealthy: value.status == "ok"
            )
        }

        return GoUsageSummary(
            rolling5h: window(payload.usage.rolling, label: "5h"),
            weekly: window(payload.usage.weekly, label: "Weekly"),
            monthly: window(payload.usage.monthly, label: "Monthly")
        )
    }

    // MARK: - Plumbing

    private func getJSON<T: Decodable>(
        path: String,
        apiKey: String,
        as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: Self.consoleAPIBase.appendingPathComponent(path))
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Dandelion)", forHTTPHeaderField: "User-Agent")

        let data = try await perform(request)
        guard let decoded = try? Self.decoder.decode(T.self, from: data) else {
            throw UsageServiceError.balanceNotFound
        }
        return decoded
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageServiceError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageServiceError.network
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            // The API key is no longer accepted.
            throw UsageServiceError.unauthorized
        default:
            throw UsageServiceError.network
        }
    }

    /// Reset timestamps arrive as ISO-8601 with millisecond precision
    /// (`2026-09-19T22:56:29.799Z`), which `.iso8601` alone won't parse.
    /// The formatters are built per call so the strategy stays `@Sendable`.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = withFraction.date(from: text) ?? plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognized date: \(text)")
            )
        }
        return decoder
    }()

    // MARK: - Wire formats

    private struct BillingStatus: Decodable {
        /// Micro-cents, as a string (100,000,000 per dollar).
        let balanceMicroCents: String?
        let creditLimitMicroCents: String?
        let availableMicroCents: String?
    }

    private struct AutoRecharge: Decodable {
        let enabled: Bool
        let thresholdDollars: Double
        let rechargeAmountDollars: Double
    }

    private struct GoUsageResponse: Decodable {
        let usage: Usage

        struct Usage: Decodable {
            let rolling: GoUsageWindowPayload
            let weekly: GoUsageWindowPayload
            let monthly: GoUsageWindowPayload
        }
    }

    private struct GoUsageWindowPayload: Decodable {
        let status: String
        let percent: Double
        let resetsAt: Date
    }
}
