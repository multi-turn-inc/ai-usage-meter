import AppKit
import SwiftUI
import AIUsageMeterCore

struct SettingsPanel: View {
    @Bindable var appState: AppState
    @Binding var showSettings: Bool

    @State private var appeared = false
    @State private var showBugReport = false

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

                    // MARK: - Accounts
                    settingsSection(title: L.accounts, delay: 0.03) {
                        accountsCard
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

    // MARK: - Accounts

    /// Lists every login found on the machine with a monitor toggle. "Remove"
    /// only hides a discovered account — deleting someone's actual credentials
    /// isn't this app's call — except for accounts it added itself, whose config
    /// home it owns.
    @ViewBuilder
    private var accountsCard: some View {
        let registry = AccountRegistry.shared
        let accounts = registry.allAccounts()

        VStack(spacing: 0) {
            if accounts.isEmpty {
                Text(L.noAccountsFound)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }

            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider().opacity(0.2).padding(.leading, 40) }
                HStack(spacing: 10) {
                    Image(systemName: account.service.iconName)
                        .font(.system(size: 12))
                        .foregroundStyle(account.service.brandColor)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        // Editable nickname. The discovered label stays as the
                        // placeholder so clearing the field reverts to it.
                        TextField(account.label, text: aliasBinding(for: account))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(accountSourceNote(account))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if !account.isDefault {
                        Button {
                            registry.remove(account)
                            appState.reloadAccounts()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(registry.canDelete(account) ? L.removeAccount : L.dismissAccount)
                    }

                    Toggle("", isOn: Binding(
                        get: { !registry.isHidden(account.id) },
                        set: { shown in
                            registry.setHidden(!shown, for: account.id)
                            appState.reloadAccounts()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(account.service.brandColor)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
            }

            if registry.dismissedCount > 0 {
                Divider().opacity(0.2)
                Button {
                    registry.restoreDismissed()
                    appState.reloadAccounts()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9))
                        Text("\(L.restoreRemoved) (\(registry.dismissedCount))")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.2)

            HStack(spacing: 8) {
                ForEach([ServiceType.claude, ServiceType.codex], id: \.self) { service in
                    Button {
                        AccountRegistry.shared.addAccount(service: service) {
                            appState.reloadAccounts(interactive: false)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 10))
                            Text("\(service.displayName) \(L.addAccount)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding(8)

            Text(L.addPlanHint)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, registry.addStatus == nil ? 8 : 2)

            if let status = registry.addStatus {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .padding(4)
        .premiumCard()
    }

    private func aliasBinding(for account: ProviderAccount) -> Binding<String> {
        Binding(
            get: { AccountRegistry.shared.alias(for: account.id) ?? "" },
            set: { AccountRegistry.shared.setAlias($0, for: account.id) }
        )
    }

    private func accountSourceNote(_ account: ProviderAccount) -> String {
        let source: String
        if account.isDefault {
            source = "CLI 기본 계정"
        } else if account.id.contains(":own:") {
            source = "Token Burn에서 추가"
        } else {
            switch account.source {
            case .file: source = "외부 앱 관리 (파일)"
            case .keychain: source = "외부 앱 관리 (키체인)"
            }
        }
        return [account.planName, source].compactMap { $0 }.joined(separator: " · ")
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
