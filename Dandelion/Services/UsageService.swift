//
//  UsageService.swift
//  Dandelion
//
//  Reads live Zen credit and OpenCode Go usage from OpenCode's *new*
//  console (the 2026-09 "OpenCode Console" rewrite), replacing the old
//  workspace-page HTML scraping:
//
//  - Zen balance comes from the console's JSON API, authenticated by the
//    browser's `__Host-console_session` cookie plus an `x-org-id` header:
//        GET https://opencode.ai/console/api/billing/status
//        GET https://opencode.ai/console/api/billing/auto-recharge
//        GET https://opencode.ai/console/api/orgs           (org discovery)
//    Money is `*MicroCents`, as strings, at 1e8 per dollar (verified live:
//    505700511 renders as "$5.06" in the console).
//
//  - Go usage no longer needs a browser session at all: OpenCode publishes an
//    official, API-key-authenticated endpoint (added 2026-08-11):
//        GET https://opencode.ai/zen/go/v1/usage
//        Authorization: Bearer <opencode-go key>
//    returning `{rolling,weekly,monthly}` percentages with absolute reset
//    timestamps - verified live against a real account.
//
//  Both surfaces are undocumented and can change on any opencode.ai
//  redeploy, so every failure throws (callers show the graceful fallback
//  state) rather than returning stale/zeroed data.
//

import Foundation

enum UsageServiceError: Error, Sendable, Equatable {
    /// No org id could be resolved for the signed-in account.
    case workspaceNotFound
    /// The console answered, but the billing payload had no usable balance.
    case balanceNotFound
    /// The Go usage endpoint answered, but the payload had no usable windows.
    case goUsageNotFound
    /// The console rejected the session cookie (needs a fresh browser login).
    case sessionExpired
    /// No OpenCode Go API key was found locally; Go usage needs one.
    case missingGoAPIKey
    case network
}

actor UsageService {
    /// Console JSON API, exactly as the console web app calls it.
    private static let consoleAPIBase = URL(string: "https://opencode.ai/console/api")!
    /// Official Go subscription usage endpoint (API-key authenticated).
    private static let goUsageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

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

    /// Resolves the account's org id, then reads its billing status (plus
    /// auto-recharge settings) to build a `ZenBalance`. Throws on any failure
    /// so callers can show the graceful fallback state.
    ///
    /// - Parameter workspaceIDOverride: skips org discovery when set - the
    ///   manual fallback Settings exposes.
    func fetchZenBalance(cookie: SessionCookie, workspaceIDOverride: String? = nil) async throws -> ZenBalance {
        let orgID = try await resolveOrgID(cookie: cookie, override: workspaceIDOverride)

        let status: BillingStatus = try await getJSON(
            path: "/billing/status", cookie: cookie, orgID: orgID, as: BillingStatus.self
        )
        // Auto-recharge is context only: never fail the balance over it.
        let autoRecharge: AutoRecharge? = try? await getJSON(
            path: "/billing/auto-recharge", cookie: cookie, orgID: orgID, as: AutoRecharge.self
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
            // The console's billing payload no longer reports month-to-date
            // spend alongside the limit, so this stays empty rather than
            // showing an unrelated (30-day) usage figure.
            monthlyUsageUSD: nil
        )
    }

    // MARK: - Go usage

    /// Reads the Go subscription's 5h/weekly/monthly windows from OpenCode's
    /// official API. Needs a locally discovered `opencode-go` key; no browser
    /// session is involved.
    func fetchGoUsage(workspaceIDOverride _: String? = nil) async throws -> GoUsageSummary {
        guard let apiKey = authDiscovery.discoverCredentials()
            .first(where: { $0.provider == .go })?.apiKey
        else {
            throw UsageServiceError.missingGoAPIKey
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
            monthly: window(payload.usage.monthly, label: "Monthly"),
            // This endpoint reports percentages only; OpenCode's "now billing
            // from Zen balance" flag has no equivalent here.
            isUsingZenBalance: false
        )
    }

    // MARK: - Console plumbing

    private func resolveOrgID(cookie: SessionCookie, override: String?) async throws -> String {
        if let override, !override.isEmpty {
            return override
        }
        let orgs: [ConsoleOrg] = try await getJSON(path: "/orgs", cookie: cookie, orgID: nil, as: [ConsoleOrg].self)
        guard let orgID = orgs.first?.id, !orgID.isEmpty else {
            throw UsageServiceError.workspaceNotFound
        }
        return orgID
    }

    private func getJSON<T: Decodable>(
        path: String,
        cookie: SessionCookie,
        orgID: String?,
        as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: Self.consoleAPIBase.appendingPathComponent(path))
        request.timeoutInterval = 15
        request.setValue("__Host-console_session=\(cookie.value)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Dandelion)", forHTTPHeaderField: "User-Agent")
        if let orgID {
            // The console API requires the active workspace on every
            // org-scoped call ("x-org-id is required" without it).
            request.setValue(orgID, forHTTPHeaderField: "x-org-id")
        }

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
            // Session cookie / API key no longer accepted.
            throw UsageServiceError.sessionExpired
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

    private struct ConsoleOrg: Decodable {
        let id: String
    }

    private struct BillingStatus: Decodable {
        let billingMode: String
        let mode: String
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
