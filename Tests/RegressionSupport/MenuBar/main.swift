import AppKit
import SwiftUI
import AIUsageMeterCore

struct ProviderAccount { let id: String }
extension ServiceType {
    var brandColor: Color { Color(nsColor: self == .claude ? .systemOrange : .systemBlue) }
}
#if BASELINE
extension MenuBarIconRenderer { static func displayedLoad(_ value: Double) -> Double { value } }
#endif

// These are intentionally small, deterministic stand-ins for the app model. The
// production renderer is compiled into this executable; no app state, keychain,
// credentials, network, or live load sampling is used.
struct ServiceConfig {
    let id: UUID
    var serviceType: ServiceType
    var isEnabled: Bool
    var brandColor: Color { Color(nsColor: serviceType == .claude ? .systemOrange : .systemBlue) }
}

@MainActor final class ServiceViewModel {
    let id: UUID
    var config: ServiceConfig
    var usagePercentage: Double
    var fiveHourUsage: Double?
    var sevenDayUsage: Double?
    var isConsuming: Bool
    var account: ProviderAccount?
    init(_ type: ServiceType, usage: Double = 42, consuming: Bool = true) {
        id = UUID(); config = ServiceConfig(id: id, serviceType: type, isEnabled: true)
        usagePercentage = usage; fiveHourUsage = usage; sevenDayUsage = usage; isConsuming = consuming
    }
}

@MainActor final class AppState {
    var services: [ServiceViewModel] = []
    var menuBarNeedsRedraw = 0
}

@MainActor final class ThemeManager {
    var effectiveScheme: ColorScheme = .light
    var current: AppTheme { AppTheme(menuBar: MenuBarTheme()) }
}
struct MenuBarTheme { }
struct AppTheme { let menuBar: MenuBarTheme }

@MainActor final class SystemLoadMonitor {
    static let shared = SystemLoadMonitor()
    var cpu = 31.0; var gpu = 17.0; var ram = 53.0
    static func ramColor(_ value: Double) -> Color { Color(hue: min(max(value, 0), 100) / 300 + 0.5, saturation: 0.75, brightness: 0.95) }
}
enum AppDefaults {
    static let suiteName = "MenuBarRegression"
    static let userDefaults: UserDefaults = {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        return UserDefaults(suiteName: suiteName)!
    }()
}
@MainActor final class AccountRegistry {
    static let shared = AccountRegistry(); private var pinned = Set<String>()
    func isPinned(_ account: ProviderAccount) -> Bool { pinned.contains(account.id) }
    func pin(_ account: ProviderAccount) { pinned.insert(account.id) }
}

@MainActor final class RedrawHarness {
    let state = AppState(); let theme = ThemeManager(); var renders = 0
    private let gate = MenuBarRenderGate()
    func tick(force: Bool = false) {
        guard gate.shouldRender(appState: state, themeManager: theme, force: force) else { return }
        #if BASELINE
        let image = MenuBarIconRenderer.render(appState: state, themeManager: theme, animationDate: Date())
        #else
        let image = MenuBarIconRenderer.render(appState: state, themeManager: theme)
        #endif
        _ = image.tiffRepresentation
        renders += 1
    }
}

@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main struct Main {
    @MainActor static func main() {
        defer { UserDefaults.standard.removePersistentDomain(forName: AppDefaults.suiteName) }
        let h = RedrawHarness(); let claude = ServiceViewModel(.claude); let codex = ServiceViewModel(.codex, usage: 65)
        h.state.services = [claude, codex]; h.tick(force: true)
        let start = h.renders
        let begin = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - begin < 5 {
            #if BASELINE
            let image = MenuBarIconRenderer.render(appState: h.state, themeManager: h.theme, animationDate: Date())
            _ = image.tiffRepresentation
            h.renders += 1
            #else
            h.tick()
            #endif
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 12.0))
        }
        let idle = h.renders - start
        #if BASELINE
        check(idle > 20, "baseline heartbeat renders only \(idle) times")
        #else
        check(idle == 0, "unchanged state redraws \(idle) times")
        #endif
        let eventBase = h.renders
        claude.usagePercentage += 1; claude.fiveHourUsage = claude.usagePercentage; h.tick(); check(h.renders == eventBase + 1, "usage change redraw")
        codex.config.isEnabled = false; h.tick(); check(h.renders == eventBase + 2, "disabled service redraw")
        AppDefaults.userDefaults.set(false, forKey: "loadTabEnabled"); h.tick(); check(h.renders == eventBase + 3, "load toggle redraw")
        h.theme.effectiveScheme = .dark; h.tick(); check(h.renders == eventBase + 4, "appearance redraw")
        AppDefaults.userDefaults.set(true, forKey: "loadTabEnabled"); h.tick(); check(h.renders == eventBase + 5, "load re-enable redraw")
        #if BASELINE
        SystemLoadMonitor.shared.cpu = 31.4; h.tick(); check(h.renders == eventBase + 6, "baseline load redraw")
        SystemLoadMonitor.shared.cpu = 32.0; h.tick(); check(h.renders == eventBase + 7, "baseline whole-percent redraw")
        #else
        SystemLoadMonitor.shared.cpu = 31.4; h.tick(); check(h.renders == eventBase + 5, "sub-percent load does not redraw")
        SystemLoadMonitor.shared.cpu = 32.0; h.tick(); check(h.renders == eventBase + 6, "whole-percent load redraw")
        #endif
        codex.config.isEnabled = true
        let alternate = ServiceViewModel(.codex, usage: 90)
        h.state.services.append(alternate)
        let beforePin = h.renders
        AccountRegistry.shared.pin(ProviderAccount(id: codex.id.uuidString))
        codex.account = ProviderAccount(id: codex.id.uuidString)
        h.tick()
        check(h.renders == beforePin + 1, "pinned representative redraw")
        #if BASELINE
        let baseline = true
        #else
        let baseline = false
        #endif
        print("PASS baseline=\(baseline) renders=\(h.renders) unchanged5s=\(idle) elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - begin))s")
    }
}
