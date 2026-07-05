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
