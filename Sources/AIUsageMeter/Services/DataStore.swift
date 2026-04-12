import Foundation

class DataStore {
    static let shared = DataStore()

    private let userDefaults = AppDefaults.userDefaults
    private let keychainManager = KeychainManager.shared

    private let configsKey = "serviceConfigs"
    private let settingsKey = "appSettings"

    private init() {}

    // MARK: - Service Configuration

    func saveConfig(_ config: ServiceConfig) {
        var configs = getAllConfigs()
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }

        // Save API key to Keychain (securely)
        if !config.apiKey.isEmpty {
            try? keychainManager.save(config.apiKey, for: config.id.uuidString)
        }

        // Save config without API key to UserDefaults
        var configToSave = config
        configToSave.apiKey = "" // Don't store API key in UserDefaults

        if let encoded = try? JSONEncoder().encode(configs.map { c in
            var copy = c
            copy.apiKey = ""
            return copy
        }) {
            userDefaults.set(encoded, forKey: configsKey)
        }
    }

    func getConfig(for id: UUID) -> ServiceConfig? {
        guard var config = getAllConfigs().first(where: { $0.id == id }) else {
            return nil
        }

        // Restore API key from Keychain
        if let apiKey = try? keychainManager.retrieve(for: id.uuidString) {
            config.apiKey = apiKey
        }

        return config
    }

    func getConfig(for type: ServiceType) -> ServiceConfig? {
        guard var config = getAllConfigs().first(where: { $0.serviceType == type }) else {
            return nil
        }

        // Restore API key from Keychain
        if let apiKey = try? keychainManager.retrieve(for: config.id.uuidString) {
            config.apiKey = apiKey
        }

        return config
    }

    func getAllConfigs() -> [ServiceConfig] {
        guard let data = userDefaults.data(forKey: configsKey),
              let configs = try? JSONDecoder().decode([ServiceConfig].self, from: data) else {
            return []
        }
        return configs
    }

    func deleteConfig(_ id: UUID) {
        var configs = getAllConfigs()
        configs.removeAll { $0.id == id }

        try? keychainManager.delete(for: id.uuidString)

        if let encoded = try? JSONEncoder().encode(configs) {
            userDefaults.set(encoded, forKey: configsKey)
        }
    }

    // MARK: - App Settings

    struct AppSettings: Codable {
        var refreshInterval: TimeInterval = 300
        var showNotifications: Bool = true
        var notificationThreshold: Double = 80
        var launchAtLogin: Bool = false
        var activityDetectionEnabled: Bool = false
    }

    func saveSettings(_ settings: AppSettings) {
        if let encoded = try? JSONEncoder().encode(settings) {
            userDefaults.set(encoded, forKey: settingsKey)
        }
    }

    func getSettings() -> AppSettings {
        guard let data = userDefaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    // MARK: - Usage Cache

    func cacheUsage(_ usage: UsageData, for serviceId: UUID) {
        if let encoded = try? JSONEncoder().encode(usage) {
            userDefaults.set(encoded, forKey: "usage.\(serviceId.uuidString)")
        }
    }

    func getCachedUsage(for serviceId: UUID) -> UsageData? {
        guard let data = userDefaults.data(forKey: "usage.\(serviceId.uuidString)"),
              let usage = try? JSONDecoder().decode(UsageData.self, from: data) else {
            return nil
        }
        return usage
    }

    func clearCache() {
        let keys = userDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("usage.") }
        keys.forEach { userDefaults.removeObject(forKey: $0) }
    }
}
