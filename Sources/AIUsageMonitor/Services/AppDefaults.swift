import Foundation

enum AppDefaults {
    // Stable preferences domain independent from bundle identifier changes.
    private static let suiteName = "com.aiusagemonitor.shared"
    private static let migrationMarkerKey = "aim.defaults.migrated.v1"

    static let userDefaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        migrateLegacyDomainsIfNeeded(into: defaults)
        return defaults
    }()

    private static func migrateLegacyDomainsIfNeeded(into target: UserDefaults) {
        guard !target.bool(forKey: migrationMarkerKey) else { return }

        let sourceDomains = orderedSourceDomains().filter { $0 != suiteName }
        for domain in sourceDomains {
            guard let values = UserDefaults.standard.persistentDomain(forName: domain),
                  !values.isEmpty else {
                continue
            }

            for (key, value) in values where target.object(forKey: key) == nil {
                target.set(value, forKey: key)
            }
        }

        target.set(true, forKey: migrationMarkerKey)
    }

    private static func orderedSourceDomains() -> [String] {
        var result: [String] = []
        let candidates = [
            Bundle.main.bundleIdentifier,
            ProcessInfo.processInfo.processName,
            "com.aiusagemonitor",
            "AIUsageMonitor",
            "com.ai-usage-monitor",
            "com.multiturn.ai-usage-monitor",
            "com.multi-turn.ai-usage-monitor",
            "ai-usage-monitor"
        ]

        for candidate in candidates {
            guard let domain = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !domain.isEmpty,
                  !result.contains(domain) else {
                continue
            }
            result.append(domain)
        }
        return result
    }
}
