import SwiftUI
import AIUsageMeterCore

/// Skips menu-bar renders whose inputs haven't changed since the last one.
@MainActor
final class MenuBarRenderGate {
    private var lastSnapshot: IconSnapshot?

    func shouldRender(appState: AppState, themeManager: ThemeManager,
                      at date: Date = Date(), force: Bool = false) -> Bool {
        let snapshot = IconSnapshot(appState: appState, themeManager: themeManager, date: date)
        guard force || snapshot != lastSnapshot else { return false }
        lastSnapshot = snapshot
        return true
    }
}

/// Everything the menu-bar icon is drawn from, so identical frames can be told apart.
struct IconSnapshot: Equatable {
    struct Service: Equatable {
        let id: UUID
        let serviceType: String
        let usagePercentage: Double
        let fiveHourUsage: Double?
        let sevenDayUsage: Double?
        let isConsuming: Bool
        let beat: Double
    }

    let services: [Service]
    let redrawToken: Int
    let colorScheme: ColorScheme

    @MainActor
    init(appState: AppState, themeManager: ThemeManager, date: Date) {
        self.redrawToken = appState.menuBarNeedsRedraw
        self.services = ServiceType.allCases
            .compactMap { appState.menuBarRepresentative(for: $0) }
            .map {
                Service(
                    id: $0.id,
                    serviceType: $0.config.serviceType.rawValue,
                    usagePercentage: $0.usagePercentage,
                    fiveHourUsage: $0.fiveHourUsage,
                    sevenDayUsage: $0.sevenDayUsage,
                    isConsuming: $0.isConsuming,
                    beat: MenuBarIconRenderer.beat(for: $0, at: date)
                )
            }
        self.colorScheme = themeManager.effectiveScheme
    }
}
