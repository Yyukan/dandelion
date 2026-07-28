//
//  AppSettings.swift
//  Dandelion
//
//  Persists user-configurable settings across launches via UserDefaults:
//  auto-refresh on/off + interval, and the manual workspace ID override used
//  when automatic workspace discovery fails.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let autoRefreshEnabled = "autoRefreshEnabled"
        static let autoRefreshInterval = "autoRefreshIntervalSeconds"
        static let manualWorkspaceID = "manualWorkspaceID"
    }

    /// Selectable auto-refresh cadences, in seconds.
    static let availableIntervals: [TimeInterval] = [30, 60, 300, 900]

    private let defaults: UserDefaults

    var autoRefreshEnabled: Bool {
        didSet { defaults.set(autoRefreshEnabled, forKey: Keys.autoRefreshEnabled) }
    }

    var autoRefreshInterval: TimeInterval {
        didSet { defaults.set(autoRefreshInterval, forKey: Keys.autoRefreshInterval) }
    }

    /// Fallback for when the Zen page's embedded `wrk_...` token can't be
    /// found (e.g. a future markup change); empty means "auto-discover".
    var manualWorkspaceID: String {
        didSet { defaults.set(manualWorkspaceID, forKey: Keys.manualWorkspaceID) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoRefreshEnabled = defaults.object(forKey: Keys.autoRefreshEnabled) as? Bool ?? false
        let storedInterval = defaults.double(forKey: Keys.autoRefreshInterval)
        self.autoRefreshInterval = storedInterval > 0 ? storedInterval : 300
        self.manualWorkspaceID = defaults.string(forKey: Keys.manualWorkspaceID) ?? ""
    }
}
