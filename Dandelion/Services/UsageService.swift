//
//  UsageService.swift
//  Dandelion
//
//  Fetches the live Zen balance from OpenCode's private workspace billing
//  page - there is no public REST API for this (see the plan's research
//  notes); it is an undocumented, session-cookie-authenticated endpoint that
//  can change without notice on any opencode.ai redeploy.
//
//  Verified live against a real account: the workspace ID is embedded in
//  any authenticated page as a `wrk_...` token, and the billing page embeds
//  the account's billing state as a JS object literal containing
//  `balance`/`monthlyLimit`/`monthlyUsage`/`reloadTrigger`/`reloadAmount`
//  fields, where dollar amounts are encoded as integers scaled by 1e8
//  (confirmed: a raw `balance` of 908960881 renders as "$9.09" on the page).
//
//  The workspace's "go" page similarly embeds a `rollingUsage`/`weeklyUsage`/
//  `monthlyUsage` object literal (5h/weekly/monthly windows), each with a
//  `status`, `resetInSec` and an already-percentage `usagePercent`, plus a
//  `useBalance` flag for OpenCode's documented "fell back to Zen balance"
//  behavior - also confirmed live against a real account.
//

import Foundation

enum UsageServiceError: Error, Sendable, Equatable {
    case workspaceNotFound
    case balanceNotFound
    case goUsageNotFound
    case network
}

actor UsageService {
    /// Confirmed live: dollar amounts in the billing payload are integers
    /// scaled by one hundred million (e.g. 908960881 == $9.09).
    private static let dollarScale = 100_000_000.0

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Resolves the account's workspace ID, then reads its billing state to
    /// build a `ZenBalance`. Throws on any failure so callers can show the
    /// graceful fallback state rather than a stale/zeroed-out balance.
    ///
    /// - Parameter workspaceIDOverride: skips auto-discovery of the `wrk_...`
    ///   token when set - the manual fallback Settings exposes for when that
    ///   discovery fails (e.g. a future markup change upstream).
    func fetchZenBalance(cookie: SessionCookie, workspaceIDOverride: String? = nil) async throws -> ZenBalance {
        let workspaceID = try await resolveWorkspaceID(cookie: cookie, override: workspaceIDOverride)
        return try await fetchBalance(workspaceID: workspaceID, cookie: cookie)
    }

    /// Resolves the account's workspace ID, then reads its Go usage-window
    /// state (5h rolling / weekly / monthly) plus the "fell back to Zen
    /// balance" flag.
    func fetchGoUsage(cookie: SessionCookie, workspaceIDOverride: String? = nil) async throws -> GoUsageSummary {
        let workspaceID = try await resolveWorkspaceID(cookie: cookie, override: workspaceIDOverride)
        return try await fetchGoUsage(workspaceID: workspaceID, cookie: cookie)
    }

    private func resolveWorkspaceID(cookie: SessionCookie, override: String?) async throws -> String {
        if let override, !override.isEmpty {
            return override
        }
        let html = try await fetchHTML(url: URL(string: "https://opencode.ai/zen")!, cookie: cookie)
        guard let workspaceID = Self.firstMatch(pattern: #"wrk_[A-Za-z0-9]+"#, in: html) else {
            throw UsageServiceError.workspaceNotFound
        }
        return workspaceID
    }

    private func fetchBalance(workspaceID: String, cookie: SessionCookie) async throws -> ZenBalance {
        let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/billing")!
        let html = try await fetchHTML(url: url, cookie: cookie)

        guard let rawBalance = Self.firstMatch(pattern: #"\bbalance:(\d+)"#, in: html).flatMap(Double.init) else {
            throw UsageServiceError.balanceNotFound
        }

        let reloadTrigger = Self.firstMatch(pattern: #"\breloadTrigger:(\d+)"#, in: html).flatMap(Double.init) ?? 0
        let reloadAmount = Self.firstMatch(pattern: #"\breloadAmount:(\d+)"#, in: html).flatMap(Double.init) ?? 0
        let reloadEnabled = Self.firstMatch(pattern: #"\breload:(null|\d+)"#, in: html) != "null"
        let monthlyLimit = Self.firstMatch(pattern: #"\bmonthlyLimit:(\d+)"#, in: html).flatMap(Double.init)
        let rawMonthlyUsage = Self.firstMatch(pattern: #"\bmonthlyUsage:(\d+)"#, in: html).flatMap(Double.init)

        return ZenBalance(
            currentUSD: rawBalance / Self.dollarScale,
            autoReloadEnabled: reloadEnabled,
            autoReloadThresholdUSD: reloadTrigger,
            autoReloadAmountUSD: reloadAmount,
            monthlyLimitUSD: monthlyLimit,
            monthlyUsageUSD: rawMonthlyUsage.map { $0 / Self.dollarScale }
        )
    }

    private func fetchGoUsage(workspaceID: String, cookie: SessionCookie) async throws -> GoUsageSummary {
        let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/go")!
        let html = try await fetchHTML(url: url, cookie: cookie)

        guard let rolling5h = Self.parseUsageWindow(key: "rollingUsage", label: "5h", in: html),
              let weekly = Self.parseUsageWindow(key: "weeklyUsage", label: "Weekly", in: html),
              let monthly = Self.parseUsageWindow(key: "monthlyUsage", label: "Monthly", in: html)
        else {
            throw UsageServiceError.goUsageNotFound
        }

        return GoUsageSummary(
            rolling5h: rolling5h,
            weekly: weekly,
            monthly: monthly,
            isUsingZenBalance: Self.parseMinifiedBool(key: "useBalance", in: html) ?? false
        )
    }

    /// Parses one `<key>:{status:"...",resetInSec:N,usagePercent:N,...}` block
    /// (the object literal is sometimes wrapped in a `$R[n]=` resumability
    /// assignment, which this pattern tolerates but doesn't require).
    /// `usagePercent` may be an integer (older dashboard) or a float
    /// (e.g. `0.5` — newer dashboard), so it matches `[\d.]+`.
    /// The dashboard has also added extra fields after `usagePercent`
    /// (`usage:N,limit:N`), so the pattern accepts any content up to `}`.
    private static func parseUsageWindow(key: String, label: String, in html: String) -> GoUsageWindow? {
        let pattern = #"\#(key):(?:\$R\[\d+\]=)?\{status:"(\w+)",resetInSec:(\d+),usagePercent:([\d.]+)(?:,.*?)?\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges == 4 else { return nil }

        func group(_ index: Int) -> String? {
            guard let r = Range(match.range(at: index), in: html) else { return nil }
            return String(html[r])
        }
        guard let status = group(1), let resetInSec = group(2).flatMap(Double.init),
              let usagePercent = group(3).flatMap(Double.init)
        else { return nil }

        return GoUsageWindow(label: label, usedPercent: usagePercent, resetsIn: resetInSec, isHealthy: status == "ok")
    }

    /// The dashboard's minified JS encodes booleans as `!0` (true) / `!1`
    /// (false) rather than `true`/`false`.
    private static func parseMinifiedBool(key: String, in html: String) -> Bool? {
        guard let value = firstMatch(pattern: #"\#(key):(!0|!1)"#, in: html) else { return nil }
        return value == "!0"
    }

    private func fetchHTML(url: URL, cookie: SessionCookie) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("auth=\(cookie.value)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Dandelion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UsageServiceError.network
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw UsageServiceError.balanceNotFound
        }
        return html
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let groupRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
        guard let swiftRange = Range(groupRange, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
