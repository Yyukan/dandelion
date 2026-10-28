//
//  AppSettings.swift
//  Dandelion
//
//  Persists user-configurable settings across launches via UserDefaults:
//  auto-refresh on/off + interval.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let autoRefreshEnabled = "autoRefreshEnabled"
        static let autoRefreshInterval = "autoRefreshIntervalSeconds"
    }

    /// Selectable auto-refresh cadences, in seconds: 5 minutes, 30 minutes, 1 hour.
    static let availableIntervals: [TimeInterval] = [300, 1800, 3600]

    private let defaults: UserDefaults

    var autoRefreshEnabled: Bool {
        didSet { defaults.set(autoRefreshEnabled, forKey: Keys.autoRefreshEnabled) }
    }

    var autoRefreshInterval: TimeInterval {
        didSet { defaults.set(autoRefreshInterval, forKey: Keys.autoRefreshInterval) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoRefreshEnabled = defaults.object(forKey: Keys.autoRefreshEnabled) as? Bool ?? false
        let storedInterval = defaults.double(forKey: Keys.autoRefreshInterval)
        self.autoRefreshInterval = storedInterval > 0 ? storedInterval : 300
    }
}
