import SwiftUI
import AppKit

@main
struct AIUsageMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var menuBarController: MenuBarPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarPanelController(
            title: "AI Usage",
            appState: appState,
            themeManager: ThemeManager.shared
        )
        menuBarController = controller

#if DEBUG
        if let path = ProcessInfo.processInfo.environment["AIM_SNAPSHOT_ONBOARDING_PATH"],
           !path.isEmpty {
            Task { @MainActor in
                await controller.debugSnapshotOnboardingPNG(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
#endif
    }
}
