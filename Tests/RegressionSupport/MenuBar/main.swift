import AppKit
import SwiftUI
import AIUsageMeterCore

struct ProviderAccount { let id: String }
extension ServiceType {
    var brandColor: Color { Color(nsColor: self == .claude ? .systemOrange : .systemBlue) }
}

// These are intentionally small, deterministic stand-ins for the app model. The
// production renderer is compiled into this executable; no app state, keychain,
// credentials, network, or live sampling is used.
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

    /// Mirrors the app: a pinned login wins, else the first enabled one.
    func menuBarRepresentative(for service: ServiceType) -> ServiceViewModel? {
        let logins = services.filter { $0.config.isEnabled && $0.config.serviceType == service }
        return logins.first { $0.account.map(AccountRegistry.shared.isPinned) == true } ?? logins.first
    }
}

@MainActor final class ThemeManager {
    var effectiveScheme: ColorScheme = .light
    var current: AppTheme { AppTheme(menuBar: MenuBarTheme()) }
}
struct MenuBarTheme { }
struct AppTheme { let menuBar: MenuBarTheme }

@MainActor final class AccountRegistry {
    static let shared = AccountRegistry(); private var pinned = Set<String>()
    func isPinned(_ account: ProviderAccount) -> Bool { pinned.contains(account.id) }
    func pin(_ account: ProviderAccount) { pinned.insert(account.id) }
}

#if BASELINE
// The 36080fc renderer predates the pulse and still draws the load cell.
extension MenuBarIconRenderer {
    static func beat(for service: ServiceViewModel, at date: Date) -> Double { 0 }
}
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
#endif

@MainActor final class RedrawHarness {
    let state = AppState(); let theme = ThemeManager(); var renders = 0
    private let gate = MenuBarRenderGate()
    func tick(force: Bool = false) {
        let now = Date()
        guard gate.shouldRender(appState: state, themeManager: theme, at: now, force: force) else { return }
        let image = MenuBarIconRenderer.render(appState: state, themeManager: theme, animationDate: now)
        _ = image.tiffRepresentation
        renders += 1
    }
    /// Every tick renders: what the old 12 Hz heartbeat timer did.
    func renderUnconditionally() {
        let image = MenuBarIconRenderer.render(appState: state, themeManager: theme, animationDate: Date())
        _ = image.tiffRepresentation
        renders += 1
    }
}

@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@MainActor func run(seconds: TimeInterval, hertz: Double, _ body: () -> Void) {
    let begin = CFAbsoluteTimeGetCurrent()
    while CFAbsoluteTimeGetCurrent() - begin < seconds {
        body()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0 / hertz))
    }
}

@main struct Main {
    @MainActor static func main() {
        let h = RedrawHarness(); let claude = ServiceViewModel(.claude); let codex = ServiceViewModel(.codex, usage: 65)
        h.state.services = [claude, codex]; h.tick(force: true)

        // Agents consuming for five seconds, at each version's own frame rate.
        var start = h.renders
        #if BASELINE
        run(seconds: 5, hertz: 12) { h.renderUnconditionally() }
        #else
        run(seconds: 5, hertz: 5) { h.tick() }
        #endif
        let consuming = h.renders - start

        // Nothing consuming, nothing changing: no frames at all.
        claude.isConsuming = false; codex.isConsuming = false
        h.tick(force: true)
        start = h.renders
        #if BASELINE
        let idle = 0
        #else
        run(seconds: 2, hertz: 12) { h.tick() }
        let idle = h.renders - start
        check(idle == 0, "unchanged state redraws \(idle) times")
        check(consuming > 0, "a consuming agent must still pulse")
        #endif

        #if !BASELINE
        // Each input change draws exactly once.
        let eventBase = h.renders
        claude.usagePercentage += 1; claude.fiveHourUsage = claude.usagePercentage; h.tick(); check(h.renders == eventBase + 1, "usage change redraw")
        codex.config.isEnabled = false; h.tick(); check(h.renders == eventBase + 2, "disabled service redraw")
        h.theme.effectiveScheme = .dark; h.tick(); check(h.renders == eventBase + 3, "appearance redraw")
        codex.config.isEnabled = true; h.tick(); check(h.renders == eventBase + 4, "re-enabled service redraw")
        let alternate = ServiceViewModel(.codex, usage: 90, consuming: false)
        h.state.services.insert(alternate, at: 0)
        h.tick(); check(h.renders == eventBase + 5, "new representative redraw")
        AccountRegistry.shared.pin(ProviderAccount(id: codex.id.uuidString))
        codex.account = ProviderAccount(id: codex.id.uuidString)
        h.state.menuBarNeedsRedraw += 1
        h.tick(); check(h.renders == eventBase + 6, "pinned representative redraw")
        #endif

        #if BASELINE
        let baseline = true
        #else
        let baseline = false
        #endif
        print("PASS baseline=\(baseline) consuming5s=\(consuming) idle=\(idle)")
    }
}
