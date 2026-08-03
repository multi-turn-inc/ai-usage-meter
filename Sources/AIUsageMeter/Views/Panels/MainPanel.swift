import SwiftUI

struct MainPanel: View {
    @Bindable var appState: AppState
    @Binding var showSettings: Bool

    @State private var appeared = false
    @State private var showLegendHelp = false

    // Which view to show is driven by which menu-bar cell was clicked
    // (appState.panelTab), not an in-panel switcher.
    private var tab: PanelTab { loadTabEnabled ? appState.panelTab : .usage }
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
                    if tab == .load && loadTabEnabled {
                        LoadHelpContent()
                            .padding(14)
                            .frame(width: 280)
                    } else {
                        MenuBarLegendContent(showsDescription: true)
                            .padding(14)
                            .frame(width: 280)
                    }
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

            if tab == .load && loadTabEnabled {
                LoadView()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            } else {
                VStack(spacing: 14) {
                    // A grid, not an HStack: five gauges in a row are ~480pt wide
                    // and the panel is 300, so a row silently clipped the extras
                    // *and* dragged the cards below out of alignment.
                    LazyVGrid(columns: gaugeColumns, spacing: 12) {
                        ForEach(Array(gaugeServices.enumerated()), id: \.element.id) { index, service in
                            CircularGaugeView(
                                service: service,
                                compact: gaugeServices.count >= 3,
                                mini: gaugeServices.count > 3
                            )
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
                // Each account adds a card, so the stack grows without bound and
                // the window can only clip it. Cap the height and scroll instead;
                // the header and footer stay put.
                .scrollableIfTallerThan(420)
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

    /// One gauge per account. The menu-bar icon collapses to one cell per
    /// provider because its width is scarce; the panel has room, and seeing each
    /// login's headroom side by side is the point of tracking several.
    private var gaugeServices: [ServiceViewModel] {
        enabledServices
    }

    /// Up to three per row so the widest case (five mini gauges) wraps to two
    /// rows instead of overflowing the fixed-width panel.
    private var gaugeColumns: [GridItem] {
        let perRow = min(max(gaugeServices.count, 1), 3)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: perRow)
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
