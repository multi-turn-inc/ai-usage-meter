import Foundation
import SwiftUI
import Combine
import ServiceManagement
import AIUsageMeterCore

@MainActor
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
    var tokenUsage: TokenUsageSummary = .empty
    /// Bumped when something the icon depends on changes but the usage numbers
    /// don't — pinning a different representative account, for instance.
    var menuBarNeedsRedraw: Int = 0
    /// Which plan to use now, per provider. See `PlanAdvisor`.
    var recommendations: [ServiceType: PlanRecommendation] = [:]
    /// Last pick per provider, so near-ties don't flip the advice every refresh.
    var previousPicks: [ServiceType: String] = [:]
    private var adviceTimer: Timer?

    private var refreshTimer: Timer?
    private var refreshInterval: TimeInterval = 300
    private var didStartRefreshWorkflow: Bool = false
    private var processMonitorTimer: Timer?
    private var rateLimitRetryScheduled = false
    private let dataStore = DataStore.shared

    // Credential file watchers for instant account-switch detection
    private var credentialFileWatchers: [any DispatchSourceFileSystemObject] = []
    private var credentialDirWatchers: [any DispatchSourceFileSystemObject] = []
    private var credentialRefreshDebounce: DispatchWorkItem?
    /// Last seen modification date of each watched credentials file (nil when
    /// absent), so a directory event that didn't touch one can be ignored.
    private var credentialFileStamps: [String: Date?] = [:]

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

        // If credential file is missing, the first refresh must be interactive
        // so Keychain access can restore it. Otherwise use non-interactive.
        // A render run is unattended: it must never raise a Keychain prompt.
        let isRenderRun = Self.isRenderRun
        let needsInteractive = !KeychainManager.shared.hasCredentialFile() && !isRenderRun

        if (!showMenuBarLegendOnboarding || isRenderRun) && !Self.isFixtureRun {
            startRefreshWorkflowIfNeeded(interactive: needsInteractive)
        }
    }

    /// Unattended screenshot runs (`AIM_BLOG_RENDER`).
    static var isRenderRun: Bool {
        ProcessInfo.processInfo.environment["AIM_BLOG_RENDER"] != nil
    }

    /// Screenshot runs with made-up plans: nothing real is fetched.
    static var isFixtureRun: Bool {
        ProcessInfo.processInfo.environment["AIM_BLOG_RENDER_FIXTURE"] != nil
    }

    deinit {
        // AppState is owned by AppDelegate for the app lifetime, so this only
        // fires on process teardown when the OS reclaims resources anyway.
        // Timers/dispatch sources are cancelled on release; nothing to do here
        // (touching MainActor-isolated state from a nonisolated deinit would
        // race under Swift 6).
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
            Task { @MainActor in
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
        // Same rule as init(): if there's no credential file yet, the first
        // refresh has to be interactive so Keychain can restore it. Without
        // this recheck a fresh user would get a silent non-interactive refresh
        // and stay stuck on "Loading" until the next 5-min cycle.
        let needsInteractive = !KeychainManager.shared.hasCredentialFile()
        startRefreshWorkflowIfNeeded(interactive: needsInteractive)
    }

    private func startRefreshWorkflowIfNeeded(interactive: Bool = false) {
        guard !didStartRefreshWorkflow else { return }
        didStartRefreshWorkflow = true

        if activityDetectionEnabled {
            startProcessMonitor()
        }
        startCredentialFileWatcher()

        // Already on MainActor via the class isolation; no extra hop needed.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refresh(interactive: interactive)
            startAutoRefreshTimer()
        }

        // Resets happen between refreshes; re-judge every minute so the advice
        // and the menu bar move on the moment a window refills.
        adviceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateAdvice() }
        }
    }

    // MARK: - Credential File Watcher

    private func startCredentialFileWatcher() {
        stopCredentialFileWatcher()

        let filePaths = Self.credentialFilePaths
        credentialFileStamps = Self.credentialStamps()

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
            Task { @MainActor in
                self?.onCredentialFileChanged()
            }
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
            Task { @MainActor in
                self?.onCredentialFileChanged()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        credentialDirWatchers.append(source)
    }

    private static var credentialFilePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/.credentials.json").path,
            home.appendingPathComponent(".config/claude/.credentials.json").path,
            home.appendingPathComponent(".config/claude-code/.credentials.json").path
        ]
    }

    private static func credentialStamps() -> [String: Date?] {
        Dictionary(uniqueKeysWithValues: credentialFilePaths.map { path in
            (path, (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)
        })
    }

    private func onCredentialFileChanged() {
        // A directory watcher fires on any entry change, and Claude Code
        // rewrites history.jsonl in ~/.claude on every prompt. Each firing used
        // to refetch every account — on a busy day, enough calls to lock
        // accounts out of Anthropic's usage endpoint. Only a real change to a
        // credentials file counts.
        let stamps = Self.credentialStamps()
        guard stamps != credentialFileStamps else { return }
        credentialFileStamps = stamps

        credentialRefreshDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            print("🔄 Credential change detected → refreshing...")
            KeychainManager.shared.clearCredentialsCache()
            // Use interactive: true so Keychain can restore the credential
            // file if it was deleted (e.g. by Claude Code token refresh).
            Task { @MainActor in
                await self?.refresh(interactive: true)
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
        // One row per *account*, not per provider: a machine commonly holds
        // several paid logins per provider and each has its own quota. Accounts
        // the user hid stay discovered but unmonitored.
        let accounts = AccountRegistry.shared.visibleAccounts()
        var models: [ServiceViewModel] = accounts.map { account in
            ServiceViewModel(
                config: ServiceConfig(serviceType: account.service, isEnabled: true),
                usage: UsageData.placeholder(for: account.service),
                account: account
            )
        }

        // Providers we can't discover (Gemini) — and a cold-start machine with no
        // logins at all — still need their rows so the UI and settings work.
        for type in ServiceType.allCases where !accounts.contains(where: { $0.service == type }) {
            models.append(ServiceViewModel(
                config: ServiceConfig(serviceType: type, isEnabled: type != .gemini && accounts.isEmpty),
                usage: UsageData.placeholder(for: type)
            ))
        }

        services = models
    }

    /// Rebuilds the rows after accounts are added, removed, or hidden, keeping
    /// already-fetched usage so visible rows don't flash back to "loading".
    func reloadAccounts(interactive: Bool = false) {
        let previous = Dictionary(uniqueKeysWithValues: services.compactMap { service in
            service.account.map { ($0.id, service) }
        })
        setupPlaceholderServices()
        loadPersistedConfiguration()
        for index in services.indices {
            guard let id = services[index].account?.id, let old = previous[id] else { continue }
            services[index].usage = old.usage
            services[index].lastError = old.lastError
            services[index].hasLoaded = old.hasLoaded
        }
        updateAdvice()
        // A reload that follows the user adding an account is interactive: this
        // is the one moment a Keychain prompt is expected, so the new row can
        // resolve immediately instead of sitting on "grant access".
        Task { await refresh(interactive: interactive) }
    }

    private func loadPersistedConfiguration() {
        let persistedConfigs = dataStore.getAllConfigs()
        if !persistedConfigs.isEmpty {
            for index in services.indices {
                let type = services[index].config.serviceType
                if let stored = persistedConfigs.first(where: { $0.serviceType == type }) {
                    // Copy the per-provider settings but keep each account's own
                    // identity — several accounts share a service type, and
                    // adopting the stored id wholesale would collapse them.
                    services[index].config.apiKey = stored.apiKey
                    services[index].config.organizationId = stored.organizationId
                    services[index].config.isEnabled = stored.isEnabled
                    services[index].config.refreshInterval = stored.refreshInterval
                    services[index].config.notificationThreshold = stored.notificationThreshold
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
        if isRefreshing {
            print("⏳ Refresh already in progress, skipping")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        print("🔄 Starting refresh...")

        for service in services where service.config.isEnabled {
            service.snapshotBeforeRefresh()
        }

        // Build the client list on the main actor (needs isEnabled/config),
        // then hand each client off to a detached task so URLSession + Keychain
        // I/O never blocks the UI. `AIServiceAPI` isn't Sendable, but each
        // client is used by exactly one task and never touched again from
        // MainActor, so isolated ownership is safe.
        struct Job {
            /// The row's stable id, not its position. Positions go stale the
            /// moment the account list changes — deleting an account mid-refresh
            /// left results pointing past the end of the array.
            let id: UUID
            let name: String
            let client: AIServiceAPI
        }
        // A second login into a plan whose first login is answering adds
        // nothing but another request against the same rate limit.
        let redundant = Set(planRows.filter { Self.isHealthy($0.login) }.flatMap { $0.otherLogins.map(\.id) })
        let jobs: [Job] = services.compactMap { service in
            guard service.config.isEnabled else {
                print("⏭️ Skipping disabled service: \(service.name)")
                return nil
            }
            guard !redundant.contains(service.id) else { return nil }
            let label = service.accountLabel.map { "\(service.name) (\($0))" } ?? service.name
            print("📡 Fetching: \(label)")
            return Job(
                id: service.id,
                name: label,
                client: Self.createAPIClient(for: service.config,
                                             interactive: interactive,
                                             account: service.account)
            )
        }

        // Results land as each account answers. Waiting for the whole group
        // let one throttled account — sleeping out a retry — hold every other
        // row on "loading" for a minute.
        var errors: [String] = []
        await withTaskGroup(of: (UUID, String, Result<UsageData, Error>).self) { group in
            for (position, job) in jobs.enumerated() {
                group.addTask {
                    // Stagger the starts. Firing every account at once turned one
                    // refresh into five near-simultaneous calls to the same
                    // provider, which is what tripped its rate limiter and left
                    // whole rows stuck with no data.
                    if position > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(position) * 700_000_000)
                    }
                    // Credential cache is cleared by file watcher on account switch,
                    // no need to clear on every refresh.
                    do {
                        let usage = try await job.client.fetchUsage()
                        print("✅ \(job.name): \(usage.usagePercentage)%")
                        return (job.id, job.name, .success(usage))
                    } catch {
                        print("❌ \(job.name) error: \(error)")
                        return (job.id, job.name, .failure(error))
                    }
                }
            }

            for await (id, serviceName, result) in group {
                if let error = apply(result, to: id, name: serviceName) {
                    errors.append(error)
                }
                updateAdvice()
            }
        }

        lastRefreshDate = Date()
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "; ")
        updateAdvice()

        // Parse token logs from Claude Code + Codex on a background priority so
        // file I/O never blocks the main thread; the final assignment hops back
        // to MainActor. `weak self` isn't needed inside a detached task with an
        // explicit MainActor hop — but capturing self by value keeps the
        // Sendable checker happy without racing.
        Task.detached(priority: .utility) { [weak self] in
            let claude = ClaudeCodeTokenParser.shared.parse(days: 7)
            // Start with Claude data, then merge Codex into it
            var dailyBuckets = Dictionary(uniqueKeysWithValues: claude.daily.map { ($0.date, $0) })
            var hourlyBuckets = Dictionary(uniqueKeysWithValues: claude.hourly.map { ($0.hourKey, $0) })
            CodexTokenParser.shared.merge(into: &dailyBuckets, hourly: &hourlyBuckets, days: 7)

            let summary = TokenUsageSummary(
                daily: dailyBuckets.values.sorted { $0.date < $1.date },
                hourly: hourlyBuckets.values.sorted { $0.hourKey < $1.hourKey },
                lastParsed: Date()
            )
            await MainActor.run { [weak self] in
                self?.tokenUsage = summary
            }
        }

        print("🏁 Refresh complete. Errors: \(errorMessage ?? "none")")
    }

    /// Stores one account's result. Returns an error line for the summary, if any.
    private func apply(_ result: Result<UsageData, Error>, to id: UUID, name serviceName: String) -> String? {
        // The row may have been removed while the request was in flight.
        guard let index = services.firstIndex(where: { $0.id == id }) else { return nil }
        switch result {
        case .success(let usage):
            services[index].usage = usage
            services[index].lastError = nil
            services[index].hasLoaded = true
            services[index].computeDelta()
            print("📊 Updated \(serviceName): \(usage.usagePercentage)%")

            let historyEntry = UsageHistoryEntry(
                serviceType: services[index].config.serviceType,
                fiveHourUsage: usage.fiveHourUsage,
                sevenDayUsage: usage.sevenDayUsage
            )
            UsageHistoryStore.shared.saveEntry(historyEntry)
            return nil

        case .failure(let error):
            // Rate limit: keep previous data, don't show as error
            if let apiError = error as? APIError,
               case .rateLimitExceeded(let until) = apiError {
                print("⏳ \(serviceName): rate limited, keeping previous data")
                // A row that has real numbers can quietly keep them. A row
                // that has never loaded cannot: staying silent left it
                // spinning "Updating…" forever with no hint why, which is
                // exactly the state a user reads as "broken".
                if !services[index].hasLoaded {
                    let wait = until.map { Durations.compact($0.timeIntervalSinceNow) }
                    services[index].lastError = wait.map { "요청 제한 — \($0) 뒤 다시 시도 (rate limit)" }
                        ?? "요청이 많아 잠시 후 다시 시도합니다 (rate limit)"
                }
                // A short throttle is worth an early retry. A lockout the
                // provider has timed is not: retrying every account every 75
                // seconds for most of an hour buys nothing, and the regular
                // refresh picks the account up once it lifts.
                if until.map({ $0.timeIntervalSinceNow < 120 }) ?? true {
                    scheduleRateLimitRetry()
                }
                return nil
            }
            services[index].lastError = error.localizedDescription
            return "\(serviceName): \(error.localizedDescription)"
        }
    }

    /// After a 429 on first load, retry well before the normal 5-min cycle so the
    /// card doesn't sit on "Loading". Coalesced so repeated 429s schedule just one.
    private func scheduleRateLimitRetry() {
        guard !rateLimitRetryScheduled else { return }
        rateLimitRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 75) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rateLimitRetryScheduled = false
                await self.refresh(interactive: false)
            }
        }
    }

    /// nonisolated so the refresh TaskGroup can build clients up-front on the
    /// main actor and hand them off; it doesn't touch AppState.
    nonisolated static func createAPIClient(
        for config: ServiceConfig, interactive: Bool, account: ProviderAccount? = nil
    ) -> AIServiceAPI {
        switch config.serviceType {
        case .claude:
            return AnthropicClient(config: config, allowKeychainInteraction: interactive, account: account)
        case .codex:
            return CodexClient(config: config, account: account)
        case .gemini:
            return GeminiClient(config: config)
        }
    }
}

@MainActor
@Observable
class ServiceViewModel: Identifiable {
    let id: UUID
    var config: ServiceConfig
    var usage: UsageData
    var lastError: String?
    /// The specific login this row reports on. nil for providers we can't
    /// enumerate (Gemini) or a machine with no logins yet.
    let account: ProviderAccount?

    var fiveHourDelta: Double = 0
    var sevenDayDelta: Double = 0
    /// When this login's usage was last seen to rise — the evidence that it is
    /// the one being used.
    var lastIncreaseAt: Date?
    var isConsuming: Bool = false
    var consumingDetectedAt: Date?

    private var previousFiveHourUsage: Double?
    private var previousSevenDayUsage: Double?

    init(config: ServiceConfig, usage: UsageData, account: ProviderAccount? = nil) {
        self.id = config.id
        self.config = config
        self.usage = usage
        self.account = account
    }

    /// Label for the account, honouring a user-set nickname.
    var accountLabel: String? {
        account.map { AccountRegistry.shared.displayName(for: $0) }
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
        if fiveHourDelta > 0 || sevenDayDelta > 0 {
            lastIncreaseAt = Date()
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

    /// True once a refresh has succeeded at least once. Until then the row is
    /// still showing `UsageData.placeholder`, whose zeroes would otherwise render
    /// as a confident "100% remaining" bar under a "Loading" badge.
    var hasLoaded: Bool = false

    /// Any failure on a row that has never loaded is an authentication problem in
    /// practice — a monitor can read usage or it can't. Sniffing the message text
    /// for keywords silently missed new wordings (a Keychain-grant prompt read as
    /// "everything is fine, 100% left"), so presence of an error is the signal and
    /// the text is only used to choose which remedy to suggest.
    var isAuthError: Bool { lastError != nil }

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
