import SwiftUI

struct ContentView: View {
    @Bindable var appState: AppState
    @State private var showSettings: Bool = false
    @State private var lastDisappearTime: Date?

    private let autoResetDelay: TimeInterval = 10

    var body: some View {
        let showOnboarding = appState.showMenuBarLegendOnboarding && !showSettings

        ZStack {
            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 0) {
                    if showSettings {
                        SettingsPanel(appState: appState, showSettings: $showSettings)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                    } else {
                        MainPanel(appState: appState, showSettings: $showSettings)
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showSettings)
            }
            .conditionalCompositingGroup(showOnboarding)
            .blur(radius: showOnboarding ? 10 : 0)
            .scaleEffect(showOnboarding ? 0.98 : 1.0)
            .saturation(showOnboarding ? 0.85 : 1.0)
            .brightness(showOnboarding ? -0.02 : 0)
            .animation(.easeInOut(duration: 0.22), value: showOnboarding)
            .allowsHitTesting(!showOnboarding)

            if showOnboarding {
                MenuBarLegendOnboardingOverlay {
                    appState.dismissMenuBarLegendOnboarding()
                }
                .transition(.opacity)
            }
        }
        .frame(width: 300)
        .onAppear {
            if showSettings,
               let lastDisappear = lastDisappearTime,
               Date().timeIntervalSince(lastDisappear) >= autoResetDelay {
                showSettings = false
            }
        }
        .onDisappear {
            lastDisappearTime = Date()
        }
    }
}




struct PulsingLoadingIndicator: View {
    @State private var phase: CGFloat = 0
    @State private var glowOpacity: Double = 0.4

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white.opacity(0.8))
                    .frame(width: 12, height: 12)
                    .blur(radius: 6 + phase * 4)
                    .opacity(glowOpacity)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white.opacity(0.9))
                    .frame(width: 10, height: 10)
                    .shadow(color: .white.opacity(0.6), radius: 4 + phase * 6)
            }
            .frame(width: 24, height: 24)

            Text(L.updating)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                phase = 1
                glowOpacity = 0.9
            }
        }
    }
}

struct SpinningRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    @State private var rotation: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(rotation))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            if refreshing {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    rotation = 0
                }
            }
        }
    }
}

extension View {
    /// Apply `.compositingGroup()` only when needed (e.g. blur overlay active).
    /// Avoids the expensive offscreen render pass during normal interaction.
    @ViewBuilder
    func conditionalCompositingGroup(_ active: Bool) -> some View {
        if active {
            self.compositingGroup()
        } else {
            self
        }
    }
}

struct StaggerAppear: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(
                .spring(response: 0.45, dampingFraction: 0.8).delay(delay),
                value: appeared
            )
    }
}

struct PulseEffect: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.15 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

enum PanelTab { case usage, load }

struct MainPanel: View {
    @Bindable var appState: AppState
    @Binding var showSettings: Bool

    @State private var appeared = false
    @State private var showLegendHelp = false
    @State private var tab: PanelTab = .usage

    private var loadTabEnabled: Bool { AppDefaults.userDefaults.object(forKey: "loadTabEnabled") as? Bool ?? true }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Token Burn")
                        .font(.system(size: 16, weight: .bold))

                    if appState.tokenUsage.todayTokens > 0 {
                        Text("· \(formatTokens(appState.tokenUsage.todayTokens)) today")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }

                Spacer()

                Button {
                    showLegendHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .popover(isPresented: $showLegendHelp) {
                    MenuBarLegendContent(showsDescription: true)
                        .padding(14)
                        .frame(width: 280)
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if loadTabEnabled {
                Picker("", selection: $tab) {
                    Text(L.tabUsage).tag(PanelTab.usage)
                    Text(L.tabLoad).tag(PanelTab.load)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            if tab == .load && loadTabEnabled {
                LoadView()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            } else {
                VStack(spacing: 14) {
                    HStack(spacing: enabledServices.count >= 3 ? 20 : 32) {
                        ForEach(Array(enabledServices.enumerated()), id: \.element.id) { index, service in
                            CircularGaugeView(service: service, compact: enabledServices.count >= 3)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 12)
                                .animation(
                                    .spring(response: 0.5, dampingFraction: 0.7)
                                        .delay(Double(index) * 0.08),
                                    value: appeared
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    VStack(spacing: 10) {
                        ForEach(Array(enabledServices.enumerated()), id: \.element.id) { index, service in
                            DetailCard(
                                service: service,
                                onRefresh: { Task { await appState.refresh(interactive: true) } }
                            )
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 16)
                                .animation(
                                    .spring(response: 0.5, dampingFraction: 0.75)
                                        .delay(0.15 + Double(index) * 0.08),
                                    value: appeared
                                )
                        }
                    }

                    TokenUsageView(summary: appState.tokenUsage)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(
                            .spring(response: 0.5, dampingFraction: 0.75).delay(0.3),
                            value: appeared
                        )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Divider().opacity(0.3).padding(.horizontal, 16)

            HStack {
                if appState.isRefreshing {
                    PulsingLoadingIndicator()
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else if let lastRefresh = appState.lastRefreshDate {
                    Text(formatLastUpdate(lastRefresh))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }

                Spacer()

                SpinningRefreshButton(isRefreshing: appState.isRefreshing) {
                    Task { await appState.refresh(interactive: true) }
                }

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .opacity(0.5)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .animation(.easeInOut(duration: 0.3), value: appState.isRefreshing)
        }
        .onAppear {
            withAnimation { appeared = true }
        }
    }

    private var enabledServices: [ServiceViewModel] {
        appState.services.filter { $0.config.isEnabled }
    }

    private func formatLastUpdate(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let seconds = Int(interval)
        let minutes = seconds / 60
        let hours = minutes / 60

        let timeText: String
        if hours > 0 {
            timeText = "\(hours)h \(minutes % 60)m"
        } else if minutes > 0 {
            timeText = "\(minutes)m \(seconds % 60)s"
        } else {
            timeText = "\(seconds)s"
        }

        return "\(L.lastUpdate): \(timeText) \(L.ago)"
    }
}

struct SettingsPanel: View {
    @Bindable var appState: AppState
    @Binding var showSettings: Bool

    @State private var appeared = false
    @State private var showBugReport = false
    @State private var apiKeyDraft: String = ""

    var body: some View {
        if showBugReport {
            BugReportPanel(isPresented: $showBugReport)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
        } else {
            settingsContent
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Button {
                    showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                Text(L.settings)
                    .font(.system(size: 16, weight: .bold))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 14) {
                    // MARK: - Services
                    settingsSection(title: L.services, delay: 0.0) {
                        VStack(spacing: 0) {
                            settingsServiceRow(
                                icon: "brain.head.profile",
                                iconColor: ServiceType.claude.brandColor,
                                name: "Claude",
                                isOn: claudeEnabledBinding,
                                tintColor: ServiceType.claude.brandColor
                            )
                            Divider().opacity(0.2).padding(.leading, 52)
                            settingsServiceRow(
                                icon: "terminal",
                                iconColor: ServiceType.codex.brandColor,
                                name: "Codex",
                                isOn: codexEnabledBinding,
                                tintColor: ServiceType.codex.brandColor
                            )
                        }
                        .padding(4)
                        .premiumCard()
                    }

                    // MARK: - General
                    settingsSection(title: L.general, delay: 0.06) {
                        VStack(spacing: 0) {
                            settingsRow(icon: "lock.open", iconColor: .secondary) {
                                Text(L.launchAtLogin)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { appState.launchAtLogin },
                                    set: { appState.setLaunchAtLogin($0) }
                                ))
                                .toggleStyle(.switch)
                                .tint(ServiceType.codex.brandColor)
                                .labelsHidden()
                                .scaleEffect(0.7)
                                .frame(width: 38, height: 22)
                            }

                            Divider().opacity(0.2).padding(.leading, 52)

                            settingsRow(icon: "clock", iconColor: .secondary) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L.refreshInterval)
                                        .font(.system(size: 13, weight: .medium))
                                    Picker("", selection: refreshIntervalBinding) {
                                        Text("1m").tag(TimeInterval(60))
                                        Text("5m").tag(TimeInterval(300))
                                        Text("15m").tag(TimeInterval(900))
                                        Text("30m").tag(TimeInterval(1800))
                                    }
                                    .pickerStyle(.segmented)
                                }
                            }

                            Divider().opacity(0.2).padding(.leading, 52)

                            settingsRow(icon: "eye", iconColor: .secondary) {
                                Text(L.activityDetection)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { appState.activityDetectionEnabled },
                                    set: { appState.setActivityDetection($0) }
                                ))
                                .toggleStyle(.switch)
                                .tint(ServiceType.codex.brandColor)
                                .labelsHidden()
                                .scaleEffect(0.7)
                                .frame(width: 38, height: 22)
                            }

                            Divider().opacity(0.2).padding(.leading, 52)

                            settingsRow(icon: "globe", iconColor: .secondary) {
                                Text(L.language)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Menu {
                                    ForEach(Language.allCases, id: \.self) { lang in
                                        Button {
                                            L.currentLanguage = lang
                                        } label: {
                                            if L.currentLanguage == lang {
                                                Label(lang.displayName, systemImage: "checkmark")
                                            } else {
                                                Text(lang.displayName)
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(L.currentLanguage.displayName)
                                            .font(.system(size: 12))
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.roundedRectangle(radius: 8))
                            }
                        }
                        .padding(4)
                        .premiumCard()
                    }

                    // MARK: - Update
                    settingsSection(title: L.update, delay: 0.12) {
                        VStack(spacing: 10) {
                            HStack {
                                settingsIcon(systemName: "arrow.triangle.2.circlepath", color: .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Version")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("v\(currentVersion)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button {
                                    Updater.shared.checkForUpdates()
                                } label: {
                                    Text(L.checkUpdate)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                            }

                            if Updater.shared.updateAvailable, let latest = Updater.shared.latestVersion {
                                Divider().opacity(0.2)
                                Button {
                                    Updater.shared.installUpdate()
                                } label: {
                                    HStack(spacing: 8) {
                                        if Updater.shared.isUpdating {
                                            ProgressView().controlSize(.small).tint(.white)
                                        } else {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .font(.system(size: 16, weight: .semibold))
                                        }
                                        Text(Updater.shared.isUpdating
                                             ? L.updating
                                             : "\(L.updateNow) · v\(latest)")
                                            .font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Color.accentColor)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(Updater.shared.isUpdating)
                            }
                        }
                        .padding(10)
                        .premiumCard()
                    }

                    // MARK: - Thermal Advisor
                    settingsSection(title: L.thermalAdvisor, delay: 0.15) {
                        thermalAdvisorCard
                    }

                    // MARK: - Support
                    settingsSection(title: L.support, delay: 0.18) {
                        VStack(spacing: 0) {
                            Button { showBugReport = true } label: {
                                settingsRow(icon: "ladybug", iconColor: .secondary) {
                                    Text(L.bugReport)
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.quaternary)
                                }
                            }
                            .buttonStyle(.plain)

                            Divider().opacity(0.2).padding(.leading, 52)

                            Button {
                                if let url = URL(string: "https://github.com/multi-turn-inc/ai-usage-meter") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                settingsRow(icon: "star.fill", iconColor: .yellow) {
                                    Text(L.starOnGitHub)
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.quaternary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(4)
                        .premiumCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            withAnimation { appeared = true }
        }
        .onDisappear { appeared = false }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showBugReport)
    }

    // MARK: - Thermal Advisor

    @ViewBuilder
    private var thermalAdvisorCard: some View {
        let advisor = ThermalAdvisor.shared
        // Config only — the live load gauges + diagnosis live in the main panel's
        // Load tab. Here the user toggles the Load tab, sets the key (for AI
        // diagnosis), and the auto-when-hot opt-in.
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { AppDefaults.userDefaults.object(forKey: "loadTabEnabled") as? Bool ?? true },
                set: { AppDefaults.userDefaults.set($0, forKey: "loadTabEnabled") }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.loadTab)
                        .font(.system(size: 13, weight: .medium))
                    Text(L.loadTabDesc)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(.accentColor)

            Divider().opacity(0.2)

            VStack(alignment: .leading, spacing: 4) {
                Text(L.anthropicKey)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    SecureField("sk-ant-...", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button(L.save) { advisor.setAPIKey(apiKeyDraft) }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.glass)
                        .disabled(apiKeyDraft.isEmpty)
                }
            }

            Divider().opacity(0.2)

            Toggle(isOn: Binding(
                get: { advisor.isEnabled },
                set: { advisor.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.autoDiagnoseWhenHot)
                        .font(.system(size: 13, weight: .medium))
                    Text(L.thermalAdvisorPrivacy)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(.accentColor)
            .disabled(!advisor.hasAPIKey)
        }
        .padding(12)
        .premiumCard()
        .onAppear {
            // Seed once; don't clobber an unsaved edit on re-appear.
            if apiKeyDraft.isEmpty { apiKeyDraft = advisor.apiKey ?? "" }
        }
    }

    // MARK: - Settings Helpers

    private func settingsSection<Content: View>(title: String, delay: Double, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.leading, 4)

            content()
        }
        .modifier(StaggerAppear(appeared: appeared, delay: delay))
    }

    private func settingsServiceRow(icon: String, iconColor: Color, name: String, isOn: Binding<Bool>, tintColor: Color) -> some View {
        HStack(spacing: 10) {
            settingsIcon(systemName: icon, color: iconColor)

            Text(name)
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(tintColor)
                .labelsHidden()
                .scaleEffect(0.7)
                .frame(width: 38, height: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func settingsRow<Content: View>(icon: String, iconColor: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            settingsIcon(systemName: icon, color: iconColor)
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func settingsIcon(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.1))
            )
    }

    private var currentVersion: String {
        Updater.appVersion
    }

    private var claudeEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.services.first { $0.config.serviceType == .claude }?.config.isEnabled ?? true },
            set: { newValue in
                if let idx = appState.services.firstIndex(where: { $0.config.serviceType == .claude }) {
                    appState.services[idx].config.isEnabled = newValue
                    appState.persistServiceConfigs()
                }
            }
        )
    }

    private var codexEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.services.first { $0.config.serviceType == .codex }?.config.isEnabled ?? true },
            set: { newValue in
                if let idx = appState.services.firstIndex(where: { $0.config.serviceType == .codex }) {
                    appState.services[idx].config.isEnabled = newValue
                    appState.persistServiceConfigs()
                }
            }
        )
    }

    private var geminiEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.services.first { $0.config.serviceType == .gemini }?.config.isEnabled ?? true },
            set: { newValue in
                if let idx = appState.services.firstIndex(where: { $0.config.serviceType == .gemini }) {
                    appState.services[idx].config.isEnabled = newValue
                    appState.persistServiceConfigs()
                }
            }
        )
    }

    private var refreshIntervalBinding: Binding<TimeInterval> {
        Binding(
            get: { appState.services.first?.config.refreshInterval ?? 300 },
            set: { newValue in
                for i in appState.services.indices {
                    appState.services[i].config.refreshInterval = newValue
                }
                appState.updateRefreshInterval(newValue)
            }
        )
    }
}

struct CircularGaugeView: View {
    let service: ServiceViewModel
    var compact: Bool = false

    @State private var animatedFiveHour: Double = 0
    @State private var animatedSevenDay: Double = 0
    @State private var appeared = false
    @State private var pulseScale: CGFloat = 1.0

    private var outerSize: CGFloat { compact ? 68 : 82 }
    private var innerSize: CGFloat { compact ? 52 : 64 }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                service.brandColor.opacity(0.08),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: outerSize / 2
                        )
                    )
                    .frame(width: outerSize + 12, height: outerSize + 12)
                    .scaleEffect(pulseScale)

                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 5.5)
                    .frame(width: outerSize, height: outerSize)

                Circle()
                    .trim(from: 0, to: CGFloat(animatedFiveHour))
                    .stroke(
                        AngularGradient(
                            colors: [service.brandColor.opacity(0.4), service.brandColor],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * animatedFiveHour)
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: outerSize, height: outerSize)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: service.brandColor.opacity(0.3), radius: 4)

                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 4)
                    .frame(width: innerSize, height: innerSize)

                Circle()
                    .trim(from: 0, to: CGFloat(animatedSevenDay))
                    .stroke(
                        service.brandColor.opacity(0.5),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                    )
                    .frame(width: innerSize, height: innerSize)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: service.brandColor.opacity(0.2), radius: 3)
            
                if service.isAuthError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.yellow)
                        .modifier(PulseEffect())
                } else {
                    VStack(spacing: compact ? -2 : -1) {
                        Text("\(Int(animatedFiveHour * 100))")
                            .font(.system(size: compact ? 20 : 24, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("\(Int(animatedSevenDay * 100))")
                            .font(.system(size: compact ? 12 : 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }
            .scaleEffect(appeared ? 1.0 : 0.6)
            .opacity(appeared ? 1 : 0)

            Text(service.name)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(service.isAuthError ? .secondary : .primary)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) {
                appeared = true
            }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.2)) {
                animatedFiveHour = fiveHourRemaining
                animatedSevenDay = sevenDayRemaining
            }
        }
        .onChange(of: fiveHourRemaining) { _, newValue in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) {
                animatedFiveHour = newValue
            }
            triggerPulse()
        }
        .onChange(of: sevenDayRemaining) { _, newValue in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) {
                animatedSevenDay = newValue
            }
        }
    }

    private func triggerPulse() {
        withAnimation(.easeOut(duration: 0.15)) { pulseScale = 1.08 }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.5).delay(0.15)) { pulseScale = 1.0 }
    }

    private var fiveHourRemaining: Double {
        if service.isAuthError { return 0 }
        let usage = service.fiveHourUsage ?? service.usagePercentage
        return max(0, (100.0 - usage)) / 100.0
    }

    private var sevenDayRemaining: Double {
        if service.isAuthError { return 0 }
        let usage = service.sevenDayUsage ?? 0
        return max(0, (100.0 - usage)) / 100.0
    }
}

/// The "Load" tab: a 2-axis load box (width = CPU, height = GPU, color = RAM),
/// the top-CPU process list, and an optional on-demand AI diagnosis.
struct LoadView: View {
    private var load = SystemLoadMonitor.shared
    private var advisor = ThermalAdvisor.shared

    private let boxW: CGFloat = 196
    private let boxH: CGFloat = 116

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                loadGauge
                processList
                Divider().opacity(0.2)
                aiSection
            }
            .padding(12)
        }
        .frame(maxHeight: 560)
        .premiumCard()
        .task {
            // Sample while the tab is open; auto-cancels when it closes. The first
            // CPU read only seeds the tick baseline, so sample once, then loop.
            // Load is cheap (in-process) → 1s for a dense, smooth trail; the
            // process list shells out to `ps`, so refresh it only every 3s.
            load.sample()
            await advisor.sampleNow()
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                load.sample()
                tick += 1
                if tick % 3 == 0 { await advisor.sampleNow() }
            }
        }
    }

    // MARK: 2-axis gauge

    private var loadGauge: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                // GPU (vertical axis)
                VStack(spacing: 1) {
                    Text("GPU").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(Int(load.gpu.rounded()))%").font(.system(size: 13, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                }
                .frame(width: 36)

                LoadTrajectory(load: load)
                    .frame(width: boxW, height: boxH)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .separatorColor).opacity(0.10))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 1)
                    )
            }

            // CPU (horizontal axis) — aligned under the box, not the GPU label
            HStack(spacing: 6) {
                Spacer().frame(width: 44)
                Text("CPU").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(Int(load.cpu.rounded()))%").font(.system(size: 13, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Spacer()
            }

            // RAM legend (the trail color)
            HStack(spacing: 6) {
                Spacer().frame(width: 44)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LoadTrajectory.ramColor(load.ram).gradient)
                    .frame(width: 12, height: 12)
                Text("\(L.ram) \(Int(load.ram.rounded()))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: process list

    @ViewBuilder
    private var processList: some View {
        if !advisor.topProcesses.isEmpty {
            VStack(spacing: 3) {
                Text(L.topCPU)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(advisor.topProcesses) { p in
                    HStack {
                        Text(p.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(p.cpu.rounded()))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(p.cpu >= 50 ? Color.orange : Color.secondary)
                    }
                }
            }
        }
    }

    // MARK: AI diagnosis

    @ViewBuilder
    private var aiSection: some View {
        if advisor.hasAPIKey {
            Button {
                advisor.diagnoseNow()
            } label: {
                HStack(spacing: 6) {
                    if advisor.isDiagnosing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 11))
                    }
                    Text(advisor.isDiagnosing ? L.updating : L.aiDiagnose)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(advisor.isDiagnosing)

            if let diagnosis = advisor.diagnosis {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(diagnosis)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }
            if let err = advisor.lastError {
                Text(err).font(.system(size: 10)).foregroundStyle(.red)
            }
        } else {
            Text(L.thermalAdvisorNeedsKey)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The load gauge: a translucent, glassy 3D rounded rectangle that grows from the
/// bottom-left — width = CPU, height = GPU — with its fill color = RAM pressure.
/// Faint outlines of recent sizes linger behind it (the trajectory of the size
/// change). The size eases from the previous sample to the newest and is redrawn
/// every display frame via TimelineView, with a gentle breathing + moving sheen,
/// so it feels like a fluid, living volume at 60 fps.
/// Moves toward the latest sample at a CONSTANT speed (a fixed %/second), so the
/// rate of change feels uniform — no accelerate-near-far easing, no per-sample
/// restart. It glides at the same pace whether the target is close or far, and
/// simply holds once it arrives.
final class LoadSmoother {
    var cpu = 0.0, gpu = 0.0, ram = 0.0
    private var lastTick: Date?
    private let speed = 42.0       // percent per second (constant) for CPU/GPU
    private let ramSpeed = 30.0    // RAM color shifts a touch more slowly

    func advance(toCPU tc: Double, gpu tg: Double, ram tr: Double, now: Date) {
        let dt = lastTick.map { max(0, now.timeIntervalSince($0)) } ?? 0
        lastTick = now
        cpu = step(cpu, tc, speed * dt)
        gpu = step(gpu, tg, speed * dt)
        ram = step(ram, tr, ramSpeed * dt)
    }

    private func step(_ current: Double, _ target: Double, _ maxDelta: Double) -> Double {
        let d = target - current
        if abs(d) <= maxDelta { return target }
        return current + (d < 0 ? -maxDelta : maxDelta)
    }
}

struct LoadTrajectory: View {
    var load: SystemLoadMonitor
    @State private var smoother = LoadSmoother()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                draw(ctx, size, now: timeline.date)
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, now: Date) {
        // faint grid
        let grid = Color.gray.opacity(0.10)
        for f in [0.25, 0.5, 0.75] {
            var v = Path(); v.move(to: CGPoint(x: size.width * f, y: 0)); v.addLine(to: CGPoint(x: size.width * f, y: size.height))
            ctx.stroke(v, with: .color(grid), lineWidth: 0.5)
            var h = Path(); h.move(to: CGPoint(x: 0, y: size.height * f)); h.addLine(to: CGPoint(x: size.width, y: size.height * f))
            ctx.stroke(h, with: .color(grid), lineWidth: 0.5)
        }

        let hist = load.history
        guard !hist.isEmpty else { return }

        func rrect(cpu: Double, gpu: Double, radius: CGFloat) -> (Path, CGRect) {
            let w = max(10, CGFloat(min(max(cpu, 0), 100) / 100) * size.width)
            let h = max(10, CGFloat(min(max(gpu, 0), 100) / 100) * size.height)
            let rect = CGRect(x: 0, y: size.height - h, width: w, height: h)
            return (Path(roundedRect: rect, cornerRadius: radius), rect)
        }

        // Ghost trail of past sizes (the trajectory of the size change).
        let n = hist.count
        let step = max(1, n / 12)
        for i in stride(from: 0, to: n - 1, by: step) {
            let p = hist[i]
            let frac = Double(i) / Double(max(n - 1, 1))   // 0 oldest → 1 newest
            let (path, _) = rrect(cpu: p.cpu, gpu: p.gpu, radius: 8)
            ctx.stroke(path, with: .color(Self.ramColor(p.ram).opacity(0.05 + frac * 0.10)), lineWidth: 1)
        }

        // Chase the latest sample at a constant speed (uniform rate of change).
        smoother.advance(toCPU: load.cpu, gpu: load.gpu, ram: load.ram, now: now)
        let phase = now.timeIntervalSinceReferenceDate
        let cpu = smoother.cpu
        let gpu = smoother.gpu
        let color = Self.ramColor(smoother.ram)

        let (body, rect) = rrect(cpu: cpu, gpu: gpu, radius: 11)

        // Soft outer glow for depth.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 12))
            layer.fill(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 12),
                       with: .color(color.opacity(0.45)))
        }

        // Translucent 3D body: lighter top → deeper bottom.
        ctx.fill(body, with: .linearGradient(
            Gradient(colors: [color.opacity(0.72), color.opacity(0.40)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)))

        // Glass sheen on the upper portion, gently sliding for a fluid feel.
        ctx.drawLayer { layer in
            layer.clip(to: body)
            let shift = CGFloat(sin(phase * 0.7)) * rect.width * 0.12
            let sheen = CGRect(x: rect.minX - rect.width * 0.2 + shift, y: rect.minY,
                               width: rect.width * 0.7, height: max(8, rect.height * 0.5))
            layer.fill(Path(roundedRect: sheen, cornerRadius: 10),
                       with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.0), .white.opacity(0.30), .white.opacity(0.0)]),
                        startPoint: CGPoint(x: sheen.minX, y: rect.minY),
                        endPoint: CGPoint(x: sheen.maxX, y: rect.minY)))
        }

        // Glassy edge highlight.
        ctx.stroke(body, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.55), .white.opacity(0.12)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)), lineWidth: 1)
    }

    /// Smooth green → red by RAM pressure.
    static func ramColor(_ r: Double) -> Color {
        let x = min(max(r, 0), 100) / 100
        return Color(hue: 0.33 * (1 - x), saturation: 0.75, brightness: 0.95)
    }
}

struct DetailCard: View {
    let service: ServiceViewModel
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                Circle()
                    .fill(service.isAuthError ? ThemeManager.shared.current.statusDanger : service.brandColor)
                    .frame(width: 8, height: 8)

                Text(service.name)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                if service.isAuthError {
                    Text("재인증 필요")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ThemeManager.shared.current.statusDanger)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.regular.tint(ThemeManager.shared.current.statusDanger.opacity(0.25)), in: .capsule)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text(formattedPlan)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(service.brandColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.regular.tint(service.brandColor.opacity(0.25)), in: .capsule)
                }
            }

            if service.isAuthError {
                AuthErrorView(service: service, onRefresh: onRefresh)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                HStack(spacing: 16) {
                    UsageBar(
                        label: primaryLabel,
                        percentage: max(0, 100 - (service.fiveHourUsage ?? service.usagePercentage)),
                        resetText: primaryResetText,
                        color: service.brandColor
                    )

                    if let sevenDay = service.sevenDayUsage {
                        UsageBar(
                            label: secondaryLabel,
                            percentage: max(0, 100 - sevenDay),
                            resetText: formatReset(service.sevenDayResetDate),
                            color: service.brandColor.opacity(0.5)
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))

                staleWarningRow
            }
        }
        .padding(12)
        .premiumCard()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: service.isAuthError)
    }

    /// Nothing while data is fresh. Only when it's stale (>10 min — more than two
    /// missed 5-min cycles) does an orange warning appear, so a frozen value from a
    /// failed refresh isn't mistaken for the current number.
    @ViewBuilder
    private var staleWarningRow: some View {
        let interval = max(0, Date().timeIntervalSince(service.usage.lastUpdated))
        if interval > 600 {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 8, weight: .semibold))
                Text(relativeAge(interval))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(L.dataStale)
        }
    }

    private func relativeAge(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    private var isGemini: Bool {
        service.config.serviceType == .gemini
    }

    private var primaryLabel: String {
        isGemini ? "Pro" : "5h"
    }

    private var secondaryLabel: String {
        isGemini ? "Flash" : "7d"
    }

    private var formattedPlan: String {
        let tier = service.tier.lowercased()
        if tier.contains("max") {
            return "Max"
        } else if tier.contains("pro") {
            return "Pro"
        } else if tier.contains("team") {
            return "Team"
        } else if tier.contains("enterprise") {
            return "Enterprise"
        } else if tier.contains("free") {
            return "Free"
        }
        return service.tier.components(separatedBy: "_").last?.capitalized ?? service.tier
    }

    private var primaryResetText: String? {
        let usage = service.fiveHourUsage ?? service.usagePercentage
        if usage < 1 && !isGemini {
            return L.resetOnUse
        }
        return formatReset(service.resetDate)
    }

    private func formatReset(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return nil }

        let totalMinutes = Int(interval / 60)
        if totalMinutes < 60 {
            return L.formatResetTime(L.formatMinutes(totalMinutes))
        }

        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours < 24 {
            let timeText = L.formatHoursMinutes(hours, minutes)
            return L.formatResetTime(timeText)
        }

        let days = Int(interval / 86400)
        let remainingHours = Int((interval.truncatingRemainder(dividingBy: 86400)) / 3600)
        let timeText = L.formatDaysHours(days, remainingHours)
        return L.formatResetTime(timeText)
    }
}

struct AuthErrorView: View {
    let service: ServiceViewModel
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 14))
                    .modifier(PulseEffect())

                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button(action: openTerminalWithCommand) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 11))
                        Text(buttonLabel)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.glass)

                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var needsLogout: Bool {
        guard let error = service.lastError?.lowercased() else { return false }
        return error.contains("scope") || error.contains("permission") || error.contains("403")
            || error.contains("/logout")
    }

    private var errorMessage: String {
        if let error = service.lastError {
            let lower = error.lowercased()
            if lower.contains("scope") || lower.contains("permission") {
                return "토큰 권한이 부족합니다. 로그아웃 후 재로그인해주세요."
            }
            if lower.contains("만료") || lower.contains("expired") || lower.contains("revoke") {
                return "토큰이 만료되었습니다. 재로그인해주세요."
            }
        }
        switch service.config.serviceType {
        case .claude: return "Claude 인증이 필요합니다."
        case .gemini: return "Gemini 인증이 필요합니다."
        case .codex: return "Codex 인증이 필요합니다."
        }
    }

    private var buttonLabel: String {
        switch service.config.serviceType {
        case .claude: return needsLogout ? "로그아웃 후 재로그인" : "claude 실행하기"
        case .gemini: return "gemini auth 실행하기"
        case .codex: return "codex 실행하기"
        }
    }

    private func openTerminalWithCommand() {
        let command: String
        switch service.config.serviceType {
        case .claude:
            command = needsLogout ? "claude /logout && claude" : "claude"
        case .gemini:
            command = "gemini"
        case .codex:
            command = "codex"
        }

        let scriptPath = NSTemporaryDirectory() + "aimonitor-reauth.command"
        let scriptContent = "#!/bin/bash\necho '🔄 재인증 중...'\n\(command)\necho ''\necho '✅ 완료! 이 창을 닫아도 됩니다.'\nread -p ''\n"
        try? scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        NSWorkspace.shared.open(URL(fileURLWithPath: scriptPath))
    }
}

struct UsageBar: View {
    let label: String
    let percentage: Double
    let resetText: String?
    let color: Color

    @State private var animatedPercentage: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(Int(animatedPercentage))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                let barWidth = geo.size.width * CGFloat(animatedPercentage) / 100
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(Color(nsColor: .separatorColor).opacity(0.2))
                        .frame(height: 7)

                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.75), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: barWidth, height: 7)
                        .shadow(color: color.opacity(0.25), radius: 3, y: 1)
                }
            }
            .frame(height: 7)

            if let reset = resetText {
                Text(reset)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.1)) {
                animatedPercentage = percentage
            }
        }
        .onChange(of: percentage) { _, newValue in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                animatedPercentage = newValue
            }
        }
    }
}

struct UpdateSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.update)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack {
                Text("v\(currentVersion)")
                    .font(.subheadline)

                Spacer()

                Button {
                    Updater.shared.checkForUpdates()
                } label: {
                    Text(L.checkUpdate)
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, 16)
    }

    private var currentVersion: String {
        Updater.appVersion
    }
}

struct HelpPanel: View {
    @Binding var isPresented: Bool
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        isPresented = false
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                Text(L.menuBarLegendTitle)
                    .font(.system(size: 16, weight: .bold))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 16) {
                    Text(L.menuBarLegendDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05), value: appeared)

                    MenuBarLegendDiagram(isPresented: appeared)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

                    HStack(spacing: 8) {
                        MenuBarLegendExplainCard(
                            symbol: "arrow.left.and.right",
                            title: "5h",
                            description: L.menuBarLegendHorizontal
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

                        MenuBarLegendExplainCard(
                            symbol: "arrow.up.and.down",
                            title: "7d",
                            description: L.menuBarLegendVertical
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25), value: appeared)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            withAnimation { appeared = true }
        }
        .onDisappear { appeared = false }
    }
}

private struct MenuBarLegendExplainCard: View {
    let symbol: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.2))
                )
        )
    }
}

struct SupportSection: View {
    @Binding var showBugReport: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.support)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(spacing: 8) {
                Button {
                    showBugReport = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ladybug")
                            .font(.system(size: 12))
                        Text(L.bugReport)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 10))

                Button {
                    if let url = URL(string: FeedbackConfig.donationURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "heart")
                            .font(.system(size: 12))
                        Text(L.donate)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 10))
            }
        }
        .padding(.horizontal, 16)
    }
}

struct BugReportPanel: View {
    @Binding var isPresented: Bool
    @State private var reportText: String = ""
    @State private var includeDiagnostics: Bool = true
    @State private var showDiagnosticPreview: Bool = false
    @State private var isSending = false
    @State private var sent = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                Text(L.bugReport)
                    .font(.system(size: 16, weight: .bold))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if sent {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text(L.bugReportSent)
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .transition(.scale.combined(with: .opacity))
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        TextEditor(text: $reportText)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.3))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color(nsColor: .separatorColor).opacity(0.3))
                                    )
                            )
                            .frame(minHeight: 100)
                            .overlay(alignment: .topLeading) {
                                if reportText.isEmpty {
                                    Text(L.bugReportPlaceholder)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 18)
                                        .allowsHitTesting(false)
                                }
                            }

                        // Diagnostics toggle
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "stethoscope")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text(L.includeDiagnostics)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Toggle("", isOn: $includeDiagnostics)
                                    .toggleStyle(.switch)
                                    .tint(.accentColor)
                                    .labelsHidden()
                                    .scaleEffect(0.7)
                                    .frame(width: 36, height: 20)
                            }

                            if includeDiagnostics {
                                Button {
                                    showDiagnosticPreview.toggle()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(L.viewDiagnostics)
                                            .font(.system(size: 11))
                                        Image(systemName: showDiagnosticPreview ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)

                                if showDiagnosticPreview {
                                    Text(DiagnosticCollector.collect())
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.2))
                                        )
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color(nsColor: .separatorColor).opacity(0.2))
                                )
                        )
                        .animation(.easeInOut(duration: 0.2), value: includeDiagnostics)
                        .animation(.easeInOut(duration: 0.2), value: showDiagnosticPreview)

                        HStack {
                            Spacer()
                            Button {
                                sendReport()
                            } label: {
                                HStack(spacing: 6) {
                                    if isSending {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .frame(width: 14, height: 14)
                                    } else {
                                        Image(systemName: "paperplane.fill")
                                            .font(.system(size: 12))
                                    }
                                    Text(L.send)
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                            .disabled(reportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: sent)
    }

    private func sendReport() {
        let text = reportText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSending = true

        let diagnostics = includeDiagnostics ? DiagnosticCollector.collect() : nil
        var htmlBody = "<h3>Bug Report</h3><p>\(text.replacingOccurrences(of: "\n", with: "<br>"))</p>"
        if let diag = diagnostics {
            htmlBody += "<h4>Diagnostics</h4><pre>\(diag)</pre>"
        }

        let payload: [String: Any] = [
            "from": "Token Burn <onboarding@resend.dev>",
            "to": [FeedbackConfig.feedbackEmail],
            "subject": "Bug Report — Token Burn",
            "html": htmlBody
        ]

        guard let url = URL(string: "https://api.resend.com/emails"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            isSending = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(FeedbackConfig.resendAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                isSending = false
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    withAnimation { sent = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isPresented = false
                    }
                }
            }
        }.resume()
    }
}

enum DiagnosticCollector {
    static func collect() -> String {
        var lines: [String] = []

        // App
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        lines.append("App: v\(appVersion)")

        // macOS
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        // Locale
        lines.append("Locale: \(Locale.current.identifier)")

        // Claude Code version
        let claudeVersion = shellOutput("claude --version") ?? "not found"
        lines.append("Claude Code: \(claudeVersion)")

        // Keychain credentials
        let creds = KeychainManager.shared.getClaudeCodeCredentials(allowInteraction: false)
        if let creds {
            lines.append("Token: \(creds.isExpired ? "expired" : "valid")")
            if let tier = creds.rateLimitTier {
                lines.append("Tier: \(tier)")
            }
            if let scopes = creds.scopes {
                lines.append("Scopes: \(scopes.joined(separator: ", "))")
            }
        } else {
            lines.append("Token: not found")
        }

        // Credential file paths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let credPaths = [
            "\(home)/.claude/.credentials.json",
            "\(home)/.config/claude/.credentials.json",
            "\(home)/.config/claude-code/.credentials.json"
        ]
        let existingFiles = credPaths.filter { FileManager.default.fileExists(atPath: $0) }
        lines.append("Cred files: \(existingFiles.isEmpty ? "none" : existingFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")

        // Keychain entries count
        let entryCount = countKeychainEntries()
        lines.append("Keychain entries: \(entryCount)")

        return lines.joined(separator: "\n")
    }

    private static func shellOutput(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + 3
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func countKeychainEntries() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            return items.count
        }
        return 0
    }
}

enum FeedbackConfig {
    static var resendAPIKey: String {
        Bundle.main.object(forInfoDictionaryKey: "ResendAPIKey") as? String ?? ""
    }
    static var feedbackEmail: String {
        Bundle.main.object(forInfoDictionaryKey: "FeedbackEmail") as? String ?? ""
    }
    static var donationURL: String {
        Bundle.main.object(forInfoDictionaryKey: "DonationURL") as? String ?? ""
    }
}

struct ServiceToggle: View {
    let name: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(name)
                .font(.subheadline)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(color)
                .labelsHidden()
                .scaleEffect(0.75)
                .frame(width: 38, height: 22)
        }
    }
}
