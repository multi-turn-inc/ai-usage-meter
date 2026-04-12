import Foundation
import SwiftUI
import Combine
import ServiceManagement

@Observable
class AppState {
    var services: [ServiceViewModel] = []
    var isRefreshing: Bool = false
    var lastRefreshDate: Date?
    var errorMessage: String?
    var showingSettings: Bool = false
    var launchAtLogin: Bool = false
    var activityDetectionEnabled: Bool = false
    var showMenuBarLegendOnboarding: Bool = false

    private var refreshTimer: Timer?
    private var refreshInterval: TimeInterval = 300
    private var didStartRefreshWorkflow: Bool = false
    private var processMonitorTimer: Timer?
    private let dataStore = DataStore.shared

    // Credential file watchers for instant account-switch detection
    private var credentialFileWatchers: [any DispatchSourceFileSystemObject] = []
    private var credentialDirWatchers: [any DispatchSourceFileSystemObject] = []
    private var credentialRefreshDebounce: DispatchWorkItem?

    var totalUsagePercentage: Double {
        guard !services.isEmpty else { return 0 }
        return services.map(\.usagePercentage).reduce(0, +) / Double(services.count)
    }

    var iconName: String {
        switch totalUsagePercentage {
        case 0..<25:
            return "chart.bar.fill"
        case 25..<50:
            return "chart.bar.fill"
        case 50..<75:
            return "exclamationmark.circle.fill"
        case 75...100:
            return "exclamationmark.triangle.fill"
        default:
            return "chart.bar"
        }
    }

    init() {
        setupPlaceholderServices()
        loadPersistedConfiguration()
        loadLaunchAtLoginState()
        showMenuBarLegendOnboarding = !AppDefaults.userDefaults.bool(forKey: OnboardingDefaults.didDismissMenuBarLegend)

        // Avoid launching into a Keychain permission prompt while onboarding is visible.
        if !showMenuBarLegendOnboarding {
            startRefreshWorkflowIfNeeded()
        }
    }

    deinit {
        stopAutoRefreshTimer()
        stopProcessMonitor()
        stopCredentialFileWatcher()
    }

    // MARK: - Auto Refresh Timer

    func startAutoRefreshTimer() {
        stopAutoRefreshTimer()

        // Get refresh interval from first enabled service
        if let enabledService = services.first(where: { $0.config.isEnabled }) {
            refreshInterval = enabledService.config.refreshInterval
        }

        print("⏰ Starting auto-refresh timer: \(Int(refreshInterval))s interval")

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.refresh(interactive: false)
            }
        }
    }

    func stopAutoRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func startProcessMonitor() {
        stopProcessMonitor()
        ProcessMonitor.shared.start()
        processMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncConsumingState()
            }
        }
    }

    func stopProcessMonitor() {
        processMonitorTimer?.invalidate()
        processMonitorTimer = nil
        ProcessMonitor.shared.stop()
        // Clear consuming state on all services
        for service in services {
            service.isConsuming = false
        }
    }

    func setActivityDetection(_ enabled: Bool) {
        activityDetectionEnabled = enabled
        if enabled {
            startProcessMonitor()
        } else {
            stopProcessMonitor()
        }
        persistAppSettings()
    }

    private func syncConsumingState() {
        let monitor = ProcessMonitor.shared
        for service in services where service.config.isEnabled {
            let active = monitor.isActive(service.config.serviceType)
            if service.isConsuming != active {
                service.isConsuming = active
                if active {
                    service.consumingDetectedAt = Date()
                }
            }
        }
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = interval
        persistServiceConfigs()
        startAutoRefreshTimer()
    }

    // MARK: - Launch at Login

    func loadLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    print("✅ Launch at login enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    print("✅ Launch at login disabled")
                }
                launchAtLogin = enabled
                persistAppSettings()
            } catch {
                print("❌ Failed to set launch at login: \(error)")
            }
        }
    }

    func dismissMenuBarLegendOnboarding() {
        AppDefaults.userDefaults.set(true, forKey: OnboardingDefaults.didDismissMenuBarLegend)
        showMenuBarLegendOnboarding = false
        startRefreshWorkflowIfNeeded()
    }

    private func startRefreshWorkflowIfNeeded() {
        guard !didStartRefreshWorkflow else { return }
        didStartRefreshWorkflow = true

        if activityDetectionEnabled {
            startProcessMonitor()
        }
        startCredentialFileWatcher()

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refresh(interactive: false)
            await MainActor.run {
                startAutoRefreshTimer()
            }
        }
    }

    // MARK: - Credential File Watcher

    private func startCredentialFileWatcher() {
        stopCredentialFileWatcher()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let filePaths = [
            home.appendingPathComponent(".claude/.credentials.json").path,
            home.appendingPathComponent(".config/claude/.credentials.json").path,
            home.appendingPathComponent(".config/claude-code/.credentials.json").path
        ]

        var watchedDirs = Set<String>()

        for path in filePaths {
            if FileManager.default.fileExists(atPath: path) {
                watchCredentialFile(at: path)
            }

            let dir = (path as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: dir), watchedDirs.insert(dir).inserted {
                watchCredentialDirectory(at: dir)
            }
        }

        print("👀 Credential file watcher started (\(credentialFileWatchers.count) files, \(credentialDirWatchers.count) dirs)")
    }

    private func watchCredentialFile(at path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            print("🔑 Credential file changed: \(path)")
            self?.onCredentialFileChanged()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        credentialFileWatchers.append(source)
    }

    private func watchCredentialDirectory(at path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            print("🔑 Credential directory changed: \(path)")
            self?.onCredentialFileChanged()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        credentialDirWatchers.append(source)
    }

    private func onCredentialFileChanged() {
        credentialRefreshDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            print("🔄 Credential change detected → refreshing...")
            KeychainManager.shared.clearCredentialsCache()
            Task {
                await self?.refresh(interactive: false)
            }
        }
        credentialRefreshDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func stopCredentialFileWatcher() {
        for source in credentialFileWatchers { source.cancel() }
        credentialFileWatchers.removeAll()
        for source in credentialDirWatchers { source.cancel() }
        credentialDirWatchers.removeAll()
        credentialRefreshDebounce?.cancel()
        credentialRefreshDebounce = nil
    }

    private func setupPlaceholderServices() {
        services = ServiceType.allCases.map { type in
            ServiceViewModel(
                config: ServiceConfig(serviceType: type, isEnabled: type != .gemini),
                usage: UsageData.placeholder(for: type)
            )
        }
    }

    private func loadPersistedConfiguration() {
        let persistedConfigs = dataStore.getAllConfigs()
        if !persistedConfigs.isEmpty {
            for index in services.indices {
                let type = services[index].config.serviceType
                if let stored = persistedConfigs.first(where: { $0.serviceType == type }) {
                    services[index].config = stored
                }
            }
        }

        let settings = dataStore.getSettings()
        refreshInterval = settings.refreshInterval
        activityDetectionEnabled = settings.activityDetectionEnabled
        for index in services.indices {
            services[index].config.refreshInterval = settings.refreshInterval
            services[index].config.notificationThreshold = settings.notificationThreshold
        }
    }

    func persistServiceConfigs() {
        for service in services {
            dataStore.saveConfig(service.config)
        }
        persistAppSettings()
    }

    private func persistAppSettings() {
        let threshold = services.first?.config.notificationThreshold ?? 80
        let settings = DataStore.AppSettings(
            refreshInterval: refreshInterval,
            showNotifications: true,
            notificationThreshold: threshold,
            launchAtLogin: launchAtLogin,
            activityDetectionEnabled: activityDetectionEnabled
        )
        dataStore.saveSettings(settings)
    }

    func refresh(interactive: Bool) async {
        let shouldStart = await MainActor.run { () -> Bool in
            if isRefreshing {
                print("⏳ Refresh already in progress, skipping")
                return false
            }
            isRefreshing = true
            return true
        }
        guard shouldStart else { return }
        defer {
            Task { @MainActor in
                isRefreshing = false
            }
        }

        print("🔄 Starting refresh...")

        await MainActor.run {
            for service in services where service.config.isEnabled {
                service.snapshotBeforeRefresh()
            }
        }

        let results = await withTaskGroup(of: (Int, String, Result<UsageData, Error>).self) { group in
            for (index, service) in services.enumerated() {
                guard service.config.isEnabled else {
                    print("⏭️ Skipping disabled service: \(service.name)")
                    continue
                }
                let serviceName = service.name
                print("📡 Fetching: \(serviceName)")

                group.addTask {
                    do {
                        // Credential cache is cleared by file watcher on account switch,
                        // no need to clear on every refresh.
                        let client = self.createAPIClient(for: service.config, interactive: interactive)
                        let usage = try await client.fetchUsage()
                        print("✅ \(serviceName): \(usage.usagePercentage)%")
                        return (index, serviceName, .success(usage))
                    } catch {
                        print("❌ \(serviceName) error: \(error)")
                        return (index, serviceName, .failure(error))
                    }
                }
            }

            var collected: [(Int, String, Result<UsageData, Error>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        await MainActor.run {
            var errors: [String] = []
            for (index, serviceName, result) in results {
                switch result {
                case .success(let usage):
                    services[index].usage = usage
                    services[index].lastError = nil
                    services[index].computeDelta()
                    print("📊 Updated \(serviceName): \(usage.usagePercentage)%")

                    let historyEntry = UsageHistoryEntry(
                        serviceType: services[index].config.serviceType,
                        fiveHourUsage: usage.fiveHourUsage,
                        sevenDayUsage: usage.sevenDayUsage
                    )
                    UsageHistoryStore.shared.saveEntry(historyEntry)

                case .failure(let error):
                    // Rate limit: keep previous data, don't show as error
                    if let apiError = error as? APIError,
                       case .rateLimitExceeded = apiError {
                        print("⏳ \(serviceName): rate limited, keeping previous data")
                    } else {
                        services[index].lastError = error.localizedDescription
                        errors.append("\(serviceName): \(error.localizedDescription)")
                    }
                }
            }
            lastRefreshDate = Date()
            errorMessage = errors.isEmpty ? nil : errors.joined(separator: "; ")
            print("🏁 Refresh complete. Errors: \(errorMessage ?? "none")")
        }
    }

    private func createAPIClient(for config: ServiceConfig, interactive: Bool) -> AIServiceAPI {
        switch config.serviceType {
        case .claude:
            return AnthropicClient(config: config, allowKeychainInteraction: interactive)
        case .codex:
            return CodexClient(config: config)
        case .gemini:
            return GeminiClient(config: config)
        }
    }
}

@Observable
class ServiceViewModel: Identifiable {
    let id: UUID
    var config: ServiceConfig
    var usage: UsageData
    var lastError: String?

    var fiveHourDelta: Double = 0
    var sevenDayDelta: Double = 0
    var isConsuming: Bool = false
    var consumingDetectedAt: Date?

    private var previousFiveHourUsage: Double?
    private var previousSevenDayUsage: Double?

    init(config: ServiceConfig, usage: UsageData) {
        self.id = config.id
        self.config = config
        self.usage = usage
    }

    /// Call before updating usage to snapshot the current values.
    func snapshotBeforeRefresh() {
        previousFiveHourUsage = fiveHourUsage
        previousSevenDayUsage = sevenDayUsage
    }

    /// Call after updating usage to compute deltas and consuming state.
    func computeDelta() {
        let currentFive = fiveHourUsage ?? usagePercentage
        let currentSeven = sevenDayUsage ?? 0

        if let prevFive = previousFiveHourUsage {
            let delta = currentFive - prevFive
            fiveHourDelta = delta > 0.1 ? delta : 0
        }
        if let prevSeven = previousSevenDayUsage {
            let delta = currentSeven - prevSeven
            sevenDayDelta = delta > 0.1 ? delta : 0
        }
    }

    var name: String { config.displayName }
    var iconName: String { config.iconName }
    var brandColor: Color { config.brandColor }
    var tier: String { usage.tier }
    var tokensUsed: Int64 { usage.tokensUsed }
    var tokensLimit: Int64 { usage.tokensLimit }
    var usagePercentage: Double { usage.usagePercentage }
    var currentCost: Decimal? { usage.currentCost }
    var projectedCost: Decimal? { usage.projectedCost }
    var currency: String { usage.currency }
    var resetDate: Date? { usage.resetDate }
    var sevenDayResetDate: Date? { usage.sevenDayResetDate }
    var daysUntilSevenDayReset: Int? { usage.daysUntilSevenDayReset }

    var fiveHourUsage: Double? { usage.fiveHourUsage }
    var sevenDayUsage: Double? { usage.sevenDayUsage }
    var hasClaudeUsageWindows: Bool { fiveHourUsage != nil || sevenDayUsage != nil }

    var formattedTokensUsed: String { formatTokens(tokensUsed) }
    var formattedTokensLimit: String { formatTokens(tokensLimit) }

    var isAuthError: Bool {
        guard let error = lastError else { return false }
        let lower = error.lowercased()
        return lower.contains("401") || lower.contains("403")
            || lower.contains("토큰") || lower.contains("만료")
            || lower.contains("unauthorized") || lower.contains("token")
            || lower.contains("scope") || lower.contains("revoke")
            || lower.contains("api key") || lower.contains("apikey")
            || lower.contains("재인증") || lower.contains("credential")
    }

    var status: ServiceStatus {
        if isAuthError { return .critical }
        switch usagePercentage {
        case 0..<75: return .normal
        case 75..<90: return .warning
        default: return .critical
        }
    }

    private func formatTokens(_ tokens: Int64) -> String {
        let value = Double(tokens)
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        } else {
            return "\(Int(value))"
        }
    }
}

enum ServiceStatus {
    case normal, warning, critical
}
