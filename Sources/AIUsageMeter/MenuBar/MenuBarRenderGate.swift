import SwiftUI
import AIUsageMeterCore

@MainActor
final class MenuBarRenderGate {
    private var lastSnapshot: IconSnapshot?

    func shouldRender(appState: AppState, themeManager: ThemeManager, force: Bool = false) -> Bool {
        let snapshot = IconSnapshot(appState: appState, themeManager: themeManager)
        guard force || snapshot != lastSnapshot else { return false }
        lastSnapshot = snapshot
        return true
    }
}

struct IconSnapshot: Equatable {
    struct Service: Equatable {
        let id: UUID
        let serviceType: String
        let usagePercentage: Double
        let fiveHourUsage: Double?
        let sevenDayUsage: Double?
        let isConsuming: Bool
    }

    let services: [Service]
    let redrawToken: Int
    let loadEnabled: Bool
    let loadCPU: Double
    let loadGPU: Double
    let loadRAM: Double
    let colorScheme: ColorScheme

    @MainActor
    init(appState: AppState, themeManager: ThemeManager) {
        self.redrawToken = appState.menuBarNeedsRedraw
        self.services = MenuBarIconRenderer.mostConstrainedPerService(
            appState.services.filter { $0.config.isEnabled }
        ).map {
            Service(
                id: $0.id,
                serviceType: $0.config.serviceType.rawValue,
                usagePercentage: $0.usagePercentage,
                fiveHourUsage: $0.fiveHourUsage,
                sevenDayUsage: $0.sevenDayUsage,
                isConsuming: $0.isConsuming
            )
        }
        self.loadEnabled = AppDefaults.userDefaults.object(forKey: "loadTabEnabled") as? Bool ?? true
        self.loadCPU = loadEnabled ? MenuBarIconRenderer.displayedLoad(SystemLoadMonitor.shared.cpu) : 0
        self.loadGPU = loadEnabled ? MenuBarIconRenderer.displayedLoad(SystemLoadMonitor.shared.gpu) : 0
        self.loadRAM = loadEnabled ? MenuBarIconRenderer.displayedLoad(SystemLoadMonitor.shared.ram) : 0
        self.colorScheme = themeManager.effectiveScheme
    }
}
