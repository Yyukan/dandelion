//
//  RefreshCoordinator.swift
//  Dandelion
//
//  Orchestrates catalog/key-validation/balance/usage fetches in parallel via
//  a TaskGroup, exposing manual Refresh (⌘R) and a configurable Auto-Refresh
//  timer backed by AppSettings.
//

import Foundation
import Observation

@MainActor
@Observable
final class RefreshCoordinator {
    private(set) var isRefreshing = false
    private(set) var lastRefreshDate: Date?

    private let appSettings: AppSettings
    private let catalogViewModel: ModelCatalogViewModel
    private let zenBalanceViewModel: ZenBalanceViewModel
    private let goUsageViewModel: GoUsageViewModel

    private var autoRefreshTask: Task<Void, Never>?

    init(
        appSettings: AppSettings,
        catalogViewModel: ModelCatalogViewModel,
        zenBalanceViewModel: ZenBalanceViewModel,
        goUsageViewModel: GoUsageViewModel
    ) {
        self.appSettings = appSettings
        self.catalogViewModel = catalogViewModel
        self.zenBalanceViewModel = zenBalanceViewModel
        self.goUsageViewModel = goUsageViewModel

        if appSettings.autoRefreshEnabled {
            scheduleAutoRefresh()
        }
    }

    /// Runs credential validation, the (cache-respecting) catalog refresh,
    /// the live Zen balance and the live Go usage fetch all in parallel.
    /// A refresh already in flight is never duplicated.
    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [catalogViewModel] in await catalogViewModel.refreshConnection() }
            group.addTask { [catalogViewModel] in await catalogViewModel.refreshCatalog() }
            group.addTask { [zenBalanceViewModel] in await zenBalanceViewModel.refresh() }
            group.addTask { [goUsageViewModel] in await goUsageViewModel.refresh() }
        }

        lastRefreshDate = Date()
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        appSettings.autoRefreshEnabled = enabled
        if enabled {
            scheduleAutoRefresh()
        } else {
            autoRefreshTask?.cancel()
            autoRefreshTask = nil
        }
    }

    func setAutoRefreshInterval(_ interval: TimeInterval) {
        appSettings.autoRefreshInterval = interval
        if appSettings.autoRefreshEnabled {
            scheduleAutoRefresh()
        }
    }

    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        let interval = appSettings.autoRefreshInterval
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.refreshNow()
            }
        }
    }
}
